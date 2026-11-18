import CoreGraphics
import Foundation

/// Где показывать зеркало и когда возвращать фокус. Чистая логика (координаты AppKit: начало слева снизу).
public enum FocusRules {
    public struct Screen: Equatable, Sendable {
        public var id: CGDirectDisplayID
        public var frame: CGRect
        public var visibleFrame: CGRect
        public init(id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect) {
            self.id = id
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    /// Экран для зеркала: тот, где курсор, если это настоящий экран; иначе первый (со строкой меню). Никогда — скрытый.
    /// 14.11: `NSWindow.center()` ставил зеркало на `NSScreen.main` — экран ключевого окна активной программы, а это был
    /// ChatGPT, чьё окно уже уехало на скрытый дисплей; зеркало открылось там, пользователь его не видел.
    public static func mirrorScreen(_ screens: [Screen], hidden: CGDirectDisplayID, mouse: CGPoint) -> Screen? {
        let real = screens.filter { $0.id != hidden }
        return real.first(where: { $0.frame.contains(mouse) }) ?? real.first
    }

    /// Рамка зеркала по центру видимой части экрана, не больше её.
    public static func centered(_ size: CGSize, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        return CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(), width: width, height: height)
    }

    /// Зеркало (рамка AppKit) хоть немного на скрытом дисплее — вернуть на настоящий экран.
    public static func needsRescue(mirror: CGRect, hiddenCocoa: CGRect) -> Bool {
        !hiddenCocoa.isNull && mirror.intersects(hiddenCocoa)
    }

    /// Программа ИИ стала активной сама (Dock, ⌘Tab, её собственная активация, наш щелчок не вернул фокус):
    /// вернуть активность Mac Utils, если зеркало на экране и курсор не передан программе (перетаскивание, меню).
    public static func shouldReclaim(activatedIsTarget: Bool, mirrorShown: Bool, handoff: HandoffKind?, stepsRunning: Bool) -> Bool {
        activatedIsTarget && mirrorShown && handoff == nil && !stepsRunning
    }
}

extension FocusRules {
    public enum KeyDecision: Equatable, Sendable {
        /// Не трогать: событие уходит активной программе как обычно.
        case pass
        /// Поглотить и отправить в программу ИИ.
        case forward
        /// Поглотить и никуда не отправлять (`MirrorKeys.route` → `.drop`).
        case drop
    }

    /// Клавиши при видимом зеркале. «Фокус у зеркала» — после щелчка по нему и до щелчка мимо или переключения программ.
    /// Пока курсор передан программе (меню, протягивание), она активна сама — клавиши идут ей напрямую.
    public static func keyDecision(code: CGKeyCode, flags: CGEventFlags, mirrorFocused: Bool, handoff: HandoffKind?) -> KeyDecision {
        guard mirrorFocused, handoff == nil else { return .pass }
        switch MirrorKeys.route(code: code, flags: flags) {
        case .forward: return .forward
        case .drop: return .drop
        case .keepLocal: return .pass
        }
    }

    /// Какую программу запомнить как «программу пользователя» (куда возвращать активность): обычную, не ИИ и не Mac Utils.
    public static func isUserApp(isRegular: Bool, isTarget: Bool, isSelf: Bool, bundleID: String?) -> Bool {
        isRegular && !isTarget && !isSelf && bundleID != "com.apple.loginwindow"
    }

    public enum ActivationReaction: Equatable, Sendable {
        /// Пользователь сам перешёл в другую программу: запомнить её, клавиши больше не перехватывать.
        case userSwitched
        /// ИИ стал активным не нашим шагом — вернуть активность программе пользователя.
        case reclaim
        case ignore
    }

    /// Уведомление «активной стала программа X». `isEcho` — эхо нашего возврата активности программе пользователя.
    /// Эхо активации самого ИИ в расчёт не берётся: 768c91b (14.11) после щелчка Claude через 0,1–1 с активировал себя
    /// сам (нажатие дошло до него уже неактивного), и уведомление об этом гасилось как «наше» — Claude оставался активным.
    /// Наша активация ИИ безвредна и без эха: пока идут шаги, возврата нет, а после них ИИ и так уже не активен.
    public static func reaction(isTarget: Bool, isSelf: Bool, isEcho: Bool, stepsRunning: Bool,
                                mirrorShown: Bool, handoff: HandoffKind?) -> ActivationReaction {
        if isTarget {
            return shouldReclaim(activatedIsTarget: true, mirrorShown: mirrorShown, handoff: handoff, stepsRunning: stepsRunning)
                ? .reclaim : .ignore
        }
        return isSelf || isEcho || stepsRunning ? .ignore : .userSwitched
    }

    /// Активация завершена, только когда и WindowServer, и `NSWorkspace` (уведомление программы) называют её.
    public static func activated(windowServer: pid_t?, workspace: pid_t?, pid: pid_t) -> Bool {
        windowServer == pid && workspace == pid
    }

    /// Повторные проверки «не активен ли снова ИИ» после возврата активности (секунды). Дальше — опрос раз в 0,25 с.
    public static let recheckDelays: [TimeInterval] = [0.15, 0.4, 1.0]
}

/// Не бороться с программой бесконечно: если ИИ снова и снова становится активным, после `maximum` возвратов за
/// `window` секунд — пауза до конца окна (и строка в журнал).
public struct ReclaimLimiter: Sendable {
    public static let window: TimeInterval = 3
    public static let maximum = 6
    private var times: [TimeInterval] = []

    public init() {}

    public mutating func allow(at time: TimeInterval) -> Bool {
        times = times.filter { time - $0 < Self.window }
        guard times.count < Self.maximum else { return false }
        times.append(time)
        return true
    }
}

/// Уведомление «активной стала программа X» приходит асинхронно — иногда уже после того, как наши шаги закончились.
/// Свои активации (ИИ на время щелчка, возврат программе пользователя) запоминаются на секунду и не принимаются
/// за действия пользователя (иначе возврат в Zoom после щелчка снимал бы фокус с зеркала).
public struct ActivationEcho: Sendable {
    private var expected: [pid_t: TimeInterval] = [:]
    public static let window: TimeInterval = 1.0

    public init() {}

    public mutating func note(_ pid: pid_t, at time: TimeInterval) {
        expected = expected.filter { time - $0.value < Self.window }
        expected[pid] = time
    }

    /// Это эхо нашей активации? (Да — забыть его.)
    public mutating func consume(_ pid: pid_t, at time: TimeInterval) -> Bool {
        guard let noted = expected[pid] else { return false }
        expected[pid] = nil
        return time - noted < Self.window
    }
}

/// Как активируется программа (ИИ на время щелчка, программа пользователя после него). С macOS 14 активация «вежливая»
/// и может молча не сработать; успех проверяется по `frontmostApplication`, а не по `NSApp.isActive` (14.11 тот дал ложный «успех»).
public enum ActivationMode: String, Sendable, CaseIterable {
    /// Сначала обычная активация, не стала активной за 80 мс — закрытая SkyLight `_SLPSSetFrontProcessWithOptions` (как AltTab, yabai).
    case auto
    /// Только обычная (для сравнения).
    case `public`
    /// Сразу SkyLight.
    case skylight
}

/// Журнал наведения: первое движение, каждое `every`-е и каждый уход с зеркала (проверка 643b753: одна строка — мало).
public enum HoverLog {
    public static let every = 25

    public static func shouldLog(count: Int, exit: Bool) -> Bool {
        exit || count == 1 || count % every == 0
    }
}

/// Нажатия в рамке зеркала, которые перехват пропустил: чьё окно было сверху.
enum MissedPressLog {
    static let limit = 20

    static func owner(of windowID: CGWindowID) -> String {
        guard windowID != 0,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first else { return "—" }
        let name = info[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = info[kCGWindowOwnerPID as String] as? Int ?? 0
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        return "\(name), pid \(pid), слой \(layer)"
    }
}

/// Как наведение над зеркалом доходит до окна ИИ.
/// 029aed9 (18.11): `mouseMoved` через `postToPid` доходил с верной точкой в окне, но подсветки не было — Chromium
/// подсвечивает, только если настоящий курсор над его окном (сверяет окно под `NSEvent.mouseLocation`).
public enum HoverMode: String, Sendable, CaseIterable {
    /// Курсор отдыхает над зеркалом `HoverPeek.dwell` — настоящий курсор уходит в ту же точку окна на скрытом дисплее
    /// (в зеркале на его месте рисуется курсор-подсказка, на основном экране он не прыгает), первое движение — назад.
    case peek
    /// Только `postToPid` (для сравнения; подсветки в Claude и ChatGPT нет).
    case pid
    case off
}

/// «Заглянуть» курсором в окно: когда.
public enum HoverPeek {
    public static let dwell: TimeInterval = 0.3

    /// Мышь ничем не занята, курсор над картинкой окна в зеркале и не двигался `dwell`.
    public static func shouldStart(idle: Bool, overContent: Bool, lastMove: TimeInterval, now: TimeInterval) -> Bool {
        idle && overContent && now - lastMove >= dwell - 0.01
    }

    /// Движение мыши заканчивает «заглядывание» — кроме нашего собственного события (метка) и события ровно в точке,
    /// куда мы курсор поставили.
    public static func endsPeek(isOwnEvent: Bool, location: CGPoint, peekPoint: CGPoint) -> Bool {
        // Порог 1 pt: после переноса курсора его положение может отличаться от цели на доли точки.
        !isOwnEvent && hypot(location.x - peekPoint.x, location.y - peekPoint.y) >= 1
    }
}

/// Видимость программ ИИ на выходе — как до включения (029aed9: Claude был виден, после выхода остался спрятан).
public enum VisibilityRestore {
    /// `wasHidden` — запомненное при включении (запущенные позже — видимы); `isHidden` — сейчас.
    public static func plan(wasHidden: [pid_t: Bool], isHidden: [pid_t: Bool]) -> (unhide: [pid_t], hide: [pid_t]) {
        var unhide: [pid_t] = [], hide: [pid_t] = []
        for (pid, hidden) in isHidden.sorted(by: { $0.key < $1.key }) {
            let before = wasHidden[pid] ?? false
            if hidden, !before { unhide.append(pid) }
            if !hidden, before { hide.append(pid) }
        }
        return (unhide, hide)
    }
}

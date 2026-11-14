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

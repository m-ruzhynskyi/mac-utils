import CoreGraphics

/// Программа, окна которой живут на скрытом дисплее.
public struct HiddenApp: Hashable, Sendable {
    public var name: String
    public var bundleIDs: Set<String>

    public init(name: String, bundleIDs: Set<String>) {
        self.name = name
        self.bundleIDs = bundleIDs
    }

    /// Claude.app (Electron) — проверено по Info.plist установленной программы.
    public static let claude = HiddenApp(name: "Claude", bundleIDs: ["com.anthropic.claudefordesktop"])
    /// ChatGPT.app: у установленной версии 26.1106 идентификатор `com.openai.codex` (по Info.plist, имя — ChatGPT),
    /// у прежних — `com.openai.chat`. Берём оба.
    public static let chatGPT = HiddenApp(name: "ChatGPT", bundleIDs: ["com.openai.chat", "com.openai.codex"])

    public func matches(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleIDs.contains(bundleID)
    }
}

/// Окно чужой программы, как его видно снаружи (`CGWindowListCopyWindowInfo` и/или AX).
public struct HiddenWindowInfo: Equatable, Sendable {
    public var id: CGWindowID
    public var pid: pid_t
    public var bundleID: String?
    /// Рамка в координатах Quartz.
    public var frame: CGRect
    /// `kCGWindowLayer`: 0 — обычные окна; меню, подсказки, всплывающие и плавающие панели — выше.
    public var layer: Int
    public var alpha: CGFloat

    public init(id: CGWindowID, pid: pid_t, bundleID: String?, frame: CGRect, layer: Int, alpha: CGFloat = 1) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
    }
}

public enum HiddenWindowAction: Equatable, Sendable {
    /// Обычное окно попало на настоящий дисплей — перенести (AX `AXPosition`) в эту точку скрытого дисплея.
    case move(CGWindowID, to: CGPoint)
    /// Меню, подсказка, плавающая панель или окно, которое AX не двигает, видно на настоящем дисплее.
    /// Перенести нельзя — только закрыть (Esc в процесс) или сообщить пользователю.
    case leak(CGWindowID, layer: Int)
}

public enum HiddenWindowRules {
    /// Меньше — служебные окна (часто 1×1 у Electron), их не трогаем.
    static let minimumSide: CGFloat = 4

    /// Слой всплывающих меню (`kCGPopUpMenuWindowLevel`): такие окна AX не двигает — их можно только закрыть.
    public static let popupLayer = 101

    /// Что сделать с окнами скрываемых программ, чтобы на настоящих дисплеях от них не осталось ни пикселя.
    /// Обычные и плавающие окна (слой < 101: окна, панели быстрого ввода, Sparkle) переносятся через AX;
    /// меню и подсказки (слой ≥ 101) — утечка.
    public static func plan(windows: [HiddenWindowInfo], apps: [HiddenApp], hidden: CGRect, physical: [CGRect]) -> [HiddenWindowAction] {
        windows.compactMap { window in
            guard apps.contains(where: { $0.matches(bundleID: window.bundleID) }),
                  window.alpha > 0, window.frame.width >= minimumSide, window.frame.height >= minimumSide,
                  let source = physical.first(where: { visibleArea(window.frame, $0) > 0 }) else { return nil }
            guard window.layer < popupLayer else { return .leak(window.id, layer: window.layer) }
            return .move(window.id, to: placement(of: window.frame, from: source, into: hidden))
        }
    }

    /// Есть ли у программы открытое меню на скрытом дисплее (для конца передачи курсора после правой кнопки).
    public static func hasMenu(windows: [HiddenWindowInfo], pid: pid_t, hidden: CGRect) -> Bool {
        windows.contains { $0.pid == pid && $0.layer >= popupLayer && hidden.intersects($0.frame) && $0.alpha > 0 }
    }

    /// Сколько обычных окон программы на скрытом дисплее (для меню и настроек: «2 окна на скрытом экране»).
    public static func hiddenWindowCount(windows: [HiddenWindowInfo], app: HiddenApp, hidden: CGRect) -> Int {
        windows.filter { app.matches(bundleID: $0.bundleID) && $0.layer == 0 && hidden.intersects($0.frame)
            && $0.alpha > 0 && $0.frame.width >= minimumSide && $0.frame.height >= minimumSide }.count
    }

    /// Куда вернуть окно при выключении: туда, где оно было до переноса, если тот дисплей ещё есть;
    /// иначе — то же место относительно скрытого дисплея на первом настоящем.
    public static func restoreOrigin(remembered: CGRect?, current: CGRect, hidden: CGRect, physical: [CGRect]) -> CGPoint? {
        if let remembered, physical.contains(where: { visibleArea(remembered, $0) > 0 }) { return remembered.origin }
        guard let first = physical.first else { return nil }
        return placement(of: current, from: hidden, into: first)
    }

    /// Новое начало окна на скрытом дисплее: то же место относительно дисплея, но целиком внутри.
    public static func placement(of frame: CGRect, from source: CGRect, into hidden: CGRect) -> CGPoint {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), max(low, high)) }
        return CGPoint(
            x: clamp(hidden.minX + frame.minX - source.minX, hidden.minX, hidden.maxX - frame.width),
            y: clamp(hidden.minY + frame.minY - source.minY, hidden.minY, hidden.maxY - frame.height))
    }

    static func visibleArea(_ frame: CGRect, _ display: CGRect) -> CGFloat {
        let overlap = frame.intersection(display)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    /// AX не отдаёт номер окна (`CGWindowID`) без закрытого `_AXUIElementGetWindow`, а ScreenCaptureKit ищет окно по номеру.
    /// Сопоставляем окно AX с окнами из `CGWindowListCopyWindowInfo` той же программы по рамке (слой 0, допуск 1 pt).
    public static func windowID(forAXFrame frame: CGRect, pid: pid_t, in windows: [HiddenWindowInfo]) -> CGWindowID? {
        let candidates = windows.filter {
            $0.pid == pid && $0.layer == 0
                && abs($0.frame.minX - frame.minX) <= 1 && abs($0.frame.minY - frame.minY) <= 1
                && abs($0.frame.width - frame.width) <= 1 && abs($0.frame.height - frame.height) <= 1
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    /// Какое окно показывать в зеркале: самое большое обычное окно программы на скрытом дисплее.
    public static func mirrorCandidate(windows: [HiddenWindowInfo], app: HiddenApp, hidden: CGRect) -> HiddenWindowInfo? {
        windows
            .filter { app.matches(bundleID: $0.bundleID) && $0.layer == 0 && hidden.intersects($0.frame) && $0.alpha > 0 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

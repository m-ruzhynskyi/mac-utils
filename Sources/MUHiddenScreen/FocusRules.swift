import CoreGraphics

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

/// Как Mac Utils возвращает себе активность. С macOS 14 активация «вежливая»: `NSApp.activate()` у программы,
/// которой пользователь не нажимал, игнорируется — а нажатие над зеркалом перехватывается и до Mac Utils не доходит.
public enum ActivationMode: String, Sendable, CaseIterable {
    /// Сначала обычная активация, не вышло за 80 мс — закрытая SkyLight `_SLPSSetFrontProcessWithOptions` (как AltTab, yabai).
    case auto
    /// Только обычная (для сравнения).
    case `public`
    /// Сразу SkyLight.
    case skylight
}

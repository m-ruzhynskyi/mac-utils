import AppKit
import CoreGraphics

/// Край экрана, у которого живёт Dock (`com.apple.dock orientation`; нет ключа — снизу).
public enum DockEdge: String, Equatable, Sendable {
    case bottom, left, right

    public init(orientation: String?) {
        self = orientation.flatMap(DockEdge.init(rawValue:)) ?? .bottom
    }
}

/// Dock в звонке (HSCR-43/45). Значки чужих программ из Dock не убрать: тип программы (`LSUIElement`) меняет только она
/// сама или её Info.plist (Claude.app/ChatGPT.app не трогаем), а настройки Dock применяются только перезапуском Dock.
///
/// HSCR-43 закрывал край Dock скрытым дисплеем, но на этом Mac любая перестановка дисплея идёт только с затемнением
/// системы (`CGConfigureDisplayFadeEffect` — 1006, HSCR-45): каждое ⌥⇧H мигало. Теперь дисплей не двигается, а Dock
/// не выезжает потому, что курсор, пока скрытый экран включён, не доходит до края с Dock (`DockEdgeGuard`) — на всех
/// мониторах. Работает при автоскрытии Dock; без него Dock виден всегда, и «Перед звонком» говорит об этом.
public enum DockAway {
    public enum Readiness: Equatable, Sendable {
        case disabled
        case ready
        case unavailable(String)
    }

    /// Ключ настройки «Убирать Dock с экрана в звонке» (по умолчанию — да).
    public static let enabledKey = "hiddenScreenDockAway"

    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    public static let noAutohideReason = "Dock не прячется сам — включите автоскрытие Dock (⌥⌘D)"

    /// Сработает ли: сторож края не даёт Dock выехать, но Dock без автоскрытия виден и так.
    public static func readiness(enabled: Bool, autohide: Bool?) -> Readiness {
        guard enabled else { return .disabled }
        return autohide == true ? .ready : .unavailable(noAutohideReason)
    }

    /// Край Dock (только чтение `com.apple.dock`).
    public static func edge() -> DockEdge {
        DockEdge(orientation: CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String)
    }
}

/// Курсор не доходит до края с Dock (HSCR-45): Dock с автоскрытием выезжает, только когда курсор упирается в этот край,
/// — сторож возвращает курсор на `margin` точек от края. Только на свободных участках края: там, где за краем другой
/// монитор (или скрытый дисплей), курсор проходит дальше как обычно.
public enum DockEdgeGuard {
    public static let margin: CGFloat = 3

    /// Участки края `edge` у `display`, за которыми нет соседних дисплеев (по x для низа, по y для боков).
    public static func freeSegments(_ display: CGRect, edge: DockEdge, neighbours: [CGRect]) -> [ClosedRange<CGFloat>] {
        let span: ClosedRange<CGFloat> = edge == .bottom ? display.minX...display.maxX : display.minY...display.maxY
        let blocked: [ClosedRange<CGFloat>] = neighbours.filter { $0 != display }.compactMap { other in
            let touches: Bool
            switch edge {
            case .bottom: touches = other.minY == display.maxY
            case .left: touches = other.maxX == display.minX
            case .right: touches = other.minX == display.maxX
            }
            guard touches else { return nil }
            let lower = max(span.lowerBound, edge == .bottom ? other.minX : other.minY)
            let upper = min(span.upperBound, edge == .bottom ? other.maxX : other.maxY)
            return lower < upper ? lower...upper : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var free: [ClosedRange<CGFloat>] = []
        var start = span.lowerBound
        for range in blocked {
            if range.lowerBound > start { free.append(start...range.lowerBound) }
            start = max(start, range.upperBound)
        }
        if start < span.upperBound { free.append(start...span.upperBound) }
        return free
    }

    /// Сколько точек от курсора до края Dock дисплея, на котором он; не на дисплее — бесконечность.
    public static func distance(_ point: CGPoint, edge: DockEdge, displays: [CGRect]) -> CGFloat {
        guard let display = displays.first(where: { $0.contains(point) }) else { return .greatestFiniteMagnitude }
        switch edge {
        case .bottom: return display.maxY - point.y
        case .left: return point.x - display.minX
        case .right: return display.maxX - point.x
        }
    }

    /// Куда вернуть курсор, если он в полосе `margin` у свободного участка края Dock какого-то дисплея; иначе nil.
    /// `displays` — настоящие дисплеи, `neighbours` — они же и скрытый дисплей.
    public static func clamp(_ point: CGPoint, edge: DockEdge, displays: [CGRect], neighbours: [CGRect], margin: CGFloat = margin) -> CGPoint? {
        guard let display = displays.first(where: { $0.contains(point) }) else { return nil }
        let along = edge == .bottom ? point.x : point.y
        guard freeSegments(display, edge: edge, neighbours: neighbours).contains(where: { $0.contains(along) }) else { return nil }
        switch edge {
        case .bottom:
            let limit = display.maxY - margin
            return point.y > limit ? CGPoint(x: point.x, y: limit) : nil
        case .left:
            let limit = display.minX + margin
            return point.x < limit ? CGPoint(x: limit, y: point.y) : nil
        case .right:
            let limit = display.maxX - margin
            return point.x > limit ? CGPoint(x: limit, y: point.y) : nil
        }
    }
}

/// Dock по намеренному жесту (HSCR-47): курсор, который упирается в край с Dock непрерывно `hold` секунд, сторож
/// пропускает — Dock выезжает (и виден в демонстрации, пока выдвинут). Случайное касание края Dock не вызывает.
/// Сторож снова держит край, когда курсор отойдёт от него больше чем на `rearm` точек.
public struct DockEdgeDwell: Equatable, Sendable {
    public static let hold: TimeInterval = 0.5
    /// Перерыв между движениями у края дольше этого — нажим прервался, отсчёт заново.
    public static let gap: TimeInterval = 0.3
    public static let rearm: CGFloat = 40

    public private(set) var pressingSince: TimeInterval?
    public private(set) var lastPress: TimeInterval = 0
    public private(set) var released = false

    public init() {}

    public enum Decision: Equatable, Sendable {
        /// Вернуть курсор от края.
        case clamp
        /// Пропустить: Dock выезжает. `justReleased` — впервые за этот нажим (строка в журнал).
        case pass(justReleased: Bool)
    }

    /// `atEdge` — курсор в полосе у свободного края (сторож вернул бы его); `distance` — сколько точек до края.
    public mutating func decide(atEdge: Bool, distance: CGFloat, now: TimeInterval) -> Decision {
        if released {
            if distance > Self.rearm { self = DockEdgeDwell() }
            return atEdge || distance <= Self.rearm ? .pass(justReleased: false) : .clamp
        }
        guard atEdge else {
            if distance > Self.rearm { pressingSince = nil }
            return .clamp
        }
        if let since = pressingSince, now - lastPress <= Self.gap {
            lastPress = now
            if now - since >= Self.hold {
                released = true
                return .pass(justReleased: true)
            }
        } else {
            pressingSince = now
            lastPress = now
        }
        return .clamp
    }
}

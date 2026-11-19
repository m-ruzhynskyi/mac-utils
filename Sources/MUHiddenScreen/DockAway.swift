import AppKit
import CoreGraphics

/// Край экрана, у которого живёт Dock (`com.apple.dock orientation`; нет ключа — снизу).
public enum DockEdge: String, Equatable, Sendable {
    case bottom, left, right

    public init(orientation: String?) {
        self = orientation.flatMap(DockEdge.init(rawValue:)) ?? .bottom
    }
}

/// Dock в звонке (HSCR-43). Значки чужих программ из Dock не убрать: тип программы (`LSUIElement`) меняет только она
/// сама или её Info.plist (Claude.app/ChatGPT.app не трогаем), а настройки Dock (`autohide-delay`, закреплённые)
/// применяются только перезапуском Dock — экран мигает, и запущенные программы в Dock всё равно остаются.
///
/// Работает раскладка: при «Отдельных пространствах на дисплеях» (по умолчанию) Dock живёт только на дисплее,
/// у которого край Dock свободен, — у мониторов, поставленных друг над другом, Dock бывает лишь на нижнем.
/// Скрытый дисплей встаёт вплотную под основной экран (или слева/справа — по краю Dock) и закрывает этот край целиком:
/// Dock уходит на скрытый дисплей, а курсор туда не пускает `pullBack` — Dock не выезжает нигде.
/// Раскладка — только на сеанс (`.forSession`), настройки Dock не меняются; при выключении дисплей уходит за угол.
public enum DockAway {
    public enum Plan: Equatable, Sendable {
        case place(CGPoint)
        case unavailable(String)
    }

    /// Готовность для проверки «Перед звонком».
    public enum Readiness: Equatable, Sendable {
        case disabled
        case ready
        case unavailable(String)
    }

    /// Ключ настройки «Убирать Dock с экрана в звонке» (по умолчанию — да).
    public static let enabledKey = "hiddenScreenDockAway"

    public static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    public static let spansDisplaysReason = "Dock всегда на основном экране: выключены отдельные пространства Spaces на дисплеях (Рабочий стол и Dock → Mission Control)"
    public static let occupiedReason = "У края экрана с Dock стоит другой монитор"
    public static let tooSmallReason = "Скрытый экран короче края с Dock"

    /// Размер скрытого дисплея: не меньше основного экрана, чтобы закрыть край Dock целиком.
    public static func displaySize(base: CGSize, main: CGRect) -> CGSize {
        guard !main.isNull, !main.isEmpty else { return base }
        return CGSize(width: max(base.width, main.width), height: max(base.height, main.height))
    }

    /// Куда поставить скрытый дисплей размера `size`, чтобы он закрыл край Dock основного экрана `main`.
    /// `others` — остальные настоящие дисплеи (без основного и без скрытого).
    public static func plan(edge: DockEdge, spansDisplays: Bool, main: CGRect, others: [CGRect], size: CGSize) -> Plan {
        if spansDisplays { return .unavailable(spansDisplaysReason) }
        let origin: CGPoint
        switch edge {
        case .bottom:
            guard size.width >= main.width else { return .unavailable(tooSmallReason) }
            origin = CGPoint(x: main.minX, y: main.maxY)
        case .left:
            guard size.height >= main.height else { return .unavailable(tooSmallReason) }
            origin = CGPoint(x: main.minX - size.width, y: main.minY)
        case .right:
            guard size.height >= main.height else { return .unavailable(tooSmallReason) }
            origin = CGPoint(x: main.maxX, y: main.minY)
        }
        let candidate = CGRect(origin: origin, size: size)
        // Другой монитор уже у этого края (или на месте скрытого) — macOS не даст встать вплотную.
        if others.contains(where: { $0.intersects(candidate) || touchesEdge($0, edge: edge, main: main) }) {
            return .unavailable(occupiedReason)
        }
        return .place(origin)
    }

    /// Закрыт ли край Dock основного экрана скрытым дисплеем целиком (фактическая рамка после раскладки).
    public static func covers(edge: DockEdge, hidden: CGRect, main: CGRect) -> Bool {
        switch edge {
        case .bottom: return hidden.minY == main.maxY && hidden.minX <= main.minX && hidden.maxX >= main.maxX
        case .left: return hidden.maxX == main.minX && hidden.minY <= main.minY && hidden.maxY >= main.maxY
        case .right: return hidden.minX == main.maxX && hidden.minY <= main.minY && hidden.maxY >= main.maxY
        }
    }

    /// Окно Dock (уровень Dock) на скрытом дисплее: Dock туда переехал и сам не вернётся, пока дисплей есть.
    public static func dockOn(_ display: CGRect, dockFrames: [CGRect]) -> Bool {
        dockFrames.contains { display.contains(CGPoint(x: $0.midX, y: $0.midY)) }
    }

    private static func touchesEdge(_ rect: CGRect, edge: DockEdge, main: CGRect) -> Bool {
        switch edge {
        case .bottom: return rect.minY == main.maxY && rect.maxX > main.minX && rect.minX < main.maxX
        case .left: return rect.maxX == main.minX && rect.maxY > main.minY && rect.minY < main.maxY
        case .right: return rect.minX == main.maxX && rect.maxY > main.minY && rect.minY < main.maxY
        }
    }

    // MARK: Чтение системы (только чтение)

    /// Край Dock и «одно пространство на все дисплеи» (`com.apple.spaces spans-displays`).
    public static func dockSettings() -> (edge: DockEdge, spansDisplays: Bool) {
        let orientation = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String
        let spans = (CFPreferencesCopyAppValue("spans-displays" as CFString, "com.apple.spaces" as CFString) as? NSNumber)?.boolValue ?? false
        return (DockEdge(orientation: orientation), spans)
    }

    /// Рамки видимых окон Dock уровня Dock (Quartz): по ним видно, на каком дисплее Dock.
    public static func dockFrames() -> [CGRect] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let level = Int(CGWindowLevelForKey(.dockWindow))
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == dock.processIdentifier,
                  (info[kCGWindowLayer as String] as? Int) == level,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 4, rect.height >= 4 else { return nil }
            return rect
        }
    }

    /// Настоящие дисплеи без скрытого (наш виртуальный узнаём по производителю «MU»).
    public static func physicalDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayVendorNumber($0) != HiddenDisplay.vendorID }
    }

    /// Для «Перед звонком»: сработает ли при текущей раскладке.
    public static func readiness(enabled: Bool = DockAway.isEnabled,
                                 base: CGSize = HiddenScreenOptions.defaultDisplaySize) -> Readiness {
        guard enabled else { return .disabled }
        let settings = dockSettings()
        let mainID = CGMainDisplayID()
        let main = CGDisplayBounds(mainID)
        let others = physicalDisplays().filter { $0 != mainID }.map(CGDisplayBounds)
        switch plan(edge: settings.edge, spansDisplays: settings.spansDisplays, main: main, others: others,
                    size: displaySize(base: base, main: main)) {
        case .place: return .ready
        case let .unavailable(reason): return .unavailable(reason)
        }
    }
}

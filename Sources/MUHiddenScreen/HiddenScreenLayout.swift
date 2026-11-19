import AppKit
import CoreGraphics
import MUCore

/// Как перестраивать раскладку (HSCR-44). 19.11 на Mac с Sidecar перестановка «без затемнения» вернула
/// `CGDisplayConfiguration: 1006` (`kCGErrorNotImplemented`) за 7 мс, а прежняя — с затемнением системы — с 14.11 по 18.11
/// работала. Поэтому пробуем по порядку и запоминаем первый сработавший способ на сеанс.
public struct LayoutAttempt: Equatable, Sendable, CustomStringConvertible {
    public enum Fade: String, Equatable, Sendable {
        /// `CGConfigureDisplayFadeEffect` с нулевым временем.
        case none = "без затемнения"
        /// Короткое затемнение (0,05 с) — если нулевое macOS не принимает.
        case short = "короткое затемнение"
        /// Без `CGConfigureDisplayFadeEffect`: затемнение системы (~0,3 + 0,5 с, заметное мигание).
        case system = "затемнение системы"
    }

    public enum Scope: String, Equatable, Sendable {
        case session = "на сеанс"
        /// `.forAppOnly`: раскладка живёт, пока жива Mac Utils.
        case app = "пока жива Mac Utils"
    }

    public var fade: Fade
    public var scope: Scope

    public init(_ fade: Fade, _ scope: Scope = .session) {
        self.fade = fade
        self.scope = scope
    }

    public var description: String { "\(fade.rawValue), \(scope.rawValue)" }

    /// Порядок: сначала без мигания, затемнение системы — последним.
    public static let order: [LayoutAttempt] = [LayoutAttempt(.none), LayoutAttempt(.short), LayoutAttempt(.none, .app), LayoutAttempt(.system)]

    /// Порядок с уже сработавшим способом первым.
    public static func order(preferred: LayoutAttempt?) -> [LayoutAttempt] {
        guard let preferred else { return order }
        return [preferred] + order.filter { $0 != preferred }
    }

    /// Что пробовать после отказа. Отказ на начале или на самой точке (`origin`) от затемнения не зависит — дальше не пробуем.
    public static func next(after failure: LayoutFailure, tried: [LayoutAttempt], preferred: LayoutAttempt?) -> LayoutAttempt? {
        guard failure.step == .fade || failure.step == .complete else { return nil }
        return order(preferred: preferred).first { !tried.contains($0) }
    }
}

/// На каком шаге macOS отказала и с каким кодом (`CGError`).
public struct LayoutFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Step: String, Equatable, Sendable {
        case begin = "CGBeginDisplayConfiguration"
        case fade = "CGConfigureDisplayFadeEffect"
        case origin = "CGConfigureDisplayOrigin"
        case complete = "CGCompleteDisplayConfiguration"
    }

    public var step: Step
    public var code: Int32

    public init(step: Step, code: Int32) {
        self.step = step
        self.code = code
    }

    public var description: String { "\(step.rawValue): \(code)" }
}

/// Раскладка дисплеев: скрытый дисплей — за угол или под край Dock, только на сеанс (после выхода раскладка прежняя).
@MainActor
enum HiddenScreenLayout {
    /// Способ, который сработал в этом запуске.
    static var working: LayoutAttempt?

    struct Result {
        var rect: CGRect
        /// Сработавший способ; nil — все отказали (или ставить не нужно было).
        var attempt: LayoutAttempt?
        var failures: [(LayoutAttempt, LayoutFailure)]
    }

    /// Поставить дисплей в `origin`, перебирая способы (`LayoutAttempt`). Каждый отказ — строка в журнал с шагом и кодом.
    static func place(_ id: CGDirectDisplayID, origin: CGPoint) -> Result {
        if CGDisplayBounds(id).origin == origin { return Result(rect: CGDisplayBounds(id), attempt: working, failures: []) }
        var tried: [LayoutAttempt] = []
        var failures: [(LayoutAttempt, LayoutFailure)] = []
        var attempt: LayoutAttempt? = LayoutAttempt.order(preferred: working).first
        while let current = attempt {
            tried.append(current)
            do {
                try apply(id, origin: origin, attempt: current)
                working = current
                if !failures.isEmpty || current.fade != .none {
                    Log.hiddenScreen.info("раскладка: сработал способ «\(current.description, privacy: .public)»")
                }
                return Result(rect: CGDisplayBounds(id), attempt: current, failures: failures)
            } catch let failure as LayoutFailure {
                failures.append((current, failure))
                Log.hiddenScreen.error("раскладка: «\(current.description, privacy: .public)» — отказ на \(failure.description, privacy: .public); \(layoutText(), privacy: .public)")
                attempt = LayoutAttempt.next(after: failure, tried: tried, preferred: working)
            } catch {
                attempt = nil
            }
        }
        return Result(rect: CGDisplayBounds(id), attempt: nil, failures: failures)
    }

    private static func apply(_ id: CGDirectDisplayID, origin: CGPoint, attempt: LayoutAttempt) throws {
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { throw LayoutFailure(step: .begin, code: error.rawValue) }
        switch attempt.fade {
        case .none: error = CGConfigureDisplayFadeEffect(config, 0, 0, 0, 0, 0)
        case .short: error = CGConfigureDisplayFadeEffect(config, 0.05, 0.05, 0, 0, 0)
        case .system: error = .success
        }
        guard error == .success else {
            CGCancelDisplayConfiguration(config)
            throw LayoutFailure(step: .fade, code: error.rawValue)
        }
        error = CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
        guard error == .success else {
            CGCancelDisplayConfiguration(config)
            throw LayoutFailure(step: .origin, code: error.rawValue)
        }
        error = CGCompleteDisplayConfiguration(config, attempt.scope == .app ? .forAppOnly : .forSession)
        guard error == .success else { throw LayoutFailure(step: .complete, code: error.rawValue) }
    }

    /// Начало «за углом» раскладки (`HiddenScreenGeometry.cornerOrigin`).
    static func cornerOrigin(_ id: CGDirectDisplayID) -> CGPoint {
        HiddenScreenGeometry.cornerOrigin(size: CGDisplayBounds(id).size, beside: HiddenDisplay.physicalDisplays(excluding: id))
    }

    /// Все активные дисплеи одной строкой: номер, рамка, основной/встроенный/скрытый, производитель/модель, имя.
    static func layoutText() -> String {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return "дисплеи: —" }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return "дисплеи: —" }
        let names = Dictionary(NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen.localizedName) } },
                               uniquingKeysWith: { first, _ in first })
        let items = ids.prefix(Int(count)).map { id -> String in
            let b = CGDisplayBounds(id)
            var marks: [String] = []
            if CGDisplayIsMain(id) != 0 { marks.append("основной") }
            if CGDisplayIsBuiltin(id) != 0 { marks.append("встроенный") }
            if CGDisplayVendorNumber(id) == HiddenDisplay.vendorID { marks.append("скрытый") }
            if CGDisplayIsInMirrorSet(id) != 0 { marks.append("зеркалирование") }
            let vendor = String(format: "%04X/%04X", CGDisplayVendorNumber(id), CGDisplayModelNumber(id))
            return "\(id) «\(names[id] ?? "?")» (\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))×\(Int(b.height))) \(vendor) \(marks.joined(separator: " "))"
        }
        return "дисплеи: " + items.joined(separator: "; ")
    }
}

import CoreGraphics
import Foundation

// Закрытый API CoreGraphics для виртуальных дисплеев (как в DeskPad/BetterDisplay; объявления — по DeskPad, MIT,
// https://github.com/Stengo/DeskPad, CGVirtualDisplayPrivate.h). Заголовков в SDK нет, классы есть в CoreGraphics.tbd.
// Описаны @objc-протоколами: вызовы идут через objc_msgSend с обычными правилами памяти, без отдельной C-цели
// (функциональный модуль может зависеть только от MUCore/MUDesign/MUAudio — scripts/check-module-deps.py).

@objc private protocol VirtualDisplayModeAPI: NSObjectProtocol {
    init(width: UInt, height: UInt, refreshRate: Double)
}

@objc private protocol VirtualDisplaySettingsAPI: NSObjectProtocol {
    init()
    var modes: [AnyObject] { get set }
    var hiDPI: UInt32 { get set }
}

@objc private protocol VirtualDisplayDescriptorAPI: NSObjectProtocol {
    init()
    var name: String { get set }
    var maxPixelsWide: UInt32 { get set }
    var maxPixelsHigh: UInt32 { get set }
    var sizeInMillimeters: CGSize { get set }
    var serialNum: UInt32 { get set }
    var productID: UInt32 { get set }
    var vendorID: UInt32 { get set }
    var terminationHandler: ((AnyObject?, AnyObject?) -> Void)? { get set }
    func setDispatchQueue(_ queue: DispatchQueue)
}

@objc private protocol VirtualDisplayAPI: NSObjectProtocol {
    init?(descriptor: AnyObject)
    var displayID: UInt32 { get }
    @objc(applySettings:) func applySettings(_ settings: AnyObject) -> Bool
}

/// Виртуальный дисплей через закрытый `CGVirtualDisplay` (на Mac пользователя создан 13.11).
/// Дисплей живёт, пока жив объект в создавшем процессе. Поэтому его держит процесс-помощник (`HiddenScreenHelper`):
/// при падении Mac Utils помощник сначала прячет программы, потом снимает дисплей.
public final class HiddenDisplay {
    public enum Failure: Error, Equatable {
        case classMissing
        case createFailed
        case settingsRejected
    }

    public let pointSize: CGSize
    public let hiDPI: Bool
    private var display: VirtualDisplayAPI?
    public var displayID: CGDirectDisplayID { display?.displayID ?? kCGNullDirectDisplay }

    public init(pointSize: CGSize = CGSize(width: 1440, height: 900), hiDPI: Bool = true) {
        self.pointSize = pointSize
        self.hiDPI = hiDPI
    }

    /// Класс по имени как тип с методами из протокола (протокол он формально не объявляет — проверка `as?` не прошла бы).
    private static func api<T>(_ name: String, as type: T.Type) -> T? {
        guard let cls = NSClassFromString(name) else { return nil }
        return unsafeBitCast(cls, to: type)
    }

    /// Создать дисплей. `onTerminate` — система сама сняла дисплей (например, после перезапуска WindowServer).
    public func open(onTerminate: @escaping () -> Void) throws {
        guard let descriptorType = Self.api("CGVirtualDisplayDescriptor", as: VirtualDisplayDescriptorAPI.Type.self),
              let displayType = Self.api("CGVirtualDisplay", as: VirtualDisplayAPI.Type.self),
              let settingsType = Self.api("CGVirtualDisplaySettings", as: VirtualDisplaySettingsAPI.Type.self),
              let modeType = Self.api("CGVirtualDisplayMode", as: VirtualDisplayModeAPI.Type.self) else { throw Failure.classMissing }
        let scale: CGFloat = hiDPI ? 2 : 1
        let descriptor = descriptorType.init()
        descriptor.setDispatchQueue(.main)
        // Имя видно в «Системных настройках → Дисплеи» и в списке экранов при выборе демонстрации (зрителям не показывается).
        descriptor.name = "Mac Utils"
        descriptor.maxPixelsWide = UInt32(pointSize.width * scale)
        descriptor.maxPixelsHigh = UInt32(pointSize.height * scale)
        // ~110 точек на дюйм: macOS считает дисплей обычным, а не телевизором.
        descriptor.sizeInMillimeters = CGSize(width: pointSize.width / 110 * 25.4, height: pointSize.height / 110 * 25.4)
        descriptor.vendorID = 0x4D55   // «MU»
        descriptor.productID = 0x4853  // «HS»
        descriptor.serialNum = 1
        descriptor.terminationHandler = { _, _ in onTerminate() }
        guard let display = displayType.init(descriptor: descriptor) else { throw Failure.createFailed }

        let settings = settingsType.init()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [modeType.init(width: UInt(pointSize.width), height: UInt(pointSize.height), refreshRate: 60)]
        guard display.applySettings(settings) else { throw Failure.settingsRejected }
        self.display = display
    }

    public var bounds: CGRect { displayID == kCGNullDirectDisplay ? .null : CGDisplayBounds(displayID) }

    /// Убрать дисплей. Окна, которые на нём остались, macOS перенесёт на настоящий экран — прятать программы до вызова.
    public func close() {
        display = nil
    }

    public static func physicalDisplays(excluding hidden: CGDirectDisplayID) -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { $0 != hidden }.map(CGDisplayBounds)
    }
}

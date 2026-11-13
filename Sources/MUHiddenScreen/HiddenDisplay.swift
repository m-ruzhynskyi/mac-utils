import CoreGraphics
import Foundation
import MUHiddenScreenPrivate

/// Виртуальный дисплей через закрытый `CGVirtualDisplay` (как DeskPad/BetterDisplay). Прототип: не запускался.
/// Дисплей живёт, пока жив объект `CGVirtualDisplay` в этом процессе: при выходе или падении Mac Utils
/// macOS убирает дисплей и переносит его окна на настоящие экраны — поэтому `close()` сначала прячет программы.
public final class HiddenDisplay {
    public enum Failure: Error, Equatable {
        case classMissing
        case createFailed
        case settingsRejected
        case configuration(CGError)
    }

    public let pointSize: CGSize
    public let hiDPI: Bool
    private var display: CGVirtualDisplay?
    public var displayID: CGDirectDisplayID { display?.displayID ?? kCGNullDirectDisplay }

    public init(pointSize: CGSize = CGSize(width: 1440, height: 900), hiDPI: Bool = true) {
        self.pointSize = pointSize
        self.hiDPI = hiDPI
    }

    /// Создать дисплей. `onTerminate` — система сама сняла дисплей (например, после перезапуска WindowServer).
    public func open(onTerminate: @escaping () -> Void) throws {
        guard NSClassFromString("CGVirtualDisplay") != nil else { throw Failure.classMissing }
        let scale: CGFloat = hiDPI ? 2 : 1
        let descriptor = CGVirtualDisplayDescriptor()
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
        guard let display = CGVirtualDisplay(descriptor: descriptor) else { throw Failure.createFailed }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(pointSize.width), height: UInt(pointSize.height), refreshRate: 60)]
        guard display.apply(settings) else { throw Failure.settingsRejected }
        self.display = display
    }

    /// Отодвинуть дисплей за угол раскладки (`HiddenScreenGeometry.cornerOrigin`). Только на сеанс: после выхода раскладка прежняя.
    @discardableResult
    public func moveBeyondCorner() throws -> CGRect {
        let id = displayID
        let others = Self.physicalDisplays(excluding: id)
        let origin = HiddenScreenGeometry.cornerOrigin(size: pointSize, beside: others)
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { throw Failure.configuration(error) }
        error = CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
        guard error == .success else {
            CGCancelDisplayConfiguration(config)
            throw Failure.configuration(error)
        }
        error = CGCompleteDisplayConfiguration(config, .forSession)
        guard error == .success else { throw Failure.configuration(error) }
        // macOS может поправить начало (связность раскладки) — возвращаем то, что получилось.
        return CGDisplayBounds(id)
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

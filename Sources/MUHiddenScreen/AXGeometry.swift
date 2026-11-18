import ApplicationServices
import CoreGraphics

/// Позиция и размер окна из ответа AX — с проверкой типа (не `as! AXValue`), и коды ошибок для журнала.
enum AXGeometry {
    static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint, AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize, AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Рамка окна и коды чтения AXPosition / AXSize (0 — успех).
    static func read(_ element: AXUIElement) -> (frame: CGRect?, positionError: Int32, sizeError: Int32) {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef)
        let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        guard positionError == .success, sizeError == .success,
              let origin = point(positionRef), let extent = size(sizeRef) else {
            return (nil, positionError.rawValue, sizeError.rawValue)
        }
        return (CGRect(origin: origin, size: extent), 0, 0)
    }
}

/// Заблокирован ли экран. 13.11 23:59 (`hidden-screen-test4.log`): активной была `com.apple.loginwindow` с окном
/// на весь экран (слой 2004) — Mac был заблокирован; AX при этом отдаёт окна чужих программ без позиции и размера,
/// и перенос невозможен. Движок в это время ждёт, а не пишет «утечки».
enum ScreenLock {
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return isLocked(session)
    }

    /// Ключи сессии: `CGSSessionScreenIsLocked` (экран заблокирован) и `kCGSSessionOnConsoleKey` (сессия не у консоли — другой пользователь).
    static func isLocked(_ session: [String: Any]) -> Bool {
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return true }
        return false
    }
}

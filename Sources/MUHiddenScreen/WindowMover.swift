import AppKit
import ApplicationServices
import MUCore

/// Окна чужих программ: список (CGWindowList) и перенос (AX). Нужен доступ «Универсальный доступ». Прототип: не запускался.
public final class WindowMover {
    public init() {}

    /// Видимые окна программ с этими pid (`kCGWindowListOptionOnScreenOnly` — окна всех дисплеев, включая скрытый).
    public func windows(pids: Set<pid_t>) -> [HiddenWindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return HiddenWindowInfo(id: id, pid: pid, bundleID: bundleID, frame: frame, layer: layer, alpha: alpha)
        }
    }

    /// Окна программы в AX с их рамками (координаты Quartz — как у CGWindowList).
    public func axWindows(pid: pid_t) -> [(element: AXUIElement, frame: CGRect)] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { element in frame(of: element).map { (element, $0) } }
    }

    public func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    @discardableResult
    public func move(_ element: AXUIElement, to origin: CGPoint) -> Bool {
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    public func resize(_ element: AXUIElement, to size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    /// Элемент AX окна с этим номером: сначала `_AXUIElementGetWindow` (MUCore `AXWindowID`), иначе — по рамке.
    public func element(for id: CGWindowID, pid: pid_t, known windows: [HiddenWindowInfo]) -> AXUIElement? {
        let candidates = axWindows(pid: pid)
        if let exact = candidates.first(where: { AXWindowID.of($0.element) == id }) { return exact.element }
        let same = windows.filter { $0.pid == pid }
        return candidates.first { HiddenWindowRules.windowID(forAXFrame: $0.frame, pid: pid, in: same) == id }?.element
    }

    /// Применить план. Возвращает то, что перенести не вышло (утечки из плана и окна, которые AX не сдвинул).
    /// `moved` — номер окна и рамка до переноса (чтобы при выключении вернуть окно на место).
    public func apply(_ actions: [HiddenWindowAction], windows: [HiddenWindowInfo],
                      moved: (CGWindowID, CGRect) -> Void = { _, _ in }) -> [HiddenWindowAction] {
        var failed: [HiddenWindowAction] = []
        for action in actions {
            guard case let .move(id, origin) = action,
                  let info = windows.first(where: { $0.id == id }) else { failed.append(action); continue }
            if let element = element(for: id, pid: info.pid, known: windows), move(element, to: origin) {
                moved(id, info.frame)
                continue
            }
            failed.append(.leak(id, layer: info.layer))
        }
        return failed
    }
}

/// Слежение AX за окнами программы: новое окно, перенос, смена размера → контроллер сразу пересчитывает план
/// (новое окно Electron успевает показаться на главном экране хотя бы на кадр — без запуска не проверить).
public final class WindowObserver {
    private var observer: AXObserver?
    private let app: AXUIElement
    private let onChange: () -> Void

    public init?(pid: pid_t, onChange: @escaping () -> Void) {
        self.app = AXUIElementCreateApplication(pid)
        self.onChange = onChange
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue().onChange()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return nil }
        observer = created
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXWindowMovedNotification, kAXWindowResizedNotification,
                     kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }
}

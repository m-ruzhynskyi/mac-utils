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
        AXWindowSource.windows(pid: pid).elements.compactMap { element in frame(of: element).map { (element, $0) } }
    }

    public func frame(of element: AXUIElement) -> CGRect? {
        AXGeometry.read(element).frame
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

    /// Окна AX программы и код ошибки запроса списка (для журнала).
    public func axCandidates(pid: pid_t) -> (windows: [(element: AXUIElement, windowID: CGWindowID?, frame: CGRect)], error: AXError, source: String) {
        let found = AXWindowSource.windows(pid: pid)
        return (found.elements.compactMap { element in frame(of: element).map { (element, AXWindowID.of(element), $0) } },
                found.error, found.source)
    }

    /// Элемент AX окна с этим номером (`HiddenWindowRules.pickAXWindow`).
    public func element(for id: CGWindowID, pid: pid_t, known windows: [HiddenWindowInfo]) -> AXUIElement? {
        guard let frame = windows.first(where: { $0.id == id })?.frame else { return nil }
        let candidates = axCandidates(pid: pid).windows
        return HiddenWindowRules.pickAXWindow(id: id, frame: frame, candidates: candidates.map { ($0.windowID, $0.frame) })
            .map { candidates[$0].element }
    }

    /// Результат переноса: новая рамка или подробности для журнала.
    public enum MoveOutcome {
        case moved(CGRect)
        case failed(String)
    }

    /// Перенести окно `id` в точку: позиция; не доехало — позиция, размер и ещё раз позиция (как `WindowTiler.setFrame`:
    /// при переезде на другой дисплей macOS может подрезать размер). Успех — по фактической рамке, а не по коду AX.
    public func moveWindow(id: CGWindowID, pid: pid_t, known windows: [HiddenWindowInfo], to origin: CGPoint) -> MoveOutcome {
        guard let info = windows.first(where: { $0.id == id }) else { return .failed("окна \(id) нет в списке") }
        let lookup = axCandidates(pid: pid)
        let candidates = lookup.windows
        guard let index = HiddenWindowRules.pickAXWindow(id: id, frame: info.frame, candidates: candidates.map { ($0.windowID, $0.frame) }) else {
            let list = candidates.map { "\($0.windowID.map(String.init) ?? "?")@\(Self.text($0.frame))" }.joined(separator: ", ")
            return .failed("AX: окно не найдено (kAXWindows: \(lookup.error.rawValue), источник \(lookup.source), окон AX \(candidates.count): [\(list)], ищу \(id)@\(Self.text(info.frame)), доверие AX \(AXIsProcessTrusted() ? 1 : 0))")
        }
        let element = candidates[index].element
        var point = origin
        guard let position = AXValueCreate(.cgPoint, &point) else { return .failed("AXValueCreate") }
        let first = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        if let now = frame(of: element), HiddenWindowRules.arrived(now, at: origin) { return .moved(now) }
        var size = info.frame.size
        let extent = AXValueCreate(.cgSize, &size)
        let sized = extent.map { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, $0) } ?? .failure
        let second = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, position)
        let after = frame(of: element)
        if HiddenWindowRules.arrived(after, at: origin) { return .moved(after ?? info.frame) }
        return .failed("AXPosition \(first.rawValue)/\(second.rawValue), AXSize \(sized.rawValue), рамка после: \(after.map(Self.text) ?? "—"), цель \(Int(origin.x)),\(Int(origin.y))")
    }

    static func text(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))×\(Int(rect.height))"
    }

    /// Применить план. Возвращает то, что перенести не вышло: утечки из плана и окна, которые AX не сдвинул
    /// (с причиной — для журнала). `moved` — номер окна и рамка до переноса (чтобы при выключении вернуть на место).
    public func apply(_ actions: [HiddenWindowAction], windows: [HiddenWindowInfo],
                      moved: (CGWindowID, CGRect) -> Void = { _, _ in }) -> [(action: HiddenWindowAction, reason: String)] {
        var failed: [(HiddenWindowAction, String)] = []
        for action in actions {
            switch action {
            case let .leak(_, layer):
                failed.append((action, "слой \(layer): меню или подсказка, AX не переносит"))
            case let .move(id, origin):
                guard let info = windows.first(where: { $0.id == id }) else { continue }
                switch moveWindow(id: id, pid: info.pid, known: windows, to: origin) {
                case .moved: moved(id, info.frame)
                case let .failed(reason): failed.append((.leak(id, layer: info.layer), reason))
                }
            }
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

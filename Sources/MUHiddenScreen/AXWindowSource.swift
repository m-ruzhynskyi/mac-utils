import AppKit
import ApplicationServices
import MUCore

/// Окна программы через AX — с запасными источниками. 13.11 (`hidden-screen-test3.log`): `kAXWindows` отвечал «успех»,
/// а окон не было ни одного — ни у Claude, ни у ChatGPT (и переключатель того же процесса видел 0 окон).
enum AXWindowSource {
    struct Result {
        var elements: [AXUIElement]
        var error: AXError
        /// Откуда окна: windows, values, children, focused/main, none.
        var source: String
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        return app
    }

    /// `kAXWindows` (с повтором при `cannotComplete`, как `WindowTiler`) → `AXUIElementCopyAttributeValues` →
    /// дети с ролью AXWindow → главное и ключевое окно.
    static func windows(pid: pid_t) -> Result {
        let app = application(pid)
        var value: CFTypeRef?
        var error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if error == .cannotComplete { error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) }
        let listed = elements(value)
        if !listed.isEmpty { return Result(elements: listed, error: error, source: "windows") }

        var values: CFArray?
        if AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 64, &values) == .success {
            let ranged = elements(values)
            if !ranged.isEmpty { return Result(elements: ranged, error: error, source: "values") }
        }

        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children) == .success {
            let windows = elements(children).filter { string($0, kAXRoleAttribute) == kAXWindowRole as String }
            if !windows.isEmpty { return Result(elements: windows, error: error, source: "children") }
        }

        var extra: [AXUIElement] = []
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var window: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &window) == .success, let window,
                  CFGetTypeID(window) == AXUIElementGetTypeID() else { continue }
            let element = window as! AXUIElement
            if !extra.contains(where: { CFEqual($0, element) }) { extra.append(element) }
        }
        return Result(elements: extra, error: error, source: extra.isEmpty ? "none" : "focused/main")
    }

    /// Массив AXUIElement из ответа AX без мостика `as? [AXUIElement]` (проверяется тип каждого элемента).
    static func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let array = value as! CFArray
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(array, index) else { return nil }
            let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (object as! AXUIElement)
        }
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func typeName(_ value: CFTypeRef?) -> String {
        guard let value else { return "nil" }
        return (CFCopyTypeIDDescription(CFGetTypeID(value)) as String?) ?? "?"
    }
}

/// `--hs-ax-dump`: при старте — что видит AX у каждой программы списка и у контрольных (Finder, активная программа).
/// Если и у Finder 0 окон — дело не в движке, а в доверии AX этой сборки (TCC по подписи; переразрешить «Универсальный доступ»).
@MainActor
enum AXDump {
    static let flag = "--hs-ax-dump"

    static func run(apps: [HiddenApp], mover: WindowMover) {
        let me = Bundle.main
        emit("AX-дамп: доверие \(AXIsProcessTrusted() ? 1 : 0), Mac Utils pid \(getpid()), \(me.bundlePath)")
        var targets: [(String, NSRunningApplication)] = []
        for running in NSWorkspace.shared.runningApplications {
            if let app = apps.first(where: { $0.matches(bundleID: running.bundleIdentifier) }) { targets.append((app.name, running)) }
        }
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            targets.append(("контроль Finder", finder))
        }
        if let front = NSWorkspace.shared.frontmostApplication, !targets.contains(where: { $0.1 == front }) {
            targets.append(("контроль активная \(front.bundleIdentifier ?? "?")", front))
        }
        for (name, running) in targets {
            let pid = running.processIdentifier
            let cgWindows = mover.windows(pids: [pid])
            let app = AXWindowSource.application(pid)
            var axPid: pid_t = 0
            AXUIElementGetPid(app, &axPid)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
            var children: CFTypeRef?
            let childrenError = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &children)
            let found = AXWindowSource.windows(pid: pid)
            let role = AXWindowSource.string(app, kAXRoleAttribute) ?? "—"
            emit(AXDumpFormat.line(name: name, bundleID: running.bundleIdentifier, pid: pid, axPid: axPid, hidden: running.isHidden,
                                   cgWindows: cgWindows.map { ($0.id, $0.frame, $0.layer) },
                                   windowsError: error.rawValue, windowsType: AXWindowSource.typeName(value),
                                   windowsCount: AXWindowSource.elements(value).count,
                                   childrenError: childrenError.rawValue, childrenCount: AXWindowSource.elements(children).count,
                                   appRole: role, source: found.source,
                                   axWindows: found.elements.map { element in (AXWindowID.of(element), mover.frame(of: element)) }))
        }
    }

    private static func emit(_ text: String) {
        Log.hiddenScreen.error("\(text, privacy: .public)")
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// Строка AX-дампа (без системы — для теста формата).
enum AXDumpFormat {
    static func line(name: String, bundleID: String?, pid: pid_t, axPid: pid_t, hidden: Bool,
                     cgWindows: [(CGWindowID, CGRect, Int)], windowsError: Int32, windowsType: String, windowsCount: Int,
                     childrenError: Int32, childrenCount: Int, appRole: String, source: String,
                     axWindows: [(CGWindowID?, CGRect?)]) -> String {
        func rect(_ r: CGRect?) -> String {
            guard let r else { return "—" }
            return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))"
        }
        let cg = cgWindows.map { "\($0.0)@\(rect($0.1))/слой \($0.2)" }.joined(separator: ", ")
        let ax = axWindows.map { "\($0.0.map(String.init) ?? "?")@\(rect($0.1))" }.joined(separator: ", ")
        return "AX-дамп: \(name) [\(bundleID ?? "?")] pid \(pid) (AX pid \(axPid))\(hidden ? " скрыта" : ""); роль \(appRole); "
            + "CG окон \(cgWindows.count): [\(cg)]; kAXWindows: код \(windowsError), тип \(windowsType), элементов \(windowsCount); "
            + "kAXChildren: код \(childrenError), элементов \(childrenCount); итог \(source): [\(ax)]"
    }
}

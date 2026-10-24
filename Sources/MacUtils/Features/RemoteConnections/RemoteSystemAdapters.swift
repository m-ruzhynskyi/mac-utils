import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MURemoteConnections
import Security
import MUScreenshot
import MUTextEditor

/// Элемент интерфейса AnyDesk/TeamViewer через AXUIElement. Значение защищённого поля не читается — только
/// `AXNumberOfCharacters`.
final class SystemAXNode: AXNode {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
        // Зависшая программа не должна держать главный поток дольше полсекунды на вызов.
        AXUIElementSetMessagingTimeout(element, 0.5)
    }

    private func attribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func element(_ name: String) -> AXUIElement? {
        guard let value = attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Роль, подписи и дети — одним запросом на узел и до конца жизни узла: окна читаются заново на каждом опросе,
    /// а за опрос дерево обходится несколько раз (большое главное окно AnyDesk, rc-console2). Значение (`AXValue`)
    /// сюда не входит: у полей оно не читается вовсе, у надписей — отдельно, у галочек — каждый раз заново.
    private lazy var basics: [String: CFTypeRef] = {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                     kAXPlaceholderValueAttribute, kAXChildrenAttribute]
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0),
                                                     &values) == .success,
              let list = values as? [AnyObject], list.count == names.count else { return [:] }
        var out: [String: CFTypeRef] = [:]
        for (name, value) in zip(names, list) {
            // Атрибута нет — на его месте AXValue с ошибкой.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            out[name] = value
        }
        return out
    }()

    var role: String? { basics[kAXRoleAttribute] as? String }
    var subrole: String? { basics[kAXSubroleAttribute] as? String }

    private lazy var staticText: String? = attribute(kAXValueAttribute) as? String

    var label: String? {
        switch role {
        case kAXStaticTextRole: return staticText
        case kAXTextFieldRole, kAXTextAreaRole, "AXSecureTextField": return nil
        default: return basics[kAXTitleAttribute] as? String
        }
    }

    private(set) lazy var children: [AXNode] = {
        guard let list = basics[kAXChildrenAttribute] as? [AnyObject] else { return [] }
        return list.compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? SystemAXNode(item as! AXUIElement) : nil
        }
    }()

    var processID: Int32? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    var valueLength: Int? { (attribute(kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue }

    var placeholder: String? { basics[kAXPlaceholderValueAttribute] as? String }
    var detail: String? { basics[kAXDescriptionAttribute] as? String }

    var isChecked: Bool? {
        guard role == kAXCheckBoxRole || role == kAXRadioButtonRole else { return nil }
        return (attribute(kAXValueAttribute) as? NSNumber).map { $0.intValue == 1 }
    }

    var defaultButton: AXNode? { element(kAXDefaultButtonAttribute).map(SystemAXNode.init) }

    func isSame(as other: AXNode) -> Bool {
        guard let other = other as? SystemAXNode else { return false }
        return CFEqual(element, other.element)
    }

    /// CFString из байтов создаётся прямо перед вызовом и сразу отпускается. Затереть её нельзя —
    /// это честное ограничение AX; посимвольный ввод ниже обходится без строк.
    func setSecretValue(_ secret: SecretBuffer) -> Bool {
        secret.withBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  let string = CFStringCreateWithBytes(nil, base, raw.count, CFStringBuiltInEncodings.UTF8.rawValue, false)
            else { return false }
            return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, string) == .success
        }
    }

    /// Только не секретный текст (ID компьютера).
    func setText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success
    }

    func clearValue() -> Bool {
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, "" as CFString) == .success
    }

    func focus() -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    func press() -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
}

/// «Универсальный доступ» только проверяется: запрос разрешения — кнопкой в HUD/настройках, не отсюда.
final class SystemAXAccess: AXAccess {
    var isTrusted: Bool { AXIsProcessTrusted() }

    private func app(_ pid: Int32) -> SystemAXNode { SystemAXNode(AXUIElementCreateApplication(pid)) }

    func windows(ofProcess pid: Int32) -> [AXNode] {
        let app = app(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app.element, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AnyObject] else { return [] }
        return list.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? SystemAXNode($0 as! AXUIElement) : nil }
    }

    func focusedElement(ofProcess pid: Int32) -> AXNode? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app(pid).element, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return SystemAXNode(value as! AXUIElement)
    }
}

final class WorkspaceLauncher: AppLauncher {
    func isInstalled(bundleID: String) -> Bool { appURL(bundleID: bundleID) != nil }

    func appURL(bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }

    func runningProcess(bundleID: String) -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }?.processIdentifier
    }

    func bundleID(ofProcess pid: Int32) -> String? { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier }

    var frontmostProcess: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// Team ID работающего процесса — только если его подпись действительна и выдана Apple разработчику.
    func teamID(ofProcess pid: Int32) -> String? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic" as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    func activate(process pid: Int32) { NSRunningApplication(processIdentifier: pid)?.activate() }
}

/// Нажатия только в процесс программы (`postToPid`), не в общий поток событий.
final class ProcessKeyboard: KeyboardSender {
    private let source = CGEventSource(stateID: .privateState)

    func type(_ units: UnsafeBufferPointer<UInt16>, to pid: Int32) {
        guard let base = units.baseAddress else { return }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
            event.postToPid(pid)
        }
    }

    func pressReturn(to pid: Int32) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Return), keyDown: down) else { continue }
            event.flags = []
            event.postToPid(pid)
        }
    }
}

/// Звонок: открыть `tel:` именно в UniTalk. `NSWorkspace.open(_:withApplicationAt:)` обработчик по умолчанию не меняет.
/// `completion(false)` — UniTalk не открылся (ошибка в completion `NSWorkspace.open`); вызывается на главном потоке.
protocol RemoteDialer: AnyObject {
    func appURL(bundleID: String) -> URL?
    func open(_ url: URL, withApplicationAt app: URL, completion: @escaping @MainActor (Bool) -> Void)
}

final class WorkspaceDialer: RemoteDialer {
    func appURL(bundleID: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    func open(_ url: URL, withApplicationAt app: URL, completion: @escaping @MainActor (Bool) -> Void) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            let ok = error == nil
            Task { @MainActor in completion(ok) }
        }
    }
}

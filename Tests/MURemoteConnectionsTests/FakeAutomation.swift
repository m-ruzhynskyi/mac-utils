import Foundation
@testable import MURemoteConnections

/// Элемент выдуманного окна AnyDesk/TeamViewer. Поле хранит введённое — это «чужая программа», ей пароль и нужен.
final class FakeNode: AXNode {
    var role: String?
    var subrole: String?
    var label: String?
    var placeholder: String?
    var detail: String?
    var kids: [FakeNode]
    var processID: Int32?
    var value: [UInt16] = []
    var acceptsAXValue = true
    /// AX ответил «успешно», но значение не записалось.
    var swallowsAXValue = false
    /// AX сообщает длину (у части программ не сообщает).
    var reportsLength = true
    var focusable = true
    var isChecked: Bool?
    var onPress: (() -> Void)?
    weak var defaultButtonNode: FakeNode?
    weak var ax: FakeAX?

    init(_ role: String, subrole: String? = nil, label: String? = nil, pid: Int32? = nil, children: [FakeNode] = []) {
        self.role = role
        self.subrole = subrole
        self.label = label
        self.processID = pid
        self.kids = children
    }

    var children: [AXNode] { kids }
    var valueLength: Int? { reportsLength ? value.count : nil }
    var defaultButton: AXNode? { defaultButtonNode }
    var text: String { String(decoding: value, as: UTF16.self) }

    func isSame(as other: AXNode) -> Bool { self === other }

    func setSecretValue(_ secret: SecretBuffer) -> Bool {
        guard acceptsAXValue else { return false }
        if swallowsAXValue { return true }
        value = secret.withBytes { Array(String(decoding: $0, as: UTF8.self).utf16) }
        return true
    }

    func setText(_ text: String) -> Bool {
        guard acceptsAXValue else { return false }
        value = Array(text.utf16)
        return true
    }

    func clearValue() -> Bool { value = []; return true }

    func focus() -> Bool {
        guard focusable, let pid = processID else { return false }
        ax?.focused[pid] = self
        return true
    }

    /// AX отказал в нажатии (`AXPress` вернул ошибку): ничего не меняется.
    var pressFails = false

    func press() -> Bool {
        if pressFails { return false }
        if isChecked != nil { isChecked?.toggle() }
        onPress?()
        return true
    }

    /// Все элементы поддерева.
    func descendants() -> [FakeNode] { [self] + kids.flatMap { $0.descendants() } }
}

final class FakeAX: AXAccess {
    var isTrusted = true
    var windows: [Int32: [FakeNode]] = [:]
    var focused: [Int32: FakeNode] = [:]

    func windows(ofProcess pid: Int32) -> [AXNode] { windows[pid] ?? [] }
    func focusedElement(ofProcess pid: Int32) -> AXNode? { focused[pid] }

    func show(_ window: FakeNode, pid: Int32) {
        for node in window.descendants() { node.ax = self; node.processID = node.processID ?? pid }
        windows[pid, default: []].append(window)
    }

    /// Как настоящая программа: окно пароля закрылось — открылось окно сеанса с ID в заголовке.
    /// Тесты «сеанса нет» выключают это.
    var sessionAfterPassword = true

    func close(_ window: FakeNode, pid: Int32) {
        windows[pid]?.removeAll { $0 === window }
        guard sessionAfterPassword, window.descendants().contains(where: { $0.subrole == "AXSecureTextField" }),
              let id = FakeLauncher.current?.openedID else { return }
        show(FakeNode("AXWindow", subrole: "AXStandardWindow", label: "Сеанс \(id)", children: [FakeNode("AXGroup")]), pid: pid)
    }
}

final class FakeLauncher: AppLauncher {
    var installed: Set<String> = [RemoteProgram.anyDesk.bundleID, RemoteProgram.teamViewer.bundleID]
    /// bundle id → pid запущенных программ.
    var running: [String: Int32] = [:]
    /// pid → bundle id (можно подменить, чтобы проверить проверку bundle id).
    var bundles: [Int32: String] = [:]
    /// pid → Team ID подписи (по умолчанию — настоящий у запущенной программы).
    var teams: [Int32: String] = [:]
    var frontmostProcess: Int32? = 1
    var opened: [URL] = []
    var openSucceeds = true
    /// Программа выходит вперёд по `activate`.
    var activationWorks = true
    var onOpen: ((URL) -> Void)?
    /// Последний созданный — для окна сеанса в `FakeAX.close`.
    nonisolated(unsafe) static weak var current: FakeLauncher?

    init() { FakeLauncher.current = self }

    /// ID из последней открытой ссылки (`anydesk:ID`, `teamviewer10://control?device=ID`).
    var openedID: String? {
        guard let url = opened.last?.absoluteString else { return nil }
        if let r = url.range(of: "device=") { return String(url[r.upperBound...]) }
        if url.hasPrefix("anydesk:") { return String(url.dropFirst("anydesk:".count)) }
        return nil
    }

    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }

    func open(_ url: URL) -> Bool {
        guard openSucceeds else { return false }
        opened.append(url)
        onOpen?(url)
        return true
    }

    /// Другие процессы с тем же bundle id (у AnyDesk — `--control`, `--local-service`): без окон и старше интерфейса,
    /// поэтому, как у `NSRunningApplication`, первые в списке.
    var helpers: [String: [Int32]] = [:]

    func runningProcess(bundleID: String) -> Int32? { helpers[bundleID]?.first ?? running[bundleID] }
    func runningProcesses(bundleID: String) -> [Int32] { (helpers[bundleID] ?? []) + (running[bundleID].map { [$0] } ?? []) }

    /// Фоновый процесс программы (настоящая подпись, без окон).
    func addHelper(_ program: RemoteProgram, pid: Int32) {
        helpers[program.bundleID, default: []].append(pid)
        bundles[pid] = program.bundleID
        teams[pid] = program.teamID
    }
    func bundleID(ofProcess pid: Int32) -> String? { bundles[pid] }
    func teamID(ofProcess pid: Int32) -> String? { teams[pid] }

    func activate(process pid: Int32) { if activationWorks { frontmostProcess = pid } }

    func launch(_ program: RemoteProgram, pid: Int32) {
        running[program.bundleID] = pid
        bundles[pid] = program.bundleID
        teams[pid] = program.teamID
    }
}

/// Нажатия: печатает в поле с фокусом процесса-адресата (как сделала бы программа).
final class FakeKeyboard: KeyboardSender {
    let ax: FakeAX
    var typed: [(pid: Int32, units: [UInt16])] = []
    var returns: [Int32] = []
    var beforeEachCharacter: ((Int) -> Void)?
    var onReturn: (() -> Void)?

    init(ax: FakeAX) { self.ax = ax }

    func type(_ units: UnsafeBufferPointer<UInt16>, to pid: Int32) {
        typed.append((pid, Array(units)))
        ax.focused[pid]?.value.append(contentsOf: units)
        beforeEachCharacter?(typed.count)
    }

    func pressReturn(to pid: Int32) {
        returns.append(pid)
        onReturn?()
    }
}

/// Время идёт только в `sleep`; на каждом шаге срабатывают запланированные события.
final class FakeClock: RemoteClock {
    private(set) var milliseconds = 0
    private var events: [(at: Int, action: () -> Void)] = []

    func at(_ ms: Int, _ action: @escaping () -> Void) { events.append((ms, action)) }

    func sleep(milliseconds ms: Int) async throws {
        try Task.checkCancellation()
        await Task.yield()
        milliseconds += ms
        let due = events.filter { $0.at <= milliseconds }
        events.removeAll { $0.at <= milliseconds }
        for e in due { e.action() }
        try Task.checkCancellation()
    }
}

/// Окно пароля AnyDesk как в 9.x: заголовок «Авторизация», защищённое поле, галочка, «ОК» по умолчанию.
struct FakePasswordWindow {
    let window: FakeNode
    let field: FakeNode
    let checkbox: FakeNode
    let ok: FakeNode

    init(title: String = "Авторизация", checkbox: String = "Входить автоматически", nested: Bool = true) {
        field = FakeNode("AXTextField", subrole: "AXSecureTextField")
        self.checkbox = FakeNode("AXCheckBox", label: checkbox)
        self.checkbox.isChecked = false
        ok = FakeNode("AXButton", label: "ОК")
        let message = FakeNode("AXStaticText", label: "Требуется пароль AnyDesk.")
        let body = nested ? [FakeNode("AXGroup", children: [message, FakeNode("AXGroup", children: [field])]), self.checkbox, ok]
                          : [message, field, self.checkbox, ok]
        window = FakeNode("AXWindow", subrole: "AXDialog", label: title, children: body)
        window.defaultButtonNode = ok
    }
}

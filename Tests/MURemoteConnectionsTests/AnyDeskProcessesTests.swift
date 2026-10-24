import XCTest
@testable import MURemoteConnections

/// rc-console3 (1.10.4, журнал пользователя: `connect result=unconfirmed typed=0 ms=20161`, «Диагностики» нет).
/// У AnyDesk с одним bundle id работают `--local-service` и `--control` (без окон, запущены при входе в систему)
/// и сам интерфейс. Автоматор брал первый процесс — `--control` — и смотрел в ноль окон: карточка «Terminal Session»
/// не находилась, таймаут 20 с шёл без паузы, «Диагностика» была пустой. Только выдуманные окна и данные.
@MainActor
final class AnyDeskProcessesTests: XCTestCase {
    private let ui: Int32 = 8181
    private let control: Int32 = 5757
    private let service: Int32 = 5756
    private let password = "Pw-8-выдумка"
    private var ax: FakeAX!
    private var launcher: FakeLauncher!
    private var keyboard: FakeKeyboard!
    private var clock: FakeClock!
    private var logger: RecordingLogger!
    private var phases: [ConnectionPhase] = []

    private let record = ConnectionRecord(sourceRow: 2, name: "Лаборатория Демо", id: "123456789", hasPassword: true)

    override func setUp() async throws {
        ax = FakeAX(); launcher = FakeLauncher(); keyboard = FakeKeyboard(ax: ax); clock = FakeClock(); logger = RecordingLogger()
        phases = []
        // Как на Mac пользователя: фоновые процессы AnyDesk запущены при входе, раньше интерфейса.
        launcher.addHelper(.anyDesk, pid: service)
        launcher.addHelper(.anyDesk, pid: control)
    }

    private var texts: ProviderTexts { ProviderTexts.builtIn(keys: AnyDeskAutomator.keys) }

    /// Карточка как в nib: Console выбрана, Connect активен.
    private func card(connect: FakeNode) -> FakeNode {
        let console = FakeNode("AXRadioButton", label: "Console"); console.isChecked = true
        let user = FakeNode("AXRadioButton", label: "User account"); user.isChecked = false
        return FakeNode("AXGroup", children: [
            FakeNode("AXStaticText", label: "Terminal Session"),
            FakeNode("AXStaticText", label: "Please select the terminal session you would like to connect to:"),
            FakeNode("AXGroup", children: [console, FakeNode("AXGroup", children: [user, FakeNode("AXTextField")])]),
            FakeNode("AXButton", label: "Cancel"), connect])
    }

    private func connect(_ c: RemoteConnector? = nil) async -> (ConnectionOutcome, RemoteConnector) {
        let connector = c ?? RemoteConnector(ax: ax, launcher: launcher, keyboard: keyboard, clock: clock, logger: logger)
        let pw = password
        let outcome = await connector.connect(ConnectRequest(record: record, program: .anyDesk), provider: AnyDeskAutomator(texts: texts),
                                              password: { .found(SecretBuffer(pw.utf8)) }, progress: { self.phases.append($0) })
        return (outcome, connector)
    }

    /// Сценарий пользователя: главное окно AnyDesk (процесс интерфейса) уже открыто, после ссылки в нём карточка
    /// «Terminal Session» (Console выбрана). Фоновые процессы — первые в списке. «Connect» нажат один раз, затем окно
    /// пароля — пароль введён. До исправления: `unconfirmed` через 20 с, ничего не нажато.
    func testCardInUIProcessIsFoundAlthoughHelperProcessesComeFirst() async {
        let slot = FakeNode("AXGroup")
        let main = FakeNode("AXWindow", subrole: "AXStandardWindow", label: "AnyDesk",
                            children: [FakeNode("AXToolbar"), FakeNode("AXGroup", children: [slot])])
        launcher.launch(.anyDesk, pid: ui)
        ax.show(main, pid: ui)
        let field = FakeNode("AXTextField", subrole: "AXSecureTextField")
        let ok = FakeNode("AXButton", label: "OK")
        ok.onPress = { [unowned self] in slot.kids = [FakeNode("AXStaticText", label: "Waiting for image.")]; for n in slot.descendants() { n.ax = ax; n.processID = ui } }
        var connectPresses = 0
        let connectButton = FakeNode("AXButton", label: "Connect")
        connectButton.onPress = { [unowned self] in
            connectPresses += 1
            slot.kids = []
            clock.at(clock.milliseconds + 1000) { [unowned self] in
                slot.kids = [FakeNode("AXGroup", children: [FakeNode("AXStaticText", label: "Authorization"),
                                                            FakeNode("AXStaticText", label: "AnyDesk password required."), field, ok])]
                for n in slot.descendants() { n.ax = ax; n.processID = ui }
            }
        }
        launcher.onOpen = { [unowned self] _ in
            clock.at(500) { [unowned self] in
                slot.kids = [card(connect: connectButton)]
                for n in slot.descendants() { n.ax = ax; n.processID = ui }
            }
        }
        let (outcome, _) = await connect()
        XCTAssertEqual(connectPresses, 1)
        XCTAssertEqual(field.text, password)
        XCTAssertEqual(outcome, .connected)
        XCTAssertTrue(phases.contains(.intermediate(.sessionChoice)))
        XCTAssertNotEqual(launcher.frontmostProcess, control, "вперёд выводится интерфейс, не фоновый процесс")

        // Журнал: этапы с числами и ключами надписей программы, без ID и имён.
        let log = logger.events.map(\.message)
        XCTAssertTrue(log.contains { $0.hasPrefix("connect stage=start") && $0.contains("processes=3") }, "\(log)")
        XCTAssertTrue(log.contains { $0.hasPrefix("connect stage=wait") && $0.contains("ui=3") && $0.contains("state=sessionChoice") }, "\(log)")
        XCTAssertTrue(log.contains { $0.hasPrefix("connect stage=prompt step=pressed console=1 others=1 othersOn=0")
            && $0.contains("key=ad_dlg_terminal_title") }, "\(log)")
        XCTAssertTrue(log.contains("connect stage=waited result=field"), "\(log)")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789=_ \n-")
        let text = log.joined(separator: "\n")
        XCTAssertTrue(text.unicodeScalars.allSatisfy(allowed.contains), text)
        for leak in ["123456789", "Лаборатория", password] { XCTAssertFalse(text.contains(leak), leak) }
    }

    /// Окон нет ни у одного процесса AnyDesk — итог «не подтверждено», а «Диагностика» всё равно есть: процессы,
    /// окна каждого (0), подпись. Журнал: сводка обхода и причина.
    func testDiagnosticsExistEvenWithZeroWindows() async {
        launcher.launch(.anyDesk, pid: ui)   // интерфейс без окон (окна закрыты или AX их не отдал)
        let (outcome, connector) = await connect()
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertEqual(connector.lastDiagnostics, ["# processes: 3, pid found: yes",
                                                   "# process 1: windows 0, signature ok",
                                                   "# process 2: windows 0, signature ok",
                                                   "# process 3: windows 0, signature ok"])
        let log = logger.events.map(\.message)
        XCTAssertTrue(log.contains("connect stage=waited result=timeout"), "\(log)")
        XCTAssertTrue(log.contains("connect stage=scan processes=3 windows=0 nodes=0 depth=0 full=0"), "\(log)")
        XCTAssertTrue(log.contains { $0.hasPrefix("connect stage=wait processes=3 ui=1 windows=0 state=waiting") }, "\(log)")
    }

    /// Окно есть, карточка в нём не узнана — «Диагностика» показывает процесс, окно и ключи совпавших надписей;
    /// в журнале — те же ключи.
    func testDiagnosticsAndLogNameMatchedKeysOfUnrecognisedWindow() async {
        let window = FakeNode("AXWindow", subrole: "AXStandardWindow", label: "AnyDesk", children: [
            FakeNode("AXGroup", children: [FakeNode("AXButton", label: "Connect"), FakeNode("AXRadioButton", label: "Console")])])
        launcher.launch(.anyDesk, pid: ui)
        ax.show(window, pid: ui)
        let (outcome, connector) = await connect()
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        let lines = connector.lastDiagnostics
        XCTAssertEqual(lines.first, "# processes: 3, pid found: yes")
        XCTAssertTrue(lines.contains("# process 3: windows 1, signature ok"), "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasSuffix("AXButton ← ad.dlg.connect") }, "\(lines)")
        let log = logger.events.map(\.message)
        XCTAssertTrue(log.contains { $0.hasPrefix("connect stage=scan processes=3 windows=1")
            && $0.contains("key=ad_dlg_connect") && $0.contains("key=ad_dlg_terminal_console") }, "\(log)")
    }
}

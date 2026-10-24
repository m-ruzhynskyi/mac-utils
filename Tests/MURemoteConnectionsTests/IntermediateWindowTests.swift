import XCTest
@testable import MURemoteConnections

/// Промежуточные окна и подтверждение сеанса (task-rc-terminal-session): AnyDesk «Terminal Session», «Connecting…»,
/// «Waiting for image»; TeamViewer, открывшийся на главном экране без ID. Только выдуманные окна и данные.
@MainActor
final class IntermediateWindowTests: XCTestCase {
    private let adPID: Int32 = 5151
    private let tvPID: Int32 = 6161
    private let password = "Pw-9-выдумка"
    private var ax: FakeAX!
    private var launcher: FakeLauncher!
    private var keyboard: FakeKeyboard!
    private var clock: FakeClock!
    private var phases: [ConnectionPhase] = []
    private var lookups = 0
    private var secrets: [SecretBuffer] = []

    private let record = ConnectionRecord(sourceRow: 3, name: "Склад Выдуманный", id: "123456789", hasPassword: true)

    /// Надписи AnyDesk 9.8 (en), как их собирает `ProviderTexts.load`.
    private let adTexts = ProviderTexts(
        passwordWindowTitles: ["Authorization"], rejectionTexts: ["Password Rejected"],
        autologinTitles: ["Log in automatically from now on"],
        promptTexts: ["Terminal Session", "Please select the terminal session you would like to connect to:"],
        promptContinueTitles: ["Connect"], promptDefaultTitles: ["Console"],
        progressTexts: ["Connecting...", "Connection in progress. Please wait.", "Please wait for the remote side to accept your session request."],
        sessionTexts: ["Waiting for image."], closedTexts: ["Client Offline", "Session Closed"],
        promptAccountTitles: ["User account"], accountPasswordTexts: ["User account password required."])

    override func setUp() async throws {
        ax = FakeAX(); launcher = FakeLauncher(); keyboard = FakeKeyboard(ax: ax); clock = FakeClock()
        phases = []; lookups = 0; secrets = []
    }

    private func connector(_ adjust: (inout RemoteConnector.Timing) -> Void = { _ in }) -> RemoteConnector {
        let c = RemoteConnector(ax: ax, launcher: launcher, keyboard: keyboard, clock: clock)
        adjust(&c.timing)
        return c
    }

    private func connect(_ request: ConnectRequest, _ provider: RemoteProvider,
                         _ connector: RemoteConnector? = nil, accountPassword: String? = nil) async -> ConnectionOutcome {
        let pw = password
        return await (connector ?? self.connector()).connect(request, provider: provider, password: {
            self.lookups += 1
            let s = SecretBuffer(pw.utf8)
            self.secrets.append(s)
            return .found(s)
        }, accountPassword: accountPassword.map { apw in {
            let s = SecretBuffer(apw.utf8)
            self.secrets.append(s)
            return .found(s)
        } }, progress: { self.phases.append($0) })
    }

    private func anyDesk(timeout: Int = 20) -> ConnectRequest {
        ConnectRequest(record: record, program: .anyDesk, timeoutSeconds: timeout)
    }

    private func teamViewer(timeout: Int = 20, withPassword: Bool = true) -> ConnectRequest {
        ConnectRequest(record: record, program: .teamViewer, withPassword: withPassword, timeoutSeconds: timeout)
    }

    private var finishedPhases: [ConnectionOutcome] {
        phases.compactMap { if case .finished(let o) = $0 { return o } else { return nil } }
    }

    /// Поменять содержимое окна, как это делает программа (новые элементы — того же процесса).
    private func put(_ kids: [FakeNode], in window: FakeNode, pid: Int32) {
        window.kids = kids
        for node in window.descendants() { node.ax = ax; node.processID = pid }
    }

    // MARK: AnyDesk — окно сеанса с диалогами внутри

    private struct TerminalPrompt {
        let group: FakeNode
        let console: FakeNode
        let user: FakeNode
        let connect: FakeNode
        let cancel: FakeNode
        let login: FakeNode

        init(consoleSelected: Bool = true, withConnect: Bool = true) {
            console = FakeNode("AXRadioButton", label: "Console")
            console.isChecked = consoleSelected
            user = FakeNode("AXRadioButton", label: "User account")
            user.isChecked = !consoleSelected
            connect = FakeNode("AXButton", label: "Connect")
            cancel = FakeNode("AXButton", label: "Cancel")
            login = FakeNode("AXTextField")
            let kids = [FakeNode("AXStaticText", label: "Terminal Session"),
                        FakeNode("AXStaticText", label: "Please select the terminal session you would like to connect to:"),
                        console, FakeNode("AXGroup", children: [user, login]), cancel] + (withConnect ? [connect] : [])
            group = FakeNode("AXGroup", children: kids)
        }
    }

    /// Окно сеанса AnyDesk: заголовок — ID, внутри панель и (пока идёт подключение) диалог.
    private func sessionWindow(title: String = "123 456 789") -> FakeNode {
        FakeNode("AXWindow", subrole: "AXStandardWindow", label: title, children: [FakeNode("AXToolbar")])
    }

    private func remoteScreen() -> [FakeNode] { [FakeNode("AXToolbar"), FakeNode("AXGroup", children: [FakeNode("AXImage")])] }

    private func progress(_ text: String = "Connection in progress. Please wait.") -> FakeNode {
        FakeNode("AXGroup", children: [FakeNode("AXStaticText", label: "Connecting..."), FakeNode("AXStaticText", label: text),
                                       FakeNode("AXButton", label: "Cancel")])
    }

    /// Баг пользователя: «Terminal Session» до окна пароля. «Connect» нажат сам (Console оставлен), «Cancel» — нет,
    /// тоста успеха нет, после закрытия окна пароль введён.
    func testTerminalSessionIsPassedAutomaticallyThenPasswordEntered() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt()
        var cancelPressed = false
        prompt.cancel.onPress = { cancelPressed = true }
        let pw = FakePasswordWindow(title: "Authorization")
        pw.ok.onPress = { [unowned self] in ax.close(pw.window, pid: adPID); put(remoteScreen(), in: window, pid: adPID) }
        var connectPresses = 0
        prompt.connect.onPress = { [unowned self] in
            connectPresses += 1
            put(remoteScreen() + [progress()], in: window, pid: adPID)
            clock.at(clock.milliseconds + 2500) { [unowned self] in ax.show(pw.window, pid: adPID) }
        }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            clock.at(500) { [unowned self] in
                ax.show(window, pid: adPID)
                put([FakeNode("AXToolbar"), prompt.group], in: window, pid: adPID)
            }
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(connectPresses, 1, "«Connect» нажат один раз")
        XCTAssertFalse(cancelPressed, "«Cancel» не нажимается никогда")
        XCTAssertEqual(prompt.console.isChecked, true, "выбор по умолчанию — Console")
        XCTAssertEqual(pw.field.text, password)
        XCTAssertTrue(phases.contains(.intermediate(.sessionChoice)))
        XCTAssertEqual(finishedPhases, [.connected], "до пароля — ни одного итога, ни «подключено без пароля»")
        XCTAssertTrue(secrets.allSatisfy(\.isEmpty))
    }

    /// AnyDesk запомнил «User account» — ставим Console и жмём «Connect».
    func testTerminalSessionSelectsConsoleIfAnotherChoiceIsSelected() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt(consoleSelected: false)
        let pw = FakePasswordWindow(title: "Authorization")
        pw.ok.onPress = { [unowned self] in ax.close(pw.window, pid: adPID) }
        var consoleBeforeConnect: Bool?
        prompt.connect.onPress = { [unowned self] in
            consoleBeforeConnect = prompt.console.isChecked
            put(remoteScreen(), in: window, pid: adPID)
            ax.show(pw.window, pid: adPID)
        }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([prompt.group], in: window, pid: adPID)
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(consoleBeforeConnect, true)
        XCTAssertEqual(pw.field.text, password)
    }

    /// В промежуточном окне нет кнопки продолжения — ничего не нажимаем, таймаут стоит, пока окно открыто;
    /// пользователь ответил сам — пароль вводится.
    func testPromptWithoutContinueIsNotAnsweredAndPausesTimeout() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt(withConnect: false)
        var cancelPressed = false
        prompt.cancel.onPress = { cancelPressed = true }
        let pw = FakePasswordWindow(title: "Authorization")
        pw.ok.onPress = { [unowned self] in ax.close(pw.window, pid: adPID) }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([prompt.group], in: window, pid: adPID)
            clock.at(30_000) { [unowned self] in
                put(remoteScreen(), in: window, pid: adPID)
                ax.show(pw.window, pid: adPID)
            }
        }
        let outcome = await connect(anyDesk(timeout: 5), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connected, "30 с промежуточного окна при таймауте 5 с — не таймаут")
        XCTAssertFalse(cancelPressed)
        XCTAssertTrue(phases.contains(.intermediate(.unknown)))
        XCTAssertFalse(phases.contains(.intermediate(.sessionChoice)))
        XCTAssertEqual(pw.field.text, password)
    }

    /// Промежуточное окно висит бесконечно — ждём не дольше `limit`, итог нейтральный.
    func testPromptThatNeverClosesEndsAtLimitWithoutSuccess() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt(withConnect: false)
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([prompt.group], in: window, pid: adPID)
        }
        let c = connector { $0.limit = 60_000 }
        let outcome = await connect(anyDesk(timeout: 5), AnyDeskAutomator(texts: adTexts), c)
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertTrue((60_000...60_500).contains(clock.milliseconds), "ждали \(clock.milliseconds) мс")
        XCTAssertTrue(secrets.allSatisfy(\.isEmpty))
    }

    /// «Connect» нажат, а окно не закрылось (ошибка выбора сеанса) — второй раз не жмём, ждём пользователя.
    func testContinueIsPressedOnlyOnce() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt()
        var presses = 0
        prompt.connect.onPress = { presses += 1 }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([prompt.group], in: window, pid: adPID)
        }
        let c = connector { $0.limit = 30_000 }
        let outcome = await connect(anyDesk(timeout: 5), AnyDeskAutomator(texts: adTexts), c)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertTrue(phases.contains(.intermediate(.sessionChoice)))
        XCTAssertTrue(phases.contains(.intermediate(.unknown)), "после неудачного «Connect» — ждём пользователя")
    }

    /// «Terminal Session» после ввода пароля — тоже проходится сам; «подключено» только после него.
    func testTerminalSessionAfterPasswordIsPassed() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt()
        let pw = FakePasswordWindow(title: "Authorization")
        pw.ok.onPress = { [unowned self] in
            ax.close(pw.window, pid: adPID)
            put([prompt.group], in: window, pid: adPID)
        }
        var presses = 0
        prompt.connect.onPress = { [unowned self] in presses += 1; put(remoteScreen(), in: window, pid: adPID) }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([progress()], in: window, pid: adPID)
            clock.at(1000) { [unowned self] in ax.show(pw.window, pid: adPID) }
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(pw.field.text, password)
    }

    /// «Ожидание принятия» той стороной — таймаут стоит; окно пароля через 40 с — пароль введён.
    func testWaitingForAcceptPausesTimeout() async {
        let window = sessionWindow()
        let pw = FakePasswordWindow(title: "Authorization")
        pw.ok.onPress = { [unowned self] in ax.close(pw.window, pid: adPID) }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([progress("Please wait for the remote side to accept your session request.")], in: window, pid: adPID)
            clock.at(40_000) { [unowned self] in put(remoteScreen(), in: window, pid: adPID); ax.show(pw.window, pid: adPID) }
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connected)
        XCTAssertTrue(phases.contains(.intermediate(.remoteSide)))
        XCTAssertEqual(pw.field.text, password)
    }

    // MARK: Учётка Windows (задача 4)

    private let accountRecord = ConnectionRecord(sourceRow: 4, name: "Філія 2", id: "123456789", hasPassword: true,
                                                 account: "lims.admin", hasAccountPassword: true)

    /// Окно AnyDesk «Authorization», которое просит пароль учётной записи; `login` — поле логина, если есть.
    private func accountPasswordWindow(withLogin: Bool = false) -> (window: FakePasswordWindow, login: FakeNode) {
        let w = FakePasswordWindow(title: "Authorization")
        let login = FakeNode("AXTextField")
        w.window.kids.insert(FakeNode("AXStaticText", label: "User account password required."), at: 0)
        if withLogin { w.window.kids.insert(login, at: 1) }
        return (w, login)
    }

    /// Есть логин учётки — «User account», логин вписан, «Connect»; затем пароль учётки — в окно, которое его просит.
    func testTerminalSessionWithAccountSelectsUserAccountAndEntersAccountPassword() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt()
        let (pw, _) = accountPasswordWindow()
        pw.ok.onPress = { [unowned self] in ax.close(pw.window, pid: adPID); put(remoteScreen(), in: window, pid: adPID) }
        var atConnect: (user: Bool?, console: Bool?, login: String)?
        prompt.user.onPress = { prompt.user.isChecked = true; prompt.console.isChecked = false }
        prompt.connect.onPress = { [unowned self] in
            atConnect = (prompt.user.isChecked, prompt.console.isChecked, prompt.login.text)
            put([progress()], in: window, pid: adPID)
            clock.at(clock.milliseconds + 1000) { [unowned self] in ax.show(pw.window, pid: adPID) }
        }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([prompt.group], in: window, pid: adPID)
        }
        let request = ConnectRequest(record: accountRecord, program: .anyDesk)
        let outcome = await connect(request, AnyDeskAutomator(texts: adTexts), accountPassword: "Win-9-выдумка")
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(atConnect?.user, true, "выбрано «User account»")
        XCTAssertEqual(atConnect?.console, false)
        XCTAssertEqual(atConnect?.login, "lims.admin")
        XCTAssertEqual(pw.field.text, "Win-9-выдумка", "в окно учётки — пароль учётки")
        XCTAssertFalse(prompt.login.text.contains(password), "пароль программы — нигде")
        XCTAssertTrue(secrets.allSatisfy(\.isEmpty), "оба пароля затёрты")
    }

    /// Пустое поле логина в окне пароля учётки заполняется.
    func testAccountPasswordWindowGetsLoginWhenEmpty() async {
        let (pw, login) = accountPasswordWindow(withLogin: true)
        pw.ok.onPress = { [unowned self] in ax.close(pw.window, pid: adPID) }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            clock.at(500) { [unowned self] in ax.show(pw.window, pid: adPID) }
        }
        let outcome = await connect(ConnectRequest(record: accountRecord, program: .anyDesk), AnyDeskAutomator(texts: adTexts),
                                    accountPassword: "Win-9-выдумка")
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(login.text, "lims.admin")
        XCTAssertEqual(pw.field.text, "Win-9-выдумка")
    }

    /// Окно просит пароль учётки, а его в файле нет — пароль AnyDesk туда не вводится.
    func testProgramPasswordNeverGoesIntoAccountPasswordWindow() async {
        let (pw, _) = accountPasswordWindow()
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(pw.window, pid: adPID)
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .openedWithoutPassword(.notInFile))
        XCTAssertEqual(pw.field.text, "")
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    /// Ревью #157, H1: пароля программы в файле нет, пароль учётки есть, окно — обычное окно пароля программы
    /// (AnyDesk или TeamViewer). Пароль учётки туда не вводится и даже не читается.
    func testAccountPasswordNeverGoesIntoProgramPasswordWindow() async {
        let noProgramPassword = ConnectionRecord(sourceRow: 5, name: "Філія 3", id: "123456789", hasPassword: false,
                                                 account: "lims.admin", hasAccountPassword: true)
        for (program, provider, pid) in [(RemoteProgram.anyDesk, AnyDeskAutomator(texts: adTexts) as RemoteProvider, adPID),
                                         (.teamViewer, TeamViewerAutomator(texts: tvTexts), tvPID)] {
            ax = FakeAX(); launcher = FakeLauncher(); keyboard = FakeKeyboard(ax: ax); clock = FakeClock(); secrets = []
            let pw = FakePasswordWindow(title: program == .anyDesk ? "Authorization" : "Аутентификация")
            launcher.onOpen = { [unowned self] _ in
                launcher.launch(program, pid: pid)
                ax.show(pw.window, pid: pid)
            }
            var accountReads = 0
            let outcome = await connector().connect(ConnectRequest(record: noProgramPassword, program: program), provider: provider,
                                                    password: { .noPassword },
                                                    accountPassword: { accountReads += 1; return .found(SecretBuffer("Win-9".utf8)) },
                                                    progress: { _ in })
            XCTAssertEqual(outcome, .openedWithoutPassword(.notInFile), "\(program)")
            XCTAssertEqual(pw.field.text, "", "\(program): в окно программы — ничего")
            XCTAssertEqual(accountReads, 0, "\(program): пароль учётки не читался")
            XCTAssertTrue(keyboard.typed.isEmpty)
        }
    }

    /// Без логина учётки — как раньше: Console и «Connect»; поле логина не трогаем.
    func testTerminalSessionWithoutAccountKeepsConsole() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt()
        var pressed = false
        prompt.connect.onPress = { pressed = true }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([prompt.group], in: window, pid: adPID)
        }
        _ = await connect(anyDesk(timeout: 2), AnyDeskAutomator(texts: adTexts), connector { $0.limit = 10_000 })
        XCTAssertTrue(pressed)
        XCTAssertEqual(prompt.console.isChecked, true)
        XCTAssertEqual(prompt.login.text, "")
    }

    // MARK: AnyDesk — подтверждение сеанса без пароля

    /// Компьютер запомнен: «Connecting…», затем экран сеанса без диалогов. Пароль в файле есть и ждётся, поэтому
    /// тишина — ещё не сеанс (ревью #155, P3): к таймауту окно без ID в заголовке — «не подтверждено».
    func testConnectingThenCalmWindowWithoutIDWhilePasswordExpectedIsUnconfirmed() async {
        let window = sessionWindow(title: "AnyDesk")
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([progress()], in: window, pid: adPID)
            clock.at(2000) { [unowned self] in put(remoteScreen(), in: window, pid: adPID) }
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertFalse(finishedPhases.contains(.connectedWithoutPassword))
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    func testWaitingForImageConfirmsSession() async {
        let window = sessionWindow(title: "AnyDesk")
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([FakeNode("AXStaticText", label: "Connected"), FakeNode("AXStaticText", label: "Waiting for image.")],
                in: window, pid: adPID)
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connectedWithoutPassword)
        XCTAssertLessThan(clock.milliseconds, 1000)
    }

    /// Новое окно с ID в заголовке и без диалогов — сеанс.
    func testNewWindowNamedAfterIDIsSession() async {
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            let window = sessionWindow()
            ax.show(window, pid: adPID)
            put(remoteScreen(), in: window, pid: adPID)
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connectedWithoutPassword)
    }

    /// Окно с этим ID было открыто до подключения — оно не доказательство.
    func testWindowThatExistedBeforeIsNotEvidence() async {
        launcher.launch(.anyDesk, pid: adPID)
        let old = sessionWindow()
        ax.show(old, pid: adPID)
        let outcome = await connect(anyDesk(timeout: 5), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
    }

    /// Сеанс не открылся («Client Offline») — не успех.
    func testClosedSessionIsNotSuccess() async {
        let window = sessionWindow()
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([FakeNode("AXStaticText", label: "Client Offline"), FakeNode("AXButton", label: "OK")], in: window, pid: adPID)
        }
        let outcome = await connect(anyDesk(timeout: 5), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertFalse(finishedPhases.contains(.connectedWithoutPassword))
    }

    /// Главное окно AnyDesk, никакого сеанса — к таймауту нейтральный итог, без галочки.
    func testNoSessionAtTimeoutIsNeutral() async {
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(FakeNode("AXWindow", subrole: "AXStandardWindow", label: "AnyDesk",
                             children: [FakeNode("AXTextField"), FakeNode("AXButton", label: "Connect")]), pid: adPID)
        }
        let outcome = await connect(anyDesk(timeout: 5), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertEqual(outcome.code, "unconfirmed")
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertTrue(keyboard.typed.isEmpty)
        XCTAssertTrue(secrets.allSatisfy(\.isEmpty))
    }

    /// Незнакомый диалог — ничего не нажимаем (даже «OK»), таймаут стоит.
    func testUnknownDialogIsNeverAnswered() async {
        var pressed: [String] = []
        let ok = FakeNode("AXButton", label: "OK")
        let cancel = FakeNode("AXButton", label: "Cancel")
        ok.onPress = { pressed.append("OK") }
        cancel.onPress = { pressed.append("Cancel") }
        let dialog = FakeNode("AXWindow", subrole: "AXDialog", label: "",
                              children: [FakeNode("AXStaticText", label: "All running sessions will be terminated."), cancel, ok])
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(dialog, pid: adPID)
            clock.at(25_000) { [unowned self] in ax.close(dialog, pid: adPID) }
        }
        let outcome = await connect(anyDesk(timeout: 5), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(pressed, [])
        XCTAssertTrue(phases.contains(.intermediate(.unknown)))
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertGreaterThanOrEqual(clock.milliseconds, 30_000, "5 с таймаута отсчитаны после закрытия диалога")
    }

    // MARK: Ревью #155: подтверждение после пароля, ленивый пароль

    /// Окно пароля AnyDesk; по «ОК» оно закрывается и выполняется `then`.
    private func adPasswordWindow(at ms: Int, then: @escaping () -> Void = {}) -> FakePasswordWindow {
        let pw = FakePasswordWindow(title: "Authorization")
        pw.ok.onPress = { [unowned self] in ax.close(pw.window, pid: adPID); then() }
        clock.at(ms) { [unowned self] in ax.show(pw.window, pid: adPID) }
        return pw
    }

    /// P1: после пароля AnyDesk закрыл сеанс не из-за пароля («Client Offline») — не «Подключено».
    func testSessionClosedAfterPasswordIsNotConnected() async {
        let window = sessionWindow()
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            _ = adPasswordWindow(at: 500) { [unowned self] in
                put([FakeNode("AXStaticText", label: "Client Offline"), FakeNode("AXButton", label: "OK")], in: window, pid: adPID)
            }
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .sessionClosed)
        XCTAssertFalse(outcome.isSuccess)
    }

    /// P2: окно пароля закрылось, а признака сеанса нет — «Пароль введён · сеанс не подтверждён», не успех.
    func testPasswordAcceptedWithoutAnySessionIsNotConnected() async {
        ax.sessionAfterPassword = false
        var pw: FakePasswordWindow?
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            pw = adPasswordWindow(at: 500)
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .submitted)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertEqual(pw?.field.text, password)
    }

    /// P2: после пароля — спокойное окно сеанса (с ID в заголовке) — «Подключено».
    func testPasswordThenCalmSessionWindowIsConnected() async {
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            _ = adPasswordWindow(at: 500) { [unowned self] in
                let w = sessionWindow()
                ax.show(w, pid: adPID)
                put(remoteScreen(), in: w, pid: adPID)
            }
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connected)
    }

    /// P2: «Waiting for image» после пароля — сразу «Подключено».
    func testPasswordThenWaitingForImageIsConnected() async {
        let window = sessionWindow(title: "AnyDesk")
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            _ = adPasswordWindow(at: 500) { [unowned self] in
                put([FakeNode("AXStaticText", label: "Waiting for image.")], in: window, pid: adPID)
            }
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connected)
    }

    /// P3: «Terminal Session» → «Connect» → 6 с тишины в окне сеанса → окно пароля: пароль введён, не «без пароля».
    func testQuietSessionWindowWhileWaitingForPasswordIsNotASession() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt()
        var pw: FakePasswordWindow?
        prompt.connect.onPress = { [unowned self] in
            put(remoteScreen(), in: window, pid: adPID)
            pw = adPasswordWindow(at: clock.milliseconds + 6500) { [unowned self] in
                put([FakeNode("AXStaticText", label: "Waiting for image.")], in: window, pid: adPID)
            }
        }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([prompt.group], in: window, pid: adPID)
        }
        let outcome = await connect(anyDesk(), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(pw?.field.text, password)
        XCTAssertFalse(finishedPhases.contains(.connectedWithoutPassword))
    }

    /// P3: пароль ждём, а до конца таймаута — спокойное новое окно с ID: тогда (и только тогда) «без пароля».
    func testTitledCalmWindowCountsAsSessionOnlyAtTimeout() async {
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            let w = sessionWindow()
            ax.show(w, pid: adPID)
            put(remoteScreen(), in: w, pid: adPID)
        }
        let outcome = await connect(anyDesk(timeout: 10), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .connectedWithoutPassword)
        XCTAssertGreaterThanOrEqual(clock.milliseconds, 10_000, "не раньше таймаута")
        XCTAssertEqual(lookups, 1, "только проверка до ссылки")
        XCTAssertTrue(secrets.allSatisfy(\.isEmpty))
    }

    /// P4: пароль читается из файла только когда найдено поле, не на время промежуточных окон.
    func testPasswordIsReadOnlyWhenFieldIsFound() async {
        let window = sessionWindow()
        let prompt = TerminalPrompt(withConnect: false)
        var pw: FakePasswordWindow?
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: adPID)
            ax.show(window, pid: adPID)
            put([prompt.group], in: window, pid: adPID)
            clock.at(60_000) { [unowned self] in
                put(remoteScreen(), in: window, pid: adPID)
                pw = adPasswordWindow(at: 60_500)
            }
        }
        var readAt: Int?
        let pwText = password
        let outcome = await connector().connect(anyDesk(), provider: AnyDeskAutomator(texts: adTexts), password: {
            readAt = self.clock.milliseconds
            let s = SecretBuffer(pwText.utf8)
            self.secrets.append(s)
            return .found(s)
        }, progress: { _ in })
        XCTAssertEqual(pw?.field.text, password)
        XCTAssertGreaterThanOrEqual(readAt ?? 0, 60_500, "до окна пароля файл не читался")
        XCTAssertNotEqual(outcome, .connectedWithoutPassword)
        XCTAssertTrue(secrets.allSatisfy(\.isEmpty))
    }

    /// P4: окна пароля так и не было — пароль прочитан только для проверки до ссылки и сразу затёрт.
    func testPasswordNotKeptWithoutPasswordWindow() async {
        var wipedBeforeOpen: Bool?
        launcher.onOpen = { [unowned self] _ in
            wipedBeforeOpen = secrets.allSatisfy(\.isEmpty)
            launcher.launch(.anyDesk, pid: adPID)
        }
        let outcome = await connect(anyDesk(timeout: 3), AnyDeskAutomator(texts: adTexts))
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertEqual(lookups, 1)
        XCTAssertEqual(wipedBeforeOpen, true, "к открытию ссылки пароля в памяти уже нет")
    }

    /// P9: у формы ID нет своей «Connect» — плитку другого компьютера не жмём; Return в поле ID.
    func testTeamViewerNeverPressesAnotherDevicesConnect() async {
        let field = FakeNode("AXComboBox")
        field.placeholder = "Enter end user’s ID, IP, or hostname"
        let arrow = FakeNode("AXButton")   // кнопка формы — только значок, подписи нет
        let tile = FakeNode("AXButton")
        tile.detail = "Connect"
        var tilePressed = false
        tile.onPress = { tilePressed = true }
        let form = FakeNode("AXGroup", children: [FakeNode("AXGroup", children: [field]), arrow])
        let window = FakeNode("AXWindow", subrole: "AXStandardWindow", label: "TeamViewer", children: [
            FakeNode("AXWebArea", children: [
                FakeNode("AXGroup", children: [form]),
                FakeNode("AXGroup", children: [FakeNode("AXGroup", children: [FakeNode("AXStaticText", label: "Другой компьютер"), tile])]),
            ]),
        ])
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.teamViewer, pid: tvPID)
            ax.show(window, pid: tvPID)
        }
        _ = await connect(teamViewer(timeout: 4), TeamViewerAutomator(texts: tvTexts))
        XCTAssertFalse(tilePressed, "«Connect» плитки другого компьютера не нажата")
        XCTAssertEqual(field.text, "123456789")
        XCTAssertEqual(keyboard.returns, [tvPID], "Return — в поле ID")
    }

    // MARK: TeamViewer — главный экран без ID

    private let tvTexts = ProviderTexts(connectFieldTexts: ["ID, IP address, or hostname", "Enter end user’s ID, IP, or hostname"],
                                        connectButtonTitles: ["Connect"])

    private struct TVMain {
        let window: FakeNode
        let field: FakeNode
        let connect: FakeNode
        let tileConnect: FakeNode
        let search: FakeNode
    }

    /// Новый интерфейс TeamViewer 15.8x: веб-страница, подписи — в описании и подсказке.
    private func tvNewMain() -> TVMain {
        let field = FakeNode("AXComboBox")
        field.placeholder = "Enter end user’s ID, IP, or hostname"
        let connect = FakeNode("AXButton")
        connect.detail = "Connect"
        let tile = FakeNode("AXButton")
        tile.detail = "Connect"
        let search = FakeNode("AXButton")
        search.detail = "Search and Connect"
        let panel = FakeNode("AXGroup", children: [
            FakeNode("AXStaticText", label: "Control remote device"),
            FakeNode("AXGroup", children: [FakeNode("AXStaticText", label: "ID, IP address, or hostname"), field]),
            connect,
        ])
        let web = FakeNode("AXWebArea", children: [
            FakeNode("AXGroup", children: [FakeNode("AXButton", label: "Remote Support"), FakeNode("AXButton", label: "Devices")]),
            search,
            FakeNode("AXGroup", children: [FakeNode("AXRadioButton", label: "TeamViewer ID"), FakeNode("AXRadioButton", label: "Sessions")]),
            panel,
            FakeNode("AXGroup", children: [FakeNode("AXStaticText", label: "Склад-2"), tile]),
        ])
        let window = FakeNode("AXWindow", subrole: "AXStandardWindow", label: "TeamViewer",
                              children: [FakeNode("AXGroup", children: [web])])
        return TVMain(window: window, field: field, connect: connect, tileConnect: tile, search: search)
    }

    private func tvLaunchesOnMain(_ main: TVMain) {
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.teamViewer, pid: tvPID)
            ax.show(main.window, pid: tvPID)
        }
    }

    /// Баг 2: TeamViewer открылся на главном экране. ID вписан, «Connect» нажат сам, затем пароль введён.
    func testTeamViewerMainScreenGetsIDAndConnectThenPassword() async {
        let main = tvNewMain()
        tvLaunchesOnMain(main)
        let auth = FakePasswordWindow(title: "Аутентификация")
        auth.ok.onPress = { [unowned self] in ax.close(auth.window, pid: tvPID) }
        var idAtConnect: String?
        main.connect.onPress = { [unowned self] in
            idAtConnect = main.field.text
            clock.at(clock.milliseconds + 1500) { [unowned self] in ax.show(auth.window, pid: tvPID) }
        }
        var wrongButtons = 0
        main.tileConnect.onPress = { wrongButtons += 1 }
        main.search.onPress = { wrongButtons += 1 }
        let outcome = await connect(teamViewer(), TeamViewerAutomator(texts: tvTexts))
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(idAtConnect, "123456789")
        XCTAssertEqual(wrongButtons, 0, "нажат «Connect» рядом с полем, не плитка и не поиск")
        XCTAssertEqual(auth.field.text, password)
        XCTAssertFalse(main.field.text.contains(password), "пароль не в поле ID")
        XCTAssertTrue(phases.contains(.typingID))
        XCTAssertEqual(finishedPhases, [.connected])
        XCTAssertTrue(keyboard.typed.allSatisfy { $0.pid == tvPID })
    }

    /// Прежний интерфейс: надпись «Partner ID» над полем без подсказки. Надписи по умолчанию — без файлов программы.
    func testTeamViewerClassicPartnerIDField() async {
        let field = FakeNode("AXComboBox")
        let connectButton = FakeNode("AXButton", label: "Connect")
        let window = FakeNode("AXWindow", subrole: "AXStandardWindow", label: "TeamViewer", children: [
            FakeNode("AXGroup", children: [FakeNode("AXStaticText", label: "Control Remote Computer"),
                                           FakeNode("AXStaticText", label: "Partner ID"), field, connectButton]),
        ])
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.teamViewer, pid: tvPID)
            ax.show(window, pid: tvPID)
        }
        let auth = FakePasswordWindow(title: "Authentication")
        auth.ok.onPress = { [unowned self] in ax.close(auth.window, pid: tvPID) }
        connectButton.onPress = { [unowned self] in ax.show(auth.window, pid: tvPID) }
        let outcome = await connect(teamViewer(), TeamViewerAutomator())
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(field.text, "123456789")
        XCTAssertEqual(auth.field.text, password)
    }

    /// Ссылка сработала — поле главного экрана не трогаем.
    func testTeamViewerLinkWorksFormUntouched() async {
        let main = tvNewMain()
        let auth = FakePasswordWindow(title: "Аутентификация")
        auth.ok.onPress = { [unowned self] in ax.close(auth.window, pid: tvPID) }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.teamViewer, pid: tvPID)
            ax.show(main.window, pid: tvPID)
            clock.at(1500) { [unowned self] in ax.show(auth.window, pid: tvPID) }
        }
        var pressed = false
        main.connect.onPress = { pressed = true }
        let outcome = await connect(teamViewer(), TeamViewerAutomator(texts: tvTexts))
        XCTAssertEqual(outcome, .connected)
        XCTAssertFalse(pressed)
        XCTAssertEqual(main.field.text, "")
        XCTAssertFalse(phases.contains(.typingID))
    }

    /// «Connect» ничего не начал — нейтральный итог, совет вставить ID (приложение кладёт в буфер только ID).
    func testTeamViewerNothingStartedIsUnconfirmedWithIDCopy() async {
        let main = tvNewMain()
        tvLaunchesOnMain(main)
        let outcome = await connect(teamViewer(timeout: 5), TeamViewerAutomator(texts: tvTexts))
        XCTAssertEqual(outcome, .unconfirmed(copyID: true))
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertFalse(finishedPhases.contains(.connectedWithoutPassword))
        XCTAssertTrue(secrets.allSatisfy(\.isEmpty))
    }

    /// Поля ID нет (другой экран) — ничего не вводим, итог нейтральный.
    func testTeamViewerWithoutConnectFieldIsUnconfirmed() async {
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.teamViewer, pid: tvPID)
            ax.show(FakeNode("AXWindow", subrole: "AXStandardWindow", label: "TeamViewer",
                             children: [FakeNode("AXStaticText", label: "Chat")]), pid: tvPID)
        }
        let outcome = await connect(teamViewer(timeout: 5), TeamViewerAutomator(texts: tvTexts))
        XCTAssertEqual(outcome, .unconfirmed(copyID: true))
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    /// TeamViewer пустил без пароля: окно сеанса с ID в заголовке — подключено.
    func testTeamViewerSessionWindowWithoutPasswordIsConnected() async {
        let main = tvNewMain()
        tvLaunchesOnMain(main)
        main.connect.onPress = { [unowned self] in
            let session = FakeNode("AXWindow", subrole: "AXStandardWindow", label: "123 456 789 - TeamViewer",
                                   children: [FakeNode("AXToolbar"), FakeNode("AXGroup")])
            ax.show(session, pid: tvPID)
        }
        let outcome = await connect(teamViewer(), TeamViewerAutomator(texts: tvTexts))
        XCTAssertEqual(outcome, .connectedWithoutPassword)
        XCTAssertEqual(main.field.text, "123456789")
    }

    /// По умолчанию в окне пароля стоит «Cancel» — её не нажимаем, Return тоже не шлём; пароль убран из поля.
    func testDefaultCancelIsNeverPressed() async {
        let field = FakeNode("AXTextField", subrole: "AXSecureTextField")
        let cancel = FakeNode("AXButton", label: "Cancel")
        var cancelPressed = false
        cancel.onPress = { cancelPressed = true }
        let window = FakeNode("AXWindow", subrole: "AXDialog", label: "Authentication", children: [field, cancel])
        window.defaultButtonNode = cancel
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.teamViewer, pid: tvPID)
            ax.show(window, pid: tvPID)
        }
        let outcome = await connect(teamViewer(), TeamViewerAutomator(texts: tvTexts))
        XCTAssertFalse(cancelPressed)
        XCTAssertTrue(keyboard.returns.isEmpty, "Return нажал бы «Cancel»")
        XCTAssertEqual(field.text, "", "пароль не остался в поле")
        if case .failed(.fieldNotFound) = outcome {} else { XCTFail("\(outcome)") }
    }

    /// TeamViewer не выходит вперёд — ID через `AXValue`, «Connect» всё равно нажат.
    func testTeamViewerIDByAXValueWhenNotFrontmost() async {
        launcher.activationWorks = false
        let main = tvNewMain()
        tvLaunchesOnMain(main)
        var pressed = false
        main.connect.onPress = { pressed = true }
        _ = await connect(teamViewer(timeout: 3), TeamViewerAutomator(texts: tvTexts))
        XCTAssertTrue(pressed)
        XCTAssertEqual(main.field.text, "123456789")
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    /// ⌘↩ (без пароля): ID тоже вписывается, окно аутентификации — пользователю; файл паролей не читается.
    func testTeamViewerWithoutPasswordShortcutStillFillsID() async {
        let main = tvNewMain()
        tvLaunchesOnMain(main)
        let auth = FakePasswordWindow(title: "Аутентификация")
        main.connect.onPress = { [unowned self] in ax.show(auth.window, pid: tvPID) }
        let outcome = await connect(teamViewer(withPassword: false), TeamViewerAutomator(texts: tvTexts))
        XCTAssertEqual(outcome, .openedWithoutPassword(.userChoice))
        XCTAssertEqual(main.field.text, "123456789")
        XCTAssertEqual(auth.field.text, "", "пароль вводит пользователь")
        XCTAssertEqual(lookups, 0)
    }

    // MARK: Надписи из файлов программы

    /// `ProviderTexts.load`: ключи AnyDesk, префикс `ad.dlg.closed.` и переводы веб-интерфейса TeamViewer.
    func testTextsLoadFromStringsAndWebLocales() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("rc-texts-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        let res = app.appendingPathComponent("Contents/Resources")
        let en = res.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: en, withIntermediateDirectories: true)
        let strings = """
        "ad.dlg.terminal.title" = "Terminal Session";
        "ad.dlg.connect" = "Connect";
        "ad.dlg.terminal.console" = "Console";
        "ad.dlg.wait_for_accept.msg" = "Please wait for the remote side to accept your session request.";
        "ad.dlg.wait_for_image.msg" = "Waiting for image.";
        "ad.dlg.closed.client_offline.title" = "Client Offline";
        "ad.dlg.closed.msg" = "The session has ended.\\nStatus: %s";
        "ad.dlg.closed.new" = "New Session";
        """
        try strings.write(to: en.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let web = res.appendingPathComponent("BrowserUI_TVOne/locales/uk")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        let json = #"{"remote_support": {"participant_id": {"search_dropdown": {"recent_connections_with_ip": {"placeholder": "Введіть ID"}}}, "connections": {"connect": "Підключитися"}}}"#
        try json.write(to: web.appendingPathComponent("translation.json"), atomically: true, encoding: .utf8)

        let ad = ProviderTexts.load(appURL: app, keys: AnyDeskAutomator.keys)
        XCTAssertEqual(ad.promptTexts, ["terminal session"])
        XCTAssertEqual(ad.promptContinueTitles, ["connect"])
        XCTAssertEqual(ad.promptDefaultTitles, ["console"])
        XCTAssertTrue(ad.progressTexts.contains("please wait for the remote side to accept your session request"))
        XCTAssertEqual(ad.sessionTexts, ["waiting for image"])
        XCTAssertEqual(ad.closedTexts, ["client offline"], "только заголовки и сообщения без подстановок; кнопки — нет")

        let tv = TeamViewerAutomator(texts: ProviderTexts.load(appURL: app, keys: TeamViewerAutomator.keys)).texts
        XCTAssertTrue(tv.connectFieldTexts.contains("введіть id"))
        XCTAssertTrue(tv.connectFieldTexts.contains("partner id"), "прежний интерфейс — надписи по умолчанию")
        XCTAssertTrue(tv.connectButtonTitles.isSuperset(of: ["підключитися", "connect"]))
    }
}

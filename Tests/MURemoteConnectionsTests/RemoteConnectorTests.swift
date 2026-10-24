import XCTest
@testable import MURemoteConnections

/// Подключение на моках AX-дерева: настоящие AnyDesk и TeamViewer не запускаются.
@MainActor
final class RemoteConnectorTests: XCTestCase {
    private let anyDeskPID: Int32 = 4242
    private let password = "Pw-7-секрет"
    private var ax: FakeAX!
    private var launcher: FakeLauncher!
    private var keyboard: FakeKeyboard!
    private var clock: FakeClock!
    private var logger: RecordingLogger!
    private var phases: [ConnectionPhase] = []
    private var lookups = 0
    private var lastSecret: SecretBuffer?

    private let record = ConnectionRecord(sourceRow: 2, name: "Лаборатория Север", id: "123456789", hasPassword: true)
    private let texts = ProviderTexts(passwordWindowTitles: ["Авторизация", "Authorization"],
                                      rejectionTexts: ["Пароль отклонён"], autologinTitles: ["Входить автоматически"])

    override func setUp() async throws {
        ax = FakeAX()
        launcher = FakeLauncher()
        keyboard = FakeKeyboard(ax: ax)
        clock = FakeClock()
        logger = RecordingLogger()
        phases = []
        lookups = 0
        lastSecret = nil
    }

    private func connector() -> RemoteConnector {
        RemoteConnector(ax: ax, launcher: launcher, keyboard: keyboard, clock: clock, logger: logger)
    }

    private func connect(_ request: ConnectRequest? = nil, provider: RemoteProvider? = nil,
                         lookup: PasswordLookup? = nil) async -> ConnectionOutcome {
        let request = request ?? ConnectRequest(record: record, program: .anyDesk)
        let provider = provider ?? AnyDeskAutomator(texts: texts)
        let pw = password
        return await connector().connect(request, provider: provider, password: {
            self.lookups += 1
            if let lookup { return lookup }
            let s = SecretBuffer(pw.utf8)
            self.lastSecret = s
            return .found(s)
        }, progress: { self.phases.append($0) })
    }

    /// AnyDesk запускается по ссылке, окно пароля появляется через `after` мс.
    @discardableResult
    private func anyDeskShowsPassword(after ms: Int = 1000, closeOnOK: Bool = true) -> FakePasswordWindow {
        let w = FakePasswordWindow()
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: anyDeskPID)
            clock.at(clock.milliseconds + ms) { [unowned self] in ax.show(w.window, pid: anyDeskPID) }
        }
        if closeOnOK { w.ok.onPress = { [unowned self] in ax.close(w.window, pid: anyDeskPID) } }
        return w
    }

    // MARK: Успех

    func testAXValueEntersPasswordAndConfirms() async {
        let w = anyDeskShowsPassword()
        let outcome = await connect()
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(launcher.opened, [URL(string: "anydesk:123456789")!])
        XCTAssertEqual(w.field.text, password)
        XCTAssertTrue(keyboard.typed.isEmpty, "через AXValue клавиатура не нужна")
        XCTAssertEqual(w.checkbox.isChecked, false, "автологин выключен")
        XCTAssertEqual(phases.first, .opening)
        XCTAssertTrue(phases.contains(.waiting(elapsed: 0, timeout: 20)))
        XCTAssertTrue(phases.contains(.entered))
        XCTAssertEqual(phases.last, .finished(.connected))
        XCTAssertEqual(lastSecret?.isEmpty, true, "пароль затёрт")
        XCTAssertEqual(logger.events, [.connection(result: "connected", typed: true, milliseconds: clock.milliseconds)])
    }

    /// Окна пароля нет и сеанса не видно — не «подключено без пароля», а «не подтверждено».
    func testNoPasswordWindowAndNoSessionIsUnconfirmed() async {
        launcher.onOpen = { [unowned self] _ in launcher.launch(.anyDesk, pid: anyDeskPID) }
        let outcome = await connect(ConnectRequest(record: record, program: .anyDesk, timeoutSeconds: 5))
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertEqual(phases.compactMap { if case .waiting(let e, _) = $0 { return e } else { return nil } }, [0, 1, 2, 3, 4])
        XCTAssertEqual(lastSecret?.isEmpty, true)
    }

    func testAutologinCheckboxIsTickedWhenAsked() async {
        let w = anyDeskShowsPassword()
        let outcome = await connect(ConnectRequest(record: record, program: .anyDesk, autologin: true))
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(w.checkbox.isChecked, true)
    }

    func testAutologinUsesOnlyCheckboxWhenTitleUnknown() async {
        let w = anyDeskShowsPassword()
        w.checkbox.label = "Log in automatically from now on"
        _ = await connect(ConnectRequest(record: record, program: .anyDesk, autologin: true))
        XCTAssertEqual(w.checkbox.isChecked, true)
    }

    func testCharacterFallbackWhenAXValueRefused() async {
        let w = anyDeskShowsPassword()
        w.field.acceptsAXValue = false
        let outcome = await connect()
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(w.field.text, password)
        XCTAssertEqual(keyboard.typed.count, password.unicodeScalars.count)
        XCTAssertTrue(keyboard.typed.allSatisfy { $0.pid == anyDeskPID }, "нажатия только в AnyDesk")
    }

    func testCharacterFallbackWhenLengthDoesNotMatch() async {
        let w = anyDeskShowsPassword()
        // AX ответил «успешно», но длина поля не та — значит, не взяло.
        w.field.swallowsAXValue = true
        let outcome = await connect()
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(w.field.text, password)
        XCTAssertEqual(keyboard.typed.count, password.unicodeScalars.count)
    }

    func testTypesOnlyIntoTheNewWindow() async {
        // AnyDesk уже открыт, в нём старое окно с защищённым полем (например, пароль настроек).
        launcher.launch(.anyDesk, pid: anyDeskPID)
        let old = FakePasswordWindow(title: "Настройки")
        ax.show(old.window, pid: anyDeskPID)
        let fresh = FakePasswordWindow()
        fresh.ok.onPress = { [unowned self] in ax.close(fresh.window, pid: anyDeskPID) }
        launcher.onOpen = { [unowned self] _ in
            clock.at(clock.milliseconds + 750) { [unowned self] in ax.show(fresh.window, pid: anyDeskPID) }
        }
        let outcome = await connect()
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(fresh.field.text, password)
        XCTAssertEqual(old.field.text, "")
    }

    /// «Повторить» после «Ввод прерван»: вводит в окно, которое открыло прерванное подключение.
    func testRetryReusesWindowOfInterruptedConnection() async {
        let connector = connector()
        let w = anyDeskShowsPassword()
        launcher.activationWorks = false
        let first = await connector.connect(ConnectRequest(record: record, program: .anyDesk), provider: AnyDeskAutomator(texts: texts),
                                            password: { .found(SecretBuffer(self.password.utf8)) }, progress: { _ in })
        XCTAssertEqual(first, .failed(.focusLost))
        XCTAssertEqual(w.field.text, "")
        launcher.activationWorks = true
        launcher.onOpen = nil // окно уже открыто, новое не появится
        let retry = await connector.connect(ConnectRequest(record: record, program: .anyDesk, reuseOpenWindow: true),
                                            provider: AnyDeskAutomator(texts: texts),
                                            password: { .found(SecretBuffer(self.password.utf8)) }, progress: { _ in })
        XCTAssertEqual(retry, .connected)
        XCTAssertEqual(w.field.text, password)
    }

    /// «Повторить» не вводит в окно пароля другого подключения, открытое в той же программе.
    func testRetryDoesNotTypeIntoForeignWindow() async {
        launcher.launch(.anyDesk, pid: anyDeskPID)
        let foreign = FakePasswordWindow()
        ax.show(foreign.window, pid: anyDeskPID)
        let outcome = await connect(ConnectRequest(record: record, program: .anyDesk, timeoutSeconds: 2, reuseOpenWindow: true))
        XCTAssertEqual(outcome, .unconfirmed(copyID: false), "своего окна не появилось")
        XCTAssertEqual(foreign.field.text, "", "в чужое окно ничего не введено")
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    /// Окно прерванного подключения к другой записи «Повторить» тоже не берёт.
    func testRetryForAnotherRecordIgnoresInterruptedWindow() async {
        let connector = connector()
        let w = anyDeskShowsPassword()
        launcher.activationWorks = false
        _ = await connector.connect(ConnectRequest(record: record, program: .anyDesk), provider: AnyDeskAutomator(texts: texts),
                                    password: { .found(SecretBuffer(self.password.utf8)) }, progress: { _ in })
        launcher.activationWorks = true
        launcher.onOpen = nil
        let other = ConnectionRecord(sourceRow: 9, name: "Склад", id: "223456789", hasPassword: true)
        let outcome = await connector.connect(ConnectRequest(record: other, program: .anyDesk, timeoutSeconds: 2, reuseOpenWindow: true),
                                              provider: AnyDeskAutomator(texts: texts),
                                              password: { .found(SecretBuffer("другой".utf8)) }, progress: { _ in })
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertEqual(w.field.text, "")
    }

    /// Bundle id правильный, а подпись — не того разработчика: пароль не вводится.
    func testWrongTeamIDIsNeverTyped() async {
        let w = anyDeskShowsPassword()
        let original = launcher.onOpen
        var team: String? = "XXXXXXXXXX"
        launcher.onOpen = { [unowned self] url in
            original?(url)
            launcher.teams[anyDeskPID] = team
        }
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.untrustedProgram))
        XCTAssertEqual(w.field.text, "")
        XCTAssertTrue(keyboard.typed.isEmpty)
        XCTAssertEqual(lastSecret?.isEmpty, true)
        team = nil
        let unsigned = await connect()
        XCTAssertEqual(unsigned, .failed(.untrustedProgram), "подпись не проверилась — тоже нет")
    }

    func testTeamIDsMatchInstalledApps() {
        XCTAssertEqual(RemoteProgram.anyDesk.teamID, "KHRWM533LU")
        XCTAssertEqual(RemoteProgram.teamViewer.teamID, "H7UGFBUGV6")
    }

    func testSubmittedWhenWindowStaysOpen() async {
        let w = anyDeskShowsPassword(closeOnOK: false)
        let outcome = await connect()
        XCTAssertEqual(outcome, .submitted)
        XCTAssertEqual(w.field.text, password)
    }

    func testReturnKeyWhenNoButton() async {
        let w = anyDeskShowsPassword(closeOnOK: false)
        w.window.defaultButtonNode = nil
        w.ok.label = "Продолжить"
        keyboard.onReturn = { [unowned self] in ax.close(w.window, pid: anyDeskPID) }
        let outcome = await connect()
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(keyboard.returns, [anyDeskPID])
    }

    // MARK: Ошибки

    func testWrongPasswordWhenFieldIsCleared() async {
        let w = anyDeskShowsPassword(closeOnOK: false)
        w.ok.onPress = { [unowned self] in clock.at(clock.milliseconds + 500) { w.field.value = [] } }
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.wrongPassword))
    }

    func testWrongPasswordWhenRejectionWindowAppears() async {
        let w = anyDeskShowsPassword()
        w.ok.onPress = { [unowned self] in
            ax.close(w.window, pid: anyDeskPID)
            clock.at(clock.milliseconds + 1000) { [unowned self] in
                ax.show(FakeNode("AXWindow", label: "Пароль отклонён", children: [FakeNode("AXButton", label: "ОК")]), pid: anyDeskPID)
            }
        }
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.wrongPassword))
    }

    func testWrongPasswordWhenPasswordWindowReappears() async {
        let w = anyDeskShowsPassword()
        w.ok.onPress = { [unowned self] in
            ax.close(w.window, pid: anyDeskPID)
            clock.at(clock.milliseconds + 500) { [unowned self] in ax.show(FakePasswordWindow().window, pid: anyDeskPID) }
        }
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.wrongPassword))
    }

    func testFocusLostMidwayStopsTyping() async {
        let w = anyDeskShowsPassword()
        w.field.acceptsAXValue = false
        keyboard.beforeEachCharacter = { [unowned self] n in if n == 3 { launcher.frontmostProcess = 1 } }
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.focusLost))
        XCTAssertEqual(keyboard.typed.count, 3, "после потери фокуса ни одного символа")
        XCTAssertEqual(w.field.text, "", "начатое затёрто")
        XCTAssertTrue(keyboard.returns.isEmpty)
        XCTAssertEqual(lastSecret?.isEmpty, true)
    }

    func testFocusLostWhenAnyDeskDoesNotComeForward() async {
        let w = anyDeskShowsPassword()
        launcher.activationWorks = false
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.focusLost))
        XCTAssertEqual(w.field.text, "")
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    func testUnfocusableFieldReportsFieldNotFound() async {
        let w = anyDeskShowsPassword()
        w.field.acceptsAXValue = false
        w.field.focusable = false
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.fieldNotFound(structure: AXTree.structure(of: w.window))))
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    func testWrongBundleIDIsNeverTyped() async {
        // Процесс назвался AnyDesk, но его bundle id другой.
        let w = FakePasswordWindow()
        launcher.onOpen = { [unowned self] _ in
            launcher.running[RemoteProgram.anyDesk.bundleID] = anyDeskPID
            launcher.bundles[anyDeskPID] = "com.example.fake"
            ax.show(w.window, pid: anyDeskPID)
        }
        let outcome = await connect(ConnectRequest(record: record, program: .anyDesk, timeoutSeconds: 2))
        XCTAssertEqual(outcome, .failed(.launchFailed))
        XCTAssertEqual(w.field.text, "")
    }

    func testFieldOwnedByAnotherProcessIsRejected() async {
        let w = anyDeskShowsPassword()
        w.field.processID = 999
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.focusLost))
        XCTAssertEqual(w.field.text, "")
    }

    func testPasswordWindowWithoutFieldReportsStructure() async {
        let window = FakeNode("AXWindow", label: "Авторизация", children: [
            FakeNode("AXGroup", children: [FakeNode("AXStaticText", label: "Требуется пароль AnyDesk.")]),
            FakeNode("AXButton", label: "ОК"),
        ])
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: anyDeskPID)
            ax.show(window, pid: anyDeskPID)
        }
        let outcome = await connect()
        guard case .failed(.fieldNotFound(let structure)) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(structure, ["AXWindow", "  AXGroup", "    AXStaticText", "  AXButton"])
        XCTAssertFalse(structure.joined().contains("Авторизация"), "только роли, без надписей")
        XCTAssertLessThan(clock.milliseconds, 5000, "ждём не весь таймаут")
    }

    func testNotInstalled() async {
        launcher.installed = []
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.notInstalled))
        XCTAssertTrue(launcher.opened.isEmpty)
        XCTAssertEqual(lookups, 0, "пароль даже не читается")
    }

    func testNoAccessibilityStillOpensButDoesNotReadPassword() async {
        ax.isTrusted = false
        anyDeskShowsPassword()
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.noAccessibility))
        XCTAssertEqual(launcher.opened.count, 1)
        XCTAssertEqual(lookups, 0)
    }

    func testEntryGoneDoesNotOpen() async {
        let outcome = await connect(lookup: .entryGone)
        XCTAssertEqual(outcome, .failed(.entryGone))
        XCTAssertTrue(launcher.opened.isEmpty)
    }

    func testNoPasswordInFileOnlyOpens() async {
        anyDeskShowsPassword()
        let outcome = await connect(lookup: .noPassword)
        XCTAssertEqual(outcome, .openedWithoutPassword(.notInFile))
        XCTAssertEqual(launcher.opened.count, 1)
    }

    func testWithoutPasswordShortcut() async {
        anyDeskShowsPassword()
        let outcome = await connect(ConnectRequest(record: record, program: .anyDesk, withPassword: false))
        XCTAssertEqual(outcome, .openedWithoutPassword(.userChoice))
        XCTAssertEqual(lookups, 0)
    }

    func testFileUnreadableAtConnectTime() async {
        let outcome = await connector().connect(ConnectRequest(record: record, program: .anyDesk),
                                                provider: AnyDeskAutomator(), password: { throw ConnectionsError.locked },
                                                progress: { _ in })
        XCTAssertEqual(outcome, .failed(.fileUnavailable(.locked)))
        XCTAssertTrue(launcher.opened.isEmpty)
    }

    func testAliasWithTeamViewer() async {
        let alias = ConnectionRecord(sourceRow: 3, name: "Офис", id: "office@ad")
        let outcome = await connect(ConnectRequest(record: alias, program: .teamViewer), provider: TeamViewerAutomator())
        XCTAssertEqual(outcome, .failed(.aliasNotSupported))
    }

    func testLaunchFailed() async {
        launcher.openSucceeds = false
        let outcome = await connect()
        XCTAssertEqual(outcome, .failed(.launchFailed))
    }

    func testCancelWhileWaitingWipesSecret() async {
        launcher.onOpen = { [unowned self] _ in launcher.launch(.anyDesk, pid: anyDeskPID) }
        let task = Task { await connect() }
        clock.at(3000) { task.cancel() }
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(lastSecret?.isEmpty, true)
    }

    // MARK: TeamViewer

    func testTeamViewerEntersPasswordWithoutCheckbox() async {
        let tvPID: Int32 = 5151
        let field = FakeNode("AXTextField", subrole: "AXSecureTextField")
        let box = FakeNode("AXCheckBox", label: "Запомнить")
        box.isChecked = false
        let ok = FakeNode("AXButton", label: "Log In")
        let window = FakeNode("AXWindow", label: "Аутентификация TeamViewer", children: [field, box, ok])
        ok.onPress = { [unowned self] in ax.close(window, pid: tvPID) }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.teamViewer, pid: tvPID)
            clock.at(clock.milliseconds + 2000) { [unowned self] in ax.show(window, pid: tvPID) }
        }
        let tv = ConnectionRecord(sourceRow: 5, name: "Лаборатория Восток", id: "1234567890", program: .teamViewer, hasPassword: true)
        let outcome = await connect(ConnectRequest(record: tv, program: .teamViewer, autologin: true), provider: TeamViewerAutomator())
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(launcher.opened, [URL(string: "teamviewer10://control?device=1234567890")!])
        XCTAssertEqual(field.text, password)
        XCTAssertEqual(box.isChecked, false, "у TeamViewer галочки не трогаем")
    }

    // MARK: Программа записи и надписи

    func testResolvedProgram() {
        let plain = ConnectionRecord(sourceRow: 1, name: "a", id: "123456789")
        XCTAssertEqual(plain.resolvedProgram(default: .teamViewer, ambiguous: true), .teamViewer)
        XCTAssertEqual(plain.resolvedProgram(default: nil, ambiguous: false), .anyDesk)
        XCTAssertNil(plain.resolvedProgram(default: nil, ambiguous: true), "обе программы в файле — спросить")
        let alias = ConnectionRecord(sourceRow: 1, name: "a", id: "a@ad")
        XCTAssertEqual(alias.resolvedProgram(default: nil, ambiguous: true), .anyDesk)
        let tv = ConnectionRecord(sourceRow: 1, name: "a", id: "123456789", program: .teamViewer)
        XCTAssertEqual(tv.resolvedProgram(default: .anyDesk, ambiguous: true), .teamViewer)
    }

    func testTextsLoadFromInstalledAppStrings() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-\(UUID().uuidString)/AnyDesk.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        for (lang, title, rejected, remember) in [("ru", "Авторизация", "Пароль отклонён", "Входить автоматически"),
                                                   ("en", "Authorization", "Password Rejected", "Log in automatically from now on")] {
            let dir = app.appendingPathComponent("Contents/Resources/\(lang).lproj")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try """
            "ad.dlg.passwd.title" = "\(title)";
            "ad.dlg.closed.auth_failed.title" = "\(rejected)";
            "ad.dlg.passwd.remember" = "\(remember)";
            "ad.dlg.ok" = "OK";
            "unrelated" = "x";
            """.write(to: dir.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        // Только файлы программы (без встроенных надписей) — ровно их строки.
        var fileKeys = AnyDeskAutomator.keys
        fileKeys.builtIn = []
        let fromFiles = ProviderTexts.load(appURL: app, keys: fileKeys)
        XCTAssertEqual(fromFiles.passwordWindowTitles, ["авторизация", "authorization"])
        XCTAssertEqual(fromFiles.rejectionTexts, ["пароль отклонён", "password rejected"])
        // Со встроенными en/ru/uk — плюс украинские, которых в этой «программе» нет.
        let texts = ProviderTexts.load(appURL: app, keys: AnyDeskAutomator.keys)
        XCTAssertEqual(texts.passwordWindowTitles, ["авторизация", "authorization", "необхідно вказати пароль"])
        XCTAssertTrue(texts.autologinTitles.contains("log in automatically from now on"))
        XCTAssertTrue(texts.isPasswordWindow(FakeNode("AXWindow", label: "Authorization")))
        XCTAssertFalse(texts.isPasswordWindow(FakeNode("AXWindow", label: "AnyDesk")))
        XCTAssertEqual(ProviderTexts.load(appURL: app.appendingPathComponent("nope"), keys: fileKeys), ProviderTexts())
        XCTAssertEqual(ProviderTexts.load(appURL: app.appendingPathComponent("nope"), keys: AnyDeskAutomator.keys),
                       ProviderTexts.builtIn(keys: AnyDeskAutomator.keys), "файлов нет — встроенные надписи")
    }

    func testLengthsCountScalarsAndUTF16() {
        XCTAssertEqual(RemoteConnector.lengths(of: SecretBuffer("ab".utf8)), [2])
        XCTAssertEqual(RemoteConnector.lengths(of: SecretBuffer("a😀".utf8)), [2, 3])
    }
}

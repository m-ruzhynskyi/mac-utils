import AppKit
@testable import MURemoteConnections
import XCTest

/// Приёмка A-3 по ТЗ § 3.3, § 4, § 6: подключение с вводом пароля. Настоящие AnyDesk/TeamViewer, окна и системные
/// диалоги не нужны — дерево интерфейса, запуск и клавиатура подменены (`FakeAutomation.swift`), пароль идёт из настоящего файла.
@MainActor
final class AcceptanceConnectTests: XCTestCase {
    private let pid: Int32 = 4242
    private var ax: FakeAX!
    private var launcher: FakeLauncher!
    private var keyboard: FakeKeyboard!
    private var clock: FakeClock!
    private var logger: RecordingLogger!
    private var phases: [ConnectionPhase] = []
    private var secrets: [SecretBuffer] = []
    private var lookups = 0
    private var dir: URL!

    private let texts = ProviderTexts(passwordWindowTitles: ["Авторизация"], rejectionTexts: ["Пароль отклонён"],
                                      autologinTitles: ["Входить автоматически"])

    override func setUp() async throws {
        ax = FakeAX(); launcher = FakeLauncher(); keyboard = FakeKeyboard(ax: ax); clock = FakeClock()
        logger = RecordingLogger(); phases = []; secrets = []; lookups = 0
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-a3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func connector() -> RemoteConnector {
        RemoteConnector(ax: ax, launcher: launcher, keyboard: keyboard, clock: clock, logger: logger)
    }

    private func provider(_ program: RemoteProgram = .anyDesk) -> RemoteProvider { RemoteProviders.provider(for: program, texts: texts) }

    /// Пароль берётся «из файла»: замыкание считает вызовы и запоминает буфер, чтобы проверить затирание.
    @discardableResult
    private func connect(_ request: ConnectRequest, program: RemoteProgram = .anyDesk,
                         lookup: @escaping () async throws -> PasswordLookup) async -> ConnectionOutcome {
        await connector().connect(request, provider: provider(program), password: {
            self.lookups += 1
            let result = try await lookup()
            if case .found(let s) = result { self.secrets.append(s) }
            return result
        }, progress: { self.phases.append($0) })
    }

    private func request(_ id: String = "123456789", row: Int = 2, program: RemoteProgram = .anyDesk, withPassword: Bool = true,
                         autologin: Bool = false, timeout: Int = 20) -> ConnectRequest {
        ConnectRequest(record: ConnectionRecord(sourceRow: row, name: "Лаборатория Север", id: id, hasPassword: true), program: program,
                       withPassword: withPassword, autologin: autologin, timeoutSeconds: timeout)
    }

    private func found(_ text: String) -> () async throws -> PasswordLookup { { .found(SecretBuffer(text.utf8)) } }

    /// Программа запускается по ссылке, окно пароля появляется через `ms`.
    @discardableResult
    private func programShowsPassword(after ms: Int = 1000, program: RemoteProgram = .anyDesk, closeOnOK: Bool = true) -> FakePasswordWindow {
        let w = FakePasswordWindow()
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(program, pid: pid)
            clock.at(clock.milliseconds + ms) { [unowned self] in ax.show(w.window, pid: pid) }
        }
        if closeOnOK { w.ok.onPress = { [unowned self] in ax.close(w.window, pid: pid) } }
        return w
    }

    private func assertAllSecretsWiped(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        for s in secrets { XCTAssertTrue(s.isEmpty, "пароль не затёрт \(message)", file: file, line: line) }
    }

    // MARK: Из настоящего файла: «выбор записи → подключение без действий»

    func testConnectFromRealFilePicksRightPasswordAndWipes() async throws {
        let url = dir.appendingPathComponent("list.xlsx")
        try Fixtures.xlsx(rows: Fixtures.cleanRows(30)).write(to: url)
        let snap = try ConnectionsFileStore.read(url: url, sheet: nil)
        let record = snap.records[7]
        let w = programShowsPassword()
        let outcome = await connect(ConnectRequest(record: record, program: .anyDesk, timeoutSeconds: 20)) {
            try ConnectionsFileStore.lookupPassword(for: record, url: url, sheet: nil)
        }
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(launcher.opened.map(\.absoluteString), ["anydesk:\(record.id)"])
        XCTAssertEqual(w.field.text, Fixtures.password(7))
        assertAllSecretsWiped()
        XCTAssertEqual(phases.first, .opening)
        XCTAssertEqual(phases.last, .finished(.connected))
    }

    func testPasswordChangedInFileAfterListLoadedIsUsed() async throws {
        let url = dir.appendingPathComponent("list.xlsx")
        var rows = Fixtures.cleanRows(10)
        try Fixtures.xlsx(rows: rows).write(to: url)
        let record = try ConnectionsFileStore.read(url: url, sheet: nil).records[2]
        rows[3][2] = "Свежий-пароль-№5"
        try Fixtures.xlsx(rows: rows).write(to: url)
        let w = programShowsPassword()
        let outcome = await connect(ConnectRequest(record: record, program: .anyDesk)) {
            try ConnectionsFileStore.lookupPassword(for: record, url: url, sheet: nil)
        }
        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(w.field.text, "Свежий-пароль-№5")
    }

    func testRecordRemovedFromFileDoesNotOpenAnything() async throws {
        let url = dir.appendingPathComponent("list.xlsx")
        var rows = Fixtures.cleanRows(10)
        try Fixtures.xlsx(rows: rows).write(to: url)
        let record = try ConnectionsFileStore.read(url: url, sheet: nil).records[2]
        rows.remove(at: 3)
        try Fixtures.xlsx(rows: rows).write(to: url)
        let outcome = await connect(ConnectRequest(record: record, program: .anyDesk)) {
            try ConnectionsFileStore.lookupPassword(for: record, url: url, sheet: nil)
        }
        XCTAssertEqual(outcome, .failed(.entryGone))
        XCTAssertTrue(launcher.opened.isEmpty)
    }

    func testFileGoneAtConnectTimeIsReportedNotCrashed() async {
        let url = dir.appendingPathComponent("нет.xlsx")
        let record = ConnectionRecord(sourceRow: 2, name: "x", id: "123456789", hasPassword: true)
        let outcome = await connect(ConnectRequest(record: record, program: .anyDesk)) {
            try ConnectionsFileStore.lookupPassword(for: record, url: url, sheet: nil)
        }
        XCTAssertEqual(outcome, .failed(.fileUnavailable(.unavailable)))
        XCTAssertTrue(launcher.opened.isEmpty)
    }

    // MARK: Пароли любого вида

    func testAwkwardPasswordsAreTypedExactlyCharacterByCharacter() async {
        let cases = ["Pw-1-секрет", "p@$$ w0rd!\"'\\<>&", "пароль 🔐 с эмодзи 👨‍👩‍👧", "日本語パスワード", "é́ ü Ω", String(repeating: "Zz9!", count: 125), " пробелы по краям "]
        for pw in cases {
            setUpFresh()
            let w = programShowsPassword()
            w.field.acceptsAXValue = false
            let outcome = await connect(request(), lookup: found(pw))
            XCTAssertEqual(outcome, .connected, pw)
            XCTAssertEqual(w.field.text, pw, "посимвольный ввод исказил пароль")
            XCTAssertTrue(keyboard.typed.allSatisfy { $0.pid == pid })
            assertAllSecretsWiped(pw)
        }
        // То же через AXValue.
        for pw in cases {
            setUpFresh()
            let w = programShowsPassword()
            _ = await connect(request(), lookup: found(pw))
            XCTAssertEqual(w.field.text, pw)
            XCTAssertTrue(keyboard.typed.isEmpty, "AXValue взялось — клавиатура не нужна")
        }
    }

    private func setUpFresh() {
        ax = FakeAX(); launcher = FakeLauncher(); keyboard = FakeKeyboard(ax: ax); clock = FakeClock(); phases = []; secrets = []; lookups = 0
    }

    // MARK: Таймаут и опрос

    func testDefaultTimeoutIsTwentySecondsAndWithoutSessionIsNotSuccess() async {
        XCTAssertEqual(ConnectRequest(record: request().record, program: .anyDesk).timeoutSeconds, 20)
        let poll = RemoteConnector.Timing().poll
        XCTAssertTrue((200...300).contains(poll), "опрос каждые 200–300 мс, сейчас \(poll)")
        launcher.onOpen = { [unowned self] _ in launcher.launch(.anyDesk, pid: pid) }   // запущен, окна пароля нет
        let outcome = await connect(request(), lookup: found("Pw-1"))
        // Не «подключено без пароля»: окна пароля нет, но и сеанса не видно (task-rc-terminal-session, п. 1 и 4).
        XCTAssertEqual(outcome, .unconfirmed(copyID: false), "ни окна пароля, ни сеанса — не подтверждено")
        XCTAssertTrue((20_000...20_400).contains(clock.milliseconds), "ждали \(clock.milliseconds) мс")
        XCTAssertTrue(keyboard.typed.isEmpty)
        XCTAssertFalse(outcome.isSuccess)
        assertAllSecretsWiped()
    }

    func testWindowJustBeforeAndJustAfterTimeout() async {
        for (delay, expectTyped) in [(19_000, true), (21_000, false)] {
            setUpFresh()
            let w = programShowsPassword(after: delay)
            let outcome = await connect(request(), lookup: found("Pw-2"))
            XCTAssertEqual(w.field.text == "Pw-2", expectTyped, "окно через \(delay) мс")
            XCTAssertEqual(outcome, expectTyped ? .connected : .unconfirmed(copyID: false))
        }
    }

    func testCustomTimeoutIsRespected() async {
        launcher.onOpen = { [unowned self] _ in launcher.launch(.anyDesk, pid: pid) }
        _ = await connect(request(timeout: 5), lookup: found("Pw"))
        XCTAssertTrue((5_000...5_400).contains(clock.milliseconds), "\(clock.milliseconds)")
    }

    func testProgramThatNeverStartsIsALaunchError() async {
        let outcome = await connect(request(timeout: 3), lookup: found("Pw"))
        XCTAssertEqual(outcome, .failed(.launchFailed))
        XCTAssertFalse(outcome.isSuccess)
    }

    func testProgressCountsSecondsUpToTimeout() async {
        launcher.onOpen = { [unowned self] _ in launcher.launch(.anyDesk, pid: pid) }
        _ = await connect(request(timeout: 4), lookup: found("Pw"))
        let waits = phases.compactMap { p -> Int? in if case .waiting(let e, let t) = p { XCTAssertEqual(t, 4); return e } else { return nil } }
        XCTAssertEqual(waits, [0, 1, 2, 3, 4].filter { waits.contains($0) })
        XCTAssertGreaterThanOrEqual(waits.count, 4)
    }

    // MARK: Автологин, «без пароля», ссылки

    func testAutologinCheckboxOnlyWhenAskedAndOnlyForAnyDesk() async {
        for (autologin, program, expected) in [(true, RemoteProgram.anyDesk, true), (false, .anyDesk, false), (true, .teamViewer, false)] {
            setUpFresh()
            let w = programShowsPassword(program: program)
            _ = await connect(request(program: program, autologin: autologin), program: program, lookup: found("Pw"))
            XCTAssertEqual(w.checkbox.isChecked, expected, "autologin=\(autologin) \(program)")
            XCTAssertEqual(w.field.text, "Pw")
        }
    }

    func testWithoutPasswordShortcutOpensOnlyAndNeverReadsFile() async {
        let outcome = await connect(request(withPassword: false), lookup: found("Pw"))
        XCTAssertEqual(outcome, .openedWithoutPassword(.userChoice))
        XCTAssertEqual(lookups, 0, "файл с паролями не читается")
        XCTAssertEqual(launcher.opened.count, 1)
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    func testRecordWithoutPasswordOnlyOpens() async {
        let outcome = await connect(request(), lookup: { .noPassword })
        XCTAssertEqual(outcome, .openedWithoutPassword(.notInFile))
        XCTAssertTrue(outcome.isSuccess)
    }

    func testLinksForIDsAliasesAndPrograms() async {
        let cases: [(String, RemoteProgram, String?)] = [
            ("123456789", .anyDesk, "anydesk:123456789"), ("1234567890", .anyDesk, "anydesk:1234567890"), ("office@ad", .anyDesk, "anydesk:office@ad"),
            ("front-desk.2@company", .anyDesk, "anydesk:front-desk.2@company"), ("123456789", .teamViewer, "teamviewer10://control?device=123456789"),
            ("office@ad", .teamViewer, nil),
        ]
        for (id, program, link) in cases {
            setUpFresh()
            let outcome = await connect(request(id, program: program, withPassword: false), program: program, lookup: found("Pw"))
            XCTAssertEqual(launcher.opened.map(\.absoluteString), link.map { [$0] } ?? [], "\(id) \(program)")
            if link == nil { XCTAssertEqual(outcome, .failed(.aliasNotSupported)) }
        }
    }

    func testPasswordNeverInLink() async {
        programShowsPassword()
        _ = await connect(request(), lookup: found("Pw-секрет-в-ссылке"))
        XCTAssertFalse(launcher.opened.map(\.absoluteString).joined().contains("секрет"))
    }

    // MARK: Ошибки § 6

    func testNoAccessibilityOpensWithoutTypingAndWithoutReadingPasswords() async {
        ax.isTrusted = false
        let w = programShowsPassword()
        let outcome = await connect(request(), lookup: found("Pw"))
        XCTAssertEqual(outcome, .failed(.noAccessibility))
        XCTAssertEqual(launcher.opened.count, 1, "программа открыта, чтобы пользователь ввёл пароль сам")
        XCTAssertEqual(lookups, 0, "без разрешения пароль даже не читается")
        XCTAssertEqual(w.field.text, "")
        XCTAssertTrue(keyboard.typed.isEmpty && keyboard.returns.isEmpty)
        XCTAssertFalse(outcome.isSuccess)
    }

    func testNotInstalledDoesNotOpenAndHasDownloadLink() async {
        launcher.installed = []
        let outcome = await connect(request(), lookup: found("Pw"))
        XCTAssertEqual(outcome, .failed(.notInstalled))
        XCTAssertTrue(launcher.opened.isEmpty)
        XCTAssertEqual(lookups, 0)
        XCTAssertEqual(RemoteProgram.anyDesk.downloadURL.absoluteString, "https://anydesk.com/download")
        XCTAssertEqual(RemoteProgram.teamViewer.downloadURL.host, "www.teamviewer.com")
    }

    func testFieldNotFoundTellsToTypeManuallyAndDoesNotTouchClipboard() async {
        let before = NSPasteboard.general.changeCount
        let window = FakeNode("AXWindow", label: "Авторизация", children: [FakeNode("AXButton", label: "ОК")])
        launcher.onOpen = { [unowned self] _ in launcher.launch(.anyDesk, pid: pid); ax.show(window, pid: pid) }
        let outcome = await connect(request(), lookup: found("Pw-секрет"))
        guard case .failed(.fieldNotFound(let structure)) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(structure.joined().contains("секрет"))
        XCTAssertEqual(NSPasteboard.general.changeCount, before, "буфер обмена не используется")
        XCTAssertTrue(keyboard.typed.isEmpty)
        assertAllSecretsWiped()
    }

    func testWrongPasswordIsReportedAndFieldKeptByTheProgram() async {
        let w = programShowsPassword(closeOnOK: false)
        w.ok.onPress = { [unowned self] in
            let alert = FakeNode("AXWindow", label: "Пароль отклонён")
            ax.show(alert, pid: pid)
        }
        let outcome = await connect(request(), lookup: found("Pw-неверный"))
        XCTAssertEqual(outcome, .failed(.wrongPassword))
        assertAllSecretsWiped()
    }

    func testSubmittedWhenWindowStaysOpenWaitingForTheOtherSide() async {
        programShowsPassword(closeOnOK: false)
        let outcome = await connect(request(), lookup: found("Pw"))
        XCTAssertEqual(outcome, .submitted)
        XCTAssertTrue(outcome.isSuccess)
    }

    // MARK: Только в AnyDesk, пока фокус у него (§ 4)

    func testNeverTypesIntoAnotherApplication() async {
        // Впереди окно другой программы; AnyDesk не выходит вперёд.
        let w = programShowsPassword()
        w.field.acceptsAXValue = false
        launcher.activationWorks = false
        launcher.frontmostProcess = 77
        let outcome = await connect(request(), lookup: found("Pw-секрет"))
        XCTAssertEqual(outcome, .failed(.focusLost))
        XCTAssertTrue(keyboard.typed.isEmpty)
        XCTAssertEqual(w.field.text, "")
        assertAllSecretsWiped()
    }

    func testSecureFieldOfAnotherAppWithSimilarWindowIsIgnored() async {
        // Окно «Авторизация» есть у чужого процесса, а у AnyDesk окна пароля нет.
        let other = FakePasswordWindow()
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: pid)
            launcher.bundles[555] = "com.example.other"
            ax.show(other.window, pid: 555)
        }
        let outcome = await connect(request(timeout: 3), lookup: found("Pw"))
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        XCTAssertEqual(other.field.text, "")
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    func testPasswordWindowOpenedBeforeIsNotUsedUnlessRetry() async {
        let old = FakePasswordWindow()
        launcher.launch(.anyDesk, pid: pid)
        ax.show(old.window, pid: pid)
        let neu = FakePasswordWindow()
        launcher.onOpen = { [unowned self] _ in clock.at(clock.milliseconds + 500) { [unowned self] in ax.show(neu.window, pid: pid) } }
        neu.ok.onPress = { [unowned self] in ax.close(neu.window, pid: pid) }
        _ = await connect(request(), lookup: found("Pw-новый"))
        XCTAssertEqual(old.field.text, "", "чужое окно пароля (другое подключение) не трогаем")
        XCTAssertEqual(neu.field.text, "Pw-новый")
    }

    // MARK: Отмена

    func testCancelWhileWaitingWipesPasswordAndTypesNothing() async {
        launcher.onOpen = { [unowned self] _ in launcher.launch(.anyDesk, pid: pid) }
        let task = Task { @MainActor in await self.connect(self.request(), lookup: self.found("Pw-секрет")) }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(keyboard.typed.isEmpty)
        assertAllSecretsWiped()
        XCTAssertFalse(outcome.isSuccess)
    }

    // MARK: Журнал, ход подключения: пароля нет

    func testLogAndPhasesNeverContainPasswordOrID() async {
        let secretText = "Pw-УНИКАЛЬНЫЙ-секрет-31337"
        programShowsPassword()
        _ = await connect(request(), lookup: found(secretText))
        let text = logger.events.map(\.message).joined(separator: "\n") + "\(phases)"
        XCTAssertFalse(text.contains("УНИКАЛЬНЫЙ"), text)
        XCTAssertFalse(text.contains("123456789"))
        XCTAssertTrue(logger.events.contains { if case .connection(let r, let typed, _) = $0 { return r == "connected" && typed } else { return false } })
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789=_ \n")
        XCTAssertTrue(logger.events.map(\.message).joined().unicodeScalars.allSatisfy(allowed.contains))
    }

    // MARK: Перебор сочетаний: инварианты безопасности

    private struct Lcg { var s: UInt64; mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(n)) } }

    func testRandomisedScenariosNeverBreakSecurityInvariants() async {
        var rng = Lcg(s: 20261023)
        let clipboard = NSPasteboard.general.changeCount
        var outcomes: [String: Int] = [:]
        for i in 0..<300 {
            setUpFresh()
            let pw = ["Pw-\(i)-секрет", "a", "🔐x" + String(repeating: "й", count: rng.next(40))][rng.next(3)]
            ax.isTrusted = rng.next(8) != 0
            let w = FakePasswordWindow(nested: rng.next(2) == 0)
            w.field.acceptsAXValue = rng.next(2) == 0
            w.field.swallowsAXValue = rng.next(5) == 0
            w.field.reportsLength = rng.next(3) != 0
            w.field.focusable = rng.next(6) != 0
            if rng.next(4) != 0 { w.ok.onPress = { [unowned self] in ax.close(w.window, pid: pid) } }
            launcher.activationWorks = rng.next(6) != 0
            launcher.frontmostProcess = [1, 77, pid][rng.next(3)]
            let wrongBundle = rng.next(8) == 0
            let showAfter = [0, 500, 3_000, 25_000][rng.next(4)]
            let foreignPID: Int32 = rng.next(6) == 0 ? 999 : 0
            if foreignPID != 0 { w.field.processID = foreignPID }
            launcher.onOpen = { [unowned self] _ in
                launcher.launch(.anyDesk, pid: pid)
                if wrongBundle { launcher.bundles[pid] = "com.example.impostor" }
                clock.at(clock.milliseconds + showAfter) { [unowned self] in ax.show(w.window, pid: pid) }
            }
            let flipAt = rng.next(4) == 0 ? rng.next(8) + 1 : 0
            keyboard.beforeEachCharacter = { [unowned self] n in if n == flipAt { launcher.frontmostProcess = 1 } }
            let withPassword = rng.next(10) != 0
            let outcome = await connect(request(withPassword: withPassword, autologin: rng.next(2) == 0, timeout: 1 + rng.next(20)), lookup: found(pw))
            outcomes[outcome.code, default: 0] += 1

            // Инварианты.
            for t in keyboard.typed {
                XCTAssertEqual(t.pid, pid, "сценарий \(i): ввод не в AnyDesk")
                XCTAssertEqual(launcher.bundles[t.pid], RemoteProgram.anyDesk.bundleID, "сценарий \(i): ввод в процесс с чужим bundle id")
            }
            if wrongBundle { XCTAssertTrue(keyboard.typed.isEmpty && w.field.text.isEmpty, "сценарий \(i)") }
            if !ax.isTrusted { XCTAssertTrue(keyboard.typed.isEmpty && w.field.text.isEmpty && lookups == 0, "сценарий \(i): без Accessibility") }
            if !withPassword { XCTAssertEqual(lookups, 0, "сценарий \(i)") }
            for s in secrets { XCTAssertTrue(s.isEmpty, "сценарий \(i): пароль не затёрт, исход \(outcome.code)") }
            if case .failed(let f) = outcome, f.code == "focus" || f.code == "nofield" {
                XCTAssertEqual(w.field.text, "", "сценарий \(i): после \(f.code) в чужом поле остался пароль")
            }
            if foreignPID != 0 { XCTAssertEqual(w.field.text, "", "сценарий \(i): поле чужого процесса") }
            let log = logger.events.map(\.message).joined() + "\(phases)" + outcome.code
            XCTAssertFalse(log.contains("секрет") || (pw.count > 4 && log.contains(pw)), "сценарий \(i): пароль в журнале")
            XCTAssertTrue(keyboard.returns.allSatisfy { $0 == pid }, "сценарий \(i): Enter не туда")
        }
        XCTAssertEqual(NSPasteboard.general.changeCount, clipboard, "буфер обмена не трогали")
        XCTAssertGreaterThan(outcomes.count, 4, "перебор должен проходить разные исходы: \(outcomes)")
    }
}

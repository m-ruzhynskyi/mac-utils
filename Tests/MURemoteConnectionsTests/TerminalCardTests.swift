import XCTest
@testable import MURemoteConnections

/// rc-console2: карточка «Terminal Session» встроена в большое главное окно AnyDesk (английский интерфейс, Console уже
/// выбрана) и не узнавалась. Надписи — на всех языках сразу (en/ru/uk обязательно), обход — на любой разумной глубине,
/// «Connect» — когда «Console» выбрана или не читается, а «User account» не выбран. Только выдуманные окна и данные.
@MainActor
final class TerminalCardTests: XCTestCase {
    private let pid: Int32 = 7171
    private let password = "Pw-7-выдумка"
    private var ax: FakeAX!
    private var launcher: FakeLauncher!
    private var keyboard: FakeKeyboard!
    private var clock: FakeClock!
    private var phases: [ConnectionPhase] = []
    private var secrets: [SecretBuffer] = []

    private let record = ConnectionRecord(sourceRow: 2, name: "Склад Демо", id: "123456789", hasPassword: true,
                                          account: "demo.admin", hasAccountPassword: true)

    override func setUp() async throws {
        ax = FakeAX(); launcher = FakeLauncher(); keyboard = FakeKeyboard(ax: ax); clock = FakeClock()
        phases = []; secrets = []
    }

    /// Надписи окна на языке программы (из её `Localizable.strings`).
    private struct Language {
        let title, description, console, user, connect, cancel, passwordTitle, passwordMessage: String
    }

    private let english = Language(title: "Terminal Session",
                                   description: "Please select the terminal session you would like to connect to:",
                                   console: "Console", user: "User account", connect: "Connect", cancel: "Cancel",
                                   passwordTitle: "Authorization", passwordMessage: "Administrator account password required.")
    private let russian = Language(title: "Терминальный сеанс",
                                   description: "Выберите сеанс работы с терминалом, к которому Вы хотите подключиться:",
                                   console: "Консоль", user: "Учётная запись", connect: "Подключиться", cancel: "Отмена",
                                   passwordTitle: "Авторизация", passwordMessage: "Требуется пароль учётной записи администратора.")
    private let ukrainian = Language(title: "Термінальний сеанс",
                                     description: "Будь ласка, виберіть термінальний сеанс, до якого Ви хочете підключитися:",
                                     console: "Консоль", user: "Обліковий запис користувача", connect: "Підключитися",
                                     cancel: "Скасувати", passwordTitle: "Необхідно вказати пароль",
                                     passwordMessage: "Потрібен пароль облікового запису адміністратора.")

    /// Карточка как в nib (`ADSessionTerminalDialogViewController`): заголовок, описание, радиокнопки, поле, кнопки.
    private final class Card {
        let root: FakeNode
        let console: FakeNode
        let user: FakeNode
        let login: FakeNode
        let connect: FakeNode
        let cancel: FakeNode
        var log: [String] = []

        init(_ l: Language, consoleChecked: Bool? = true, userChecked: Bool? = false, consoleTitled: Bool = true) {
            console = FakeNode("AXRadioButton", label: consoleTitled ? l.console : nil)
            console.isChecked = consoleChecked
            user = FakeNode("AXRadioButton", label: l.user)
            user.isChecked = userChecked
            login = FakeNode("AXTextField")
            connect = FakeNode("AXButton", label: l.connect)
            cancel = FakeNode("AXButton", label: l.cancel)
            let consoleRow = consoleTitled ? [console] : [console, FakeNode("AXStaticText", label: l.console)]
            root = FakeNode("AXGroup", children: [
                FakeNode("AXStaticText", label: l.title), FakeNode("AXStaticText", label: l.description),
                FakeNode("AXGroup", children: [FakeNode("AXGroup", children: consoleRow),
                                               FakeNode("AXGroup", children: [user, login])]),
                cancel, connect])
            console.onPress = { [unowned self] in log.append("console"); user.isChecked = user.isChecked.map { _ in false } }
            user.onPress = { [unowned self] in log.append("user") }
            cancel.onPress = { [unowned self] in log.append("cancel") }
            connect.onPress = { [unowned self] in log.append("connect") }
        }
    }

    /// `node` на глубине `depth` (считая окно нулевым) внутри цепочки групп.
    private func nest(_ node: FakeNode, depth: Int) -> FakeNode {
        var current = node
        for _ in 1..<max(depth, 1) { current = FakeNode("AXGroup", children: [current]) }
        return current
    }

    /// Плитки главного экрана AnyDesk: сотни узлов перед карточкой.
    private func tiles(_ count: Int) -> FakeNode {
        FakeNode("AXScrollArea", children: [FakeNode("AXList", children: (0..<count).map { i in
            FakeNode("AXGroup", children: [FakeNode("AXImage"), FakeNode("AXStaticText", label: "Плитка \(i)"),
                                           FakeNode("AXButton", label: "…"), FakeNode("AXGroup", children: [FakeNode("AXImage")])])
        })])
    }

    /// Главное окно AnyDesk (было открыто до ссылки): вкладки, плитки, место для диалога сеанса.
    private func mainWindow(_ slot: FakeNode) -> FakeNode {
        FakeNode("AXWindow", subrole: "AXStandardWindow", label: "AnyDesk",
                 children: [FakeNode("AXToolbar", children: [FakeNode("AXTabGroup")]), tiles(400), slot])
    }

    /// Окно пароля в той же вкладке: надпись, сообщение, защищённое поле, «OK».
    private func passwordDialog(_ l: Language) -> (group: FakeNode, field: FakeNode) {
        let field = FakeNode("AXTextField", subrole: "AXSecureTextField")
        let ok = FakeNode("AXButton", label: "OK")
        return (FakeNode("AXGroup", children: [FakeNode("AXStaticText", label: l.passwordTitle),
                                               FakeNode("AXStaticText", label: l.passwordMessage), field, ok]), field)
    }

    private func connect(_ texts: ProviderTexts, _ adjust: (inout RemoteConnector.Timing) -> Void = { _ in },
                         timeout: Int = 20) async -> (ConnectionOutcome, RemoteConnector) {
        let c = RemoteConnector(ax: ax, launcher: launcher, keyboard: keyboard, clock: clock)
        adjust(&c.timing)
        let pw = password
        let outcome = await c.connect(ConnectRequest(record: record, program: .anyDesk, timeoutSeconds: timeout),
                                      provider: AnyDeskAutomator(texts: texts), password: {
            let s = SecretBuffer(pw.utf8); self.secrets.append(s); return .found(s)
        }, accountPassword: {
            let s = SecretBuffer("Win-7-выдумка".utf8); self.secrets.append(s); return .found(s)
        }, progress: { self.phases.append($0) })
        return (outcome, c)
    }

    /// Надписи программы, которая есть только на одном языке (`lang`), + встроенные en/ru/uk.
    private func texts(installed lang: String?) throws -> ProviderTexts {
        guard let lang else { return ProviderTexts.builtIn(keys: AnyDeskAutomator.keys) }
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("rc2-\(UUID().uuidString)/AnyDesk.app")
        addTeardownBlock { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let dir = app.appendingPathComponent("Contents/Resources/\(lang).lproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let table = lang == "ru" ? AnyDeskAutomator.anyDeskRussian : lang == "uk" ? AnyDeskAutomator.anyDeskUkrainian
                                                                                  : AnyDeskAutomator.anyDeskEnglish
        let body = table.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
        try body.write(to: dir.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        return ProviderTexts.load(appURL: app, keys: AnyDeskAutomator.keys)
    }

    /// Сценарий пользователя: главное окно открыто, через 0,5 с в нём карточка на глубине `depth`; «Connect» уводит её,
    /// через 1 с на её месте окно пароля.
    private func run(_ l: Language, texts: ProviderTexts, depth: Int = 12, card: Card? = nil,
                     _ adjust: (inout RemoteConnector.Timing) -> Void = { _ in }) async -> (ConnectionOutcome, Card, FakeNode, RemoteConnector) {
        let card = card ?? Card(l)
        let slot = FakeNode("AXGroup")
        let main = mainWindow(slot)
        launcher.launch(.anyDesk, pid: pid)
        ax.show(main, pid: pid)
        let (dialog, field) = passwordDialog(l)
        let ok = dialog.kids.last!
        ok.onPress = { [unowned self] in slot.kids = [FakeNode("AXStaticText", label: "Waiting for image.")]; ax.show(FakeNode("AXGroup"), pid: pid) }
        let connectPress = card.connect.onPress
        card.connect.onPress = { [unowned self] in
            connectPress?()
            slot.kids = []
            clock.at(clock.milliseconds + 1000) { [unowned self] in
                slot.kids = [nest(dialog, depth: depth)]
                for n in slot.descendants() { n.ax = ax; n.processID = pid }
            }
        }
        launcher.onOpen = { [unowned self] _ in
            clock.at(500) { [unowned self] in
                slot.kids = [nest(card.root, depth: depth)]
                for n in slot.descendants() { n.ax = ax; n.processID = pid }
            }
        }
        let (outcome, c) = await connect(texts, adjust)
        return (outcome, card, field, c)
    }

    // MARK: Где окно и глубина

    /// Баг пользователя (1.10.3): английская карточка глубоко в большом главном окне, Console уже выбрана —
    /// «Connect» нажат один раз, Console не трогали, пароль AnyDesk введён в окно пароля после неё.
    func testCardDeepInBigMainWindowIsRecognisedAndConnected() async throws {
        let (outcome, card, field, _) = await run(english, texts: try texts(installed: "ru"), depth: 14)
        XCTAssertEqual(card.log, ["connect"], "Console уже выбрана — только «Connect», один раз")
        XCTAssertEqual(field.text, password)
        XCTAssertEqual(outcome, .connected)
        XCTAssertTrue(phases.contains(.intermediate(.sessionChoice)))
        XCTAssertTrue(secrets.allSatisfy(\.isEmpty))
        // Сценарий действительно за прежними пределами обхода (глубина 14, 600 узлов).
        XCTAssertGreaterThan(card.root.descendants().count + 400 * 6, 600)
    }

    /// Карточка на глубине 10–15 при разном объёме окна — узнаётся всегда.
    func testCardFoundAtDepthsTenToFifteen() async throws {
        let builtIn = try texts(installed: nil)
        for depth in 10...15 {
            setUpFakes()
            let (outcome, card, field, _) = await run(english, texts: builtIn, depth: depth)
            XCTAssertEqual(card.log, ["connect"], "глубина \(depth)")
            XCTAssertEqual(field.text, password, "глубина \(depth)")
            XCTAssertEqual(outcome, .connected, "глубина \(depth)")
        }
    }

    private func setUpFakes() {
        ax = FakeAX(); launcher = FakeLauncher(); keyboard = FakeKeyboard(ax: ax); clock = FakeClock(); phases = []; secrets = []
    }

    // MARK: Языки: en/ru/uk при любом языке программы и системы

    /// Окно на английском, русском и украинском; программа с надписями только на одном языке (или без файлов) —
    /// окно узнано, «Connect», пароль введён.
    func testEnglishRussianUkrainianCardsWhateverLanguageIsInstalled() async throws {
        for installed in [nil, "en", "ru", "uk"] as [String?] {
            let loaded = try texts(installed: installed)
            for language in [english, russian, ukrainian] {
                setUpFakes()
                let (outcome, card, field, _) = await run(language, texts: loaded)
                let label = "\(language.title) при \(installed ?? "встроенных")"
                XCTAssertEqual(card.log, ["connect"], label)
                XCTAssertEqual(field.text, password, label)
                XCTAssertEqual(outcome, .connected, label)
            }
        }
    }

    /// Встроенные надписи покрывают окно пароля, отказ, прогресс, сеанс и «Terminal Session» на трёх языках.
    func testBuiltInTextsCoverThreeLanguages() {
        let t = ProviderTexts.builtIn(keys: AnyDeskAutomator.keys)
        for title in ["terminal session", "терминальный сеанс", "термінальний сеанс"] { XCTAssertTrue(t.promptTexts.contains(title), title) }
        for c in ["console", "консоль"] { XCTAssertTrue(t.promptDefaultTitles.contains(c), c) }
        for c in ["connect", "подключиться", "підключитися"] { XCTAssertTrue(t.promptContinueTitles.contains(c), c) }
        for u in ["user account", "учётная запись", "обліковий запис користувача"] { XCTAssertTrue(t.promptOtherTitles.contains(u), u) }
        for p in ["authorization", "авторизация", "необхідно вказати пароль"] { XCTAssertTrue(t.passwordWindowTitles.contains(p), p) }
        for r in ["password rejected", "пароль отклонён", "з’єднання відхилено"] { XCTAssertTrue(t.rejectionTexts.contains(r), r) }
        for a in ["administrator account password required", "требуется пароль учётной записи администратора",
                  "потрібен пароль облікового запису адміністратора"] { XCTAssertTrue(t.accountPasswordTexts.contains(a), a) }
        for s in ["waiting for image", "ожидание изображения", "з'єднання встановлено.  очікую зображення"] {
            XCTAssertTrue(t.sessionTexts.contains(s), s)
        }
        XCTAssertTrue(t.progressTexts.contains("connection in progress. please wait"))
        XCTAssertEqual(t.matchedKeys["terminal session"], "ad.dlg.terminal.title")
        XCTAssertEqual(t.matchedKeys["термінальний сеанс"], "ad.dlg.terminal.title")

        let tv = TeamViewerAutomator(texts: ProviderTexts.builtIn(keys: TeamViewerAutomator.keys)).texts
        for f in ["id, ip address, or hostname", "идентификатор, ip-адрес или имя хоста", "ідентифікатор, ip-адреса або ім’я хоста"] {
            XCTAssertTrue(tv.connectFieldTexts.contains(f), f)
        }
        XCTAssertTrue(tv.connectButtonTitles.isSuperset(of: ["connect", "подключиться", "підключитися"]))
    }

    // MARK: Состояние «Console»

    /// Console выбрана, но состояние не читается (nil), нажатие не проходит, «User account» не выбран (false или nil) —
    /// «Connect» нажат, пароль введён.
    func testUnreadableConsoleWithUserAccountNotSelectedConnects() async throws {
        let builtIn = try texts(installed: nil)
        for userState in [false, nil] as [Bool?] {
            setUpFakes()
            let card = Card(english, consoleChecked: nil, userChecked: userState)
            card.console.pressFails = true
            let (outcome, _, field, _) = await run(english, texts: builtIn, card: card)
            XCTAssertEqual(card.log.filter { $0 == "connect" }.count, 1, "User account: \(String(describing: userState))")
            XCTAssertFalse(card.log.contains("user"))
            XCTAssertEqual(field.text, password)
            XCTAssertEqual(outcome, .connected)
        }
    }

    /// «User account» выбран, «Console» не нажимается — «Connect» не нажат никогда; итог «сеанс не выбран».
    func testUserAccountSelectedAndConsoleStuckNeverConnects() async throws {
        let builtIn = try texts(installed: nil)
        for consoleState in [false, nil] as [Bool?] {
            setUpFakes()
            let card = Card(english, consoleChecked: consoleState, userChecked: true)
            card.console.pressFails = true
            let (outcome, _, field, _) = await run(english, texts: builtIn, card: card) { $0.promptTimeout = 10_000 }
            XCTAssertFalse(card.log.contains("connect"), "Console: \(String(describing: consoleState))")
            XCTAssertFalse(card.log.contains("user"))
            XCTAssertEqual(card.user.isChecked, true)
            XCTAssertEqual(outcome, .sessionNotChosen)
            XCTAssertTrue(phases.contains(.intermediate(.chooseConsole)))
            XCTAssertEqual(field.text, "")
            XCTAssertTrue(keyboard.typed.isEmpty)
        }
    }

    /// Подпись «Console» не у радиокнопки, а в соседней надписи — радиокнопка находится, выбирается, затем «Connect».
    func testConsoleCaptionInNeighbouringStaticText() async throws {
        let card = Card(english, consoleChecked: false, userChecked: true, consoleTitled: false)
        let (outcome, _, field, _) = await run(english, texts: try texts(installed: nil), card: card)
        XCTAssertEqual(card.log, ["console", "connect"])
        XCTAssertEqual(field.text, password)
        XCTAssertEqual(outcome, .connected)
    }

    // MARK: Диагностика

    /// Окно не узнано (незнакомая карточка), к таймауту — «не подтверждено» и «Диагностика»: роли, глубина, ключи
    /// совпавших надписей программы; ни имени записи, ни ID, ни прочих надписей.
    func testUnconfirmedLeavesDiagnosticsWithoutTexts() async throws {
        let slot = FakeNode("AXGroup", children: [nest(FakeNode("AXGroup", children: [
            FakeNode("AXStaticText", label: "Склад Демо 123 456 789"), FakeNode("AXStaticText", label: "Терминальный сеанс?"),
            FakeNode("AXButton", label: "Connect"), FakeNode("AXRadioButton", label: "Console")]), depth: 8)])
        launcher.launch(.anyDesk, pid: pid)
        ax.show(mainWindow(slot), pid: pid)
        let (outcome, c) = await connect(try texts(installed: nil), timeout: 3)
        XCTAssertEqual(outcome, .unconfirmed(copyID: false))
        let lines = c.lastDiagnostics
        XCTAssertTrue(lines.first?.hasPrefix("# window 1:") == true, "\(lines.prefix(1))")
        XCTAssertTrue(lines.contains { $0.hasSuffix("AXButton ← ad.dlg.connect") })
        XCTAssertTrue(lines.contains { $0.contains("AXRadioButton") && $0.hasSuffix("← ad.dlg.terminal.console") })
        let joined = lines.joined(separator: "\n")
        for leak in ["Склад", "123", "456", "Плитка", "Терминальный", "AnyDesk"] { XCTAssertFalse(joined.contains(leak), leak) }
    }
}

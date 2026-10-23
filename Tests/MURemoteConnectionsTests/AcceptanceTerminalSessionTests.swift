import Foundation
@testable import MURemoteConnections
import XCTest

/// Приёмка исправления «ложное „Подключено без пароля“» (.audit/task-rc-terminal-session.md): AnyDesk с промежуточным окном
/// «Terminal Session» и TeamViewer нового интерфейса. Настоящие программы, Accessibility и экран не нужны: дерево, запуск,
/// клавиатура и время подменены. Тексты окон берутся тем же путём, что в приложении — из `Localizable.strings` / переводов
/// программы (здесь — маленькая копия бандла с настоящими строками), а не вшиты в тест.
///
/// Тесты нового поведения пропускаются (`XCTSkip`), пока в `ProviderTexts` нет полей промежуточных окон (ветка
/// fix/rc-terminal-session ещё не влита): без них результат «не подтверждено» невозможен.
@MainActor
final class AcceptanceTerminalSessionTests: XCTestCase {
    private let pid: Int32 = 5151
    private var ax: TSAX!
    private var launcher: FakeLauncher!
    private var keyboard: TSKeyboard!
    private var clock: FakeClock!
    private var phases: [(phase: ConnectionPhase, at: Int)] = []
    private var dir: URL!
    private var logger = RecordingLogger()

    private static let forbidden: Set<String> = ["Cancel", "Deny", "Close", "Отмена", "Скасувати", "Clear all", "Search and Connect ⌘K"]

    override func setUp() async throws {
        ax = TSAX(); launcher = FakeLauncher(); clock = FakeClock(); phases = []; logger = RecordingLogger()
        keyboard = TSKeyboard(ax: ax)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Окружение

    private func requireNewAPI() throws {
        let has = Mirror(reflecting: ProviderTexts()).children.contains { $0.label == "promptTexts" }
        try XCTSkipUnless(has, "ожидает API fix/rc-terminal-session: ProviderTexts.promptTexts/sessionTexts/connectFieldTexts")
    }

    private enum Lang: String, CaseIterable { case en, ru, uk }

    private static let adStrings: [Lang: [String: String]] = [
        .en: ["ad.dlg.terminal.title": "Terminal Session",
              "ad.dlg.terminal.users_logged_on": "Please select the terminal session you would like to connect to:",
              "ad.dlg.terminal.console": "Console", "ad.dlg.terminal.user": "User account",
              "ad.dlg.connect": "Connect", "ad.dlg.cancel": "Cancel", "ad.dlg.ok": "OK",
              "ad.dlg.connect.msg": "Connection in progress. Please wait.", "ad.dlg.connect.title": "Connecting...",
              "ad.dlg.wait_for_accept.msg": "Please wait for the remote side to accept your session request.",
              "ad.dlg.wait_for_accept.title": "Connecting...",
              "ad.dlg.wait_for_image.msg": "Waiting for image.", "ad.dlg.wait_for_image.title": "Connected",
              "ad.dlg.passwd.msg.pwd_required.user": "User account password required.",
              "ad.dlg.passwd.title": "Authorization", "ad.dlg.passwd.remember": "Log in automatically from now on",
              "ad.dlg.closed.auth_failed.title": "Password Rejected"],
        .ru: ["ad.dlg.terminal.title": "Терминальный сеанс",
              "ad.dlg.terminal.users_logged_on": "Выберите сеанс работы с терминалом, к которому Вы хотите подключиться:",
              "ad.dlg.terminal.console": "Консоль", "ad.dlg.terminal.user": "Учётная запись",
              "ad.dlg.connect": "Подключиться", "ad.dlg.cancel": "Отмена", "ad.dlg.ok": "ОК",
              "ad.dlg.wait_for_image.msg": "Ожидание изображения.", "ad.dlg.wait_for_image.title": "Подключено",
              "ad.dlg.passwd.msg.pwd_required.user": "Требуется пароль учётной записи пользователя.",
              "ad.dlg.passwd.title": "Авторизация", "ad.dlg.passwd.remember": "Входить автоматически",
              "ad.dlg.closed.auth_failed.title": "Пароль отклонён"],
        .uk: ["ad.dlg.terminal.title": "Термінальний сеанс",
              "ad.dlg.terminal.users_logged_on": "Будь ласка, виберіть термінальний сеанс, до якого Ви хочете підключитися:",
              "ad.dlg.terminal.console": "Консоль", "ad.dlg.terminal.user": "Обліковий запис користувача",
              "ad.dlg.connect": "Підключитися", "ad.dlg.cancel": "Скасувати", "ad.dlg.ok": "OK",
              "ad.dlg.wait_for_image.msg": "З'єднання встановлено.  Очікую зображення.", "ad.dlg.wait_for_image.title": "Підключено",
              "ad.dlg.passwd.msg.pwd_required.user": "Потрібен пароль облікового запису користувача.",
              "ad.dlg.passwd.title": "Необхідно вказати пароль", "ad.dlg.passwd.remember": "Входити автоматично",
              "ad.dlg.closed.auth_failed.title": "Пароль відхилено"],
    ]

    /// Копия бандла AnyDesk: только `Localizable.strings` на трёх языках.
    private func makeAnyDeskApp(_ langs: [Lang] = Lang.allCases) throws -> URL {
        let app = dir.appendingPathComponent("AnyDesk.app")
        for lang in langs {
            let lproj = app.appendingPathComponent("Contents/Resources/\(lang.rawValue).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: Self.adStrings[lang]!, format: .xml, options: 0)
            try data.write(to: lproj.appendingPathComponent("Localizable.strings"))
        }
        return app
    }

    /// Копия бандла TeamViewer: переводы веб-интерфейса `BrowserUI_TVOne/locales/en/translation.json`.
    private func makeTeamViewerApp() throws -> URL {
        let app = dir.appendingPathComponent("TeamViewer.app")
        let en = app.appendingPathComponent("Contents/Resources/BrowserUI_TVOne/locales/en")
        try FileManager.default.createDirectory(at: en, withIntermediateDirectories: true)
        let json: [String: Any] = ["remote_support": [
            "connections": ["connect": "Connect"],
            "participant_id": ["search_dropdown": ["recent_connections_with_ip": [
                "label": "ID, IP address, or hostname", "placeholder": "Enter end user’s ID, IP, or hostname"]]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: en.appendingPathComponent("translation.json"))
        return app
    }

    private func provider(_ program: RemoteProgram, app: URL) -> RemoteProvider {
        RemoteProviders.provider(for: program, texts: ProviderTexts.load(appURL: app, keys: RemoteProviders.keys(for: program)))
    }

    private func connector() -> RemoteConnector {
        RemoteConnector(ax: ax, launcher: launcher, keyboard: keyboard, clock: clock, logger: logger)
    }

    private func request(_ id: String, program: RemoteProgram, timeout: Int = 20) -> ConnectRequest {
        ConnectRequest(record: ConnectionRecord(sourceRow: 2, name: "Лаборатория Север", id: id, hasPassword: true), program: program,
                       withPassword: true, autologin: false, timeoutSeconds: timeout)
    }

    @discardableResult
    private func run(_ request: ConnectRequest, provider: RemoteProvider, password: String? = "Pw-секрет-1", accountPassword: String? = nil, checkForbidden: Bool = true,
                     file: StaticString = #filePath, line: UInt = #line) async -> ConnectionOutcome {
        let outcome = await connector().connect(request, provider: provider, password: {
            guard let password else { return .noPassword }
            return .found(SecretBuffer(password.utf8))
        }, accountPassword: accountPassword.map { value in { .found(SecretBuffer(value.utf8)) } },
           progress: { self.phases.append(($0, self.clock.milliseconds)) })
        if checkForbidden { assertNoForbiddenPresses(file: file, line: line) }
        assertNoSecretsInLogs([password, accountPassword, "Pw-секрет-1"].compactMap { $0 }, file: file, line: line)
        return outcome
    }

    private func assertNoForbiddenPresses(file: StaticString = #filePath, line: UInt = #line) {
        for name in ax.pressLog where Self.forbidden.contains(name) {
            XCTFail("нажато «\(name)» — отмену/отказ/закрытие/очистку не нажимаем никогда", file: file, line: line)
        }
    }

    /// Журнал и итог не содержат паролей и логинов (ТЗ § 6: «пароль нигде»).
    private func assertNoSecretsInLogs(_ secrets: [String], file: StaticString = #filePath, line: UInt = #line) {
        let text = logger.events.map { $0.message + " " + String(describing: $0) }.joined(separator: "\n")
        for secret in secrets where secret.count > 3 { XCTAssertFalse(text.contains(secret), "секрет в журнале", file: file, line: line) }
    }

    private func finishedAt() -> Int? {
        phases.first { if case .finished = $0.phase { return true } else { return false } }?.at
    }

    /// Программа запущена ссылкой: окно(а) появляются через заданное время.
    private func launches(_ program: RemoteProgram, windows: [(delay: Int, window: TSNode)]) {
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(program, pid: pid)
            for (delay, window) in windows { clock.at(clock.milliseconds + delay) { [unowned self] in ax.show(window, pid: pid) } }
        }
    }

    // MARK: Окна AnyDesk

    private struct Terminal {
        let window, console, user, userField, cancel, connect: TSNode
    }

    private func terminal(_ lang: Lang = .en, cancelIsDefault: Bool = false, order: [Int] = [0, 1], nested: Bool = false) -> Terminal {
        let s = Self.adStrings[lang]!
        let console = TSNode("AXRadioButton", label: s["ad.dlg.terminal.console"]); console.isChecked = true
        let user = TSNode("AXRadioButton", label: s["ad.dlg.terminal.user"]); user.isChecked = false
        let userField = TSNode("AXTextField")
        let cancel = TSNode("AXButton", label: s["ad.dlg.cancel"])
        let connect = TSNode("AXButton", label: s["ad.dlg.connect"])
        let radios = TSNode("AXRadioGroup", children: [console, user])
        let message = TSNode("AXStaticText", label: s["ad.dlg.terminal.users_logged_on"])
        let buttons = order == [0, 1] ? [cancel, connect] : [connect, cancel]
        let body: [TSNode] = nested ? [TSNode("AXGroup", children: [message, TSNode("AXGroup", children: [radios, userField])]) ] + buttons
                                    : [message, radios, userField] + buttons
        let window = TSNode("AXWindow", subrole: "AXDialog", label: s["ad.dlg.terminal.title"], children: body)
        window.defaultButtonNode = cancelIsDefault ? cancel : connect
        return Terminal(window: window, console: console, user: user, userField: userField, cancel: cancel, connect: connect)
    }

    private struct Password { let window, field, checkbox, ok: TSNode }

    private func passwordWindow(_ lang: Lang = .en) -> Password {
        let s = Self.adStrings[lang]!
        let field = TSNode("AXTextField", subrole: "AXSecureTextField")
        let box = TSNode("AXCheckBox", label: s["ad.dlg.passwd.remember"]); box.isChecked = false
        let ok = TSNode("AXButton", label: s["ad.dlg.ok"])
        let window = TSNode("AXWindow", subrole: "AXDialog", label: s["ad.dlg.passwd.title"],
                            children: [TSNode("AXStaticText", label: "AnyDesk password required."), field, box, ok])
        window.defaultButtonNode = ok
        return Password(window: window, field: field, checkbox: box, ok: ok)
    }

    private func sessionWindow(_ lang: Lang = .en) -> TSNode {
        let s = Self.adStrings[lang]!
        return TSNode("AXWindow", label: "AnyDesk", children: [TSNode("AXStaticText", label: s["ad.dlg.wait_for_image.msg"])])
    }

    // MARK: AnyDesk: Terminal Session

    /// Основной сценарий из жалобы: Terminal Session → «Connect» сам (Console) → окно пароля → пароль → «Подключено» только
    /// когда сеанс подтверждён (окно «Waiting for image»).
    func testTerminalSessionThenPasswordThenConfirmedSession() async throws {
        try requireNewAPI()
        for lang in Lang.allCases {
            setUpFresh()
            let app = try makeAnyDeskApp()
            let t = terminal(lang), pw = passwordWindow(lang), session = sessionWindow(lang)
            var sessionShownAt: Int?
            launches(.anyDesk, windows: [(500, t.window)])
            t.connect.onPress = { [unowned self] in
                ax.close(t.window, pid: pid)
                clock.at(clock.milliseconds + 800) { [unowned self] in ax.show(pw.window, pid: pid) }
            }
            pw.ok.onPress = { [unowned self] in
                ax.close(pw.window, pid: pid)
                clock.at(clock.milliseconds + 500) { [unowned self] in sessionShownAt = clock.milliseconds; ax.show(session, pid: pid) }
            }
            let outcome = await run(request("123456789", program: .anyDesk), provider: provider(.anyDesk, app: app))
            XCTAssertEqual(outcome.code, "connected", "\(lang)")
            XCTAssertTrue(outcome.isSuccess, "\(lang)")
            XCTAssertEqual(t.connect.pressCount, 1, "\(lang): «Connect» нажат сам, один раз")
            XCTAssertEqual(t.cancel.pressCount, 0, "\(lang): Cancel не нажимается")
            XCTAssertEqual(t.console.pressCount, 0, "\(lang): выбор по умолчанию (Console) не трогаем")
            XCTAssertEqual(t.user.pressCount, 0, "\(lang)")
            XCTAssertTrue(t.console.isChecked == true && t.user.isChecked == false, "\(lang)")
            XCTAssertEqual(t.userField.text, "", "\(lang): в поле учётной записи ничего не вписано")
            XCTAssertEqual(pw.field.text, "Pw-секрет-1", "\(lang): пароль введён в окно пароля")
            XCTAssertTrue(["", "Pw-секрет-1"].contains(keyboard.typedText), "\(lang): напечатан только пароль (или ничего: он ушёл через AX)")
            XCTAssertFalse(keyboard.typedInto.contains { $0 !== pw.field }, "\(lang): символы только в защищённое поле")
            XCTAssertEqual(pw.checkbox.isChecked, false, "\(lang): автологин не запрашивали")
            if let sessionShownAt, let fin = finishedAt() {
                XCTAssertGreaterThanOrEqual(fin, sessionShownAt, "\(lang): «Подключено» только после подтверждения сеанса")
            } else { XCTFail("\(lang): нет подтверждения сеанса или итога") }
        }
    }

    /// Пока Terminal Session открыт, ничего не печатается и Return не уходит (Cancel может быть кнопкой по умолчанию).
    func testNothingTypedAndNoReturnWhileTerminalSessionIsOpen() async throws {
        try requireNewAPI()
        let app = try makeAnyDeskApp()
        let t = terminal(.en, cancelIsDefault: true)
        launches(.anyDesk, windows: [(500, t.window)])  // Connect не закрывает окно
        let outcome = await run(request("123456789", program: .anyDesk, timeout: 30), provider: provider(.anyDesk, app: app))
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertEqual(outcome.code, "unconfirmed")
        XCTAssertEqual(t.cancel.pressCount, 0)
        XCTAssertTrue(keyboard.typed.isEmpty, "пароль не печатается в окно выбора сеанса")
        XCTAssertTrue(keyboard.returns.isEmpty, "Return не отправлен — по умолчанию там Cancel")
        XCTAssertEqual(t.userField.text, "")
        XCTAssertLessThan(clock.milliseconds, 200_000, "ожидание конечно")
    }

    /// Нет сеанса и нет окна пароля к таймауту → нейтральный итог без галочки (раньше: «Подключено без пароля»).
    func testNoSessionAndNoPasswordWindowIsUnconfirmedNotSuccess() async throws {
        try requireNewAPI()
        let app = try makeAnyDeskApp()
        for withTerminal in [true, false] {
            setUpFresh()
            let t = terminal()
            t.connect.onPress = { [unowned self] in ax.close(t.window, pid: pid) }
            launches(.anyDesk, windows: withTerminal ? [(500, t.window)] : [])
            let outcome = await run(request("123456789", program: .anyDesk), provider: provider(.anyDesk, app: app))
            XCTAssertEqual(outcome.code, "unconfirmed", "terminal=\(withTerminal)")
            XCTAssertFalse(outcome.isSuccess, "terminal=\(withTerminal): без галочки")
            XCTAssertTrue(keyboard.typed.isEmpty)
            XCTAssertFalse(String(describing: outcome).contains("copyID: true"), "AnyDesk ID в буфер не кладёт")
            XCTAssertEqual(t.cancel.pressCount, 0)
        }
    }

    /// Окно пароля не нужно, но сеанс есть («Waiting for image») — это настоящий успех «без пароля», ничего не печатается.
    func testConfirmedSessionWithoutPasswordWindowIsStillSuccess() async throws {
        try requireNewAPI()
        let app = try makeAnyDeskApp()
        launches(.anyDesk, windows: [(1500, sessionWindow())])
        let outcome = await run(request("123456789", program: .anyDesk), provider: provider(.anyDesk, app: app))
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertEqual(outcome.code, "auto")
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    /// Незнакомое окно с одними «Cancel/Deny/Close»: не нажимаем ни одну, Return не шлём (по умолчанию Cancel), итог — не успех.
    func testUnknownWindowWithOnlyCancelLikeButtonsIsNeverClicked() async throws {
        try requireNewAPI()
        let app = try makeAnyDeskApp()
        let cancel = TSNode("AXButton", label: "Cancel"), deny = TSNode("AXButton", label: "Deny"), close = TSNode("AXButton", label: "Close")
        let w = TSNode("AXWindow", subrole: "AXDialog", label: "Unexpected request",
                       children: [TSNode("AXStaticText", label: "Something new."), deny, cancel, close])
        w.defaultButtonNode = cancel
        launches(.anyDesk, windows: [(500, w)])
        let outcome = await run(request("123456789", program: .anyDesk), provider: provider(.anyDesk, app: app))
        XCTAssertFalse(outcome.isSuccess)
        for b in [cancel, deny, close] { XCTAssertEqual(b.pressCount, 0, b.label ?? "") }
        XCTAssertTrue(keyboard.returns.isEmpty)
        XCTAssertTrue(keyboard.typed.isEmpty)
    }

    /// Терминальное окно после нажатия снова на экране (программа его пересоздала): Cancel всё равно не нажимается, пароль потом вводится.
    func testTerminalSessionThatReappearsDoesNotMakeConnectorCancel() async throws {
        try requireNewAPI()
        let app = try makeAnyDeskApp()
        let t1 = terminal(), t2 = terminal(), pw = passwordWindow()
        var presses = 0
        launches(.anyDesk, windows: [(500, t1.window)])
        t1.connect.onPress = { [unowned self] in
            presses += 1; ax.close(t1.window, pid: pid)
            clock.at(clock.milliseconds + 300) { [unowned self] in ax.show(t2.window, pid: pid) }
        }
        t2.connect.onPress = { [unowned self] in
            presses += 1; ax.close(t2.window, pid: pid)
            clock.at(clock.milliseconds + 600) { [unowned self] in ax.show(pw.window, pid: pid) }
        }
        pw.ok.onPress = { [unowned self] in
            ax.close(pw.window, pid: pid)
            clock.at(clock.milliseconds + 500) { [unowned self] in ax.show(sessionWindow(), pid: pid) }
        }
        let outcome = await run(request("123456789", program: .anyDesk), provider: provider(.anyDesk, app: app))
        XCTAssertEqual(outcome.code, "connected")
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(t1.cancel.pressCount + t2.cancel.pressCount, 0)
        XCTAssertEqual(pw.field.text, "Pw-секрет-1")
    }

    /// Разные раскладки окна (порядок кнопок, вложенность, Cancel по умолчанию, языки): Connect — да, остальное — нет.
    func testTerminalSessionLayoutVariantsAlwaysPressConnectOnly() async throws {
        try requireNewAPI()
        let app = try makeAnyDeskApp()
        var variants = 0
        for lang in Lang.allCases {
            for order in [[0, 1], [1, 0]] {
                for cancelDefault in [false, true] {
                    for nested in [false, true] {
                        setUpFresh()
                        let t = terminal(lang, cancelIsDefault: cancelDefault, order: order, nested: nested)
                        let pw = passwordWindow(lang)
                        launches(.anyDesk, windows: [(400, t.window)])
                        t.connect.onPress = { [unowned self] in
                            ax.close(t.window, pid: pid)
                            clock.at(clock.milliseconds + 500) { [unowned self] in ax.show(pw.window, pid: pid) }
                        }
                        pw.ok.onPress = { [unowned self] in
                            ax.close(pw.window, pid: pid)
                            clock.at(clock.milliseconds + 500) { [unowned self] in ax.show(sessionWindow(lang), pid: pid) }
                        }
                        let outcome = await run(request("123456789", program: .anyDesk), provider: provider(.anyDesk, app: app))
                        let tag = "\(lang) order=\(order) cancelDefault=\(cancelDefault) nested=\(nested)"
                        XCTAssertEqual(outcome.code, "connected", tag)
                        XCTAssertEqual(t.connect.pressCount, 1, tag)
                        XCTAssertEqual(t.cancel.pressCount + t.user.pressCount + t.console.pressCount, 0, tag)
                        XCTAssertEqual(t.userField.text, "", tag)
                        XCTAssertEqual(pw.field.text, "Pw-секрет-1", tag)
                        variants += 1
                    }
                }
            }
        }
        XCTAssertEqual(variants, 24)
    }

    // MARK: TeamViewer нового интерфейса

    private struct TVMain { let window, field, connect, searchAndConnect, clearAll: TSNode }

    /// Левое меню, вкладки «TeamViewer ID | Sessions», блок «Control remote device» с полем и «Connect», «Search and Connect ⌘K».
    private func teamViewerMain(fieldRole: String = "AXTextField", names: FieldNames = .placeholderAndDescription) -> TVMain {
        let field = TSNode(fieldRole)
        switch names {
        case .placeholderAndDescription:
            field.placeholder = "Enter end user’s ID, IP, or hostname"; field.detail = "ID, IP address, or hostname"
        case .placeholderOnly: field.placeholder = "Enter end user’s ID, IP, or hostname"
        case .descriptionOnly: field.detail = "ID, IP address, or hostname"
        case .classic: field.detail = "Partner ID"
        }
        let connect = TSNode("AXButton", label: "Connect")
        let search = TSNode("AXButton", label: "Search and Connect ⌘K")
        let clear = TSNode("AXButton", label: "Clear all")
        let side = TSNode("AXGroup", children: ["Remote Support", "Devices", "Chat"].map { TSNode("AXRadioButton", label: $0) })
        let tabs = TSNode("AXTabGroup", children: ["TeamViewer ID", "Sessions"].map { TSNode("AXRadioButton", label: $0) })
        let control = TSNode("AXGroup", children: [TSNode("AXStaticText", label: "Control remote device"), field, connect])
        let window = TSNode("AXWindow", label: "TeamViewer", children: [search, side, tabs, TSNode("AXGroup", children: [clear, control])])
        return TVMain(window: window, field: field, connect: connect, searchAndConnect: search, clearAll: clear)
    }

    /// Признак сеанса TeamViewer по контракту #155: новое окно подключения с ID в заголовке.
    private func showTVSession(after ms: Int, id: String = "123456789") {
        let w = TSNode("AXWindow", label: "\(id) - TeamViewer", children: [TSNode("AXGroup")])
        clock.at(clock.milliseconds + ms) { [unowned self] in ax.show(w, pid: pid) }
    }

    private enum FieldNames: CaseIterable { case placeholderAndDescription, placeholderOnly, descriptionOnly, classic }

    private func tvAuthWindow() -> Password {
        let field = TSNode("AXTextField", subrole: "AXSecureTextField")
        let ok = TSNode("AXButton", label: "OK")
        let cancel = TSNode("AXButton", label: "Cancel")
        let window = TSNode("AXWindow", subrole: "AXDialog", label: "Authentication",
                            children: [TSNode("AXStaticText", label: "Enter password"), field, cancel, ok])
        window.defaultButtonNode = ok
        return Password(window: window, field: field, checkbox: TSNode("AXCheckBox"), ok: ok)
    }

    /// Ссылка не подставила ID (TeamViewer открылся на главном экране): ID вписан в поле, «Connect» нажат, потом пароль в окно.
    func testTeamViewerNewInterfaceFillsIDPressesConnectThenTypesPassword() async throws {
        try requireNewAPI()
        let app = try makeTeamViewerApp()
        for names in FieldNames.allCases {
            for role in ["AXTextField", "AXComboBox"] {
                setUpFresh()
                let main = teamViewerMain(fieldRole: role, names: names), auth = tvAuthWindow()
                var idAtConnect: String?
                launches(.teamViewer, windows: [(700, main.window)])
                main.connect.onPress = { [unowned self] in
                    idAtConnect = main.field.text
                    if main.field.text == "123456789" { clock.at(clock.milliseconds + 1000) { [unowned self] in ax.show(auth.window, pid: pid) } }
                }
                auth.ok.onPress = { [unowned self] in ax.close(auth.window, pid: pid); showTVSession(after: 400) }
                let outcome = await run(request("123456789", program: .teamViewer), provider: provider(.teamViewer, app: app))
                let tag = "\(names) \(role)"
                XCTAssertEqual(idAtConnect, "123456789", "\(tag): ID вписан до нажатия «Connect»")
                XCTAssertEqual(main.connect.pressCount, 1, tag)
                XCTAssertEqual(main.searchAndConnect.pressCount + main.clearAll.pressCount, 0, tag)
                XCTAssertEqual(auth.field.text, "Pw-секрет-1", tag)
                XCTAssertEqual(main.field.text, "123456789", "\(tag): пароль не попал в поле ID")
                XCTAssertFalse(keyboard.typedInto.contains { $0 === main.field && keyboard.typedText.contains("Pw-") }, tag)
                XCTAssertEqual(auth.window.children.first { $0.label == "Cancel" }.map { ($0 as! TSNode).pressCount }, 0, tag)
                XCTAssertTrue(outcome.isSuccess, tag)
                XCTAssertNotEqual(outcome.code, "auto", "\(tag): не «без пароля»: пароль был нужен и введён")
            }
        }
    }

    /// Фокус остаётся в поле ID, когда появляется окно аутентификации: пароль всё равно только в защищённое поле.
    func testTeamViewerPasswordNeverLandsInIDFieldEvenIfItKeepsFocus() async throws {
        try requireNewAPI()
        let app = try makeTeamViewerApp()
        let main = teamViewerMain(), auth = tvAuthWindow()
        launches(.teamViewer, windows: [(700, main.window)])
        main.connect.onPress = { [unowned self] in
            _ = main.field.focus()
            clock.at(clock.milliseconds + 800) { [unowned self] in ax.show(auth.window, pid: pid); _ = main.field.focus() }
        }
        auth.ok.onPress = { [unowned self] in ax.close(auth.window, pid: pid); showTVSession(after: 400) }
        await run(request("987654321", program: .teamViewer), provider: provider(.teamViewer, app: app))
        XCTAssertEqual(main.field.text, "987654321")
        XCTAssertFalse(main.field.text.contains("Pw-"))
        XCTAssertEqual(auth.field.text, "Pw-секрет-1")
    }

    /// Ссылка сработала сама (окно аутентификации сразу): форму не трогаем, «Connect» не нажимаем.
    func testTeamViewerLinkThatWorksLeavesMainFormAlone() async throws {
        try requireNewAPI()
        let app = try makeTeamViewerApp()
        let main = teamViewerMain(), auth = tvAuthWindow()
        launches(.teamViewer, windows: [(300, auth.window), (350, main.window)])
        auth.ok.onPress = { [unowned self] in ax.close(auth.window, pid: pid); showTVSession(after: 400) }
        let outcome = await run(request("123456789", program: .teamViewer), provider: provider(.teamViewer, app: app))
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertEqual(auth.field.text, "Pw-секрет-1")
        XCTAssertEqual(main.connect.pressCount, 0)
        XCTAssertEqual(main.field.text, "", "ID в форму не вписываем, если подключение уже идёт")
    }

    /// Connect нажат, но ни окна аутентификации, ни сеанса к таймауту: нейтральный итог, ID — в буфер (для TeamViewer), без галочки.
    func testTeamViewerTimeoutWithoutSessionIsUnconfirmedAndAsksToCopyID() async throws {
        try requireNewAPI()
        let app = try makeTeamViewerApp()
        let main = teamViewerMain()
        launches(.teamViewer, windows: [(700, main.window)])
        let outcome = await run(request("123456789", program: .teamViewer), provider: provider(.teamViewer, app: app))
        XCTAssertEqual(outcome.code, "unconfirmed")
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertTrue(String(describing: outcome).contains("copyID: true"), "\(outcome)")
        XCTAssertEqual(main.field.text, "123456789")
        XCTAssertTrue(keyboard.typedText.allSatisfy { !"Pw-секрет-1".contains($0) } || keyboard.typedText == "123456789")
    }

    /// Нет поля «ID, IP address, or hostname» (другой экран): ничего не нажимается, итог — не успех.
    func testTeamViewerWithoutConnectFormPressesNothing() async throws {
        try requireNewAPI()
        let app = try makeTeamViewerApp()
        let search = TSNode("AXButton", label: "Search and Connect ⌘K"), clear = TSNode("AXButton", label: "Clear all")
        let w = TSNode("AXWindow", label: "TeamViewer", children: [search, TSNode("AXGroup", children: [
            TSNode("AXStaticText", label: "Devices"), clear, TSNode("AXTextField", placeholder: "Search")])])
        launches(.teamViewer, windows: [(700, w)])
        let outcome = await run(request("123456789", program: .teamViewer), provider: provider(.teamViewer, app: app))
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertEqual(search.pressCount + clear.pressCount, 0)
        XCTAssertTrue(keyboard.typed.isEmpty, "в чужое поле поиска ID не вписываем")
    }

    /// Окно аутентификации TeamViewer с «Cancel»: он не нажимается, даже если по умолчанию.
    func testTeamViewerAuthCancelIsNeverPressedEvenAsDefault() async throws {
        try requireNewAPI()
        let app = try makeTeamViewerApp()
        let main = teamViewerMain(), auth = tvAuthWindow()
        let cancel = auth.window.children.compactMap { $0 as? TSNode }.first { $0.label == "Cancel" }!
        auth.window.defaultButtonNode = cancel
        launches(.teamViewer, windows: [(700, main.window)])
        main.connect.onPress = { [unowned self] in clock.at(clock.milliseconds + 500) { [unowned self] in ax.show(auth.window, pid: pid) } }
        auth.ok.onPress = { [unowned self] in ax.close(auth.window, pid: pid); showTVSession(after: 400) }
        let outcome = await run(request("123456789", program: .teamViewer), provider: provider(.teamViewer, app: app))
        XCTAssertEqual(cancel.pressCount, 0, "Cancel по умолчанию не нажимается")
        XCTAssertTrue(keyboard.returns.isEmpty, "Return не уходит: он нажал бы Cancel")
        if auth.ok.pressCount > 0 {
            XCTAssertEqual(auth.ok.pressCount, 1, "подтверждена явной кнопкой «OK»")
            XCTAssertTrue(outcome.isSuccess)
        } else {
            XCTAssertEqual(outcome.code, "failed_nofield", "итог — «введите пароль вручную»")
            XCTAssertEqual(auth.field.text, "", "пароль из поля убран")
        }
    }

    // MARK: Что значит «Подключено» после пароля (решение Connection)

    /// Контракт #155 (ревью P2): «Подключено» только при признаке сеанса после пароля («Waiting for image» или окно этого
    /// подключения). Окно пароля закрылось, а признака нет → `submitted`, не успех.
    func testPasswordAcceptedWithoutSessionSignIsSubmittedNotConnected() async throws {
        try requireNewAPI()
        let app = try makeAnyDeskApp()
        let pw = passwordWindow()
        launches(.anyDesk, windows: [(500, pw.window)])
        pw.ok.onPress = { [unowned self] in ax.close(pw.window, pid: pid) }
        let outcome = await run(request("123456789", program: .anyDesk), provider: provider(.anyDesk, app: app))
        XCTAssertEqual(pw.field.text, "Pw-секрет-1")
        XCTAssertEqual(outcome.code, "submitted")
        XCTAssertFalse(outcome.isSuccess)
    }

    /// Признак сеанса есть («Waiting for image») → `connected`.
    func testPasswordAcceptedWithSessionSignIsConnected() async throws {
        try requireNewAPI()
        let app = try makeAnyDeskApp()
        let pw = passwordWindow()
        launches(.anyDesk, windows: [(500, pw.window)])
        pw.ok.onPress = { [unowned self] in
            ax.close(pw.window, pid: pid)
            clock.at(clock.milliseconds + 400) { [unowned self] in ax.show(sessionWindow(), pid: pid) }
        }
        let outcome = await run(request("123456789", program: .anyDesk), provider: provider(.anyDesk, app: app))
        XCTAssertEqual(outcome.code, "connected")
    }

    /// После пароля висит «Connecting…» или «Terminal Session»: это ещё не «Подключено» (итог — submitted/не connected).
    func testStillConnectingOrTerminalSessionAfterPasswordIsNotConnected() async throws {
        try requireNewAPI()
        let app = try makeAnyDeskApp()
        for makeBusy in [{ (self: AcceptanceTerminalSessionTests) -> TSNode in
            TSNode("AXWindow", label: "Connecting...", children: [TSNode("AXStaticText", label: "Connection in progress. Please wait.")]) },
                         { (self: AcceptanceTerminalSessionTests) -> TSNode in self.terminal().window }] {
            setUpFresh()
            let pw = passwordWindow(), busy = makeBusy(self)
            launches(.anyDesk, windows: [(500, pw.window)])
            pw.ok.onPress = { [unowned self] in
                ax.close(pw.window, pid: pid)
                clock.at(clock.milliseconds + 200) { [unowned self] in ax.show(busy, pid: pid) }
            }
            let outcome = await run(request("123456789", program: .anyDesk), provider: provider(.anyDesk, app: app))
            XCTAssertNotEqual(outcome.code, "connected", busy.label ?? "")
            XCTAssertFalse(String(describing: outcome).isEmpty)
        }
    }

    // MARK: Задача 4: учётная запись Windows (ожидает API: ConnectionRecord.account, accountPassword, ConnectRequest)

    /// Запрос на подключение с записью, у которой есть логин и пароль учётки Windows (пароль отдаётся через `accountPassword:`).
    private func accountRequest(login: String, password: String) -> (request: ConnectRequest, accountPassword: String)? {
        let record = ConnectionRecord(sourceRow: 2, name: "Лаборатория Север", id: "123456789", hasPassword: true,
                                      account: login, hasAccountPassword: true)
        return (ConnectRequest(record: record, program: .anyDesk, withPassword: true, autologin: false, timeoutSeconds: 20), password)
    }

    /// Terminal Session и у записи есть account: «User account» выбран, логин вписан, «Connect» нажат; Console не нужен.
    func testTerminalSessionWithAccountSelectsUserAccountTypesLoginAndConnects() async throws {
        try requireNewAPI()
        guard let (req, winPassword) = accountRequest(login: "Администратор", password: "Win-пароль-9") else {
            throw XCTSkip("ожидает API задачи 4: account/accountPassword в записи и запросе")
        }
        let app = try makeAnyDeskApp()
        let t = terminal(), pw = passwordWindow()
        launches(.anyDesk, windows: [(500, t.window)])
        t.user.onPress = { t.user.isChecked = true; t.console.isChecked = false }
        t.connect.onPress = { [unowned self] in
            ax.close(t.window, pid: pid)
            clock.at(clock.milliseconds + 500) { [unowned self] in ax.show(pw.window, pid: pid) }
        }
        pw.ok.onPress = { [unowned self] in
            ax.close(pw.window, pid: pid)
            clock.at(clock.milliseconds + 500) { [unowned self] in ax.show(sessionWindow(), pid: pid) }
        }
        let outcome = await run(req, provider: provider(.anyDesk, app: app), accountPassword: winPassword)
        XCTAssertEqual(outcome.code, "connected")
        XCTAssertEqual(t.user.pressCount, 1, "выбран «User account»")
        XCTAssertEqual(t.console.pressCount, 0)
        XCTAssertEqual(t.userField.text, "Администратор", "логин вписан")
        XCTAssertEqual(t.connect.pressCount, 1)
        XCTAssertEqual(t.cancel.pressCount, 0)
        XCTAssertEqual(pw.field.text, "Pw-секрет-1", "в окно пароля AnyDesk — пароль AnyDesk, не пароль учётки")
        XCTAssertFalse(keyboard.typedText.contains("Win-пароль-9"))
    }

    /// Без account — Console + Connect, поле учётной записи пустое (проверено основным сценарием выше); с account, но без
    /// окна Terminal Session — логин и пароль учётки не вводятся никуда.
    func testAccountIsNotTypedAnywhereWhenNoTerminalSessionWindowAppears() async throws {
        try requireNewAPI()
        guard let (req, accountPassword) = accountRequest(login: "Администратор", password: "Win-пароль-9") else {
            throw XCTSkip("ожидает API задачи 4: account/accountPassword в записи и запросе")
        }
        let app = try makeAnyDeskApp()
        let pw = passwordWindow()
        launches(.anyDesk, windows: [(500, pw.window)])
        pw.ok.onPress = { [unowned self] in ax.close(pw.window, pid: pid) }
        _ = await run(req, provider: provider(.anyDesk, app: app), accountPassword: accountPassword)
        XCTAssertEqual(pw.field.text, "Pw-секрет-1")
        XCTAssertFalse(keyboard.typedText.contains(accountPassword))
        XCTAssertFalse(keyboard.typedText.contains("Администратор"))
    }

    /// AnyDesk просит пароль учётной записи («User account password required»): в защищённое поле — пароль учётки (не пароль AnyDesk),
    /// логин — только если поле логина пустое; Cancel не нажимается; пароли не в журнале. Для каждого языка интерфейса.
    func testAccountPasswordRequestGetsAccountPasswordAndLoginOnlyIfEmpty() async throws {
        try requireNewAPI()
        guard let (req, accountPassword) = accountRequest(login: "Администратор", password: "Win-пароль-9") else {
            throw XCTSkip("ожидает API задачи 4")
        }
        for lang in Lang.allCases {
            for prefilledLogin in [false, true] {
                setUpFresh()
                let app = try makeAnyDeskApp()
                let s = Self.adStrings[lang]!
                let login = TSNode("AXTextField"); login.detail = "User name"
                if prefilledLogin { _ = login.setText("Администратор") }
                let secret = TSNode("AXTextField", subrole: "AXSecureTextField")
                let ok = TSNode("AXButton", label: s["ad.dlg.ok"]), cancel = TSNode("AXButton", label: s["ad.dlg.cancel"])
                let window = TSNode("AXWindow", subrole: "AXDialog", label: s["ad.dlg.passwd.title"],
                                    children: [TSNode("AXStaticText", label: s["ad.dlg.passwd.msg.pwd_required.user"]), login, secret, cancel, ok])
                window.defaultButtonNode = ok
                launches(.anyDesk, windows: [(500, window)])
                ok.onPress = { [unowned self] in
                    ax.close(window, pid: pid)
                    clock.at(clock.milliseconds + 400) { [unowned self] in ax.show(sessionWindow(lang), pid: pid) }
                }
                let outcome = await run(req, provider: provider(.anyDesk, app: app), accountPassword: accountPassword)
                let tag = "\(lang) prefilled=\(prefilledLogin)"
                XCTAssertEqual(secret.text, accountPassword, tag)
                XCTAssertFalse(secret.text.contains("Pw-секрет-1"), "\(tag): пароль AnyDesk в поле пароля учётки не вводится никогда")
                XCTAssertEqual(login.text, "Администратор", "\(tag): логин вписан ровно один раз")
                XCTAssertEqual(cancel.pressCount, 0, tag)
                XCTAssertTrue(outcome.isSuccess, "\(tag): \(outcome)")
                assertNoSecretsInLogs([accountPassword, "Администратор"])
            }
        }
    }

    // MARK: Служебное

    /// Новое окружение внутри одного теста (циклы по вариантам).
    private func setUpFresh() {
        ax = TSAX(); launcher = FakeLauncher(); clock = FakeClock(); phases = []; logger = RecordingLogger(); keyboard = TSKeyboard(ax: ax)
    }
}

// MARK: - Подмены, не зависящие от FakeAutomation.swift (там идёт правка ветки исправления)

/// Элемент выдуманного окна. Свойства `placeholder`/`detail`/`setText` — те же, что получает `AXNode` в ветке исправления;
/// на ветке без них это просто лишние члены.
final class TSNode: AXNode {
    var role: String?
    var subrole: String?
    var label: String?
    var kids: [TSNode]
    var processID: Int32?
    var value: [UInt16] = []
    var isChecked: Bool?
    var selected = false
    var placeholder: String?
    var detail: String?
    var pressCount = 0
    var onPress: (() -> Void)?
    weak var defaultButtonNode: TSNode?
    weak var ax: TSAX?

    init(_ role: String, subrole: String? = nil, label: String? = nil, placeholder: String? = nil, children: [TSNode] = []) {
        self.role = role; self.subrole = subrole; self.label = label; self.placeholder = placeholder; self.kids = children
    }

    var children: [AXNode] { kids }
    var valueLength: Int? { value.count }
    var defaultButton: AXNode? { defaultButtonNode }
    var text: String { String(decoding: value, as: UTF16.self) }

    func isSame(as other: AXNode) -> Bool { self === other }
    func setSecretValue(_ secret: SecretBuffer) -> Bool {
        value = secret.withBytes { Array(String(decoding: $0, as: UTF8.self).utf16) }; return true
    }
    func setText(_ text: String) -> Bool { value = Array(text.utf16); return true }
    func clearValue() -> Bool { value = []; return true }
    func focus() -> Bool {
        guard let pid = processID else { return false }
        ax?.focused[pid] = self; return true
    }
    func press() -> Bool {
        pressCount += 1
        ax?.pressLog.append(label ?? role ?? "?")
        if isChecked != nil { isChecked?.toggle() }
        onPress?()
        return true
    }
    func descendants() -> [TSNode] { [self] + kids.flatMap { $0.descendants() } }
}

final class TSAX: AXAccess {
    var isTrusted = true
    var windows: [Int32: [TSNode]] = [:]
    var focused: [Int32: TSNode] = [:]
    var pressLog: [String] = []

    func windows(ofProcess pid: Int32) -> [AXNode] { windows[pid] ?? [] }
    func focusedElement(ofProcess pid: Int32) -> AXNode? { focused[pid] }

    func show(_ window: TSNode, pid: Int32) {
        for node in window.descendants() { node.ax = self; node.processID = node.processID ?? pid }
        windows[pid, default: []].append(window)
    }
    func close(_ window: TSNode, pid: Int32) { windows[pid]?.removeAll { $0 === window } }
}

/// Печатает в элемент с фокусом процесса и помнит, куда именно.
final class TSKeyboard: KeyboardSender {
    let ax: TSAX
    var typed: [(pid: Int32, units: [UInt16])] = []
    var typedInto: [TSNode] = []
    var returns: [Int32] = []

    init(ax: TSAX) { self.ax = ax }

    var typedText: String { String(decoding: typed.flatMap { $0.units }, as: UTF16.self) }

    func type(_ units: UnsafeBufferPointer<UInt16>, to pid: Int32) {
        typed.append((pid, Array(units)))
        if let target = ax.focused[pid] { target.value.append(contentsOf: units); typedInto.append(target) }
    }
    func pressReturn(to pid: Int32) { returns.append(pid) }
}

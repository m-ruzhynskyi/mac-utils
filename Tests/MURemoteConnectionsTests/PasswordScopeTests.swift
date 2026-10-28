import XCTest
@testable import MURemoteConnections

/// rc-console2 SCOPE: «OK», галочка автологина и поле логина ищутся в окне пароля. Отдельное маленькое окно пароля
/// (`AXStandardWindow`, не `AXDialog`, без листа) — целиком, на любой глубине, как в 1.10.2; диалог во вкладке главного
/// окна AnyDesk — только сам диалог (тесты главного окна — в `TerminalCardTests`). Только выдуманные окна и данные.
@MainActor
final class PasswordScopeTests: XCTestCase {
    private let password = "Pw-5-выдумка"
    private var ax: FakeAX!
    private var launcher: FakeLauncher!
    private var keyboard: FakeKeyboard!
    private var clock: FakeClock!

    override func setUp() async throws {
        ax = FakeAX(); launcher = FakeLauncher(); keyboard = FakeKeyboard(ax: ax); clock = FakeClock()
    }

    /// `node` внутри цепочки из `levels` групп.
    private func buried(_ node: FakeNode, _ levels: Int) -> FakeNode {
        (0..<levels).reduce(node) { inner, _ in FakeNode("AXGroup", children: [inner]) }
    }

    /// Отдельное окно пароля без `AXDialog`: поле на глубине `fieldDepth`, кнопка и галочка — в других ветках,
    /// так что от поля до общего предка с ними 5–6 уровней.
    private func standaloneWindow(title: String, message: String, button: String, checkbox: String?,
                                  fieldDepth: Int = 6) -> (window: FakeNode, field: FakeNode, button: FakeNode, box: FakeNode?) {
        let field = FakeNode("AXTextField", subrole: "AXSecureTextField")
        let ok = FakeNode("AXButton", label: button)
        let cancel = FakeNode("AXButton", label: "Cancel")
        let box = checkbox.map { FakeNode("AXCheckBox", label: $0) }
        box?.isChecked = false
        var kids = [FakeNode("AXStaticText", label: message), buried(field, fieldDepth - 1),
                    buried(FakeNode("AXGroup", children: [cancel, ok]), 2)]
        if let box { kids.append(buried(box, 3)) }
        let window = FakeNode("AXWindow", subrole: "AXStandardWindow", label: title, children: kids)
        return (window, field, ok, box)
    }

    private func connect(_ program: RemoteProgram, _ provider: RemoteProvider, autologin: Bool) async -> ConnectionOutcome {
        let record = ConnectionRecord(sourceRow: 2, name: "Демо", id: "123456789", program: program, hasPassword: true)
        let pw = password
        return await RemoteConnector(ax: ax, launcher: launcher, keyboard: keyboard, clock: clock)
            .connect(ConnectRequest(record: record, program: program, autologin: autologin), provider: provider,
                     password: { .found(SecretBuffer(pw.utf8)) }, progress: { _ in })
    }

    /// AnyDesk: отдельное окно «Authorization» (`AXStandardWindow`), «OK» и галочка в 5–6 уровнях от поля —
    /// пароль введён, галочка поставлена, нажат «OK».
    func testStandaloneAnyDeskPasswordWindowWithDeepOK() async {
        let w = standaloneWindow(title: "Authorization", message: "AnyDesk password required.", button: "OK",
                                 checkbox: "Log in automatically from now on")
        var okPresses = 0
        w.button.onPress = { [unowned self] in okPresses += 1; ax.close(w.window, pid: 4141) }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: 4141)
            clock.at(500) { [unowned self] in ax.show(w.window, pid: 4141) }
        }
        let outcome = await connect(.anyDesk, AnyDeskAutomator(texts: ProviderTexts.builtIn(keys: AnyDeskAutomator.keys)),
                                    autologin: true)
        XCTAssertEqual(w.field.text, password)
        XCTAssertEqual(okPresses, 1, "нажат «OK» окна пароля")
        XCTAssertEqual(w.box?.isChecked, true, "галочка автологина найдена")
        XCTAssertTrue(keyboard.returns.isEmpty, "без Return — кнопка найдена")
        XCTAssertEqual(outcome, .connected)
    }

    /// TeamViewer: отдельное окно «Аутентификация» с «Log In» далеко от поля — нажат «Log In».
    func testStandaloneTeamViewerAuthenticationWindowPressesLogIn() async {
        let w = standaloneWindow(title: "Аутентификация", message: "Введите пароль", button: "Log In", checkbox: nil)
        var presses = 0
        w.button.onPress = { [unowned self] in presses += 1; ax.close(w.window, pid: 5252) }
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.teamViewer, pid: 5252)
            clock.at(500) { [unowned self] in ax.show(w.window, pid: 5252) }
        }
        let tv = TeamViewerAutomator(texts: ProviderTexts.builtIn(keys: TeamViewerAutomator.keys))
        let outcome = await connect(.teamViewer, tv, autologin: false)
        XCTAssertEqual(w.field.text, password)
        XCTAssertEqual(presses, 1, "нажат «Log In»")
        XCTAssertTrue(keyboard.returns.isEmpty)
        XCTAssertEqual(outcome, .connected)
    }

    /// Окно больше `passwordScopeNodes` узлов (главное окно), диалог пароля внутри без «OK» с подписью —
    /// «Connect» главного окна не нажимается: Return в поле пароля программы впереди.
    func testBigWindowWithoutDialogButtonNeverPressesForeignConnect() async {
        let field = FakeNode("AXTextField", subrole: "AXSecureTextField")
        let dialog = FakeNode("AXGroup", children: [FakeNode("AXStaticText", label: "AnyDesk password required."),
                                                    field, FakeNode("AXButton")])
        let foreign = FakeNode("AXButton", label: "Connect")
        var foreignPresses = 0
        foreign.onPress = { foreignPresses += 1 }
        let filler = (0..<RemoteConnector.passwordScopeNodes).map { _ in FakeNode("AXGroup", children: [FakeNode("AXImage")]) }
        let window = FakeNode("AXWindow", subrole: "AXStandardWindow", label: "AnyDesk",
                              children: [FakeNode("AXGroup", children: [FakeNode("AXTextField"), foreign])] + filler
                                  + [buried(dialog, 4)])
        window.defaultButtonNode = foreign
        launcher.onOpen = { [unowned self] _ in
            launcher.launch(.anyDesk, pid: 4141)
            clock.at(500) { [unowned self] in ax.show(window, pid: 4141) }
        }
        _ = await connect(.anyDesk, AnyDeskAutomator(texts: ProviderTexts.builtIn(keys: AnyDeskAutomator.keys)), autologin: false)
        XCTAssertEqual(field.text, password)
        XCTAssertEqual(foreignPresses, 0, "«Connect» главного окна не нажат")
        XCTAssertEqual(keyboard.returns.count, 1, "Return — в поле пароля")
    }
}


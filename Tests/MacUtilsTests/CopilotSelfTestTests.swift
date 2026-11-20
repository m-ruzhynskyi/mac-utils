import XCTest
@testable import MacUtils
@testable import MUCopilot
@testable import MUAIBackend

/// COPILOT-39: ссылки `macutils://copilot…`, ключ `--copilot-selftest`, «Думаю…» сразу, честная подсказка о скорости Codex.
/// Самопроверку здесь не запускаем: это настоящий запрос к ИИ.
@MainActor
final class CopilotSelfTestTests: XCTestCase {
    override func tearDown() {
        AppAction.copilotOnNow = { CopilotGlue.shared.session.isOn }
    }

    func testSelfTestFlagParsing() {
        XCTAssertNil(CopilotSelfTest.options(["/Applications/Mac Utils.app/Contents/MacOS/MacUtils"]), "обычный запуск не меняется")
        XCTAssertNil(CopilotSelfTest.options(["MacUtils", "--copilot-question=Вопрос?"]), "вопрос без ключа самопроверки — ничего")
        XCTAssertEqual(CopilotSelfTest.options(["MacUtils", "--copilot-selftest"])?.question, CopilotSelfTest.defaultQuestion)
        XCTAssertEqual(CopilotSelfTest.options(["MacUtils", "--copilot-selftest", "--copilot-question=Почему REST, а не GraphQL?"])?.question,
                       "Почему REST, а не GraphQL?")
        XCTAssertEqual(CopilotSelfTest.options(["MacUtils", "--copilot-question=  ", "--copilot-selftest"])?.question, CopilotSelfTest.defaultQuestion)
        XCTAssertTrue(CopilotSelfTest.defaultQuestion.hasSuffix("?"))
        XCTAssertEqual(CopilotSelfTest.options(["MacUtils", "--copilot-selftest"])?.mode, .answer)
    }

    /// COPILOT-41: `--copilot-selftest=audio` — настоящий источник звука, N секунд (3…300, по умолчанию 20).
    func testAudioSelfTestFlag() {
        let audio = CopilotSelfTest.options(["MacUtils", "--copilot-selftest=audio"])
        XCTAssertEqual(audio?.mode, .audio)
        XCTAssertEqual(audio?.seconds, 20)
        XCTAssertEqual(CopilotSelfTest.options(["MacUtils", "--copilot-selftest=audio", "--copilot-seconds=45"])?.seconds, 45)
        XCTAssertEqual(CopilotSelfTest.options(["MacUtils", "--copilot-selftest=audio", "--copilot-seconds=1"])?.seconds, 3)
        XCTAssertEqual(CopilotSelfTest.options(["MacUtils", "--copilot-selftest=audio", "--copilot-seconds=abc"])?.seconds, 20)
        XCTAssertFalse(CopilotSelfTest.usesSilentListener(["MacUtils", "--copilot-selftest=audio"]), "звук — настоящий источник")
        XCTAssertTrue(CopilotSelfTest.usesSilentListener(["MacUtils", "--copilot-selftest"]), "ответ — без микрофона")
        XCTAssertFalse(CopilotSelfTest.usesSilentListener(["MacUtils"]))
        XCTAssertEqual(CopilotSelfTest.countsLine(other: 3, me: 1), "реплик собеседник: 3, вы: 1")
    }

    func testProcessesLine() {
        XCTAssertEqual(CopilotSelfTest.processesLine([]), "процессы подсказчика после выключения: нет")
        XCTAssertEqual(CopilotSelfTest.processesLine([(pid: 12, name: "codex"), (pid: 34, name: "node")]),
                       "процессы подсказчика после выключения: 12 codex, 34 node")
    }

    func testCopilotLinksRunTheSameActions() throws {
        let expected: [String: AppAction] = ["macutils://copilot": .copilotToggle, "macutils://copilot-answer": .copilotAnswer,
                                             "macutils://copilot-screen": .copilotScreen, "macutils://copilot-panel": .copilotPanel]
        for (link, action) in expected {
            XCTAssertEqual(AppAction(url: try XCTUnwrap(URL(string: link))), action, link)
            XCTAssertTrue(AppAction.catalog.contains { $0.link == link }, "\(link) — на странице «Команды и ссылки»")
        }
    }

    /// Включение по ссылке — как запись встречи: сначала вопрос (подсказчик начнёт слушать микрофон и звук звонка);
    /// снимок экрана в ИИ — тоже с вопросом. Выключение, ответ и панель — без вопроса.
    func testCopilotLinkQuestions() {
        AppAction.copilotOnNow = { false }
        XCTAssertNotNil(AppAction.copilotToggle.linkQuestion)
        XCTAssertNil(AppAction.copilotScreen.linkQuestion, "выключен — снимать нечего")
        AppAction.copilotOnNow = { true }
        XCTAssertNil(AppAction.copilotToggle.linkQuestion, "выключение — без вопроса")
        XCTAssertEqual(AppAction.copilotScreen.linkQuestion?.title, "Отправить снимок экрана в ИИ?")
        XCTAssertNil(AppAction.copilotAnswer.linkQuestion)
        XCTAssertNil(AppAction.copilotPanel.linkQuestion)
    }

    func testDeclinedLinkDoesNotTurnCopilotOn() {
        AppAction.copilotOnNow = { false }
        var asked: [String] = []
        AppAction.linkConfirmer = { title, _ in asked.append(title); return false }
        defer { AppAction.linkConfirmer = nil }
        AppAction(url: URL(string: "macutils://copilot")!)?.runFromLink()
        XCTAssertEqual(asked, ["Включить подсказчика на встрече?"])
    }

    /// «Думаю…» в полоске — сразу, как ушёл вопрос, до первого слова (у Codex это 5–10 с).
    func testThinkingShowsAtOnce() async {
        final class L: CopilotListening {
            var onFailure: (@MainActor (String) -> Void)?
            func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {}
            func stop() {}
        }
        struct Silent: CopilotAIClient {
            func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { c in
                    let t = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); c.finish() }
                    c.onTermination = { _ in t.cancel() }
                }
            }
        }
        let session = CopilotSession(ai: Silent(), listener: L(), settings: { CopilotSettings(autoAnswer: false) }, log: { _ in }, logError: { _ in })
        session.start()
        XCTAssertEqual(CopilotPanelRules.stripText(isOn: session.isOn, isAnswering: session.isAnswering, error: nil), "Слушаю · вопросов нет")
        session.feed(Utterance(.other, "Как ускорить отчёт?"))
        session.answerLast()
        XCTAssertTrue(session.isAnswering, "сразу, без ожидания первого куска")
        XCTAssertEqual(CopilotPanelRules.stripText(isOn: session.isOn, isAnswering: session.isAnswering, error: nil), "Думаю…")
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(CopilotPanelRules.stripText(isOn: session.isOn, isAnswering: session.isAnswering, error: nil), "Думаю…", "модель молчит — «Думаю…» остаётся")
        session.stop()
    }

    func testHonestCodexSpeedHintOnlyForCodex() {
        XCTAssertEqual(CopilotPage.serviceSubtitle(.codex),
                       "Codex начинает ответ примерно за 3–4 с. Claude — меньше чем за секунду: сервис меняется на странице «ИИ».")
        XCTAssertFalse(CopilotPage.serviceSubtitle(.claude).contains("3–4"))
    }
}

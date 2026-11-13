import XCTest
import Carbon.HIToolbox
@testable import MacUtils
@testable import MUCopilot
import MUCore
import MUDesign

final class CopilotDetectorTests: XCTestCase {
    func testQuestionsInThreeLanguages() {
        for text in ["Как бы вы ускорили этот отчёт", "Расскажите про ваш опыт с тестированием", "Почему запрос работает медленно?",
                     "Як би ви оптимізували цей запит", "Чому тест падає на CI", "Поясніть різницю між ними",
                     "How would you speed up this report", "Can you walk me through your last project", "What is the difference between them?",
                     "Хорошо. У нас большая таблица. Как вы построите отчёт"] {
            XCTAssertTrue(QuestionDetector.isQuestion(text), text)
        }
    }

    func testNotQuestions() {
        for text in ["Хорошо, спасибо", "У нас таблица на 40 миллионов строк", "Давайте перейдём к следующему пункту", "Как видите, пик пришёлся на вторник", "Як бачите, графік зріс", "As you can see the load grew", "Ок", "That sounds great to me"] {
            XCTAssertFalse(QuestionDetector.isQuestion(text), text)
        }
    }

    func testYourOwnSpeechIsNeverAQuestion() {
        XCTAssertFalse(QuestionDetector.isQuestion("Как бы вы это сделали?", speaker: .me))
    }

    func testPendingQuestionStopsAfterYouAnswer() {
        let q = Utterance(.other, "Как бы вы это оптимизировали?")
        XCTAssertEqual(QuestionDetector.pendingQuestion(in: [q])?.text, q.text)
        let answered = [q, Utterance(.me, "Я начну с плана запроса и посмотрю индексы")]
        XCTAssertNil(QuestionDetector.pendingQuestion(in: answered))
        let short = [q, Utterance(.me, "Хм, да")]
        XCTAssertNotNil(QuestionDetector.pendingQuestion(in: short))
    }
}

final class CopilotPromptTests: XCTestCase {
    func testTranscriptKeepsOnlyLastThreeMinutes() {
        let now = Date()
        let list = [Utterance(.other, "старое", at: now.addingTimeInterval(-400)), Utterance(.other, "Как дела?", at: now.addingTimeInterval(-100)),
                    Utterance(.me, "Хорошо", at: now.addingTimeInterval(-90))]
        XCTAssertEqual(CopilotPrompt.transcript(list, now: now), "Собеседник: Как дела?\nВы: Хорошо")
    }

    func testTranscriptCapsLength() {
        let now = Date()
        let list = (0..<50).map { Utterance(.other, String(repeating: "я", count: 400) + "\($0)", at: now) }
        XCTAssertLessThanOrEqual(CopilotPrompt.transcript(list, now: now, maxChars: 2000).count, 2000 + 450)
        XCTAssertTrue(CopilotPrompt.transcript(list, now: now, maxChars: 2000).hasSuffix("49"))
    }

    func testSystemAndUserPrompts() {
        var s = CopilotSettings(about: "QA-инженер, 5 лет")
        XCTAssertTrue(CopilotPrompt.system(settings: s).contains("NO_QUESTION"))
        XCTAssertTrue(CopilotPrompt.system(settings: s).contains("на котором задан вопрос"))
        s.meetingLanguage = "en"
        XCTAssertTrue(CopilotPrompt.system(settings: s).contains("English"))
        s.answerLanguage = "ru"
        XCTAssertTrue(CopilotPrompt.system(settings: s).contains("Язык ответа: Русский"))
        let user = CopilotPrompt.user(settings: s, utterances: [Utterance(.other, "Как дела?")], now: Date(), mode: .lastQuestion)
        XCTAssertTrue(user.contains("QA-инженер, 5 лет"))
        XCTAssertTrue(user.contains("Собеседник: Как дела?"))
        XCTAssertTrue(CopilotPrompt.user(settings: CopilotSettings(), utterances: [], now: Date(), mode: .custom("что такое индекс")).contains("что такое индекс"))
        XCTAssertTrue(CopilotPrompt.user(settings: CopilotSettings(), utterances: [], now: Date(), mode: .screen).contains("снимок экрана"))
        XCTAssertTrue(CopilotPrompt.user(settings: CopilotSettings(), utterances: [], now: Date(), mode: .shorter,
                                         previous: CopilotAnswer(say: "Прошлая фраза", points: [], sayComplete: true)).contains("Прошлая фраза"))
    }

    func testParseStreamedAnswer() {
        XCTAssertEqual(CopilotPrompt.parse(""), .answer(.empty))
        if case .answer(let a) = CopilotPrompt.parse("Начну с плана за") { XCTAssertEqual(a.say, "Начну с плана за"); XCTAssertFalse(a.sayComplete) } else { XCTFail() }
        if case .answer(let a) = CopilotPrompt.parse("Начну с плана запроса.\n- EXPLAIN ANALYZE\n- Составной индекс\n- Сводная таблица\n- Ещё\n- Лишний") {
            XCTAssertEqual(a.say, "Начну с плана запроса.")
            XCTAssertTrue(a.sayComplete)
            XCTAssertEqual(a.points, ["EXPLAIN ANALYZE", "Составной индекс", "Сводная таблица", "Ещё"])
        } else { XCTFail() }
    }

    func testParseCleansDecoration() {
        if case .answer(let a) = CopilotPrompt.parse("Скажите: «Начну с **плана**»\n• пункт") {
            XCTAssertEqual(a.say, "Начну с плана")
            XCTAssertEqual(a.points, ["пункт"])
        } else { XCTFail() }
    }

    func testParseNoQuestion() {
        XCTAssertEqual(CopilotPrompt.parse("NO_QUESTION"), .noQuestion)
        XCTAssertEqual(CopilotPrompt.parse("NO_QUESTION\n"), .noQuestion)
        XCTAssertEqual(CopilotPrompt.parse("NO_"), .answer(.empty))
    }
}

@MainActor
final class CopilotSessionTests: XCTestCase {
    final class Listener: CopilotListening {
        var started = 0, stopped = 0
        var failure: Error?
        var handler: (@MainActor (Utterance) -> Void)?
        var onFailure: (@MainActor (String) -> Void)?
        func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {
            if let failure { throw failure }
            started += 1; handler = onUtterance
        }
        func stop() { stopped += 1 }
    }

    struct AI: CopilotAIClient {
        var chunks: [String]
        var fail: Error?
        func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { c in
                for ch in chunks { c.yield(ch) }
                c.finish(throwing: fail)
            }
        }
    }

    private func make(_ ai: AI, listener: Listener? = nil, settings: CopilotSettings = CopilotSettings(), log: @escaping (String) -> Void = { _ in }) -> (CopilotSession, Listener) {
        let l = listener ?? Listener()
        return (CopilotSession(ai: ai, listener: l, settings: { settings }, log: log), l)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 50_000_000) }

    func testNeverListensUntilTurnedOnByHand() {
        let (session, listener) = make(AI(chunks: []))
        XCTAssertEqual(session.phase, .off)
        XCTAssertEqual(listener.started, 0)
        session.feed(Utterance(.other, "Как бы вы это сделали?"))
        XCTAssertTrue(session.transcript.isEmpty, "выключенный подсказчик ничего не принимает")
        session.answerLast()
        XCTAssertFalse(session.isAnswering)
    }

    func testToggleStartsAndStopsListening() {
        let (session, listener) = make(AI(chunks: []))
        session.toggle()
        XCTAssertTrue(session.isOn)
        XCTAssertEqual(listener.started, 1)
        session.toggle()
        XCTAssertEqual(session.phase, .off)
        XCTAssertEqual(listener.stopped, 1)
    }

    func testFailedStartStaysOffWithMessage() {
        let l = Listener()
        l.failure = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "нет доступа"])
        let (session, _) = make(AI(chunks: []), listener: l)
        session.start()
        XCTAssertEqual(session.phase, .off)
        XCTAssertTrue(session.error?.contains("нет доступа") == true)
    }

    func testAutoAnswerStreamsAndLogsLatency() async {
        var logs: [String] = []
        let (session, _) = make(AI(chunks: ["Начну с плана", " запроса.\n- EXPLAIN", "\n- Индекс"]), log: { logs.append($0) })
        session.start()
        session.feed(Utterance(.other, "Как бы вы ускорили этот отчёт?"))
        await settle()
        XCTAssertEqual(session.question, "Как бы вы ускорили этот отчёт?")
        XCTAssertEqual(session.answer.say, "Начну с плана запроса.")
        XCTAssertEqual(session.answer.points, ["EXPLAIN", "Индекс"])
        XCTAssertFalse(session.isAnswering)
        XCTAssertNotNil(session.expandedAt)
        XCTAssertNotNil(session.lastLatency)
        XCTAssertTrue(logs.contains { $0.contains("первый кусок через") })
    }

    func testAutoAnswerOffWaitsForHotKey() async {
        var s = CopilotSettings(); s.autoAnswer = false
        let (session, _) = make(AI(chunks: ["Фраза.\n- пункт"]), settings: s)
        session.start()
        session.feed(Utterance(.other, "Как бы вы ускорили этот отчёт?"))
        await settle()
        XCTAssertTrue(session.answer.isEmpty)
        session.answerLast()
        await settle()
        XCTAssertEqual(session.answer.say, "Фраза.")
    }

    func testSameQuestionIsAnsweredOnce() async {
        let (session, _) = make(AI(chunks: ["Фраза."]))
        session.start()
        session.feed(Utterance(.other, "Как бы вы ускорили этот отчёт?"))
        await settle()
        let first = session.expandedAt
        session.feed(Utterance(.other, "Хорошо, спасибо"))
        await settle()
        XCTAssertEqual(session.expandedAt, first)
    }

    func testNoQuestionKeepsPanelCollapsed() async {
        let (session, _) = make(AI(chunks: ["NO_QUESTION"]))
        session.start()
        session.feed(Utterance(.other, "Как бы вы ускорили этот отчёт?"))
        await settle()
        XCTAssertNil(session.expandedAt)
        XCTAssertTrue(session.answer.isEmpty)
    }

    func testAIErrorIsShown() async {
        let (session, _) = make(AI(chunks: [], fail: NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "не вошли в аккаунт"])))
        session.start()
        session.ask(custom: "что такое индекс")
        await settle()
        XCTAssertEqual(session.error, "не вошли в аккаунт")
        XCTAssertFalse(session.isAnswering)
    }

    func testStopWipesEverythingAndReleasesSources() async {
        let (session, listener) = make(AI(chunks: ["Фраза."]))
        session.start()
        session.feed(Utterance(.other, "Как бы вы ускорили этот отчёт?"))
        await settle()
        session.stop()
        XCTAssertTrue(session.transcript.isEmpty)
        XCTAssertTrue(session.answer.isEmpty)
        XCTAssertNil(session.question)
        XCTAssertNil(session.expandedAt)
        XCTAssertEqual(listener.stopped, 1)
    }

    func testLatencyMeter() {
        var m = LatencyMeter()
        let t = Date()
        m.questionEnded(at: t)
        m.firstLine(at: t.addingTimeInterval(2.5))
        m.firstLine(at: t.addingTimeInterval(9))
        XCTAssertEqual(m.seconds, 2.5)
        XCTAssertTrue(m.withinTarget)
        m.questionEnded(at: t)
        m.firstLine(at: t.addingTimeInterval(5))
        XCTAssertFalse(m.withinTarget)
    }
}

@MainActor
final class CopilotShellTests: XCTestCase {
    func testPanelRules() {
        let t = Date()
        XCTAssertTrue(CopilotPanelRules.shouldCollapse(expandedAt: t.addingTimeInterval(-21), now: t, isAnswering: false, holdingOption: false))
        XCTAssertFalse(CopilotPanelRules.shouldCollapse(expandedAt: t.addingTimeInterval(-19), now: t, isAnswering: false, holdingOption: false))
        XCTAssertFalse(CopilotPanelRules.shouldCollapse(expandedAt: t.addingTimeInterval(-60), now: t, isAnswering: true, holdingOption: false))
        XCTAssertFalse(CopilotPanelRules.shouldCollapse(expandedAt: t.addingTimeInterval(-60), now: t, isAnswering: false, holdingOption: true))
        XCTAssertFalse(CopilotPanelRules.shouldCollapse(expandedAt: nil, now: t, isAnswering: false, holdingOption: false))
        XCTAssertTrue(CopilotPanelRules.ignoresMouse(optionHeld: false))
        XCTAssertFalse(CopilotPanelRules.ignoresMouse(optionHeld: true))
    }

    func testPanelFrames() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let strip = CopilotPanelRules.frame(placement: .underCamera, expanded: false, in: screen, notchHeight: 32)
        XCTAssertEqual(strip.midX, 720)
        XCTAssertEqual(strip.maxY, 900 - 32)
        XCTAssertGreaterThan(CopilotPanelRules.frame(placement: .underCamera, expanded: true, in: screen).height, strip.height)
        let side = CopilotPanelRules.frame(placement: .side, expanded: true, in: screen)
        XCTAssertEqual(side.maxX, 1440 - 12)
        XCTAssertTrue(screen.contains(side))
    }

    func testPanelIsHiddenFromSharingAndClickThrough() {
        let session = CopilotSession(ai: UnavailableCopilotAI(), listener: UnavailableCopilotListener())
        let panel = CopilotPanel(session: session)
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    func testEnabledStateIsNeverPersisted() {
        let d = CopilotTestDefaults.make("copilot-")
        let s = CopilotPrefs.load(d)
        XCTAssertEqual(s, CopilotSettings())
        XCTAssertEqual(s.placement, .underCamera)
        XCTAssertTrue(d.dictionaryRepresentation().keys.filter { $0.lowercased().contains("copilot") }.isEmpty)
        d.set("side", forKey: CopilotPrefs.placement)
        d.set("", forKey: CopilotPrefs.answerLanguage)
        XCTAssertEqual(CopilotPrefs.load(d).placement, .side)
        XCTAssertNil(CopilotPrefs.load(d).answerLanguage)
    }

    func testStartingWithoutBackendsFailsHonestly() {
        let session = CopilotSession(ai: UnavailableCopilotAI(), listener: UnavailableCopilotListener(), log: { _ in })
        session.start()
        XCTAssertEqual(session.phase, .off)
        XCTAssertNotNil(session.error)
    }

    func testHotKeys() {
        XCTAssertEqual(HotKeyAction.copilot.defaultCombo, LayoutHotKey(keyCode: kVK_ANSI_M, modifiers: optionKey | shiftKey))
        let defaults = CopilotTestDefaults.make("copilot-keys-")
        let entries = HotKeyRegistry.entries(defaults: defaults)
        for a in [HotKeyAction.copilot, .copilotAnswer, .copilotScreen, .copilotPanel] {
            let c = HotKeyRegistry.combo(for: a, defaults: defaults)
            XCTAssertTrue(HotKeyRegistry.isValid(c))
            XCTAssertTrue(HotKeyConflicts.duplicates(of: c, excluding: .action(a), in: entries).isEmpty, "\(a)")
            XCTAssertEqual(a.section, .copilot)
        }
    }

    func testSectionNextToMeetings() {
        let s = SettingsSection.meetings.group.sections
        XCTAssertEqual(s.firstIndex(of: .copilot), s.firstIndex(of: .meetings).map { $0 + 1 })
    }
}

final class CopilotRulesTests: XCTestCase {
    private let screens = [CopilotScreen(id: "1", name: "Встроенный", isMain: true), CopilotScreen(id: "7", name: "iPad", isMain: false),
                           CopilotScreen(id: "9", name: "Монитор", isMain: false)]

    func testScreenChoice() {
        XCTAssertEqual(ScreenChoice.pick(screens, preferred: nil, placement: .underCamera)?.id, "1")
        XCTAssertEqual(ScreenChoice.pick(screens, preferred: "9", placement: .side)?.id, "1")
        XCTAssertEqual(ScreenChoice.pick(screens, preferred: nil, placement: .secondScreen)?.id, "7")
        XCTAssertEqual(ScreenChoice.pick(screens, preferred: "9", placement: .secondScreen)?.id, "9")
        XCTAssertEqual(ScreenChoice.pick(screens, preferred: "404", placement: .secondScreen)?.id, "7", "iPad отключили — первый не основной")
        XCTAssertEqual(ScreenChoice.pick([screens[0]], preferred: "7", placement: .secondScreen)?.id, "1", "второго нет — основной")
        XCTAssertNil(ScreenChoice.pick([], preferred: nil, placement: .secondScreen))
    }

    func testScreenNote() {
        XCTAssertNotNil(ScreenChoice.note([screens[0]], preferred: nil))
        XCTAssertNotNil(ScreenChoice.note(screens, preferred: "404"))
        XCTAssertNil(ScreenChoice.note(screens, preferred: "7"))
        XCTAssertNil(ScreenChoice.note(screens, preferred: ""))
    }

    func testMergeRule() {
        let t = Date()
        let a = Utterance(.other, "Как бы вы", at: t)
        XCTAssertTrue(UtteranceMerge.continues(a, with: Utterance(.other, "ускорили отчёт", at: t.addingTimeInterval(1))))
        XCTAssertFalse(UtteranceMerge.continues(a, with: Utterance(.other, "ускорили отчёт", at: t.addingTimeInterval(3))))
        XCTAssertFalse(UtteranceMerge.continues(a, with: Utterance(.me, "ускорили отчёт", at: t.addingTimeInterval(1))))
        XCTAssertFalse(UtteranceMerge.continues(Utterance(.other, "Хорошо.", at: t), with: Utterance(.other, "Дальше", at: t.addingTimeInterval(1))))
    }

    func testLocale() {
        XCTAssertEqual(CopilotLocale.identifier(for: "uk"), "uk_UA")
        XCTAssertEqual(CopilotLocale.identifier(for: "en"), "en_US")
        XCTAssertEqual(CopilotLocale.identifier(for: nil), "ru_RU")
    }
}

@MainActor
final class CopilotMergeSessionTests: XCTestCase {
    final class L: CopilotListening {
        var onFailure: (@MainActor (String) -> Void)?
        func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {}
        func stop() {}
    }
    struct Silent: CopilotAIClient {
        func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    }

    func testSplitQuestionIsMergedBeforeDetection() {
        let session = CopilotSession(ai: Silent(), listener: L(), settings: { CopilotSettings(autoAnswer: false) }, log: { _ in })
        session.start()
        let t = Date()
        session.feed(Utterance(.other, "Ну а теперь скажите", at: t))
        session.feed(Utterance(.other, "как бы вы ускорили отчёт", at: t.addingTimeInterval(1)))
        XCTAssertEqual(session.transcript.count, 1)
        XCTAssertEqual(session.transcript[0].text, "Ну а теперь скажите как бы вы ускорили отчёт")
    }

    func testListenerFailureTurnsItOffWithReason() {
        let l = L()
        let session = CopilotSession(ai: Silent(), listener: l, log: { _ in })
        session.start()
        XCTAssertTrue(session.isOn)
        l.onFailure?("Звук звонка остановился")
        XCTAssertEqual(session.phase, .off)
        XCTAssertEqual(session.error, "Звук звонка остановился")
    }
}

final class VolatileSettlerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testEmitsAfterStablePause() {
        var s = VolatileSettler()
        s.volatile("Как бы вы", at: at(0))
        XCTAssertNil(s.tick(at: at(0.5)), "пауза ещё короче 0,7 с")
        s.volatile("Как бы вы ускорили отчёт", at: at(0.6))
        XCTAssertNil(s.tick(at: at(1.2)), "текст изменился в 0,6: отсчёт заново")
        XCTAssertEqual(s.tick(at: at(1.4)), "Как бы вы ускорили отчёт")
        XCTAssertNil(s.tick(at: at(2.0)), "то же самое второй раз не отдаётся")
    }

    func testFinalAddsOnlyTheRest() {
        var s = VolatileSettler()
        s.volatile("как бы вы ускорили", at: at(0))
        XCTAssertEqual(s.tick(at: at(0.8)), "как бы вы ускорили")
        XCTAssertEqual(s.final("Как бы вы ускорили этот отчёт?"), "этот отчёт?")
        XCTAssertEqual(s.emittedWords, 0, "новая фраза")
    }

    func testFinalWithoutEarlierEmissionIsEmittedWhole() {
        var s = VolatileSettler()
        s.volatile("Привет", at: at(0))
        XCTAssertEqual(s.final("Привет, коллеги."), "Привет, коллеги.")
    }

    func testFinalNotLongerThanEmittedAddsNothing() {
        var s = VolatileSettler()
        s.volatile("Расскажите про ваш опыт", at: at(0))
        _ = s.tick(at: at(1))
        XCTAssertNil(s.final("Расскажите про ваш опыт."))
    }

    func testRevisionOfEarlyWordsDoesNotRepeat() {
        var s = VolatileSettler()
        s.volatile("как бы вы ускорили", at: at(0))
        _ = s.tick(at: at(1))
        s.volatile("как бы ты ускорил этот отчёт", at: at(1.1))
        XCTAssertNil(s.tick(at: at(1.5)))
        XCTAssertEqual(s.tick(at: at(1.9)), "этот отчёт", "отдаются только слова после уже отданных")
    }

    func testPunctuationAndCaseDoNotRestartThePause() {
        var s = VolatileSettler()
        s.volatile("как бы вы", at: at(0))
        s.volatile("Как бы вы,", at: at(0.4))
        XCTAssertEqual(s.tick(at: at(0.8)), "Как бы вы,")
    }

    func testPauseIsConfigurableAndDefaultIsSevenTenths() {
        XCTAssertEqual(VolatileSettler().pause, 0.7)
        var s = VolatileSettler(pause: 0.3)
        s.volatile("один два три", at: at(0))
        XCTAssertEqual(s.tick(at: at(0.35)), "один два три")
    }

    func testEmptyInputNeverEmits() {
        var s = VolatileSettler()
        s.volatile("   ", at: at(0))
        XCTAssertNil(s.tick(at: at(5)))
        XCTAssertNil(s.final(""))
    }

    func testReactToPausesOptionDefaultsOnAndIsStored() {
        let d = CopilotTestDefaults.make("copilot-react-")
        XCTAssertTrue(CopilotPrefs.load(d).reactToPauses)
        d.set(false, forKey: CopilotPrefs.reactToPauses)
        XCTAssertFalse(CopilotPrefs.load(d).reactToPauses)
    }

    @MainActor func testSplitPhrasePiecesFlowIntoOneQuestion() {
        // «Как бы вы» отдано после паузы, остаток финала приходит следом: сессия склеивает и ищет вопрос по целому.
        let t = Date()
        let a = Utterance(.other, "Ну скажите как бы вы", at: t)
        let b = Utterance(.other, "ускорили этот отчёт", at: t.addingTimeInterval(0.9))
        XCTAssertTrue(UtteranceMerge.continues(a, with: b))
        XCTAssertTrue(QuestionDetector.isQuestion(a.text + " " + b.text))
    }
}

final class WarmProtocolTests: XCTestCase {
    private func json(_ data: Data?) throws -> [String: Any] {
        let d = try XCTUnwrap(data)
        XCTAssertEqual(d.last, 0x0A, "одна строка на сообщение")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: d.dropLast()) as? [String: Any])
    }

    func testClaudeUserMessage() throws {
        let m = try json(WarmProtocol.claudeUserMessage("Вопрос \"раз\"\nдва"))
        XCTAssertEqual(m["type"] as? String, "user")
        let content = ((m["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(content?["type"] as? String, "text")
        XCTAssertEqual(content?["text"] as? String, "Вопрос \"раз\"\nдва")
    }

    func testCodexRequests() throws {
        let i = try json(WarmProtocol.codexInitialize(id: 1))
        XCTAssertEqual(i["method"] as? String, "initialize")
        XCTAssertEqual(((i["params"] as? [String: Any])?["clientInfo"] as? [String: Any])?["name"] as? String, "mac-utils-copilot")
        XCTAssertNil(i["jsonrpc"])
        let n = try json(WarmProtocol.codexInitialized())
        XCTAssertEqual(n["method"] as? String, "initialized")
        XCTAssertNil(n["id"], "уведомление без id")

        let t = try json(WarmProtocol.codexThreadStart(id: 2, system: "Система", cwd: "/tmp/x", model: nil))
        let tp = try XCTUnwrap(t["params"] as? [String: Any])
        XCTAssertEqual(tp["ephemeral"] as? Bool, true)
        XCTAssertEqual(tp["sandbox"] as? String, "read-only")
        XCTAssertEqual(tp["approvalPolicy"] as? String, "never")
        XCTAssertEqual(tp["developerInstructions"] as? String, "Система")
        XCTAssertNil(tp["model"])

        let u = try json(WarmProtocol.codexTurnStart(id: 3, threadID: "th1", text: "Вопрос", effort: "low", model: "fast-1"))
        let up = try XCTUnwrap(u["params"] as? [String: Any])
        XCTAssertEqual(up["threadId"] as? String, "th1")
        XCTAssertEqual(up["effort"] as? String, "low")
        XCTAssertEqual(up["model"] as? String, "fast-1")
        let input = try XCTUnwrap((up["input"] as? [[String: Any]])?.first)
        XCTAssertEqual(input["type"] as? String, "text")
        XCTAssertEqual(input["text"] as? String, "Вопрос")
    }

    func testCodexParsing() {
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"id":2,"result":{"thread":{"id":"th1"}}}"#), .response(id: 2, threadID: "th1", error: nil))
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"id":1,"result":{}}"#), .response(id: 1, threadID: nil, error: nil))
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"id":3,"error":{"code":-1,"message":"плохо"}}"#), .response(id: 3, threadID: nil, error: "плохо"))
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"method":"item/agentMessage/delta","params":{"delta":"Нач","itemId":"i","threadId":"th1","turnId":"t"}}"#),
                       .delta(threadID: "th1", text: "Нач"))
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"method":"turn/completed","params":{"threadId":"th1","turn":{"status":"completed"}}}"#),
                       .completed(threadID: "th1", failed: false, message: nil))
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"method":"turn/completed","params":{"threadId":"th1","turn":{"status":"failed","error":{"message":"лимит"}}}}"#),
                       .completed(threadID: "th1", failed: true, message: "лимит"))
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"method":"error","params":{"threadId":"th1","willRetry":true,"error":{"message":"сеть"}}}"#),
                       .error(threadID: "th1", message: "сеть", willRetry: true))
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"id":7,"method":"item/commandExecution/requestApproval","params":{}}"#), .serverRequest(idJSON: "7"))
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"method":"turn/started","params":{}}"#), .other)
        XCTAssertEqual(WarmProtocol.parseCodex("не json"), .other)
    }
}

final class HybridAnswerTests: XCTestCase {
    func testMergesSayFromFastAndPointsFromMain() {
        var h = HybridAnswer()
        h.appendPoints("- индекс\n")
        XCTAssertEqual(h.parsed, .answer(CopilotAnswer(say: "", points: ["индекс"], sayComplete: false)))
        h.appendSay("Начну с плана запроса.")
        h.finishSay()
        h.appendPoints("\n- сводная таблица")
        guard case .answer(let a) = h.parsed else { return XCTFail() }
        XCTAssertEqual(a.say, "Начну с плана запроса.")
        XCTAssertTrue(a.sayComplete)
        XCTAssertEqual(a.points.count, 2)
    }

    func testFastModelPointsAreIgnoredAndNoQuestionWinsFromEither() {
        var h = HybridAnswer()
        h.appendSay("Фраза.\n- лишний пункт")
        guard case .answer(let a) = h.parsed else { return XCTFail() }
        XCTAssertEqual(a.say, "Фраза.")
        XCTAssertTrue(a.points.isEmpty, "пункты берём только от основной")
        var n = HybridAnswer()
        n.appendSay("NO_QUESTION")
        XCTAssertEqual(n.parsed, .noQuestion)
        var m = HybridAnswer()
        m.appendPoints("NO_QUESTION")
        XCTAssertEqual(m.parsed, .noQuestion)
    }
}

final class CopilotSpeedRulesTests: XCTestCase {
    func testSayLimitIs140AndInPrompts() {
        XCTAssertEqual(CopilotPrompt.maxSayLength, 140)
        XCTAssertEqual(CopilotEvalGrader.maxSayLength, 140)
        for part in [CopilotPrompt.Part.full, .sayOnly] {
            XCTAssertTrue(CopilotPrompt.system(settings: CopilotSettings(), part: part).contains("140"), "\(part)")
        }
        XCTAssertTrue(CopilotPrompt.system(settings: CopilotSettings(), part: .pointsOnly).contains("ТОЛЬКО 2–4"))
        for part in [CopilotPrompt.Part.full, .sayOnly, .pointsOnly] {
            XCTAssertTrue(CopilotPrompt.system(settings: CopilotSettings(), part: part).contains("NO_QUESTION"))
        }
    }

    func testGraderRejectsLongFirstLine() {
        let d = CopilotDialog(id: "x", language: "ru", kind: "work", about: "", utterances: [], expectQuestion: true, questionGist: "", keywordGroups: [])
        XCTAssertTrue(CopilotEvalGrader.grade(raw: String(repeating: "я", count: 140) + "\n- а\n- б", dialog: d).passed)
        XCTAssertFalse(CopilotEvalGrader.grade(raw: String(repeating: "я", count: 141) + "\n- а\n- б", dialog: d).passed)
    }

    func testMeterTargetAndLineComplete() {
        XCTAssertEqual(LatencyMeter.target, 2.5)
        var m = LatencyMeter()
        let t = Date()
        m.questionEnded(at: t)
        m.firstLine(at: t.addingTimeInterval(1.2))
        m.lineComplete(at: t.addingTimeInterval(2.0))
        XCTAssertEqual(try XCTUnwrap(m.seconds), 1.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(m.lineCompleteSeconds), 2.0, accuracy: 0.001)
        XCTAssertTrue(m.withinTarget)
    }

    func testSpeedSettingsDefaults() {
        let d = CopilotTestDefaults.make("copilot-speed-")
        let s = CopilotPrefs.load(d)
        XCTAssertTrue(s.fastModels)
        XCTAssertFalse(s.hybrid, "гибрид — два запроса подписки, по умолчанию выключен")
        d.set(true, forKey: CopilotPrefs.hybrid)
        XCTAssertTrue(CopilotPrefs.load(d).hybrid)
    }

    func testModelProfiles() {
        let d = CopilotTestDefaults.make("copilot-models-")
        XCTAssertEqual(CopilotModels.model(.claude, .fast, defaults: d), "haiku")
        XCTAssertNil(CopilotModels.model(.claude, .main, defaults: d))
        XCTAssertNil(CopilotModels.model(.codex, .fast, defaults: d))
        d.set("gpt-fast", forKey: CopilotModels.codexFast)
        XCTAssertEqual(CopilotModels.model(.codex, .fast, defaults: d), "gpt-fast")
        XCTAssertEqual(CopilotModels.effort(.fast), "low")
        XCTAssertNil(CopilotModels.effort(.main))
        XCTAssertTrue(CopilotModels.warmEnabled(defaults: d))
        d.set(false, forKey: CopilotModels.warm)
        XCTAssertFalse(CopilotModels.warmEnabled(defaults: d))
    }
}

@MainActor
final class CopilotSpeedSessionTests: XCTestCase {
    final class L: CopilotListening {
        var onFailure: (@MainActor (String) -> Void)?
        func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {}
        func stop() {}
    }

    /// Записывает, с какими профилями и системными текстами его спрашивали; на вопрос отвечает по части.
    final class Recorder: CopilotAIClient, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(CopilotAIProfile, String)] = []
        private(set) var warmups = 0, shutdowns = 0
        func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
            lock.lock(); calls.append((profile, system)); lock.unlock()
            let text = system.contains("ТОЛЬКО 2–4") ? "- пункт раз\n- пункт два" : system.contains("ОДНОЙ строкой") ? "Короткая фраза." : "Фраза.\n- а\n- б"
            return AsyncThrowingStream { $0.yield(text); $0.finish() }
        }
        func warmUp(system: String) async { lock.lock(); warmups += 1; lock.unlock() }
        func shutdown() async { lock.lock(); shutdowns += 1; lock.unlock() }
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 80_000_000) }

    func testSingleRequestUsesFastProfileByDefaultAndMainWhenOff() async {
        let ai = Recorder()
        var settings = CopilotSettings(autoAnswer: false)
        let session = CopilotSession(ai: ai, listener: L(), settings: { settings }, log: { _ in })
        session.start()
        session.feed(Utterance(.other, "Как бы вы ускорили этот отчёт?"))
        session.answerLast()
        await settle()
        XCTAssertEqual(ai.calls.last?.0, .fast)
        settings.fastModels = false
        session.answerLast()
        await settle()
        XCTAssertEqual(ai.calls.last?.0, .main)
    }

    func testHybridSendsTwoParallelRequestsAndMerges() async {
        let ai = Recorder()
        let session = CopilotSession(ai: ai, listener: L(), settings: { CopilotSettings(autoAnswer: false, hybrid: true) }, log: { _ in })
        session.start()
        session.feed(Utterance(.other, "Как бы вы ускорили этот отчёт?"))
        session.answerLast()
        await settle()
        XCTAssertEqual(ai.calls.count, 2)
        XCTAssertEqual(Set(ai.calls.map { $0.0 }), [.fast, .main])
        XCTAssertEqual(session.answer.say, "Короткая фраза.")
        XCTAssertEqual(session.answer.points, ["пункт раз", "пункт два"])
        XCTAssertFalse(session.isAnswering)
    }

    func testScreenRequestIsNeverHybrid() async {
        let ai = Recorder()
        let session = CopilotSession(ai: ai, listener: L(), settings: { CopilotSettings(autoAnswer: false, hybrid: true) }, log: { _ in })
        session.start()
        session.lookAtScreen(image: Data([1]))
        await settle()
        XCTAssertEqual(ai.calls.count, 1)
    }

    func testWarmUpOnStartAndShutdownOnStop() async {
        let ai = Recorder()
        let session = CopilotSession(ai: ai, listener: L(), settings: { CopilotSettings() }, log: { _ in })
        session.start()
        await settle()
        XCTAssertEqual(ai.warmups, 1)
        session.stop()
        await settle()
        XCTAssertEqual(ai.shutdowns, 1)
    }
}

/// Временный набор настроек для теста; после теста его файл удаляется.
enum CopilotTestDefaults {
    static func make(_ prefix: String) -> UserDefaults {
        let name = "\(prefix)\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
}

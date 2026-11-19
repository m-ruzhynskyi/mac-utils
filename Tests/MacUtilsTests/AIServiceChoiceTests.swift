import XCTest
@testable import MacUtils
@testable import MUCopilot
@testable import MUAIBackend
import MUAI
import MUCore
import MUDownloadsSorter
import MUDropShelf
import MUMeetings
import MUScreenshot

/// COPILOT-37: один выбор сервиса на странице «ИИ» — и каждая функция с ИИ идёт в него. По тесту на функцию;
/// вместо codex и claude — заглушка бэкенда (`AI.router`), настоящие программы не запускаются, запросов нет.
final class AIServiceChoiceTests: XCTestCase {
    private var savedRouter: AIRouter!
    private var savedMakeClient: (@Sendable (AIProvider, Bool) -> CopilotAIClient)!
    private var saved: [(String, Any?)] = []
    private let log = ProviderLog()
    private static let keys = [Pref.ai, Pref.aiProvider, Pref.aiFallback, CopilotModels.warm]

    override func setUp() {
        savedRouter = AI.router
        savedMakeClient = BackendCopilotAI.makeClient
        let d = UserDefaults.standard
        saved = Self.keys.map { ($0, d.object(forKey: $0)) }
        d.set(true, forKey: Pref.ai)
        d.set(false, forKey: Pref.aiFallback)
        AI.router = AIRouter { [log] provider in RecordingEngine(provider: provider, log: log) }
    }

    override func tearDown() {
        AI.router = savedRouter
        BackendCopilotAI.makeClient = savedMakeClient
        let d = UserDefaults.standard
        for (key, value) in saved { if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) } }
    }

    /// Для каждого сервиса: выбрать его на странице «ИИ» (тот же ключ, что у переключателя) и проверить, куда ушёл запрос.
    private func assertFollowsChoice(_ feature: String, file: StaticString = #filePath, line: UInt = #line,
                                     _ run: () async throws -> Void) async throws {
        for provider in AIProvider.allCases {
            UserDefaults.standard.set(provider.rawValue, forKey: Pref.aiProvider)
            log.reset()
            try await run()
            XCTAssertEqual(log.providers, [provider], "\(feature): выбран \(provider.rawValue)", file: file, line: line)
        }
    }

    func testFixTextFollowsChoice() async throws {
        // ⌃⌥E, быстрая панель и «Команды» — все через `TextFixer.correct`.
        try await assertFollowsChoice("Исправление текста") { _ = try await TextFixer.correct("превет") }
    }

    func testMeetingReportFollowsChoice() async throws {
        try await assertFollowsChoice("Отчёт о встрече") { _ = try await MeetingRecorder.report(for: "[00:01] Я: привет") }
    }

    func testDownloadsFolderFollowsChoice() async throws {
        try await assertFollowsChoice("Папка в «Загрузках»") {
            _ = try await DownloadsAI.suggestFolder(ext: "fit", samples: ["run.fit"], existing: ["Docs"])
        }
    }

    func testShelfGroupsFollowChoice() async throws {
        try await assertFollowsChoice("Группы на полке") {
            _ = try await ShelfGrouper.group([URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")])
        }
    }

    func testShotNamesFollowChoice() async throws {
        try await assertFollowsChoice("Имена снимков") { _ = try await ShotNamer.name(for: "Счёт за интернет, оплатить до 20", app: "Safari") }
    }

    @MainActor
    func testTaskManagerExplanationFollowsChoice() async throws {
        try await assertFollowsChoice("Объяснения в диспетчере задач") {
            let explainer = ProcessExplainer()
            explainer.explain(ProcessRow(pid: 1, name: "mu-test-\(UUID().uuidString.prefix(6))", isApp: false, user: "root", cpu: 0, memory: 0))
            try await waitFor { explainer.busy.isEmpty && !self.log.providers.isEmpty }
        }
    }

    @MainActor
    func testCleanupAdviceFollowsChoice() async throws {
        try await assertFollowsChoice("Разбор очистки диска") {
            let advisor = CleanupAdvisor()
            advisor.review([CleanupItem(url: URL(fileURLWithPath: "/tmp/mu-unknown-\(UUID().uuidString.prefix(6))"), category: .caches, size: 1_000)])
            try await waitFor { !advisor.working && !self.log.providers.isEmpty }
        }
    }

    // MARK: Подсказчик

    func testCopilotColdFollowsChoice() async throws {
        UserDefaults.standard.set(false, forKey: CopilotModels.warm)
        try await assertFollowsChoice("Подсказчик (разовый запуск)") {
            for try await _ in BackendCopilotAI().stream(prompt: "вопрос", system: "s", images: [], profile: .fast) {}
        }
    }

    func testCopilotWarmFollowsChoice() async throws {
        UserDefaults.standard.set(true, forKey: CopilotModels.warm)
        let log = self.log
        BackendCopilotAI.makeClient = { provider, warm in
            XCTAssertTrue(warm)
            return StubCopilot(provider: provider, log: log)
        }
        try await assertFollowsChoice("Подсказчик (тёплый процесс)") {
            for try await _ in BackendCopilotAI().stream(prompt: "вопрос", system: "s", images: [], profile: .fast) {}
        }
        // Прогрев при ⌥⇧M — тоже у выбранного сервиса.
        try await assertFollowsChoice("Подсказчик (прогрев)") { await BackendCopilotAI().warmUp(system: "s") }
        XCTAssertEqual(BackendCopilotAI().service, AIProvider.allCases.last?.rawValue)
    }

    /// Запасной сервис включён, выбранный не ответил: подсказчик не уходит в невыбранный (ответ нужен сейчас, и выбор — человека).
    func testCopilotNeverFallsBackToOtherService() async throws {
        UserDefaults.standard.set(false, forKey: CopilotModels.warm)
        UserDefaults.standard.set(true, forKey: Pref.aiFallback)
        UserDefaults.standard.set(AIProvider.codex.rawValue, forKey: Pref.aiProvider)
        AI.router = AIRouter { [log] provider in RecordingEngine(provider: provider, log: log, fails: true) }
        do {
            for try await _ in BackendCopilotAI().stream(prompt: "вопрос", system: "s", images: [], profile: .fast) {}
            XCTFail("ошибка должна дойти до подсказчика")
        } catch {}
        XCTAssertEqual(log.providers, [.codex])
    }

    func testCopilotRefusesWhenAIIsOff() async throws {
        UserDefaults.standard.set(false, forKey: Pref.ai)
        do {
            for try await _ in BackendCopilotAI().stream(prompt: "вопрос", system: "s", images: [], profile: .fast) {}
            XCTFail("при выключенном ИИ ответа нет")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("страниц"), error.localizedDescription)
        }
        XCTAssertEqual(log.providers, [])
    }

    /// Остальные функции, как и раньше, переходят ко второму сервису только с переключателем «Запасной сервис» (по умолчанию выключен).
    func testOtherFeaturesUseOtherServiceOnlyWithFallbackSwitch() async throws {
        UserDefaults.standard.set(AIProvider.codex.rawValue, forKey: Pref.aiProvider)
        AI.router = AIRouter { [log] provider in RecordingEngine(provider: provider, log: log, fails: provider == .codex) }
        _ = try? await TextFixer.correct("текст")
        XCTAssertEqual(log.providers, [.codex])
        log.reset()
        UserDefaults.standard.set(true, forKey: Pref.aiFallback)
        _ = try await TextFixer.correct("текст")
        XCTAssertEqual(log.providers, [.codex, .claude])
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: @MainActor @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    }
}

private final class ProviderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [AIProvider] = []
    var providers: [AIProvider] { lock.withLock { list } }
    func add(_ p: AIProvider) { lock.withLock { list.append(p) } }
    func reset() { lock.withLock { list = [] } }
}

/// Заглушка бэкенда: записывает, к какому сервису пришёл запрос, и отвечает JSON, подходящим любой функции.
private struct RecordingEngine: AIEngine {
    let provider: AIProvider
    let log: ProviderLog
    var fails = false
    static let answer = #"{"folder":"Lab","groups":[{"title":"Документы","files":[1,2]}],"name":"Счёт за интернет","category":"Система","what":"служба","safe":"да","why":"системная","verdict":"safe","reason":"кэш"}"#

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> { stream(request, alive: {}) }

    func stream(_ request: AIRequest, alive: @escaping @Sendable () -> Void) -> AsyncThrowingStream<String, Error> {
        log.add(provider)
        let provider = provider, fails = fails
        return AsyncThrowingStream { c in
            if fails { c.finish(throwing: AIFailure.notFound(provider)) } else { c.yield(Self.answer); c.finish() }
        }
    }
}

private struct StubCopilot: CopilotAIClient {
    let provider: AIProvider
    let log: ProviderLog
    func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
        log.add(provider)
        return AsyncThrowingStream { $0.yield("Фраза.\n- а\n- б"); $0.finish() }
    }
    func warmUp(system: String) async { log.add(provider) }
}

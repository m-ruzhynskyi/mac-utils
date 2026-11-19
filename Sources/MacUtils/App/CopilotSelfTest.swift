import AppKit
import Darwin
import MUCore
import MUCopilot
import MUAIBackend

/// Самопроверка подсказчика для живой проверки без нажатий и без прав «Универсального доступа»:
///   open -n "/Applications/Mac Utils.app" --args --copilot-selftest [--copilot-question=<текст>]
/// Включает подсказчика (прогрев выбранного на странице «ИИ» сервиса), подаёт в конвейер готовый вопрос (микрофон и звук
/// не открываются), показывает панель и пишет в журнал (`Log.ai`, «Самопроверка подсказчика: …»): сервис, модель, прогрев,
/// «конец вопроса → первое слово», свойства панели, активную программу до и после, процессы после выключения. Потом выход.
/// Без ключа обычный запуск не меняется. Это настоящий запрос к ИИ — запускает только человек.
enum CopilotSelfTest {
    static let flag = "--copilot-selftest"
    static let questionPrefix = "--copilot-question="
    static let defaultQuestion = "Как ускорить отчёт по таблице на 40 млн строк?"
    /// Сколько ждать ответа и сколько — после выключения, прежде чем смотреть процессы.
    static let answerTimeout: TimeInterval = 60
    static let afterOffSeconds: TimeInterval = 3

    struct Options: Equatable {
        var question: String
    }

    static func options(_ arguments: [String]) -> Options? {
        guard arguments.contains(flag) else { return nil }
        let custom = arguments.last { $0.hasPrefix(questionPrefix) }.map { String($0.dropFirst(questionPrefix.count)) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Options(question: custom.flatMap { $0.isEmpty ? nil : $0 } ?? defaultQuestion)
    }

    /// «да» | «нет (<категория>)»: категория — без содержимого (`mcp-list-failed`, `process-exited(1)-mcp-config`…).
    static func warmPathLine(enabled: Bool, path: String?) -> String {
        guard enabled else { return "нет (выключен в настройках)" }
        return path ?? "нет (вопроса не было)"
    }

    /// Строка про процессы подсказчика, оставшиеся после выключения.
    static func processesLine(_ processes: [(pid: pid_t, name: String)]) -> String {
        let list = processes.isEmpty ? "нет" : processes.map { "\($0.pid) \($0.name)" }.joined(separator: ", ")
        return "процессы подсказчика после выключения: \(list)"
    }

    static func log(_ text: String) { Log.ai.notice("Самопроверка подсказчика: \(text, privacy: .public)") }

    @MainActor
    static func run(_ options: Options) async {
        let glue = CopilotGlue.shared
        let session = glue.session
        let provider = AI.provider
        let settings = CopilotPrefs.load()
        let profile: CopilotAIProfile = settings.fastModels ? .fast : .main
        let model = await CopilotModels.resolved(provider, profile, executable: nil)
        log("сервис \(provider.rawValue), ИИ \(AI.enabled ? "включён" : "выключен"), модель \(model ?? "по умолчанию сервиса"), профиль \(profile.rawValue), тёплый процесс \(CopilotModels.warmEnabled() ? "да" : "нет")")
        let before = frontmost()

        if !session.isOn { glue.toggle() }
        guard session.isOn else {
            log("не включился: \(session.error ?? "без причины")")
            return finish()
        }
        let warm = Date()
        await session.waitForWarmUp()
        log(String(format: "прогрев %.2f с", Date().timeIntervalSince(warm)))
        log("панель: \(glue.panelFacts)")

        // Вопрос собеседника: закончил говорить только что.
        let now = Date()
        session.feed(Utterance(.other, options.question, at: now, spoke: SpeechSpan(start: now.addingTimeInterval(-2), end: now)))
        if !session.isAnswering { session.answerLast() }   // «Отвечать сразу» выключено — как ⌥⇧A
        log("вопрос подан, полоска: «\(CopilotPanelRules.stripText(isOn: session.isOn, isAnswering: session.isAnswering, error: session.error))»")
        let deadline = Date().addingTimeInterval(answerTimeout)
        while session.isAnswering, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }

        if let seconds = session.lastLatency {
            log(String(format: "%@: конец вопроса → первое слово %.2f с", provider.rawValue, seconds))
        } else {
            log("\(provider.rawValue): первого слова нет\(session.isAnswering ? " за \(Int(answerTimeout)) с" : "")\(session.error.map { " — ошибка: \($0)" } ?? "")")
        }
        log("ответ: первая строка \(session.answer.say.count) знаков, пунктов \(session.answer.points.count)")
        log("тёплый путь: \(warmPathLine(enabled: CopilotModels.warmEnabled(), path: CopilotWarmRegistry.shared.lastPath(provider)))")
        log("панель после ответа: \(glue.panelFacts)")
        log("активная программа до: \(before), после: \(frontmost())")

        glue.toggle()
        try? await Task.sleep(nanoseconds: UInt64(afterOffSeconds * 1_000_000_000))
        let left = ProcessTree.descendants(of: getpid()).filter { $0 != getpid() }.map { (pid: $0, name: name(of: $0)) }
        log(processesLine(left))
        finish()
    }

    @MainActor
    private static func finish() {
        log("конец")
        AppTermination.terminate()
    }

    @MainActor
    private static func frontmost() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "нет" }
        return app.bundleIdentifier ?? app.localizedName ?? "pid \(app.processIdentifier)"
    }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : "?"
    }
}

/// Источник без звука: для самопроверки (вопрос подаёт она сама). Ничего не открывает.
@MainActor
final class SilentCopilotListener: CopilotListening {
    var onFailure: (@MainActor (String) -> Void)?
    func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {}
    func stop() {}
}

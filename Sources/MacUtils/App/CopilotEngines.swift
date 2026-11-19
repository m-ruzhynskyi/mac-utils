import Foundation
import MUCore
import MUCopilot
import MUAIBackend

// MARK: - ИИ подсказчика
//
// Всё через `MUAIBackend` и сервис со страницы «ИИ» (`AI.provider`): разовый запрос — `AI.router` (как у остальных
// функций), тёплые процессы — `ClaudeWarmHost` / `CodexWarmHost` из бэкенда с теми же запретами инструментов.

/// Свои настройки быстрых моделей (по умолчанию — быстрая модель Claude и малое «размышление» Codex).
enum CopilotModels {
    static let claudeFast = "copilotClaudeFastModel"
    static let codexFast = "copilotCodexFastModel"
    static let warm = "copilotWarmProcess"

    static func model(_ provider: AIProvider, _ profile: CopilotAIProfile, defaults: UserDefaults = .standard) -> String? {
        guard profile == .fast else { return nil }
        switch provider {
        case .claude: return nonEmpty(defaults.string(forKey: claudeFast)) ?? "haiku"
        case .codex: return nonEmpty(defaults.string(forKey: codexFast))
        }
    }

    /// Модель для запроса подсказчика. Codex: `MU_COPILOT_CODEX_MODEL` (замер `copilot-eval.sh`) → своя настройка →
    /// у быстрого профиля — быстрая из каталога codex (`codexCatalog`). Модель передаётся явно и в тёплый, и в разовый
    /// путь: иначе тёплый `app-server` брал модель из config.toml пользователя, а разовый `exec` — модель по умолчанию.
    static func resolved(_ provider: AIProvider, _ profile: CopilotAIProfile, executable: String?,
                         environment: [String: String] = ProcessInfo.processInfo.environment,
                         defaults: UserDefaults = .standard) async -> String? {
        if provider == .codex, let forced = nonEmpty(environment["MU_COPILOT_CODEX_MODEL"]) { return forced }
        if let own = model(provider, profile, defaults: defaults) { return own }
        guard provider == .codex, profile == .fast else { return nil }
        return await codexCatalog(executable)
    }

    /// Быстрая модель из каталога codex (`codex debug models`, без запросов к модели). Подменяется в тестах.
    nonisolated(unsafe) static var codexCatalog: @Sendable (_ executable: String?) async -> String? = { executable in
        var found = executable
        if found == nil { found = await CLIEnvironment.shared.executable(for: .codex) }
        guard let found else { return nil }
        return await CodexModelCatalog.shared.fastModel(executable: found)
    }

    /// Малое «размышление» у быстрого профиля: ответ подсказчику нужен сразу.
    static func effort(_ profile: CopilotAIProfile) -> String? { profile == .fast ? "low" : nil }

    static func warmEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: warm) as? Bool ?? true }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
}

// MARK: - Клиенты

/// Запуск CLI на каждый вопрос (как раньше): снимок экрана, запасной путь тёплого и сравнение в прогонщике.
/// Движок — из `AI.router`, как у всех функций Mac Utils (в тестах — заглушка); `executable` — своя программа (прогон на заглушке).
struct ColdCopilotAI: CopilotAIClient {
    let provider: AIProvider
    var executable: String?
    func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var files: [URL] = []
                defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
                do {
                    for data in images {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-\(UUID().uuidString).png")
                        try data.write(to: url)
                        files.append(url)
                    }
                    let model = await CopilotModels.resolved(provider, profile, executable: executable)
                    let request = AIRequest(prompt: prompt, system: system, images: files, timeout: BackendCopilotAI.timeout,
                                            quick: profile == .fast, model: model)
                    let engine: any AIEngine = executable.map { CLIEngine(provider, executable: $0) } ?? AI.router.engine(provider)
                    for try await piece in engine.stream(request) { continuation.yield(piece) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Тёплый клиент для одного сервиса. Картинки и любой сбой до первого куска — на холодный запуск.
final class WarmCopilotAI: CopilotAIClient, @unchecked Sendable {
    let provider: AIProvider
    private let lock = NSLock()
    private var claude: [String: ClaudeWarmHost] = [:]
    private var codex: CodexWarmHost?
    private var info: ClaudeWarmHost.Info?

    /// Как прошёл последний вопрос Claude (холодный процесс или тёплый, который по счёту) — для разбора хвостов.
    var lastInfo: ClaudeWarmHost.Info? { lock.lock(); defer { lock.unlock() }; return info }

    /// Своя программа вместо найденной (прогон `copilot-eval.sh stub` на подставных codex и claude).
    private let executableOverride: String?

    init(provider: AIProvider, executable: String? = nil) {
        self.provider = provider
        executableOverride = executable
    }

    private func findExecutable() async -> String? {
        if let executableOverride { return executableOverride }
        return await CLIEnvironment.shared.executable(for: provider)
    }

    private func claudeHost(system: String, profile: CopilotAIProfile, executable: String) -> ClaudeWarmHost {
        let key = "\(profile.rawValue)-\(system.hashValue)"
        lock.lock(); defer { lock.unlock() }
        if let host = claude[key] { return host }
        let host = ClaudeWarmHost(executable: executable, system: system, model: CopilotModels.model(.claude, profile), effort: CopilotModels.effort(profile))
        claude[key] = host
        return host
    }

    private func codexHost(executable: String) -> CodexWarmHost {
        lock.lock(); defer { lock.unlock() }
        if let host = codex { return host }
        let host = CodexWarmHost(executable: executable)
        codex = host
        return host
    }

    func warmUp(system: String) async {
        guard let executable = await findExecutable() else { return }
        switch provider {
        // Прогреваем ту сессию, куда пойдёт вопрос: быстрая модель или основная — по настройке «Быстрые модели».
        case .claude: await claudeHost(system: system, profile: CopilotPrefs.load().fastModels ? .fast : .main, executable: executable).warmUp()
        case .codex: try? await codexHost(executable: executable).warmUp()
        }
    }

    func shutdown() async {
        lock.lock(); let hosts = Array(claude.values); claude = [:]; let codex = self.codex; self.codex = nil; lock.unlock()
        for h in hosts { await h.shutdown() }
        await codex?.shutdown()
    }

    func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
        let cold = ColdCopilotAI(provider: provider, executable: executableOverride)
        guard images.isEmpty else { return cold.stream(prompt: prompt, system: system, images: images, profile: profile) }
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                var started = false
                do {
                    guard let executable = await findExecutable() else { throw AIFailure.notFound(provider) }
                    switch provider {
                    case .claude:
                        let host = claudeHost(system: system, profile: profile, executable: executable)
                        try await host.ask(prompt) { started = true; continuation.yield($0) }
                        if let i = await host.lastInfo {
                            lock.lock(); info = i; lock.unlock()
                            Log.ai.info("Подсказчик: Claude \(i.cold ? "холодный старт" : "тёплая сессия", privacy: .public), вопрос №\(i.usesBefore + 1, privacy: .public)")
                        }
                    case .codex:
                        let model = await CopilotModels.resolved(.codex, profile, executable: executable)
                        Log.ai.info("Подсказчик: Codex, модель \(model ?? "как в config.toml", privacy: .public), effort \(CopilotModels.effort(profile) ?? "как в codex", privacy: .public)")
                        let stream = try await codexHost(executable: executable).ask(
                            prompt: prompt, system: [system, AIRequest.textOnly].joined(separator: "\n"),
                            model: model, effort: CopilotModels.effort(profile))
                        for try await piece in stream { started = true; continuation.yield(piece) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    guard !started, !Task.isCancelled else { continuation.finish(throwing: error); return }
                    // Тёплый путь не сработал, ответа ещё не было: один холодный запуск.
                    Log.ai.info("Подсказчик: тёплый процесс не ответил (\(error.localizedDescription, privacy: .private)), холодный запуск")
                    do {
                        for try await piece in cold.stream(prompt: prompt, system: system, images: [], profile: profile) { continuation.yield(piece) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
            }
            // Тёплый процесс может замолчать (сеть, зависший ход): вопрос не висит дольше, чем холодный запуск.
            let silent = self.provider
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: UInt64(BackendCopilotAI.timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                task.cancel()
                continuation.finish(throwing: AIFailure.timeout(silent, seconds: BackendCopilotAI.timeout))
            }
            continuation.onTermination = { _ in task.cancel(); watchdog.cancel() }
        }
    }
}

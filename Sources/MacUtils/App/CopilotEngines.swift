import Foundation
import MUCore
import MUCopilot
import MUAIBackend

// MARK: - Тёплые процессы для подсказчика
//
// `codex exec` и `claude -p` на каждый вопрос запускают программу заново (сотни миллисекунд — секунды до первого куска).
// Здесь процесс живёт, пока подсказчик включён: Claude — одна живая сессия со stream-json на входе, Codex — `codex app-server`
// (JSON-RPC по stdio, новая одноразовая ветка на вопрос). Только текст: без инструментов, файлов и сети (кроме самого ИИ).

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

    /// Малое «размышление» у быстрого профиля: ответ подсказчику нужен сразу.
    static func effort(_ profile: CopilotAIProfile) -> String? { profile == .fast ? "low" : nil }

    static func warmEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: warm) as? Bool ?? true }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
}

/// Живой процесс: строки вывода — потоком, ввод — записью.
final class WarmProcess: @unchecked Sendable {
    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = Data()
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    init(executable: String, arguments: [String], environment: [String: String], directory: URL) {
        (lines, continuation) = AsyncStream<String>.makeStream()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; self.continuation.finish(); return }
            self.lock.lock()
            self.buffer.append(data)
            var out: [String] = []
            while let newline = self.buffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: self.buffer[..<newline], as: UTF8.self))
                self.buffer.removeSubrange(...newline)
            }
            self.lock.unlock()
            out.forEach { self.continuation.yield($0) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.lock(); self.errorTail.append(data); if self.errorTail.count > 600 { self.errorTail = self.errorTail.suffix(600) }; self.lock.unlock()
        }
        try process.run()
    }

    func write(_ data: Data) { try? input.fileHandleForWriting.write(contentsOf: data) }

    var stderrTail: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errorTail, as: UTF8.self) }
    var isRunning: Bool { process.isRunning }

    func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        continuation.finish()
    }
}

/// Читатель строк процесса: один потребитель, `next()` вызывается по очереди.
final class LineReader: @unchecked Sendable {
    private var iterator: AsyncStream<String>.Iterator
    init(_ stream: AsyncStream<String>) { iterator = stream.makeAsyncIterator() }
    func next() async -> String? { await iterator.next() }
}

struct WarmFailure: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

// MARK: Claude

/// Одна живая сессия `claude` на (системный текст, модель, «размышление»). Вопрос никогда не должен попасть на холодный процесс:
/// - новая сессия сразу «прогревается» коротким запросом (соединение и кэш системного текста готовы до первого вопроса);
/// - когда сессия подходит к обновлению (каждые `recycleAfter` вопросов, чтобы история не росла), следующая готовится
///   в фоне и подменяет текущую без ожидания.
actor ClaudeWarmHost {
    static let recycleAfter = 6
    /// Короткий служебный запрос, чтобы прогреть сессию (ответ отбрасывается).
    static let primePrompt = "Ответь одним словом: ок"

    /// Как прошёл последний вопрос: для замеров (холодный процесс — это и есть хвост).
    struct Info: Equatable, Sendable {
        var cold: Bool
        var usesBefore: Int
        var startupSeconds: Double
    }

    private struct Session {
        let process: WarmProcess
        let reader: LineReader
    }

    private let executable: String
    private let system: String
    private let model: String?
    private let effort: String?
    private var current: Session?
    private var spare: Task<Session?, Never>?
    private var uses = 0
    private var busy = false
    private(set) var lastInfo: Info?

    init(executable: String, system: String, model: String?, effort: String?) {
        self.executable = executable
        self.system = system
        self.model = model
        self.effort = effort
    }

    /// Запуск процесса и прогрев коротким запросом.
    private func makeSession() async -> Session? {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--tools", "", "--strict-mcp-config", "--safe-mode", "--disable-slash-commands", "--no-session-persistence",
                         "--system-prompt", [system, AIRequest.textOnly].joined(separator: "\n")]
        if let effort { arguments += ["--effort", effort] }
        if let model { arguments += ["--model", model] }
        let process = WarmProcess(executable: executable, arguments: arguments,
                                  environment: await CLIEnvironment.shared.environment(for: executable), directory: AIWorkspace.directory)
        do { try process.start() } catch { return nil }
        let session = Session(process: process, reader: LineReader(process.lines))
        guard let message = WarmProtocol.claudeUserMessage(Self.primePrompt) else { return session }
        process.write(message)
        var answer = AIAnswer()
        // Прогрев не должен висеть: если ответа нет 20 с, сессию всё равно отдаём (вопрос сам проверит).
        let deadline = Date().addingTimeInterval(20)
        while !answer.finished, Date() < deadline {
            guard let line = await session.reader.next() else { process.terminate(); return nil }
            if let event = ClaudeCLI.parse(line) {
                _ = answer.consume(event)
                if case .failure = event { process.terminate(); return nil }
            }
        }
        return session
    }

    func warmUp() async {
        if current?.process.isRunning != true { current = await makeSession(); uses = 0 }
    }

    func shutdown() {
        current?.process.terminate(); current = nil
        spare?.cancel(); spare = nil
        busy = false
    }

    /// Сессия для вопроса: текущая, готовая запасная или (в крайнем случае) новая.
    private func session() async throws -> (Session, cold: Bool, startup: Double) {
        let started = Date()
        if !busy, uses < Self.recycleAfter, let current, current.process.isRunning { return (current, false, 0) }
        current?.process.terminate()
        current = nil
        uses = 0
        var next: Session?
        var cold = true
        if let spare { next = await spare.value; self.spare = nil; cold = false }
        if next?.process.isRunning != true { next = await makeSession(); cold = true }
        guard let next else { throw WarmFailure("Claude: процесс не запустился") }
        current = next
        return (next, cold, Date().timeIntervalSince(started))
    }

    /// Один вопрос. Если прошлый не дочитан (его отменили), сессия заменяется: чужие события не смешиваются.
    func ask(_ prompt: String, yield: @Sendable (String) -> Void) async throws {
        let usesBefore = uses
        let (session, cold, startup) = try await session()
        lastInfo = Info(cold: cold, usesBefore: usesBefore, startupSeconds: startup)
        guard let message = WarmProtocol.claudeUserMessage(prompt) else { throw WarmFailure("Claude: не удалось собрать запрос") }
        busy = true
        session.process.write(message)
        var answer = AIAnswer()
        while true {
            if Task.isCancelled { shutdown(); throw CancellationError() }
            guard let line = await session.reader.next() else {
                let tail = session.process.stderrTail
                shutdown()
                throw WarmFailure(tail.isEmpty ? "Claude: процесс завершился" : "Claude: \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            guard let event = ClaudeCLI.parse(line) else { continue }
            if let piece = answer.consume(event) { yield(piece) }
            if case .failure(let message) = event { shutdown(); throw AIFailure.from(.claude, output: message) }
            if answer.finished { break }
        }
        busy = false
        uses += 1
        // Скоро обновление: следующую сессию готовим заранее, пока человек читает ответ.
        if uses >= Self.recycleAfter - 1, spare == nil {
            spare = Task { [self] in await self.makeSpare() }
        }
    }

    private func makeSpare() async -> Session? { await makeSession() }
}

// MARK: Codex

/// `codex app-server`: один процесс, JSON-RPC по stdio. На вопрос — новая одноразовая ветка (`thread/start`, `ephemeral`),
/// ход (`turn/start`) с нужным `effort`; куски — `item/agentMessage/delta`. Несколько вопросов одновременно (гибрид) — разные ветки.
actor CodexWarmHost {
    private let executable: String
    private var process: WarmProcess?
    private var reader: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<(threadID: String?, error: String?), Never>] = [:]
    private var turns: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var ready = false

    init(executable: String) { self.executable = executable }

    private func send(_ data: Data) { process?.write(data) }

    private func request(_ make: (Int) -> Data) async -> (threadID: String?, error: String?) {
        let id = nextID; nextID += 1
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            send(make(id))
        }
    }

    func warmUp() async throws {
        if ready, process?.isRunning == true { return }
        shutdown()
        let process = WarmProcess(executable: executable, arguments: ["app-server"],
                                  environment: await CLIEnvironment.shared.environment(for: executable), directory: AIWorkspace.directory)
        try process.start()
        self.process = process
        let lines = process.lines
        reader = Task { [weak self] in
            for await line in lines { await self?.handle(line) }
            await self?.processEnded()
        }
        let result = await request { WarmProtocol.codexInitialize(id: $0) }
        if let error = result.error { shutdown(); throw WarmFailure("Codex: \(error)") }
        send(WarmProtocol.codexInitialized())
        ready = true
    }

    func shutdown() {
        reader?.cancel(); reader = nil
        process?.terminate(); process = nil
        ready = false
        processEnded()
    }

    private func processEnded() {
        let tail = process?.stderrTail ?? ""
        for (_, c) in pending { c.resume(returning: (nil, tail.isEmpty ? "процесс Codex завершился" : tail)) }
        pending = [:]
        for (_, c) in turns { c.finish(throwing: WarmFailure("Codex: процесс завершился")) }
        turns = [:]
    }

    private func handle(_ line: String) {
        switch WarmProtocol.parseCodex(line) {
        case .response(let id, let threadID, let error):
            pending.removeValue(forKey: id)?.resume(returning: (threadID, error))
        case .delta(let thread, let text):
            if let thread { turns[thread]?.yield(text) }
        case .completed(let thread, let failed, let message):
            guard let thread, let c = turns.removeValue(forKey: thread) else { return }
            if failed { c.finish(throwing: AIFailure.from(.codex, output: message ?? "ход не удался")) } else { c.finish() }
        case .error(let thread, let message, let willRetry):
            guard !willRetry, let thread, let c = turns.removeValue(forKey: thread) else { return }
            c.finish(throwing: AIFailure.from(.codex, output: message))
        case .serverRequest(let idJSON):
            // Подсказчику ничего не разрешаем: отказ, чтобы ход не завис.
            if let id = Int(idJSON) { send(WarmProtocol.codexReject(id: id)) }
        case .other:
            break
        }
    }

    func ask(prompt: String, system: String, model: String?, effort: String?) async throws -> AsyncThrowingStream<String, Error> {
        try await warmUp()
        let started = await request { WarmProtocol.codexThreadStart(id: $0, system: system, cwd: AIWorkspace.directory.path, model: model) }
        guard let threadID = started.threadID else { throw WarmFailure("Codex: \(started.error ?? "ветка не создана")") }
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        turns[threadID] = continuation
        let turn = await request { WarmProtocol.codexTurnStart(id: $0, threadID: threadID, text: prompt, effort: effort, model: model) }
        if let error = turn.error {
            turns.removeValue(forKey: threadID)
            throw AIFailure.from(.codex, output: error)
        }
        return stream
    }

    func cancel(threadStream: Void) {}
}

// MARK: - Клиенты

/// Запуск CLI на каждый вопрос (как раньше): запасной путь и сравнение в прогонщике.
struct ColdCopilotAI: CopilotAIClient {
    let provider: AIProvider
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
                    let request = AIRequest(prompt: prompt, system: system, images: files, timeout: BackendCopilotAI.timeout, quick: profile == .fast)
                    for try await piece in CLIEngine(provider).stream(request) { continuation.yield(piece) }
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

    init(provider: AIProvider) { self.provider = provider }

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
        guard let executable = await CLIEnvironment.shared.executable(for: provider) else { return }
        switch provider {
        case .claude: await claudeHost(system: system, profile: CopilotModels.warmEnabled() ? .fast : .main, executable: executable).warmUp()
        case .codex: try? await codexHost(executable: executable).warmUp()
        }
    }

    func shutdown() async {
        lock.lock(); let hosts = Array(claude.values); claude = [:]; let codex = self.codex; self.codex = nil; lock.unlock()
        for h in hosts { await h.shutdown() }
        await codex?.shutdown()
    }

    func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
        let cold = ColdCopilotAI(provider: provider)
        guard images.isEmpty else { return cold.stream(prompt: prompt, system: system, images: images, profile: profile) }
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                var started = false
                do {
                    guard let executable = await CLIEnvironment.shared.executable(for: provider) else { throw AIFailure.notFound(provider) }
                    switch provider {
                    case .claude:
                        let host = claudeHost(system: system, profile: profile, executable: executable)
                        try await host.ask(prompt) { started = true; continuation.yield($0) }
                        if let i = await host.lastInfo {
                            lock.lock(); info = i; lock.unlock()
                            Log.ai.info("Подсказчик: Claude \(i.cold ? "холодный старт" : "тёплая сессия", privacy: .public), вопрос №\(i.usesBefore + 1, privacy: .public)")
                        }
                    case .codex:
                        let stream = try await codexHost(executable: executable).ask(
                            prompt: prompt, system: [system, AIRequest.textOnly].joined(separator: "\n"),
                            model: CopilotModels.model(.codex, profile), effort: CopilotModels.effort(profile))
                        for try await piece in stream { started = true; continuation.yield(piece) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    guard !started, !Task.isCancelled else { continuation.finish(throwing: error); return }
                    // Тёплый путь не сработал, ответа ещё не было: один холодный запуск.
                    Log.ai.info("Подсказчик: тёплый процесс не ответил (\(error.localizedDescription, privacy: .public)), холодный запуск")
                    do {
                        for try await piece in cold.stream(prompt: prompt, system: system, images: [], profile: profile) { continuation.yield(piece) }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

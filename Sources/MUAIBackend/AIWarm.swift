import Darwin
import Foundation
import MUCore

// MARK: - Тёплые процессы (подсказчик на встрече)
//
// `codex exec` и `claude -p` на каждый вопрос запускают программу заново (сотни миллисекунд — секунды до первого куска).
// Здесь процесс живёт, пока подсказчик включён: Claude — одна живая сессия со stream-json на входе, Codex — `codex app-server`
// (JSON-RPC по stdio, новая одноразовая ветка на вопрос). Те же запреты, что у разовых запросов (`ClaudeCLI.safety`,
// `CodexCLI.disabledFeatures`): только текст, без инструментов, файлов и сети (кроме самого ИИ).

/// Живой процесс: строки вывода — потоком, ввод — записью.
package final class WarmProcess: @unchecked Sendable {
    package let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = Data()
    package let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation

    package init(executable: String, arguments: [String], environment: [String: String], directory: URL) {
        (lines, continuation) = AsyncStream<String>.makeStream()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Запись в процесс, который уже завершился, — ошибка записи, а не SIGPIPE (он закрыл бы Mac Utils).
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    package func start() throws {
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

    package func write(_ data: Data) { try? input.fileHandleForWriting.write(contentsOf: data) }

    package var stderrTail: String { lock.lock(); defer { lock.unlock() }; return String(decoding: errorTail, as: UTF8.self) }
    package var isRunning: Bool { process.isRunning }

    /// Закрыть ввод, SIGTERM процессу и его потомкам (codex — node, который запускает свою программу), через 2 с — SIGKILL.
    package func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            let pid = process.processIdentifier
            let tree = ProcessTree.descendants(of: pid) + [pid]
            for p in tree { kill(p, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                for p in tree where ProcessTree.isAlive(p) { kill(p, SIGKILL) }
            }
        }
        continuation.finish()
    }
}

/// Читатель строк процесса: один потребитель, `next()` вызывается по очереди.
package final class LineReader: @unchecked Sendable {
    private var iterator: AsyncStream<String>.Iterator
    package init(_ stream: AsyncStream<String>) { iterator = stream.makeAsyncIterator() }
    package func next() async -> String? { await iterator.next() }
}

package struct WarmFailure: LocalizedError {
    package let errorDescription: String?
    package init(_ text: String) { errorDescription = text }
}

// MARK: Claude

/// Одна живая сессия `claude` на (системный текст, модель, «размышление»). Вопрос никогда не должен попасть на холодный процесс:
/// - новая сессия сразу «прогревается» коротким запросом (соединение и кэш системного текста готовы до первого вопроса);
/// - когда сессия подходит к обновлению (каждые `recycleAfter` вопросов, чтобы история не росла), следующая готовится
///   в фоне и подменяет текущую без ожидания.
package actor ClaudeWarmHost {
    package static let recycleAfter = 6
    /// Короткий служебный запрос, чтобы прогреть сессию (ответ отбрасывается).
    package static let primePrompt = "Ответь одним словом: ок"
    /// Сколько ждать ответа на прогрев.
    nonisolated(unsafe) package static var primeSeconds: TimeInterval = 20

    /// Как прошёл последний вопрос: для замеров (холодный процесс — это и есть хвост).
    package struct Info: Equatable, Sendable {
        package var cold: Bool
        package var usesBefore: Int
        package var startupSeconds: Double
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
    /// Растёт при `shutdown()`: запуск, начатый до него, по окончании закрывает свой процесс, а не отдаёт его.
    private var epoch = 0
    package private(set) var lastInfo: Info?

    package init(executable: String, system: String, model: String?, effort: String?) {
        self.executable = executable
        self.system = system
        self.model = model
        self.effort = effort
    }

    /// Запуск процесса и прогрев коротким запросом. Если за это время был `shutdown()` или задачу отменили — процесс закрывается.
    private func makeSession() async -> Session? {
        let startedEpoch = epoch
        let arguments = ClaudeCLI.sessionArguments(system: system, model: model, effort: effort)
        let environment = await CLIEnvironment.shared.environment(for: executable)
        guard epoch == startedEpoch, !Task.isCancelled else { return nil }
        let process = WarmProcess(executable: executable, arguments: arguments, environment: environment, directory: AIWorkspace.directory)
        do { try process.start() } catch { return nil }
        let session = Session(process: process, reader: LineReader(process.lines))
        guard let message = WarmProtocol.claudeUserMessage(Self.primePrompt) else { return session }
        process.write(message)
        var answer = AIAnswer()
        // Прогрев не висит: молчит `primeSeconds` — процесс закрывается по таймеру (чтение тогда кончается), вопрос пойдёт
        // на запасную или холодным запуском. Раньше срок проверялся только после очередной строки.
        let seconds = Self.primeSeconds
        let watchdog = Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); if !Task.isCancelled { process.terminate() } }
        defer { watchdog.cancel() }
        while !answer.finished {
            guard let line = await session.reader.next() else { process.terminate(); return nil }
            if let event = ClaudeCLI.parse(line) {
                _ = answer.consume(event)
                if case .failure = event { process.terminate(); return nil }
            }
        }
        guard epoch == startedEpoch, !Task.isCancelled else { process.terminate(); return nil }
        return session
    }

    package func warmUp() async {
        guard current?.process.isRunning != true else { return }
        guard let session = await makeSession() else { return }
        // Пока прогревали, вопрос мог сам завести сессию: лишнюю закрываем, а не теряем.
        if current?.process.isRunning == true { session.process.terminate(); return }
        current = session
        uses = 0
    }

    package func shutdown() {
        epoch += 1
        current?.process.terminate(); current = nil
        // Отмена задачи процесс не закрывает: запасную закрываем сами, когда (если) она запустится.
        if let spare { Task { await spare.value?.process.terminate() } }
        spare = nil
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
        if let spare { self.spare = nil; next = await spare.value; cold = false }
        if next?.process.isRunning != true { next = await makeSession(); cold = true }
        guard let next else { throw WarmFailure("Claude: процесс не запустился") }
        // Пока ждали, мог прийти `shutdown()` или другой вопрос завёл свою сессию: эту не теряем.
        if Task.isCancelled { next.process.terminate(); throw CancellationError() }
        current?.process.terminate()
        current = next
        return (next, cold, Date().timeIntervalSince(started))
    }

    /// Один вопрос. Если прошлый не дочитан (его отменили), сессия заменяется: чужие события не смешиваются.
    package func ask(_ prompt: String, yield: @Sendable (String) -> Void) async throws {
        let usesBefore = uses
        let (session, cold, startup) = try await session()
        lastInfo = Info(cold: cold, usesBefore: usesBefore, startupSeconds: startup)
        guard let message = WarmProtocol.claudeUserMessage(prompt) else { throw WarmFailure("Claude: не удалось собрать запрос") }
        busy = true
        session.process.write(message)
        var answer = AIAnswer()
        while true {
            if Task.isCancelled { drop(session); throw CancellationError() }
            guard let line = await session.reader.next() else {
                // Отмена вопроса тоже кончает чтение (nil): это не сбой процесса.
                if Task.isCancelled { drop(session); throw CancellationError() }
                let tail = session.process.stderrTail
                drop(session)
                throw WarmFailure(tail.isEmpty ? "Claude: процесс завершился" : "Claude: \(tail.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            guard let event = ClaudeCLI.parse(line) else { continue }
            if let piece = answer.consume(event) { yield(piece) }
            if case .failure(let message) = event { drop(session); throw AIFailure.from(.claude, output: message) }
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

    /// Отменённый (или сорвавшийся) вопрос: закрывается только эта сессия — её поток не дочитан, события смешались бы.
    /// Хост, эпоха и запасная остаются; запасная сразу готовится, чтобы следующий вопрос («человек договорил») шёл в тёплую.
    private func drop(_ session: Session) {
        session.process.terminate()
        if current?.process === session.process { current = nil }
        busy = false
        uses = 0
        if spare == nil { spare = Task { [self] in await self.makeSpare() } }
    }
}

// MARK: Codex

/// `codex app-server`: один процесс, JSON-RPC по stdio. На вопрос — новая одноразовая ветка (`thread/start`, `ephemeral`),
/// ход (`turn/start`) с нужным `effort`; куски — `item/agentMessage/delta`. Несколько вопросов одновременно (гибрид) — разные ветки.
package actor CodexWarmHost {
    private let executable: String
    private var process: WarmProcess?
    private var reader: Task<Void, Never>?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<(threadID: String?, error: String?), Never>] = [:]
    private var turns: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var ready = false
    /// Идущий запуск: второй вопрос (гибрид) ждёт его, а не убивает и не запускает свой.
    private var starting: Task<Void, Error>?
    private var epoch = 0

    package init(executable: String) { self.executable = executable }

    /// Сколько ждать `codex mcp list --json` (тесты укорачивают).
    nonisolated(unsafe) package static var mcpListSeconds: TimeInterval = 15

    private func send(_ data: Data) { process?.write(data) }

    private func request(_ make: (Int) -> Data) async -> (threadID: String?, error: String?) {
        // Процесса уже нет (остановлен инструментом другой половины гибрида, упал): ответа не будет — ошибка сразу,
        // вопрос уходит холодным запуском, а не ждёт 45-секундного сторожа.
        guard let process, process.isRunning else { return (nil, "процесс Codex не запущен") }
        let id = nextID; nextID += 1
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            send(make(id))
        }
    }

    package func warmUp() async throws {
        if ready, process?.isRunning == true { return }
        if let starting { return try await starting.value }
        let task = Task { try await self.launch() }
        starting = task
        defer { if epochMatches(task) { starting = nil } }
        try await task.value
    }

    private func epochMatches(_ task: Task<Void, Error>) -> Bool { starting == task }

    private func launch() async throws {
        stopProcess()
        let startedEpoch = epoch
        let environment = await CLIEnvironment.shared.environment(for: executable)
        // У app-server нет `--ignore-user-config`: свой адрес сервиса в config.toml не переопределить — тогда только `exec`.
        let config = CodexCLI.userConfigURL(environment: environment)
        let redirects = (try? String(contentsOf: config, encoding: .utf8)).map(CodexCLI.configRedirects) ?? []
        guard redirects.isEmpty else {
            throw WarmFailure("Codex: в config.toml свой адрес сервиса (\(redirects.joined(separator: ", "))) — тёплый процесс не используется, вопрос пойдёт обычным запуском")
        }
        // MCP-серверы из config.toml выключаются по именам. Список не получен (код ≠ 0, таймаут, не JSON) — тёплого нет.
        let list = CLICommand(executable: URL(fileURLWithPath: executable), arguments: ["mcp", "list", "--json"],
                              environment: environment, directory: AIWorkspace.directory)
        let output = try? await CLIProcess.run(list, timeout: Self.mcpListSeconds)
        let servers = output.flatMap { $0.status == 0 ? CodexCLI.mcpServerNames(listJSON: $0.stdout) : nil }
        guard epoch == startedEpoch else { throw CancellationError() }
        guard let arguments = CodexCLI.appServerArguments(mcpServers: servers) else {
            throw WarmFailure(servers == nil ? "Codex: не удалось получить список MCP-серверов — вопрос пойдёт обычным запуском"
                                             : "Codex: MCP-сервер с таким именем не выключить в тёплом процессе — вопрос пойдёт обычным запуском")
        }
        let process = WarmProcess(executable: executable, arguments: arguments, environment: environment,
                                  directory: AIWorkspace.directory)
        try process.start()
        self.process = process
        let lines = process.lines
        reader = Task { [weak self] in
            for await line in lines { await self?.handle(line) }
            await self?.processEnded()
        }
        let result = await request { WarmProtocol.codexInitialize(id: $0) }
        guard epoch == startedEpoch else { throw CancellationError() }
        if let error = result.error { stopProcess(); throw WarmFailure("Codex: \(error)") }
        send(WarmProtocol.codexInitialized())
        ready = true
    }

    package func shutdown() {
        epoch += 1
        starting = nil
        stopProcess()
    }

    private func stopProcess() {
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
        case .itemStarted(let thread, let kind):
            // Модель взялась за инструмент (команда, файл, MCP, веб-поиск…): процесс со всеми потомками останавливается
            // сразу, до того как результат уйдёт модели. Следующий вопрос запустит его заново.
            guard CodexCLI.isAppServerTool(kind) else { return }
            Log.ai.error("codex: модель взялась за инструмент \(kind, privacy: .public), остановлено")
            if let thread, let c = turns.removeValue(forKey: thread) { c.finish(throwing: AIFailure.toolUse(.codex, kind: kind)) }
            stopProcess()
        case .serverRequest(let idJSON):
            // Подсказчику ничего не разрешаем: отказ, чтобы ход не завис.
            // id может быть и строкой: отвечаем тем же значением, иначе ход ждал бы ответа до таймаута.
            let id = (try? JSONSerialization.jsonObject(with: Data(idJSON.utf8), options: [.fragmentsAllowed])) ?? idJSON
            send(WarmProtocol.codexReject(id: id))
        case .other:
            break
        }
    }

    package func ask(prompt: String, system: String, model: String?, effort: String?) async throws -> AsyncThrowingStream<String, Error> {
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

}

/// Протокол тёплых процессов: строки JSON, которые пишутся и читаются. Чистые функции без процессов.
package enum WarmProtocol {
    // MARK: Claude (`claude -p --input-format stream-json --output-format stream-json`)

    /// Одно сообщение пользователя в живую сессию (строка с переводом строки).
    package static func claudeUserMessage(_ text: String) -> Data? {
        let object: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": text]]]]
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        data.append(0x0A)
        return data
    }

    // MARK: Codex (`codex app-server`, JSON-RPC по stdio, строка на сообщение)

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    package static func codexInitialize(id: Int) -> Data {
        line(["id": id, "method": "initialize", "params": ["clientInfo": ["name": "mac-utils-copilot", "title": "Mac Utils", "version": "1"]]])
    }

    package static func codexInitialized() -> Data { line(["method": "initialized"]) }

    /// Новая одноразовая ветка на каждый вопрос: системный текст свой, история не копится.
    package static func codexThreadStart(id: Int, system: String, cwd: String, model: String?) -> Data {
        var params: [String: Any] = ["ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never", "cwd": cwd,
                                     "developerInstructions": system]
        if let model, !model.isEmpty { params["model"] = model }
        return line(["id": id, "method": "thread/start", "params": params])
    }

    package static func codexTurnStart(id: Int, threadID: String, text: String, effort: String?, model: String?) -> Data {
        var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text, "text_elements": [Any]()]]]
        if let effort, !effort.isEmpty { params["effort"] = effort }
        if let model, !model.isEmpty { params["model"] = model }
        // Сводка рассуждений подсказчику не нужна (не показывается): «none» по схеме app-server 0.170.
        params["summary"] = "none"
        return line(["id": id, "method": "turn/start", "params": params])
    }

    package static func codexReject(id: Any) -> Data {
        line(["id": id, "error": ["code": -32601, "message": "не поддерживается подсказчиком"]])
    }

    package enum CodexMessage: Equatable {
        case response(id: Int, threadID: String?, error: String?)
        case delta(threadID: String?, text: String)
        case completed(threadID: String?, failed: Bool, message: String?)
        /// Начался элемент хода (`item/started`): тип — `ThreadItem.type` (agentMessage, commandExecution, mcpToolCall…).
        case itemStarted(threadID: String?, type: String)
        case error(threadID: String?, message: String, willRetry: Bool)
        /// Запрос сервера к клиенту (например, разрешение): отвечаем отказом, чтобы ход не завис.
        case serverRequest(idJSON: String)
        case other
    }

    package static func parseCodex(_ line: String) -> CodexMessage {
        guard let data = line.data(using: .utf8), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .other }
        let method = json["method"] as? String
        if let method {
            let params = json["params"] as? [String: Any] ?? [:]
            if json["id"] != nil {
                let idData = (try? JSONSerialization.data(withJSONObject: json["id"]!, options: [.fragmentsAllowed])) ?? Data("0".utf8)
                return .serverRequest(idJSON: String(decoding: idData, as: UTF8.self))
            }
            switch method {
            case "item/agentMessage/delta":
                return .delta(threadID: params["threadId"] as? String, text: params["delta"] as? String ?? "")
            case "item/started":
                let item = params["item"] as? [String: Any]
                return .itemStarted(threadID: params["threadId"] as? String, type: item?["type"] as? String ?? "unknown")
            case "turn/completed":
                let turn = params["turn"] as? [String: Any]
                let status = turn?["status"] as? String
                let message = (turn?["error"] as? [String: Any])?["message"] as? String
                return .completed(threadID: params["threadId"] as? String, failed: status == "failed" || status == "interrupted", message: message)
            case "error":
                let error = params["error"] as? [String: Any]
                return .error(threadID: params["threadId"] as? String, message: error?["message"] as? String ?? "ошибка Codex", willRetry: params["willRetry"] as? Bool ?? false)
            default:
                return .other
            }
        }
        guard let id = json["id"] as? Int else { return .other }
        if let error = json["error"] as? [String: Any] { return .response(id: id, threadID: nil, error: error["message"] as? String ?? "ошибка") }
        let thread = (json["result"] as? [String: Any])?["thread"] as? [String: Any]
        return .response(id: id, threadID: thread?["id"] as? String, error: nil)
    }
}

// MARK: - Каталог моделей Codex

/// Быстрая модель Codex для подсказчика: из `codex debug models` (каталог этой версии codex, без запросов к модели),
/// один раз за запуск. Без неё тёплый `app-server` брал бы модель из config.toml пользователя (у него нет
/// `--ignore-user-config`), а холодный `exec` — модель codex по умолчанию: тёплый путь оказывался медленнее холодного.
package actor CodexModelCatalog {
    package static let shared = CodexModelCatalog()
    private var fast: [String: String?] = [:]

    package func fastModel(executable: String) async -> String? {
        if let cached = fast[executable] { return cached }
        let command = CLICommand(executable: URL(fileURLWithPath: executable), arguments: ["debug", "models"],
                                 environment: await CLIEnvironment.shared.environment(for: executable), directory: AIWorkspace.directory)
        let output = try? await CLIProcess.run(command, timeout: 10)
        let model = output.flatMap { $0.status == 0 ? CodexCLI.fastModel(listed: CodexCLI.listedModels(catalogJSON: $0.stdout)) : nil }
        fast[executable] = .some(model)
        Log.ai.info("codex: быстрая модель подсказчика — \(model ?? "как в codex", privacy: .public)")
        return model
    }
}

import Combine
import Foundation
import MUCore

// MARK: - Программа как бэкенд

/// codex или claude: найти программу, запустить с аргументами, разобрать поток. Таймаут и отмена убивают процесс.
package struct CLIEngine: AIEngine {
    package let provider: AIProvider
    /// Своя программа вместо найденной (тесты: подставной codex на /bin/sh).
    private let executable: String?

    package init(_ provider: AIProvider, executable: String? = nil) {
        self.provider = provider
        self.executable = executable
    }

    package func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, alive: {})
    }

    package func stream(_ request: AIRequest, alive: @escaping @Sendable () -> Void) -> AsyncThrowingStream<String, Error> {
        let provider = provider, executable = executable
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(provider, executable, request, alive: alive) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(_ provider: AIProvider, _ override: String?, _ request: AIRequest,
                            alive: @Sendable () -> Void, yield: (String) -> Void) async throws {
        var found = override
        if found == nil { found = await CLIEnvironment.shared.executable(for: provider) }
        guard let executable = found else { throw AIFailure.notFound(provider) }
        let environment = await CLIEnvironment.shared.environment(for: executable)
        let workspace = AIWorkspace.directory
        let arguments: [String]
        let input: Data
        switch provider {
        case .codex:
            arguments = CodexCLI.arguments(request: request, workspace: workspace.path)
            input = CodexCLI.input(request: request)
        case .claude:
            arguments = ClaudeCLI.arguments(request: request)
            input = try ClaudeCLI.input(request: request)
        }
        let command = CLICommand(executable: URL(fileURLWithPath: executable), arguments: arguments, stdin: input,
                                 environment: environment, directory: workspace)
        let parse: (String) -> AIEvent? = provider == .codex ? CodexCLI.parse : ClaudeCLI.parse
        var answer = AIAnswer(lastMessageOnly: provider == .codex)
        let started = Date()
        let process = CLIProcess.open(command, timeout: request.timeout)
        // Досрочный выход (ошибка хода, инструмент) — процесс со всеми потомками останавливается сразу.
        defer { process.stop() }
        do {
            for try await line in process.lines {
                guard let event = parse(line) else { continue }
                switch event {
                case .progress: alive()
                // Выход из цикла останавливает чтение, и процесс убивается вместе с потомками — до того,
                // как вывод команды уйдёт модели.
                case .tool(let kind):
                    Log.ai.error("\(provider.rawValue, privacy: .public): модель взялась за инструмент \(kind, privacy: .public), остановлено")
                    throw AIFailure.toolUse(provider, kind: kind)
                default: break
                }
                if let piece = answer.consume(event) { yield(piece) }
                if case .failure = event { break }
            }
        } catch let exit as CLIExit {
            switch exit.reason {
            case .timedOut: throw AIFailure.timeout(provider, seconds: request.timeout)
            case .cancelled: throw CancellationError()
            case .launchFailed: throw AIFailure.notFound(provider)
            case .exited:
                if answer.failure == nil {
                    throw AIFailure.from(provider, output: [exit.stderr, answer.lastNotice ?? ""].joined(separator: "\n"))
                }
            }
        }
        try Task.checkCancellation()
        if let failure = answer.failure { throw AIFailure.from(provider, output: failure) }
        if let piece = answer.flush() { yield(piece) }
        guard !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw answer.lastNotice.map { AIFailure.from(provider, output: $0) } ?? AIFailure.empty(provider)
        }
        Log.ai.info("\(provider.rawValue, privacy: .public): ответ за \(Int(Date().timeIntervalSince(started))) с")
    }

    /// Подключено ли: программа найдена и вход выполнен (`codex login status` / `claude auth status --json`).
    /// Вывод не пишется в журнал: в нём адрес почты.
    package static func check(_ provider: AIProvider) async -> AIConnection {
        guard let executable = await CLIEnvironment.shared.executable(for: provider) else { return .notFound }
        let arguments = provider == .codex ? ["login", "status"] : ["auth", "status", "--json"]
        let command = CLICommand(executable: URL(fileURLWithPath: executable), arguments: arguments,
                                 environment: await CLIEnvironment.shared.environment(for: executable),
                                 directory: AIWorkspace.directory)
        guard let output = try? await CLIProcess.run(command, timeout: 20) else {
            return .problem("Не удалось проверить \(provider.title)")
        }
        let text = output.stdout + "\n" + output.stderr
        let loggedIn = provider == .codex ? CodexCLI.isLoggedIn(status: output.status, output: text)
            : ClaudeCLI.isLoggedIn(status: output.status, output: text)
        return loggedIn ? .connected : .notLoggedIn
    }
}

// MARK: - Выбор и запасной

/// Порядок сервисов и переход ко второму.
package struct AIRouter: Sendable {
    package var engine: @Sendable (AIProvider) -> any AIEngine

    package init(engine: @escaping @Sendable (AIProvider) -> any AIEngine) { self.engine = engine }

    package static let live = AIRouter { CLIEngine($0) }

    /// Выбранный, а с запасным — и второй.
    package static func order(selected: AIProvider, fallback: Bool) -> [AIProvider] {
        fallback ? [selected, selected.other] : [selected]
    }

    /// Ответ первого сервиса по порядку. Ко следующему переходим, если предыдущий ничего не ответил:
    /// ошибка (не найден, не вошли, сбой) или — при `firstPieceWithin` — за столько секунд ни куска, ни признака
    /// жизни (`alive`: codex прислал `item.*`, значит модель работает, просто отдаст ответ целиком в конце).
    /// Если ответ уже начался, ошибка отдаётся как есть: два ответа не смешиваются.
    /// Если не ответил ни один — ошибки всех в одном тексте (`AIFailure.combined`).
    package func stream(_ request: AIRequest, order: [AIProvider],
                        firstPieceWithin: TimeInterval?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var failures: [AIFailure] = []
                for (index, provider) in order.enumerated() {
                    let isLast = index == order.count - 1
                    let started = StartedFlag()
                    do {
                        try await Self.attempt(engine(provider), request, deadline: isLast ? nil : firstPieceWithin,
                                               started: started) { continuation.yield($0) }
                        continuation.finish()
                        return
                    } catch {
                        if error is CancellationError || Task.isCancelled {
                            continuation.finish(throwing: CancellationError())
                            return
                        }
                        if started.value {
                            continuation.finish(throwing: error)
                            return
                        }
                        failures.append(error as? AIFailure
                            ?? AIFailure(.failed, provider: provider, message: "\(provider.title): \(error.localizedDescription)"))
                        if isLast { break }
                        Log.ai.info("\(provider.rawValue, privacy: .public) не ответил, пробую \(order[index + 1].rawValue, privacy: .public)")
                    }
                }
                continuation.finish(throwing: AIFailure.combined(failures))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Один сервис; если до `deadline` не пришло ни куска — ошибка `timeout`, чтение прерывается (процесс убивается).
    private static func attempt(_ engine: any AIEngine, _ request: AIRequest, deadline: TimeInterval?,
                                started: StartedFlag, yield: @escaping @Sendable (String) -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await piece in engine.stream(request, alive: { started.markAlive() }) {
                    started.set()
                    yield(piece)
                }
                try Task.checkCancellation()
            }
            if let deadline {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(max(0, deadline) * 1_000_000_000))
                    if !started.alive { throw AIFailure.timeout(engine.provider, seconds: deadline) }
                    try await Task.sleep(nanoseconds: .max / 2) // ответ идёт — ждём, пока чтение не закончится
                }
            }
            // Первый закончившийся решает: чтение — успех (таймер снимается), таймер — ошибка.
            try await group.next()
            group.cancelAll()
        }
    }
}

/// «Ответ уже начался» (`value`: пришёл кусок) и «модель работает» (`alive`: кусок или признак жизни) —
/// общие для задачи чтения и таймера.
package final class StartedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var working = false

    package init() {}
    package var value: Bool { lock.withLock { started } }
    package var alive: Bool { lock.withLock { started || working } }
    package func set() { lock.withLock { started = true } }
    package func markAlive() { lock.withLock { working = true } }
}

// MARK: - Для функций Mac Utils

/// Весь ИИ Mac Utils: выбранный сервис из настроек, запасной, разбор JSON.
package enum AI {
    /// Подмена для тестов (свои движки вместо codex/claude).
    nonisolated(unsafe) package static var router = AIRouter.live

    package static var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.ai) }
    /// Функция включена и в настройках ИИ, и отдельным переключателем.
    package static func isOn(_ key: String) -> Bool { enabled && UserDefaults.standard.bool(forKey: key) }

    package static var provider: AIProvider { AIProvider(stored: UserDefaults.standard.string(forKey: Pref.aiProvider)) }
    package static var fallbackEnabled: Bool { UserDefaults.standard.bool(forKey: Pref.aiFallback) }
    /// Сколько ждать первого куска ответа, прежде чем спросить второй сервис.
    package static var fallbackSeconds: TimeInterval {
        let value = UserDefaults.standard.double(forKey: Pref.aiFallbackSeconds)
        return value > 0 ? value : 20
    }

    /// Куски ответа. `long` — долгая задача (отчёт о встрече): второй сервис только при ошибке первого, не по времени.
    package static func stream(_ request: AIRequest, long: Bool = false) -> AsyncThrowingStream<String, Error> {
        let order = AIRouter.order(selected: provider, fallback: fallbackEnabled)
        return router.stream(request, order: order, firstPieceWithin: long ? nil : fallbackSeconds)
    }

    package static func generate(_ prompt: String, system: String? = nil, images: [URL] = [], timeout: TimeInterval = 120,
                                 quick: Bool = false, long: Bool = false) async throws -> String {
        let request = AIRequest(prompt: prompt, system: system, images: images, timeout: timeout, quick: quick)
        var text = ""
        for try await piece in stream(request, long: long) { text += piece }
        return text
    }

    /// Ответ-JSON, разобранный в словарь.
    package static func generateJSON(_ prompt: String, system: String? = nil, quick: Bool = false) async throws -> [String: Any] {
        let system = [system, AIRequest.jsonOnly].compactMap { $0 }.joined(separator: "\n")
        let text = try await generate(prompt, system: system, quick: quick)
        guard let object = AIParsing.jsonObject(in: text) else {
            throw AIFailure(.failed, provider: nil, message: "ИИ ответил не JSON")
        }
        return object
    }

    /// Можно ли сейчас спрашивать (выбранный или запасной подключён). Перед фоновой работой, которая без ИИ не нужна.
    package static func isReady() async -> Bool {
        let order = AIRouter.order(selected: provider, fallback: fallbackEnabled)
        for provider in order where await AIStatus.shared.connection(provider, maxAge: 600) == .connected { return true }
        return false
    }
}

// MARK: - Состояние для интерфейса

/// Подключение каждого сервиса: для страницы «ИИ» и быстрой панели.
@MainActor
package final class AIStatus: ObservableObject {
    package static let shared = AIStatus()

    @Published package private(set) var states: [AIProvider: AIConnection] = [:]
    private var checkedAt: [AIProvider: Date] = [:]
    private var running: [AIProvider: Task<AIConnection, Never>] = [:]

    package init() {}

    package func state(_ provider: AIProvider) -> AIConnection { states[provider] ?? .unknown }

    /// Проверить оба заново (и поискать программы снова — их могли только что поставить).
    package func refresh() {
        Task {
            await CLIEnvironment.shared.reset()
            for provider in AIProvider.allCases { _ = await check(provider) }
        }
    }

    /// Без повторного поиска программ: проверить только то, что старше `maxAge` секунд (быстрая панель).
    package func refreshIfStale(maxAge: TimeInterval = 120) {
        Task { for provider in AIProvider.allCases { _ = await connection(provider, maxAge: maxAge) } }
    }

    /// Состояние не старше `maxAge` секунд; иначе — проверка.
    package func connection(_ provider: AIProvider, maxAge: TimeInterval) async -> AIConnection {
        if let at = checkedAt[provider], Date().timeIntervalSince(at) < maxAge, let state = states[provider], state != .checking {
            return state
        }
        return await check(provider)
    }

    private func check(_ provider: AIProvider) async -> AIConnection {
        if let running = running[provider] { return await running.value }
        states[provider] = .checking
        let task = Task.detached { await CLIEngine.check(provider) }
        running[provider] = task
        let result = await task.value
        running[provider] = nil
        states[provider] = result
        checkedAt[provider] = Date()
        return result
    }
}

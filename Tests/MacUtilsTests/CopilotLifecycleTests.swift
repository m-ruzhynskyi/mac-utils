@testable import MacUtils
import XCTest
@testable import MUCopilot
@testable import MUAIBackend

/// Ревью подсказчика: тёплые процессы не переживают выключение, прогрев и остановка идут по очереди.
/// Вместо claude и codex — подставные скрипты /bin/sh (метка в имени файла видна в ps); настоящие программы не запускаются.
final class CopilotLifecycleTests: XCTestCase {
    private var folder: URL!
    private var marker = ""

    override func setUpWithError() throws {
        marker = "mu-copilot-fake-\(UUID().uuidString.prefix(8))"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(marker, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        killAll()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Claude

    /// Подставной `claude -p --input-format stream-json`: на каждую строку ввода — итог; первый ответ (прогрев) — через `delay` с.
    private func fakeClaude(delay: Double) throws -> String {
        let result = #"{"type":"result","subtype":"success","is_error":false,"result":"ок"}"#
        return try script("claude", """
        first=1
        while IFS= read -r line; do
          if [ "$first" = 1 ]; then sleep \(delay); first=0; fi
          echo '\(result)'
        done
        """)
    }

    func testClaudeShutdownDuringWarmUpLeavesNoProcess() async throws {
        let host = ClaudeWarmHost(executable: try fakeClaude(delay: 1.5), system: "s", model: nil, effort: nil)
        let warm = Task { await host.warmUp() }
        try await waitFor { self.count() >= 1 }
        await host.shutdown()
        await warm.value
        try await waitFor { self.count() == 0 }
        XCTAssertEqual(count(), 0, "процесс, запущенный прогревом до выключения, должен закрыться")
    }

    func testClaudeSpareSessionIsClosedOnShutdown() async throws {
        let host = ClaudeWarmHost(executable: try fakeClaude(delay: 0), system: "s", model: nil, effort: nil)
        await host.warmUp()
        // Пятый вопрос заводит запасную сессию в фоне.
        for _ in 0..<(ClaudeWarmHost.recycleAfter - 1) { try await host.ask("вопрос") { _ in } }
        try await waitFor { self.count() >= 2 }
        await host.shutdown()
        try await waitFor { self.count() == 0 }
        XCTAssertEqual(count(), 0, "запасная сессия не должна пережить выключение")
    }

    func testClaudeAnswersFromWarmSession() async throws {
        let host = ClaudeWarmHost(executable: try fakeClaude(delay: 0), system: "s", model: nil, effort: nil)
        await host.warmUp()
        var text = ""
        try await host.ask("вопрос") { text += $0 }
        XCTAssertEqual(text, "ок")
        let info = await host.lastInfo
        XCTAssertEqual(info?.cold, false)
        XCTAssertEqual(count(), 1)
        await host.shutdown()
    }

    // MARK: Codex

    /// Подставной `codex app-server`: отвечает на initialize. `pause` — задержка перед ответом.
    private func fakeCodex(pause: Double) throws -> String {
        try script("codex", """
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          if [ -n "$id" ]; then sleep \(pause); printf '{"id":%s,"result":{}}\\n' "$id"; fi
        done
        """)
    }

    func testCodexConcurrentWarmUpsStartOneServer() async throws {
        let host = CodexWarmHost(executable: try fakeCodex(pause: 0.5))
        async let a: Void = host.warmUp()
        async let b: Void = host.warmUp()
        _ = try await (a, b)
        XCTAssertEqual(count(), 1, "гибрид (два вопроса сразу) не должен убивать и перезапускать сервер")
        await host.shutdown()
        try await waitFor { self.count() == 0 }
        XCTAssertEqual(count(), 0)
    }

    func testCodexShutdownDuringStartLeavesNoProcess() async throws {
        let host = CodexWarmHost(executable: try fakeCodex(pause: 1.5))
        let warm = Task { try? await host.warmUp() }
        try await waitFor { self.count() >= 1 }
        await host.shutdown()
        await warm.value
        try await waitFor { self.count() == 0 }
        XCTAssertEqual(count(), 0)
    }

    // MARK: Процесс

    func testWritingToExitedProcessDoesNotRaiseSIGPIPE() async throws {
        let process = WarmProcess(executable: "/usr/bin/true", arguments: [], environment: ProcessInfo.processInfo.environment,
                                  directory: folder)
        try process.start()
        process.process.waitUntilExit()
        try await Task.sleep(nanoseconds: 100_000_000)
        process.write(Data(String(repeating: "x", count: 200_000).utf8)) // без F_SETNOSIGPIPE тест упал бы по сигналу
        process.terminate()
    }

    // MARK: Сессия

    /// Прогрев долгий: выключение отменяет его, и остановка идёт строго после него.
    @MainActor
    func testQuickOnOffShutsDownAfterWarmUp() async throws {
        let ai = OrderedAI()
        let session = CopilotSession(ai: ai, listener: SilentListener(), settings: { CopilotSettings() }, log: { _ in })
        session.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        session.stop()
        try await waitFor { ai.events.contains("shutdown") }
        XCTAssertEqual(ai.events, ["warm-start", "warm-cancelled", "shutdown"])
        // Включили и сразу выключили ещё раз до того, как прогрев начался: прогрева после остановки нет.
        session.start()
        session.stop()
        try await waitFor { ai.events.filter { $0 == "shutdown" }.count == 2 }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(ai.events.last, "shutdown")
    }

    // MARK: Помощники

    private func script(_ name: String, _ body: String) throws -> String {
        let url = folder.appendingPathComponent("\(name)-\(marker)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Сколько процессов подставных программ живо (sh со скриптом; его sleep — потомки).
    private func count() -> Int { pids().count }

    private func pids() -> [pid_t] {
        let pipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        ps.standardOutput = pipe
        try? ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.contains("/bin/sh") && $0.contains(marker) }
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }
    }

    private func killAll() { for pid in pids() { kill(pid, SIGKILL) } }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }
}

private final class OrderedAI: CopilotAIClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    private func note(_ e: String) { lock.withLock { _events.append(e) } }

    func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func warmUp(system: String) async {
        note("warm-start")
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        note(Task.isCancelled ? "warm-cancelled" : "warm-done")
    }

    func shutdown() async { note("shutdown") }
}

@MainActor
private final class SilentListener: CopilotListening {
    var onFailure: (@MainActor (String) -> Void)?
    func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {}
    func stop() {}
}

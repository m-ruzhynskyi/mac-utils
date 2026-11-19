import XCTest
@testable import MacUtils
@testable import MUCopilot
@testable import MUAIBackend

/// COPILOT-38 (ревью #221, раздел 3): тёплый Codex не берёт config.toml пользователя, сбой `mcp list` → холодный путь,
/// отменённый ответ не трогает новый, отмена у тёплого Claude закрывает только свою сессию.
/// Вместо codex и claude — скрипты /bin/sh; config.toml — во временном `CODEX_HOME`, настоящий `~/.codex` не читается.
final class CopilotReviewFixesTests: XCTestCase {
    private var folder: URL!
    private var marker = ""
    private var savedCodexHome: String?

    override func setUpWithError() throws {
        marker = "mu-copilot-fix-\(UUID().uuidString.prefix(8))"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(marker, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", folder.path, 1)
    }

    override func tearDownWithError() throws {
        for pid in pids() { kill(pid, SIGKILL) }
        if let savedCodexHome { setenv("CODEX_HOME", savedCodexHome, 1) } else { unsetenv("CODEX_HOME") }
        CodexWarmHost.mcpListSeconds = 15
        ClaudeWarmHost.primeSeconds = 20
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: п.1 — config.toml пользователя

    func testAppServerOverridesUserConfig() throws {
        let args = try XCTUnwrap(CodexCLI.appServerArguments(mcpServers: []))
        let overrides = zip(args, args.dropFirst()).filter { $0.0 == "-c" }.map(\.1)
        for key in [#"model_provider="openai""#, "notify=[]", #"web_search="disabled""#, "tools.web_search=false",
                    #"otel.exporter="none""#, "otel.log_user_prompt=false", "analytics.enabled=false", #"history.persistence="none""#,
                    #"sandbox_mode="read-only""#, #"approval_policy="never""#] {
            XCTAssertTrue(overrides.contains(key), key)
        }
    }

    func testConfigRedirectsAreFoundByKeyNameOnly() {
        XCTAssertEqual(CodexCLI.configRedirects(toml: ""), [])
        XCTAssertEqual(CodexCLI.configRedirects(toml: "model = \"gpt\"\n[mcp_servers.gh]\ncommand = \"x\"\n# openai_base_url = \"x\""), [])
        XCTAssertEqual(CodexCLI.configRedirects(toml: "openai_base_url = \"https://proxy\""), ["openai_base_url"])
        XCTAssertEqual(CodexCLI.configRedirects(toml: "  chatgpt_base_url=\"x\" # мой"), ["chatgpt_base_url"])
        XCTAssertEqual(CodexCLI.configRedirects(toml: "[model_providers.ollama]\nbase_url = \"http://localhost:11434/v1\""), ["model_providers"])
        XCTAssertEqual(CodexCLI.configRedirects(toml: "model_providers.my.base_url = \"x\""), ["model_providers"])
        // Ключ с тем же именем внутри чужой таблицы — не адрес сервиса.
        XCTAssertEqual(CodexCLI.configRedirects(toml: "[mcp_servers.x.env]\nopenai_base_url = \"y\""), [])
    }

    func testUserConfigLocation() {
        XCTAssertEqual(CodexCLI.userConfigURL(environment: ["CODEX_HOME": "/tmp/ch", "HOME": "/Users/x"]).path, "/tmp/ch/config.toml")
        XCTAssertEqual(CodexCLI.userConfigURL(environment: ["HOME": "/Users/x"]).path, "/Users/x/.codex/config.toml")
    }

    func testRedirectInUserConfigMeansNoWarmServer() async throws {
        try "openai_base_url = \"https://proxy.example\"\n".write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let started = folder.appendingPathComponent("app-server-started").path
        let host = CodexWarmHost(executable: try fakeCodex(mcp: "echo '[]'", started: started))
        do { try await host.warmUp(); XCTFail("свой адрес сервиса — тёплого Codex нет") } catch {
            XCTAssertTrue(error.localizedDescription.contains("openai_base_url"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: started), "app-server не запускался")
    }

    // MARK: п.2 — сбой `codex mcp list`

    func testMCPListFailureMeansNoWarmServer() async throws {
        XCTAssertNil(CodexCLI.appServerArguments(mcpServers: nil))
        XCTAssertNil(CodexCLI.mcpServerNames(listJSON: "Error: config"))
        XCTAssertNil(CodexCLI.mcpServerNames(listJSON: #"{"name":"x"}"#))
        XCTAssertEqual(CodexCLI.mcpServerNames(listJSON: "WARN\n[]"), [])
        CodexWarmHost.mcpListSeconds = 1
        for (name, mcp) in [("код 1", "echo '[]'; exit 1"), ("мусор", "echo 'Error: bad config'"), ("таймаут", "sleep 5; echo '[]'")] {
            let started = folder.appendingPathComponent("started-\(name)").path
            let host = CodexWarmHost(executable: try fakeCodex(mcp: mcp, started: started))
            do { try await host.warmUp(); XCTFail("\(name): тёплого Codex быть не должно") } catch {
                XCTAssertTrue(error.localizedDescription.contains("MCP"), "\(name): \(error.localizedDescription)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: started), "\(name): app-server не запускался (его MCP не поднялись)")
            await host.shutdown()
        }
    }

    /// п.5: процесса Codex уже нет — запрос сразу ошибка, а не 45 с ожидания.
    func testRequestToDeadCodexFailsAtOnce() async throws {
        let host = CodexWarmHost(executable: try fakeCodex(mcp: "echo '[]'", started: folder.appendingPathComponent("s").path, exitAfterInit: true))
        try await host.warmUp()
        try await Task.sleep(nanoseconds: 300_000_000)
        let t = Date()
        do { _ = try await host.ask(prompt: "вопрос", system: "s", model: nil, effort: nil); XCTFail("процесса нет") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(t), 3)
        await host.shutdown()
    }

    // MARK: п.4 — отмена у тёплого Claude

    func testCancelledClaudeQuestionKeepsHostWarm() async throws {
        // Прогрев — сразу, вопрос — через 3 с (его отменят раньше).
        let claude = try script("claude", """
        n=0
        while IFS= read -r line; do
          n=$((n+1))
          if [ "$n" -gt 1 ]; then sleep 3; fi
          echo '{"type":"result","subtype":"success","is_error":false,"result":"ок"}'
        done
        """)
        let host = ClaudeWarmHost(executable: claude, system: "s", model: nil, effort: nil)
        await host.warmUp()
        XCTAssertEqual(pids().count, 1)
        let first = Task { try await host.ask("черновик") { _ in } }
        try await Task.sleep(nanoseconds: 300_000_000)
        first.cancel()
        _ = try? await first.value
        // Отменённая сессия закрыта, запасная уже готовится — хост не выключен.
        try await waitFor { self.pids().count == 1 }
        let started = Date()
        let second = Task { try await host.ask("полный вопрос") { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        second.cancel()
        _ = try? await second.value
        let info = await host.lastInfo
        XCTAssertEqual(info?.cold, false, "следующий вопрос — в тёплую запасную, а не холодный запуск")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
        await host.shutdown()
        try await waitFor { self.pids().isEmpty }
        XCTAssertEqual(pids().count, 0)
    }

    /// п.7: claude молчит на прогреве — процесс закрывается по таймеру, прогрев не висит.
    func testSilentClaudePrimeTimesOut() async throws {
        ClaudeWarmHost.primeSeconds = 0.5
        let claude = try script("claude", "while IFS= read -r line; do sleep 30; done")
        let host = ClaudeWarmHost(executable: claude, system: "s", model: nil, effort: nil)
        let t = Date()
        await host.warmUp()
        XCTAssertLessThan(Date().timeIntervalSince(t), 5)
        try await waitFor { self.pids().isEmpty }
        XCTAssertEqual(pids().count, 0)
        await host.shutdown()
    }

    // MARK: п.3 — отменённый ответ не трогает новый

    /// Ответ приходит через `delay`; отмена кончает поток без ошибки (как у настоящего `AsyncThrowingStream`).
    struct SlowAI: CopilotAIClient {
        let delay: Double
        func stream(prompt: String, system: String, images: [Data], profile: CopilotAIProfile) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { c in
                let task = Task {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    c.yield("Фраза.\n- а\n- б"); c.finish()
                }
                c.onTermination = { _ in task.cancel() }
            }
        }
    }

    final class L: CopilotListening {
        var onFailure: (@MainActor (String) -> Void)?
        func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {}
        func stop() {}
    }

    @MainActor
    func testReplacedAnswerDoesNotFinishTheNewOne() async throws {
        for hybrid in [false, true] {
            let session = CopilotSession(ai: SlowAI(delay: 0.6), listener: L(), settings: { CopilotSettings(autoAnswer: false, hybrid: hybrid) },
                                         log: { _ in }, logError: { _ in })
            session.start()
            session.feed(Utterance(.other, "Как бы вы ускорили этот отчёт?"))
            session.answerLast()
            try await Task.sleep(nanoseconds: 100_000_000)
            session.answerLast()   // новый вопрос заменил старый
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertTrue(session.isAnswering, "hybrid=\(hybrid): «Думаю…» не пропадает")
            XCTAssertNil(session.expandedAt, "hybrid=\(hybrid): панель не раскрыта и не сворачивается раньше ответа")
            try await Task.sleep(nanoseconds: 800_000_000)
            XCTAssertFalse(session.isAnswering, "hybrid=\(hybrid)")
            XCTAssertEqual(session.answer.say, "Фраза.", "hybrid=\(hybrid)")
            session.stop()
        }
    }

    // MARK: Помощники

    /// Подставной codex: `mcp list` — по `mcp`, `app-server` — отмечает запуск в `started` и отвечает на initialize.
    private func fakeCodex(mcp: String, started: String, exitAfterInit: Bool = false) throws -> String {
        try script("codex", """
        if [ "$1" = mcp ]; then \(mcp); exit 0; fi
        touch '\(started)'
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/^{"id":\\([0-9][0-9]*\\),.*/\\1/p')
          if [ -n "$id" ]; then printf '{"id":%s,"result":{}}\\n' "$id"; \(exitAfterInit ? "exit 0;" : "") fi
        done
        """)
    }

    private func script(_ name: String, _ body: String) throws -> String {
        let url = folder.appendingPathComponent("\(name)-\(marker)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

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
            .filter { $0.contains("/bin/sh") && $0.contains(marker) && !$0.contains("codex-") }
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }
}

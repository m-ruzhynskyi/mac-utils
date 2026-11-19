import XCTest
@testable import MacUtils
@testable import MUCopilot
@testable import MUAIBackend

/// COPILOT-40: почему тёплый Codex на Mac менеджера не отвечал, и что изменилось.
/// Причина (проверено на codex 0.170.0 без запросов к модели): `codex mcp list --json` без наших `--disable` показывает и
/// серверы плагинов и встроенные (`codex_app`, `cua_repl`…), которых нет в config.toml; `-c mcp_servers.<имя>.enabled=false`
/// для такого имени создаёт запись без транспорта — app-server выходит с «invalid transport» до `initialize`.
/// Вместо codex — скрипты /bin/sh; `CODEX_HOME` — временная папка.
final class CopilotWarmCodexTests: XCTestCase {
    private var folder: URL!
    private var marker = ""
    private var savedCodexHome: String?
    private var log: URL { folder.appendingPathComponent("fake.log") }

    override func setUpWithError() throws {
        marker = "mu-copilot-40-\(UUID().uuidString.prefix(8))"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(marker, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        setenv("CODEX_HOME", folder.path, 1)
    }

    override func tearDownWithError() throws {
        for pid in pids() { kill(pid, SIGKILL) }
        if let savedCodexHome { setenv("CODEX_HOME", savedCodexHome, 1) } else { unsetenv("CODEX_HOME") }
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Список MCP

    func testMCPListUsesTheSameFlagsAsAppServer() {
        let args = CodexCLI.mcpListArguments
        XCTAssertEqual(Array(args.suffix(3)), ["mcp", "list", "--json"])
        XCTAssertTrue(args.contains("plugins") && args.contains("apps"), "плагины и apps выключены и в списке")
        XCTAssertTrue(args.contains(#"model_provider="openai""#))
    }

    func testOnlyEnabledServersAreTurnedOff() {
        let list = #"[{"name":"codex_app","enabled":false},{"name":"computer-use","enabled":false},{"name":"snyk","enabled":true},{"name":"node_repl"}]"#
        XCTAssertEqual(CodexCLI.enabledMCPServers(listJSON: list), ["snyk", "node_repl"])
        XCTAssertNil(CodexCLI.enabledMCPServers(listJSON: "Error"))
        XCTAssertNil(CodexCLI.enabledMCPServers(listJSON: #"[{"enabled":true}]"#), "без имени — сбой списка")
    }

    func testRejectedConfigIsACategoryNotText() async throws {
        let codex = try fake("""
        if printf '%s ' "$@" | grep -q 'mcp list'; then echo '[{"name":"codex_app","enabled":true}]'; exit 0; fi
        echo 'Error: invalid transport' >&2; echo 'in `mcp_servers.codex_app`' >&2; exit 1
        """)
        let host = CodexWarmHost(executable: codex)
        do { try await host.warmUp(); XCTFail("app-server не стартовал") } catch {
            XCTAssertEqual(WarmFailure.category(of: error), "process-exited(1)-mcp-config")
            XCTAssertTrue(error.localizedDescription.contains("invalid transport"), "текст — только в .private")
        }
        XCTAssertTrue(WarmCopilotAI.isLasting("process-exited(1)-mcp-config"), "до выключения — сразу разовый запуск")
        XCTAssertFalse(WarmCopilotAI.isLasting("mcp-list-failed"))
        await host.shutdown()
    }

    func testAppServerGetsOnlyEnabledServersAndStarts() async throws {
        let codex = try fake("""
        if printf '%s ' "$@" | grep -q 'mcp list'; then echo "list: $*" >> '\(log.path)'; echo '[{"name":"codex_app","enabled":false},{"name":"snyk","enabled":true}]'; exit 0; fi
        echo "server: $*" >> '\(log.path)'
        \(Self.server)
        """)
        let host = CodexWarmHost(executable: codex)
        try await host.warmUp()
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("list: --disable shell_tool"), text)
        XCTAssertTrue(text.contains("mcp_servers.snyk.enabled=false"), text)
        XCTAssertFalse(text.contains("mcp_servers.codex_app"), "выключенный встроенный не трогаем")
        await host.shutdown()
    }

    // MARK: Ветка заранее, turn/interrupt, коды ошибок

    func testSpareThreadIsUsedAndInterruptIsSentOnCancel() async throws {
        let codex = try fake("""
        if printf '%s ' "$@" | grep -q 'mcp list'; then echo '[]'; exit 0; fi
        \(Self.server)
        """)
        let host = CodexWarmHost(executable: codex)
        try await host.warmUp()
        await host.prepareThread(system: "s", model: "m")
        let spare = await host.hasSpareThread(system: "s", model: "m")
        XCTAssertTrue(spare)
        let stream = try await host.ask(prompt: "вопрос", system: "s", model: "m", effort: "low")
        let consumer = Task { for try await _ in stream {} }
        try await waitFor { self.lines().contains { $0.contains("turn") && $0.contains("start") } }
        consumer.cancel()
        try await waitFor { self.lines().contains { $0.contains("interrupt") } }
        let received = lines()
        XCTAssertEqual(received.filter { $0.contains(#""method":"thread\/start""#) }.count, 2,
                       "ветка для вопроса — заранее открытая; вторая — уже под следующий вопрос")
        let interrupt = try XCTUnwrap(received.first { $0.contains("interrupt") }, received.joined(separator: "\n"))
        XCTAssertTrue(interrupt.contains(#""turnId":"tu"#), interrupt)
        XCTAssertTrue(interrupt.contains(#""threadId":"th"#), interrupt)
        await host.shutdown()
    }

    func testThreadStartErrorCategoryHasRPCCode() async throws {
        let codex = try fake("""
        if printf '%s ' "$@" | grep -q 'mcp list'; then echo '[]'; exit 0; fi
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/^{"id":\\([0-9][0-9]*\\),.*/\\1/p')
          case "$line" in
            *'"method":"thread'*) printf '{"id":%s,"error":{"code":-32600,"message":"bad"}}\\n' "$id" ;;
            *) [ -n "$id" ] && printf '{"id":%s,"result":{}}\\n' "$id" ;;
          esac
        done
        """)
        let host = CodexWarmHost(executable: codex)
        do { _ = try await host.ask(prompt: "вопрос", system: "s", model: nil, effort: nil); XCTFail() } catch {
            XCTAssertEqual(WarmFailure.category(of: error), "rpc-error(-32600)")
        }
        await host.shutdown()
    }

    func testProtocolTurnIDAndInterrupt() throws {
        XCTAssertEqual(WarmProtocol.parseCodex(#"{"id":4,"result":{"turn":{"id":"tu4","status":"inProgress"}}}"#),
                       .response(id: 4, threadID: nil, error: nil, turnID: "tu4"))
        let data = WarmProtocol.codexTurnInterrupt(id: 5, threadID: "th1", turnID: "tu4")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["method"] as? String, "turn/interrupt")
        XCTAssertEqual(json["params"] as? [String: String], ["threadId": "th1", "turnId": "tu4"])
    }

    func testCategories() {
        XCTAssertEqual(WarmFailure.category(of: AIFailure.toolUse(.codex, kind: "commandExecution")), "tool-item")
        XCTAssertEqual(WarmFailure.category(of: AIFailure.timeout(.codex, seconds: 45)), "ai-timeout")
        XCTAssertEqual(WarmFailure.category(of: CancellationError()), "cancelled")
        XCTAssertEqual(WarmFailure.category(of: WarmFailure("секрет из вывода CLI", category: "mcp-list-failed")), "mcp-list-failed")
        XCTAssertEqual(WarmFailure.category(of: NSError(domain: "x", code: 1)), "other")
    }

    @MainActor
    func testSelfTestWarmPathLine() {
        XCTAssertEqual(CopilotSelfTest.warmPathLine(enabled: true, path: "да"), "да")
        XCTAssertEqual(CopilotSelfTest.warmPathLine(enabled: true, path: "нет (mcp-list-failed)"), "нет (mcp-list-failed)")
        XCTAssertEqual(CopilotSelfTest.warmPathLine(enabled: false, path: nil), "нет (выключен в настройках)")
    }

    // MARK: Помощники

    /// app-server: initialize → {}, thread/start → новая ветка thN, turn/start → ход tuN без ответа; всё полученное — в журнал.
    private static let server = """
    while IFS= read -r line; do
      printf '%s\\n' "$line" >> "$LOG"
      id=$(printf '%s' "$line" | sed -n 's/^{"id":\\([0-9][0-9]*\\),.*/\\1/p')
      case "$line" in
        *'"method":"thread'*) printf '{"id":%s,"result":{"thread":{"id":"th%s"}}}\\n' "$id" "$id" ;;
        *'"method":"turn'*'start"'*) printf '{"id":%s,"result":{"turn":{"id":"tu%s","status":"inProgress"}}}\\n' "$id" "$id" ;;
        *) [ -n "$id" ] && printf '{"id":%s,"result":{}}\\n' "$id" ;;
      esac
    done
    """

    private func fake(_ body: String) throws -> String {
        let url = folder.appendingPathComponent("codex-\(marker)")
        try ("#!/bin/sh\nLOG='\(log.path)'\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func lines() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
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
            .filter { $0.contains("/bin/sh") && $0.contains(marker) }
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
    }
}

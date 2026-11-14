@testable import MacUtils
import AppKit
import SwiftUI
import XCTest
@testable import MUAI
@testable import MUDesign
@testable import MUAIBackend
@testable import MUCore
@testable import MUMeetings

/// Бэкенд ИИ без настоящих запросов: codex и claude не запускаются. Потоковый вывод — образцы по документации
/// (`codex exec --json`: thread/turn/item-события; `claude -p --output-format stream-json`: system/stream_event/assistant/result).
final class AIBackendTests: XCTestCase {
    private let workspace = "/tmp/MacUtils-AI"

    // MARK: - Codex: аргументы

    func testCodexArgumentsAreReadOnlyEphemeralAndReadPromptFromStdin() {
        let request = AIRequest(prompt: "привет", system: "S")
        let args = CodexCLI.arguments(request: request, workspace: workspace)
        XCTAssertEqual(args.first, "exec")
        XCTAssertEqual(args.last, "-", "запрос — со stdin")
        for flag in ["--json", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
        XCTAssertEqual(value(after: "--sandbox", in: args), "read-only")
        XCTAssertEqual(value(after: "--cd", in: args), workspace)
        XCTAssertEqual(value(after: "--color", in: args), "never")
        XCTAssertFalse(args.contains { $0.contains("dangerously") || $0 == "workspace-write" || $0 == "--full-auto" })
        XCTAssertFalse(args.contains("привет"), "текст запроса не попадает в аргументы (виден в ps)")
        XCTAssertFalse(args.contains("-c"), "без quick — обычные рассуждения")
    }

    func testCodexImagesUseEqualsFormAndNeverSwallowThePrompt() {
        let request = AIRequest(prompt: "что на снимке", images: [URL(fileURLWithPath: "/tmp/a b.png"), URL(fileURLWithPath: "/tmp/c.jpg")])
        let args = CodexCLI.arguments(request: request, workspace: workspace)
        XCTAssertEqual(args.filter { $0.hasPrefix("--image=") }, ["--image=/tmp/a b.png", "--image=/tmp/c.jpg"])
        for (index, arg) in args.enumerated() where arg.hasPrefix("--image=") {
            let next = args[index + 1]
            XCTAssertTrue(next.hasPrefix("--image=") || (next.hasPrefix("-") && next != "-"),
                          "после картинки не должно идти значение, которое примут за ещё одну картинку: \(next)")
        }
        XCTAssertEqual(args.last, "-")
    }

    func testCodexQuickLowersReasoningAndModelIsOptional() {
        let args = CodexCLI.arguments(request: AIRequest(prompt: "x", quick: true), workspace: workspace, model: "gpt-x")
        XCTAssertEqual(value(after: "-c", in: args), "model_reasoning_effort=\"low\"")
        XCTAssertEqual(value(after: "--model", in: args), "gpt-x")
        XCTAssertFalse(CodexCLI.arguments(request: AIRequest(prompt: "x"), workspace: workspace, model: "").contains("--model"))
    }

    func testCodexInputPutsSystemBeforeTheData() {
        let text = String(decoding: CodexCLI.input(request: AIRequest(prompt: "ДАННЫЕ", system: "СИСТЕМА")), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("СИСТЕМА\n" + AIRequest.textOnly))
        XCTAssertTrue(text.hasSuffix("---\n\nДАННЫЕ"))
        let plain = String(decoding: CodexCLI.input(request: AIRequest(prompt: "x")), as: UTF8.self)
        XCTAssertTrue(plain.hasPrefix(AIRequest.defaultSystem))
    }

    // MARK: - Codex: разбор --json

    private let codexSample = """
    {"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"**Fixing typos**"}}
    {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"Привет, мир!"}}
    {"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122}}
    """

    func testCodexStreamYieldsOnlyAgentMessage() {
        let events = codexSample.split(separator: "\n").compactMap { CodexCLI.parse(String($0)) }
        XCTAssertEqual(events, [.progress, .message("Привет, мир!"), .done(nil)])
        var answer = AIAnswer(lastMessageOnly: true)
        let pieces = events.compactMap { answer.consume($0) }
        XCTAssertEqual(pieces, ["Привет, мир!"])
        XCTAssertEqual(answer.text, "Привет, мир!")
        XCTAssertTrue(answer.finished)
        XCTAssertNil(answer.failure)
    }

    func testCodexFailureAndNotices() {
        XCTAssertEqual(CodexCLI.parse(#"{"type":"turn.failed","error":{"message":"stream disconnected"}}"#), .failure("stream disconnected"))
        XCTAssertEqual(CodexCLI.parse(#"{"type":"error","message":"Reconnecting... 1/5"}"#), .notice("Reconnecting... 1/5"))
        XCTAssertNil(CodexCLI.parse("WARNING: proceeding, even though we could not update PATH"))
        XCTAssertNil(CodexCLI.parse("{не json"))
        // Старое имя элемента ответа.
        XCTAssertEqual(CodexCLI.parse(#"{"type":"item.completed","item":{"type":"assistant_message","text":"ok"}}"#), .message("ok"))
    }

    func testCodexLoginStatus() {
        XCTAssertTrue(CodexCLI.isLoggedIn(status: 0, output: "Logged in using ChatGPT"))
        XCTAssertFalse(CodexCLI.isLoggedIn(status: 1, output: "Not logged in"))
        XCTAssertFalse(CodexCLI.isLoggedIn(status: 0, output: "Not logged in"))
    }

    // MARK: - Codex: только последний ответ, без инструментов (AIB-31)

    func testCodexKeepsOnlyTheLastAgentMessage() {
        var answer = AIAnswer(lastMessageOnly: true)
        XCTAssertNil(answer.consume(.message("Сейчас исправлю опечатки…")), "предисловие не отдаётся")
        XCTAssertNil(answer.consume(.progress))
        XCTAssertNil(answer.consume(.message("Исправленный текст.")), "до конца хода — ничего")
        XCTAssertEqual(answer.consume(.done(nil)), "Исправленный текст.")
        XCTAssertEqual(answer.text, "Исправленный текст.")
        XCTAssertNil(answer.flush(), "уже отдан")

        var noTurnEnd = AIAnswer(lastMessageOnly: true)
        _ = noTurnEnd.consume(.message("ответ"))
        XCTAssertEqual(noTurnEnd.flush(), "ответ", "программа вышла без turn.completed — последнее сообщение всё равно отдаётся")

        var failed = AIAnswer(lastMessageOnly: true)
        _ = failed.consume(.message("начало"))
        _ = failed.consume(.failure("stream disconnected"))
        XCTAssertNil(failed.flush(), "при ошибке хода ответа нет")

        var claude = AIAnswer()
        XCTAssertEqual(claude.consume(.message("один")), "один", "у Claude поведение прежнее")
    }

    func testCodexArgumentsDisableTools() {
        let args = CodexCLI.arguments(request: AIRequest(prompt: "x", images: [URL(fileURLWithPath: "/tmp/a.png")]), workspace: workspace)
        for feature in ["shell_tool", "view_image", "computer_use", "browser_use", "plugins", "apps"] {
            let pairs = zip(args, args.dropFirst()).filter { $0.0 == "--disable" && $0.1 == feature }
            XCTAssertEqual(pairs.count, 1, feature)
        }
        XCTAssertFalse(args.contains("--enable"))
        XCTAssertEqual(args.last, "-", "запрос — по-прежнему со stdin, последним")
        XCTAssertLessThan(args.firstIndex(of: "--disable") ?? .max, args.count - 1)
    }

    func testCodexToolItemsAreRecognisedAndOtherItemsAreSignsOfLife() {
        for kind in ["command_execution", "file_change", "mcp_tool_call", "collab_tool_call", "local_shell_call"] {
            XCTAssertEqual(CodexCLI.parse(#"{"type":"item.started","item":{"id":"i","type":"\#(kind)"}}"#), .tool(kind), kind)
            XCTAssertEqual(CodexCLI.parse(#"{"type":"item.completed","item":{"id":"i","type":"\#(kind)"}}"#), .tool(kind), kind)
        }
        XCTAssertEqual(CodexCLI.parse(#"{"type":"item.started","item":{"id":"i","type":"reasoning"}}"#), .progress)
        XCTAssertEqual(CodexCLI.parse(#"{"type":"item.updated","item":{"id":"i","type":"todo_list"}}"#), .progress)
        XCTAssertEqual(CodexCLI.parse(#"{"type":"item.started","item":{"id":"i","type":"agent_message","text":""}}"#), .progress)
        XCTAssertNil(CodexCLI.parse(#"{"type":"turn.started"}"#), "начало хода — не признак жизни: приходит до связи с сервером")
        XCTAssertNil(CodexCLI.parse(#"{"type":"thread.started","thread_id":"x"}"#))
    }

    func testOldCodexWithoutFeatureFlagAsksToUpdate() {
        let failure = AIFailure.from(.codex, output: "Error: Unknown feature flag: shell_tool")
        XCTAssertTrue(failure.message.contains("codex update"), failure.message)
        XCTAssertEqual(failure.kind, .failed)
    }

    func testCodexEngineReturnsOnlyTheFinalAnswer() async throws {
        let script = try fakeCodex("""
        echo '{"type":"thread.started","thread_id":"t"}'
        echo '{"type":"turn.started"}'
        echo '{"type":"item.completed","item":{"id":"0","type":"agent_message","text":"Сейчас исправлю…"}}'
        echo '{"type":"item.completed","item":{"id":"1","type":"reasoning","text":"думаю"}}'
        echo '{"type":"item.completed","item":{"id":"2","type":"agent_message","text":"Исправленный текст."}}'
        echo '{"type":"turn.completed","usage":{}}'
        """)
        let text = try await CLIEngine(.codex, executable: script.path).generate(AIRequest(prompt: "x", timeout: 20))
        XCTAssertEqual(text, "Исправленный текст.")
    }

    func testCodexEngineStopsOnToolUseAndKillsTheProcess() async throws {
        let marker = "mu-ai-tool-\(UUID().uuidString.prefix(8))"
        let script = try fakeCodex("""
        echo '{"type":"turn.started"}'
        echo '{"type":"item.started","item":{"id":"1","type":"command_execution","command":"cat ~/.ssh/id_ed25519","status":"in_progress"}}'
        /bin/sh -c 'sleep 30; :' \(marker)
        echo '{"type":"item.completed","item":{"id":"2","type":"agent_message","text":"секрет"}}'
        echo '{"type":"turn.completed","usage":{}}'
        """)
        let started = Date()
        do {
            _ = try await CLIEngine(.codex, executable: script.path).generate(AIRequest(prompt: "x", timeout: 60))
            XCTFail("ответ с командой должен быть отброшен")
        } catch let failure as AIFailure {
            XCTAssertEqual(failure.provider, .codex)
            XCTAssertTrue(failure.message.contains("command_execution"), failure.message)
            XCTAssertTrue(failure.message.contains("остановлено"), failure.message)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "не ждём конца команды")
        // SIGTERM — сразу; потомок, родившийся в момент остановки, добивает SIGKILL группе через 2 с.
        var alive = true
        for _ in 0..<40 where alive {
            try await Task.sleep(nanoseconds: 100_000_000)
            alive = processExists(marker)
        }
        XCTAssertFalse(alive, "процесс codex и его потомки убиты")
    }

    // MARK: - Claude: аргументы и stdin

    func testClaudeArgumentsHaveNoToolsAndStreamJSON() {
        let args = ClaudeCLI.arguments(request: AIRequest(prompt: "x", system: "Ты корректор."))
        XCTAssertEqual(args.first, "-p")
        XCTAssertEqual(value(after: "--output-format", in: args), "stream-json")
        XCTAssertEqual(value(after: "--tools", in: args), "", "пустой список — без инструментов")
        for flag in ["--verbose", "--include-partial-messages", "--strict-mcp-config", "--safe-mode", "--no-session-persistence",
                     "--disable-slash-commands"] {
            XCTAssertTrue(args.contains(flag), flag)
        }
        XCTAssertEqual(value(after: "--system-prompt", in: args), "Ты корректор.\n" + AIRequest.textOnly)
        XCTAssertFalse(args.contains("--input-format"), "без картинок — простой текст со stdin")
        XCTAssertFalse(args.contains { $0.contains("dangerously") || $0 == "bypassPermissions" })
        XCTAssertFalse(args.contains("x"))
        XCTAssertFalse(args.contains("--effort"))
        XCTAssertEqual(value(after: "--effort", in: ClaudeCLI.arguments(request: AIRequest(prompt: "x", quick: true))), "low")
    }

    func testClaudeImagesGoAsStreamJSONContentBlocks() throws {
        let png = URL(fileURLWithPath: "/tmp/shot.PNG")
        let request = AIRequest(prompt: "Что на снимке?", images: [png])
        XCTAssertEqual(value(after: "--input-format", in: ClaudeCLI.arguments(request: request)), "stream-json")
        let data = try ClaudeCLI.input(request: request) { _ in Data([1, 2, 3]) }
        XCTAssertEqual(data.last, 0x0A, "одно сообщение — одна строка")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "user")
        let message = try XCTUnwrap(json["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AQID")
        XCTAssertEqual(content[1]["type"] as? String, "text")
        XCTAssertEqual(content[1]["text"] as? String, "Что на снимке?")
        XCTAssertEqual(try ClaudeCLI.input(request: AIRequest(prompt: "текст")), Data("текст".utf8))
        XCTAssertThrowsError(try ClaudeCLI.input(request: AIRequest(prompt: "x", images: [URL(fileURLWithPath: "/tmp/a.tiff")])) { _ in Data() })
    }

    // MARK: - Claude: разбор stream-json

    private let claudeSample = """
    {"type":"system","subtype":"init","cwd":"/tmp/MacUtils-AI","session_id":"5d3b","tools":[],"model":"claude-sonnet-5-5","permissionMode":"default"}
    {"type":"stream_event","event":{"type":"message_start","message":{"id":"msg_1","role":"assistant","content":[]}},"session_id":"5d3b"}
    {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"5d3b"}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Привет"}},"session_id":"5d3b"}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", мир!"}},"session_id":"5d3b"}
    {"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Привет, мир!"}]},"session_id":"5d3b"}
    {"type":"stream_event","event":{"type":"message_stop"},"session_id":"5d3b"}
    {"type":"result","subtype":"success","is_error":false,"duration_ms":2310,"num_turns":1,"result":"Привет, мир!","session_id":"5d3b","total_cost_usd":0.0123}
    """

    func testClaudeStreamYieldsDeltasOnceNotTwice() {
        let events = claudeSample.split(separator: "\n").compactMap { ClaudeCLI.parse(String($0)) }
        XCTAssertEqual(events, [.delta("Привет"), .delta(", мир!"), .message("Привет, мир!"), .done("Привет, мир!")])
        var answer = AIAnswer()
        XCTAssertEqual(events.compactMap { answer.consume($0) }, ["Привет", ", мир!"])
        XCTAssertEqual(answer.text, "Привет, мир!")
    }

    func testClaudeWithoutPartialMessagesUsesAssistantOrResult() {
        var answer = AIAnswer()
        let pieces = [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Готово"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"Готово"}"#,
        ].compactMap(ClaudeCLI.parse).compactMap { answer.consume($0) }
        XCTAssertEqual(pieces, ["Готово"])
        var onlyResult = AIAnswer()
        XCTAssertEqual(onlyResult.consume(.done("Итог")), "Итог")
        XCTAssertEqual(onlyResult.text, "Итог")
    }

    func testClaudeErrorResultIsFailureAndLoginIsRecognised() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#
        XCTAssertEqual(ClaudeCLI.parse(line), .failure("Not logged in · Please run /login"))
        XCTAssertEqual(ClaudeCLI.parse(#"{"type":"result","subtype":"error_max_turns","is_error":false}"#), .failure("error_max_turns"))
        let failure = AIFailure.from(.claude, output: "Not logged in · Please run /login")
        XCTAssertEqual(failure.kind, .notLoggedIn)
        XCTAssertEqual(failure.errorDescription, "Войдите в Claude: claude auth login в Терминале")
        XCTAssertEqual(AIFailure.from(.codex, output: "Error: unexpected status 401 Unauthorized").kind, .notLoggedIn)
        let other = AIFailure.from(.codex, output: "warning\nrate limit reached\n")
        XCTAssertEqual(other.kind, .failed)
        XCTAssertEqual(other.errorDescription, "ChatGPT (Codex): rate limit reached")
        XCTAssertEqual(AIFailure.from(.codex, output: "строка 401 в файле").kind, .failed, "число 401 само по себе — не вход")
    }

    func testClaudeAuthStatus() {
        XCTAssertTrue(ClaudeCLI.isLoggedIn(status: 0, output: #"{"loggedIn": true, "authMethod": "claude.ai"}"#))
        XCTAssertFalse(ClaudeCLI.isLoggedIn(status: 0, output: #"{"loggedIn": false}"#))
        XCTAssertFalse(ClaudeCLI.isLoggedIn(status: 1, output: "Not logged in"))
        XCTAssertTrue(ClaudeCLI.isLoggedIn(status: 0, output: "Logged in"))
    }

    // MARK: - Поиск программ

    func testLocatorPrefersKnownPathsThenLoginShell() {
        let home = "/Users/u"
        let found: (Set<String>) -> String? = { existing in
            CLILocator.find("codex", home: home, loginPath: "/custom/bin:/usr/bin", isExecutable: { existing.contains($0) })
        }
        XCTAssertEqual(found(["/Users/u/.local/node/bin/codex", "/custom/bin/codex"]), "/Users/u/.local/node/bin/codex")
        XCTAssertEqual(found(["/custom/bin/codex"]), "/custom/bin/codex", "нет в известных местах — PATH login shell")
        XCTAssertEqual(found(["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]), "/opt/homebrew/bin/codex")
        XCTAssertNil(found([]))
        XCTAssertEqual(CLILocator.find("claude", home: home, loginPath: nil, isExecutable: { $0 == "/Users/u/.local/bin/claude" }),
                       "/Users/u/.local/bin/claude")
        XCTAssertTrue(CLILocator.knownPaths(for: "claude", home: home).contains("/Users/u/.claude/local/claude"))
    }

    func testEnvironmentPathPutsProgramFolderFirstForNode() {
        let path = CLILocator.environmentPath(executable: "/Users/u/.local/node/bin/codex", loginPath: "/usr/bin:/Users/u/.local/node/bin:/x")
        let dirs = path.split(separator: ":").map(String.init)
        XCTAssertEqual(dirs.first, "/Users/u/.local/node/bin", "codex — скрипт `env node`, node лежит рядом")
        XCTAssertEqual(dirs.count, Set(dirs).count, "без повторов")
        XCTAssertTrue(dirs.contains("/x"))
        XCTAssertTrue(dirs.contains("/bin"))
        XCTAssertEqual(CLILocator.parseLoginPath("Welcome!\n/opt/homebrew/bin:/usr/bin\n\n"), "/opt/homebrew/bin:/usr/bin")
        XCTAssertNil(CLILocator.parseLoginPath("zsh: no such option\n"))
    }

    // MARK: - Выбор и запасной

    func testProviderSettingDefaultsToCodex() {
        XCTAssertEqual(AIProvider(stored: nil), .codex)
        XCTAssertEqual(AIProvider(stored: "ollama"), .codex)
        XCTAssertEqual(AIProvider(stored: "claude"), .claude)
        XCTAssertEqual(AIRouter.order(selected: .claude, fallback: false), [.claude])
        XCTAssertEqual(AIRouter.order(selected: .claude, fallback: true), [.claude, .codex])
        XCTAssertEqual(AIRouter.order(selected: .codex, fallback: true), [.codex, .claude])
    }

    func testFallbackOnErrorUsesSecond() async throws {
        let calls = Calls()
        let router = fakeRouter(calls, [.codex: .fail(.notLoggedIn(.codex)), .claude: .reply(["Ответ ", "Claude"])])
        let text = try await collect(router.stream(AIRequest(prompt: "x"), order: [.codex, .claude], firstPieceWithin: 5))
        XCTAssertEqual(text, "Ответ Claude")
        XCTAssertEqual(calls.providers, [.codex, .claude])
    }

    func testNoFallbackWhenDisabled() async {
        let calls = Calls()
        let router = fakeRouter(calls, [.codex: .fail(.notLoggedIn(.codex)), .claude: .reply(["нет"])])
        do {
            _ = try await collect(router.stream(AIRequest(prompt: "x"), order: [.codex], firstPieceWithin: 5))
            XCTFail("ожидалась ошибка")
        } catch {
            XCTAssertEqual((error as? AIFailure)?.kind, .notLoggedIn)
        }
        XCTAssertEqual(calls.providers, [.codex])
    }

    func testSlowPrimaryIsCancelledAndSecondAnswers() async throws {
        let calls = Calls()
        let router = fakeRouter(calls, [.codex: .hang, .claude: .reply(["быстро"])])
        let started = Date()
        let text = try await collect(router.stream(AIRequest(prompt: "x"), order: [.codex, .claude], firstPieceWithin: 0.3))
        XCTAssertEqual(text, "быстро")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(calls.cancelled.contains(.codex), "медленный основной остановлен (процесс убит)")
    }

    func testStartedAnswerIsNotMixedWithSecond() async {
        let calls = Calls()
        let router = fakeRouter(calls, [.codex: .partThenFail("начало"), .claude: .reply(["другое"])])
        var pieces: [String] = []
        do {
            for try await piece in router.stream(AIRequest(prompt: "x"), order: [.codex, .claude], firstPieceWithin: 5) {
                pieces.append(piece)
            }
            XCTFail("ожидалась ошибка")
        } catch {}
        XCTAssertEqual(pieces, ["начало"])
        XCTAssertEqual(calls.providers, [.codex])
    }

    func testLongTaskWaitsForSlowPrimaryWithoutDeadline() async throws {
        let calls = Calls()
        let router = fakeRouter(calls, [.codex: .delayed(0.4, "долгий отчёт"), .claude: .reply(["не нужен"])])
        let text = try await collect(router.stream(AIRequest(prompt: "x"), order: [.codex, .claude], firstPieceWithin: nil))
        XCTAssertEqual(text, "долгий отчёт")
        XCTAssertEqual(calls.providers, [.codex])
    }

    func testCancellingConsumerCancelsEngine() async throws {
        let calls = Calls()
        let router = fakeRouter(calls, [.codex: .hang])
        let task = Task { try await collect(router.stream(AIRequest(prompt: "x"), order: [.codex], firstPieceWithin: nil)) }
        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls.cancelled, [.codex])
    }

    func testSignOfLifeKeepsPrimaryPastTheFirstPieceDeadline() async throws {
        let calls = Calls()
        let router = fakeRouter(calls, [.codex: .aliveThenReply(0.8, "ответ Codex"), .claude: .reply(["не нужен"])])
        let text = try await collect(router.stream(AIRequest(prompt: "x"), order: [.codex, .claude], firstPieceWithin: 0.3))
        XCTAssertEqual(text, "ответ Codex", "codex работает (item.*), хотя текста ещё нет — к запасному не уходим")
        XCTAssertEqual(calls.providers, [.codex])
    }

    func testCodexEngineSignOfLifeReachesTheRouter() async throws {
        let script = try fakeCodex("""
        echo '{"type":"turn.started"}'
        echo '{"type":"item.started","item":{"id":"1","type":"reasoning"}}'
        sleep 1
        echo '{"type":"item.completed","item":{"id":"2","type":"agent_message","text":"медленно, но верно"}}'
        echo '{"type":"turn.completed","usage":{}}'
        """)
        let calls = Calls()
        let router = AIRouter { provider in
            provider == .codex ? CLIEngine(.codex, executable: script.path) as any AIEngine
                : FakeEngine(provider: provider, behavior: .reply(["Claude"]), calls: calls)
        }
        let text = try await collect(router.stream(AIRequest(prompt: "x", timeout: 20), order: [.codex, .claude], firstPieceWithin: 0.4))
        XCTAssertEqual(text, "медленно, но верно")
        XCTAssertEqual(calls.providers, [], "Claude не спрашивали")
    }

    func testSilentCodexStillFallsBackAfterDeadline() async throws {
        let script = try fakeCodex("""
        echo '{"type":"turn.started"}'
        echo '{"type":"error","message":"Reconnecting... 1/5"}'
        sleep 30
        """)
        let calls = Calls()
        let router = AIRouter { provider in
            provider == .codex ? CLIEngine(.codex, executable: script.path) as any AIEngine
                : FakeEngine(provider: provider, behavior: .reply(["Claude"]), calls: calls)
        }
        let started = Date()
        let text = try await collect(router.stream(AIRequest(prompt: "x", timeout: 60), order: [.codex, .claude], firstPieceWithin: 0.4))
        XCTAssertEqual(text, "Claude", "начало хода и переподключения — не жизнь: запасной по таймеру")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testWhenBothFailTheErrorNamesBoth() async {
        let calls = Calls()
        let router = fakeRouter(calls, [.codex: .fail(.notLoggedIn(.codex)), .claude: .fail(.notFound(.claude))])
        do {
            _ = try await collect(router.stream(AIRequest(prompt: "x"), order: [.codex, .claude], firstPieceWithin: 5))
            XCTFail("ожидалась ошибка")
        } catch let failure as AIFailure {
            XCTAssertTrue(failure.message.contains("Войдите в Codex"), failure.message)
            XCTAssertTrue(failure.message.contains("Claude не найден"), failure.message)
            XCTAssertEqual(failure.kind, .notLoggedIn, "вид — от выбранного сервиса")
            XCTAssertEqual(failure.provider, .codex)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(calls.providers, [.codex, .claude])
    }

    func testCombinedFailureOfOneIsItself() {
        XCTAssertEqual(AIFailure.combined([.empty(.claude)]), .empty(.claude))
        XCTAssertEqual(AIFailure.combined([]).kind, .failed)
    }

    // MARK: - Перевод функций

    func testMeetingReportIsOneRequestWithWholeTranscript() async throws {
        let calls = Calls()
        let saved = AI.router
        AI.router = fakeRouter(calls, [.codex: .reply(["## Итог\nок"]), .claude: .reply(["## Итог\nок"])])
        defer { AI.router = saved }
        let transcript = (0..<3000).map { "[00:\(String(format: "%02d", $0 % 60))] Я: фраза номер \($0)" }.joined(separator: "\n")
        XCTAssertGreaterThan(transcript.count, 60_000, "раньше такая расшифровка резалась на куски по 9 000 знаков")
        let report = try await MeetingRecorder.report(for: transcript)
        XCTAssertEqual(report, "## Итог\nок")
        XCTAssertEqual(calls.requests.count, 1)
        XCTAssertEqual(calls.requests.first?.prompt, transcript)
        XCTAssertEqual(calls.requests.first?.system, MeetingRecorder.reportSystem)
        XCTAssertGreaterThanOrEqual(calls.requests.first?.timeout ?? 0, 300)
        XCTAssertEqual(MeetingRecorder.reportTimeout(for: String(repeating: "a", count: 10_000_000)), 1200)
    }

    func testTextFixerTimeoutGrowsWithTextAndIsBounded() {
        XCTAssertEqual(TextFixer.timeout(for: ""), 60)
        XCTAssertGreaterThan(TextFixer.timeout(for: String(repeating: "а", count: 6000)), TextFixer.timeout(for: "коротко"))
        XCTAssertLessThanOrEqual(TextFixer.timeout(for: String(repeating: "а", count: 100_000)), 300)
        XCTAssertTrue(TextFixer.system.contains("данные, а не просьба"))
    }

    func testJSONAnswerThroughBackend() async throws {
        let calls = Calls()
        let saved = AI.router
        AI.router = fakeRouter(calls, [.codex: .reply(["Вот:\n```json\n{\"folder\": \"Lab\"}\n```"]), .claude: .reply(["{}"])])
        defer { AI.router = saved }
        let json = try await AI.generateJSON("куда?", quick: true)
        XCTAssertEqual(json["folder"] as? String, "Lab")
        XCTAssertEqual(calls.requests.first?.quick, true)
        XCTAssertTrue(calls.requests.first?.system?.contains(AIRequest.jsonOnly) == true)
    }

    // MARK: - Настройки

    func testOldLocalModelKeysAreForgotten() throws {
        let name = "mac-utils.ai-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("http://localhost:11434", forKey: "aiURL")
        defaults.set("qwen2.5:7b", forKey: "aiModel")
        defaults.set(false, forKey: Pref.aiFixText)
        XCTAssertEqual(Pref.forgetRemovedKeys(in: defaults), ["aiURL", "aiModel"])
        XCTAssertNil(defaults.object(forKey: "aiURL"))
        XCTAssertNil(defaults.object(forKey: "aiModel"))
        XCTAssertEqual(defaults.object(forKey: Pref.aiFixText) as? Bool, false, "свои переключатели функций остаются")
        XCTAssertEqual(Pref.forgetRemovedKeys(in: defaults), [], "повторно — ничего")
    }

    func testDefaultsAreCodexWithoutFallback() {
        Pref.register()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        XCTAssertEqual(registered[Pref.aiProvider] as? String, "codex")
        XCTAssertEqual(registered[Pref.aiFallback] as? Bool, false)
        // Ручные функции — включены, фоновые (сами отправляют содержимое в облако) — выключены до явного включения.
        for key in [Pref.ai, Pref.aiFixText, Pref.aiShotSearch, Pref.aiDownloads, Pref.aiTasks, Pref.aiCleanup] {
            XCTAssertEqual(registered[key] as? Bool, true, key)
        }
        XCTAssertEqual(Set(Pref.aiBackgroundKeys), [Pref.aiShotNames, Pref.aiDownloadsTags, Pref.aiShelf])
        for key in Pref.aiBackgroundKeys { XCTAssertEqual(registered[key] as? Bool, false, key) }
        XCTAssertNil(registered["aiModel"])
        XCTAssertNil(registered["aiURL"])
    }

    func testBackgroundAIChoiceFromOllamaTimesIsForgottenOnce() throws {
        let name = "mac-utils.ai-cloud-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.register(defaults: [Pref.aiShotNames: false, Pref.aiDownloadsTags: false, Pref.aiShelf: false])
        for key in Pref.aiBackgroundKeys { defaults.set(true, forKey: key) }
        defaults.set(false, forKey: Pref.aiFixText)
        XCTAssertEqual(Set(Pref.resetBackgroundAIAfterCloudMove(in: defaults)), Set(Pref.aiBackgroundKeys))
        for key in Pref.aiBackgroundKeys { XCTAssertFalse(defaults.bool(forKey: key), "\(key): после перехода — выключено") }
        XCTAssertEqual(defaults.object(forKey: Pref.aiFixText) as? Bool, false, "ручные функции не трогаются")
        // Человек включил сам — выбор сохраняется при следующих запусках.
        defaults.set(true, forKey: Pref.aiShotNames)
        XCTAssertEqual(Pref.resetBackgroundAIAfterCloudMove(in: defaults), [])
        XCTAssertTrue(defaults.bool(forKey: Pref.aiShotNames))
    }

    func testBackgroundFeaturesStayOffUntilEnabled() throws {
        let name = "mac-utils.ai-bg-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(Pref.resetBackgroundAIAfterCloudMove(in: defaults), [], "новый пользователь: сбрасывать нечего")
        XCTAssertTrue(defaults.bool(forKey: Pref.aiCloudMigrated))
    }

    // MARK: - Процесс: таймаут, отмена, потомки (только /bin/sh, cat, sleep)

    func testProcessStreamsLinesAndPassesStdin() async throws {
        let command = CLICommand(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                                 stdin: Data("один\nдва\nтри".utf8), directory: URL(fileURLWithPath: "/tmp"))
        var lines: [String] = []
        for try await line in CLIProcess.lines(command, timeout: 10) { lines.append(line) }
        XCTAssertEqual(lines, ["один", "два", "три"])
    }

    func testBigStdinDoesNotBlock() async throws {
        let big = String(repeating: "строка расшифровки\n", count: 40_000) // ~1,4 МБ — больше буфера трубы
        let command = CLICommand(executable: URL(fileURLWithPath: "/usr/bin/wc"), arguments: ["-l"],
                                 stdin: Data(big.utf8), directory: URL(fileURLWithPath: "/tmp"))
        let output = try await CLIProcess.run(command, timeout: 20)
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "40000")
    }

    func testNonZeroExitCarriesStderr() async {
        let command = CLICommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo 'Not logged in' >&2; exit 3"],
                                 directory: URL(fileURLWithPath: "/tmp"))
        do {
            for try await _ in CLIProcess.lines(command, timeout: 10) {}
            XCTFail("ожидалась ошибка")
        } catch let exit as CLIExit {
            XCTAssertEqual(exit.reason, .exited)
            XCTAssertEqual(exit.status, 3)
            XCTAssertTrue(exit.stderr.contains("Not logged in"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTimeoutKillsProcessAndItsChildren() async throws {
        let marker = "mu-ai-test-\(UUID().uuidString.prefix(8))"
        // Внук: вложенный sh с меткой вместо $0 (виден в ps) и его sleep.
        let command = CLICommand(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "/bin/sh -c 'sleep 30; :' \(marker) & wait"],
                                 directory: URL(fileURLWithPath: "/tmp"))
        let started = Date()
        do {
            for try await _ in CLIProcess.lines(command, timeout: 0.5) {}
            XCTFail("ожидался таймаут")
        } catch let exit as CLIExit {
            XCTAssertEqual(exit.reason, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.5)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(processExists(marker), "sleep-потомок должен быть убит")
    }

    func testCancelKillsProcess() async throws {
        let marker = "mu-ai-cancel-\(UUID().uuidString.prefix(8))"
        let command = CLICommand(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "/bin/sh -c 'sleep 30; :' \(marker) & wait"],
                                 directory: URL(fileURLWithPath: "/tmp"))
        let task = Task { for try await _ in CLIProcess.lines(command, timeout: 60) {} }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(processExists(marker))
        task.cancel()
        _ = try? await task.value
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(processExists(marker))
    }

    func testTimeoutAfterExitWhileGrandchildHoldsOutputIsNotATimeout() async throws {
        let marker = "mu-ai-pipe-\(UUID().uuidString.prefix(8))"
        // Процесс сразу выходит с кодом 0, но внук держит stdout ещё 3 с: чтение ждёт конец вывода до 2 с,
        // и таймаут 0,3 с срабатывает в это окно — успешный ответ не должен стать «не ответил».
        let command = CLICommand(executable: URL(fileURLWithPath: "/bin/sh"),
                                 arguments: ["-c", "echo ответ; /bin/sh -c 'sleep 3; :' \(marker) &"],
                                 directory: URL(fileURLWithPath: "/tmp"))
        var lines: [String] = []
        for try await line in CLIProcess.lines(command, timeout: 0.3) { lines.append(line) }
        XCTAssertEqual(lines, ["ответ"])
    }

    func testMissingProgramIsLaunchFailure() async {
        let command = CLICommand(executable: URL(fileURLWithPath: "/nonexistent/codex"), arguments: [],
                                 directory: URL(fileURLWithPath: "/tmp"))
        do {
            for try await _ in CLIProcess.lines(command, timeout: 5) {}
            XCTFail("ожидалась ошибка")
        } catch let exit as CLIExit {
            XCTAssertEqual(exit.reason, .launchFailed)
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: - Страница «ИИ»

    @MainActor
    func testAIPageDemoShowsBothProvidersWithoutRunningThem() {
        let host = NSHostingView(rootView: AIPage(demo: true).frame(width: 760, height: 1000))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 1000)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
        XCTAssertEqual(AIStatus.shared.state(.codex), .unknown, "демо не запускает проверку")
        XCTAssertEqual(SettingsSection.ai.title, "ИИ")
        XCTAssertFalse(SettingsSection.ai.subtitle.contains("локальн"))
    }

    // MARK: - Помощники

    private func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Подставной codex: shell-скрипт, печатающий JSONL как `codex exec --json`. Аргументы и stdin не читает.
    private func fakeCodex(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-fake-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("codex")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func processExists(_ marker: String) -> Bool {
        let pipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        ps.standardOutput = pipe
        try? ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").contains { $0.contains(marker) && !$0.contains("/bin/ps") }
    }
}

// MARK: - Подставные движки

private enum FakeBehavior: Sendable {
    case reply([String])
    case fail(AIFailure)
    case hang
    case partThenFail(String)
    case delayed(TimeInterval, String)
    /// Сразу «модель работает» (как codex `item.started`), текст — через столько секунд.
    case aliveThenReply(TimeInterval, String)
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var _providers: [AIProvider] = []
    private var _requests: [AIRequest] = []
    private var _cancelled: [AIProvider] = []
    var providers: [AIProvider] { lock.withLock { _providers } }
    var requests: [AIRequest] { lock.withLock { _requests } }
    var cancelled: [AIProvider] { lock.withLock { _cancelled } }
    func started(_ provider: AIProvider, _ request: AIRequest) { lock.withLock { _providers.append(provider); _requests.append(request) } }
    func cancel(_ provider: AIProvider) { lock.withLock { _cancelled.append(provider) } }
}

private struct FakeEngine: AIEngine {
    let provider: AIProvider
    let behavior: FakeBehavior
    let calls: Calls

    func stream(_ request: AIRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, alive: {})
    }

    func stream(_ request: AIRequest, alive: @escaping @Sendable () -> Void) -> AsyncThrowingStream<String, Error> {
        calls.started(provider, request)
        let provider = provider, behavior = behavior, calls = calls
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch behavior {
                case .reply(let pieces):
                    for piece in pieces { continuation.yield(piece) }
                    continuation.finish()
                case .fail(let failure):
                    continuation.finish(throwing: failure)
                case .hang:
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    continuation.finish()
                case .partThenFail(let piece):
                    continuation.yield(piece)
                    continuation.finish(throwing: AIFailure.empty(provider))
                case .delayed(let seconds, let text):
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    continuation.yield(text)
                    continuation.finish()
                case .aliveThenReply(let seconds, let text):
                    alive()
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    continuation.yield(text)
                    continuation.finish()
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination { calls.cancel(provider) }
                task.cancel()
            }
        }
    }
}

private func fakeRouter(_ calls: Calls, _ behaviors: [AIProvider: FakeBehavior]) -> AIRouter {
    AIRouter { provider in FakeEngine(provider: provider, behavior: behaviors[provider] ?? .fail(.notFound(provider)), calls: calls) }
}

private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var text = ""
    for try await piece in stream { text += piece }
    return text
}

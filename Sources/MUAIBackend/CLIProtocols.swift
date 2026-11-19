import Foundation

/// Событие из потокового вывода codex или claude.
package enum AIEvent: Equatable, Sendable {
    /// Кусок текста, пока ответ печатается (claude --include-partial-messages).
    case delta(String)
    /// Готовое сообщение модели целиком (codex agent_message, claude assistant).
    case message(String)
    /// Конец ответа; у claude — итоговый текст.
    case done(String?)
    /// Ошибка хода: дальше ответа не будет.
    case failure(String)
    /// Предупреждение (codex переподключается): ход продолжается, текст пригодится, если ответа так и не будет.
    case notice(String)
    /// Модель работает (codex `item.started` / `item.completed` — рассуждение, начало ответа), текста ещё нет.
    case progress
    /// Модель взялась за инструмент (команда, правка файла, MCP) — ответ отбрасывается. Значение — тип элемента.
    case tool(String)
}

/// Сборка ответа из событий: куски отдаются сразу; готовое сообщение — только если его куски не приходили.
/// `lastMessageOnly` (codex): сообщений за ход бывает несколько («Сейчас исправлю…», потом ответ) — отдаётся
/// только последнее и только в конце хода, иначе предисловие попало бы в документ вместе с исправленным текстом.
package struct AIAnswer: Equatable, Sendable {
    private(set) package var text = ""
    private var streamedSinceMessage = false
    private let lastMessageOnly: Bool
    private var lastMessage: String?
    private(set) package var finished = false
    private(set) package var failure: String?
    private(set) package var lastNotice: String?

    package init(lastMessageOnly: Bool = false) { self.lastMessageOnly = lastMessageOnly }

    /// Что отдать потребителю для этого события (nil — ничего).
    package mutating func consume(_ event: AIEvent) -> String? {
        switch event {
        case .delta(let piece):
            guard !piece.isEmpty else { return nil }
            streamedSinceMessage = true
            text += piece
            return piece
        case .message(let message):
            defer { streamedSinceMessage = false }
            if lastMessageOnly {
                if !message.isEmpty { lastMessage = message }
                return nil
            }
            guard !streamedSinceMessage, !message.isEmpty else { return nil }
            let piece = text.isEmpty ? message : "\n\n" + message
            text += piece
            return piece
        case .done(let result):
            finished = true
            guard text.isEmpty, let answer = lastMessage ?? result, !answer.isEmpty else { return nil }
            text = answer
            return answer
        case .failure(let message):
            failure = message
            return nil
        case .notice(let message):
            lastNotice = message
            return nil
        case .progress, .tool:
            return nil
        }
    }

    /// Программа закончила без конца хода: отдать последнее сообщение, если оно было (и ошибки не было).
    package mutating func flush() -> String? {
        guard lastMessageOnly, text.isEmpty, failure == nil, let lastMessage, !lastMessage.isEmpty else { return nil }
        text = lastMessage
        return lastMessage
    }
}

private func jsonLine(_ line: String) -> [String: Any]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("{") else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
}

// MARK: - Codex

/// `codex exec` (Codex CLI 0.16x): аргументы и разбор `--json` (JSONL-события).
package enum CodexCLI {
    /// Инструменты, которые выключаются: команды shell, просмотр картинок с диска, управление компьютером и браузером
    /// (в том числе внешним и через CDP), автоматизация Mac, подагенты, исполнение кода, генерация картинок, хуки,
    /// установка зависимостей навыков, плагины и приложения. Ответ — только текст: песочница «только чтение» не мешает
    /// читать `$HOME`. Имена проверены по `codex --disable … features list` (0.162.1): каждое становится `false`;
    /// неизвестное имя codex не принимает («Unknown feature flag»). `unified_exec` так не выключается (остаётся `true`) —
    /// от него защищает остановка на любом элементе, кроме ответа (`isTool`).
    package static let disabledFeatures = [
        "shell_tool", "view_image", "computer_use", "browser_use", "plugins", "apps",
        "multi_agent", "browser_use_external", "browser_use_full_cdp_access", "in_app_local_automation",
        "code_mode_host", "image_generation", "hooks", "skill_mcp_dependency_install",
    ]

    /// Аргументы: без сохранения сессии, без git-проверки, песочница «только чтение», рабочая папка — пустая,
    /// без инструментов (`--disable`), пользовательский config.toml и правила не читаются (вход — из CODEX_HOME).
    /// Картинки — `--image=<файл>`: с `=` значение одно, и следующий аргумент не принимается за ещё одну картинку.
    /// Запрос — со stdin (`-` последним аргументом).
    package static func arguments(request: AIRequest, workspace: String, model: String? = nil) -> [String] {
        // Картинки — сразу после exec: за ними всегда идёт флаг, а не `-` или другое значение.
        var arguments = ["exec"] + request.images.map { "--image=\($0.path)" }
        arguments += ["--json", "--color", "never", "--sandbox", "read-only", "--skip-git-repo-check",
                      "--ephemeral", "--ignore-user-config", "--ignore-rules", "--cd", workspace]
        arguments += disabledFeatures.flatMap { ["--disable", $0] }
        if request.quick { arguments += ["-c", "model_reasoning_effort=\"low\""] }
        if let model, !model.isEmpty { arguments += ["--model", model] }
        arguments.append("-")
        return arguments
    }

    /// `codex app-server` (тёплый процесс подсказчика). У app-server нет `--ignore-user-config` (есть у `exec`), поэтому
    /// всё из config.toml пользователя, что уводит вопрос не туда, переопределяется явно (`userConfigOverrides`), MCP-серверы
    /// выключаются по именам (`-c mcp_servers.<имя>.enabled=false`; `-c mcp_servers={}` их не убирает — таблицы сливаются),
    /// а то, что так не переопределить (свой адрес сервиса), проверяет `configRedirects`: тогда тёплого Codex нет.
    /// nil — тёплого Codex нет, вопрос идёт через `codex exec --ignore-user-config`: список MCP не получен (`mcpServers == nil`)
    /// или имя не записать ключом `-c` (точка, кавычки, пробел: имя в кавычках codex не понимает).
    package static func appServerArguments(mcpServers: [String]?) -> [String]? {
        guard let mcpServers, mcpServers.allSatisfy(isPlainKey) else { return nil }
        var arguments = ["app-server"]
        arguments += disabledFeatures.flatMap { ["--disable", $0] }
        arguments += userConfigOverrides.flatMap { ["-c", $0] }
        arguments += mcpServers.flatMap { ["-c", "mcp_servers.\($0).enabled=false"] }
        return arguments
    }

    /// Ключи config.toml, которые у тёплого процесса задаются явно (поверх файла пользователя). Имена сверены
    /// `codex app-server --strict-config --print-startup-config` (0.170.0, без запросов): неизвестный ключ там — ошибка.
    /// - `model_provider` — только OpenAI (не Ollama/`oss` и не свой провайдер);
    /// - `notify` — никакой внешней программе ход (то есть вопрос с расшифровкой) не передаётся;
    /// - `web_search` / `tools.web_search` — без поиска в сети;
    /// - `otel.*`, `analytics` — без отправки телеметрии с текстом запроса; `history` — история не пишется;
    /// - песочница «только чтение» и «ничего не спрашивать» (ещё и в каждой ветке `thread/start`).
    /// `profile` в config.toml эта версия codex не принимает (только `--profile`, а его нет).
    package static let userConfigOverrides = [
        #"model_provider="openai""#, "notify=[]", #"web_search="disabled""#, "tools.web_search=false",
        #"otel.exporter="none""#, #"otel.trace_exporter="none""#, #"otel.metrics_exporter="none""#, "otel.log_user_prompt=false",
        "analytics.enabled=false", #"history.persistence="none""#,
        #"sandbox_mode="read-only""#, #"approval_policy="never""#,
    ]

    /// Ключи config.toml, которые `-c` не обезвредить: свой адрес сервиса или свой провайдер. Есть хоть один — тёплого
    /// Codex нет (вопрос пойдёт через `exec`, который файл не читает). Смотрятся только имена ключей, значения не читаются.
    package static let redirectKeys: Set<String> = ["openai_base_url", "chatgpt_base_url", "model_providers"]

    /// Какие из `redirectKeys` есть в тексте config.toml: ключ верхнего уровня, `[model_providers…]` или `model_providers.x = …`.
    package static func configRedirects(toml: String) -> [String] {
        var found: [String] = []
        var table = ""
        for raw in toml.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                table = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).replacingOccurrences(of: "\"", with: "")
                let root = String(table.split(separator: ".").first ?? "")
                if redirectKeys.contains(root), !found.contains(root) { found.append(root) }
                continue
            }
            guard table.isEmpty, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            let root = String(key.split(separator: ".").first ?? "")
            if redirectKeys.contains(root), !found.contains(root) { found.append(root) }
        }
        return found
    }

    /// Где codex берёт config.toml: `$CODEX_HOME/config.toml`, иначе `~/.codex/config.toml`.
    package static func userConfigURL(environment: [String: String]) -> URL {
        let home = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (environment["HOME"] ?? NSHomeDirectory()) + "/.codex"
        return URL(fileURLWithPath: home).appendingPathComponent("config.toml")
    }

    /// `codex mcp list --json` с теми же `--disable` и `-c`, что у app-server: в списке только серверы, которые он поднял бы.
    package static var mcpListArguments: [String] {
        disabledFeatures.flatMap { ["--disable", $0] } + userConfigOverrides.flatMap { ["-c", $0] } + ["mcp", "list", "--json"]
    }

    /// Включённые MCP-серверы из `codex mcp list --json` (выключенные и так не стартуют, а встроенные выключенные
    /// по имени не адресуются). Не массив JSON — nil.
    package static func enabledMCPServers(listJSON: String) -> [String]? {
        guard let start = listJSON.firstIndex(of: "["),
              let list = (try? JSONSerialization.jsonObject(with: Data(listJSON[start...].utf8))) as? [[String: Any]] else { return nil }
        var names: [String] = []
        for entry in list {
            guard let name = entry["name"] as? String else { return nil }
            if entry["enabled"] as? Bool != false { names.append(name) }
        }
        return names
    }

    static func isPlainKey(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    /// Имена MCP-серверов из `codex mcp list --json` (массив объектов с `name`). Не массив JSON — nil (сбой списка:
    /// тогда тёплого Codex нет, а не «поднять все серверы из конфига»).
    package static func mcpServerNames(listJSON: String) -> [String]? {
        guard let start = listJSON.firstIndex(of: "["),
              let list = (try? JSONSerialization.jsonObject(with: Data(listJSON[start...].utf8))) as? [[String: Any]] else { return nil }
        let names = list.compactMap { $0["name"] as? String }
        return names.count == list.count ? names : nil
    }

    /// Быстрые модели для подсказчика по порядку. Замер менеджера на 1c6da07 (тёплый, effort low, первое слово, медиана):
    /// gpt-6-luna 7,3 с, gpt-6.2-sol 10,4 с. Берётся первая, что есть в каталоге этого codex и видна в списке; нет — nil.
    package static let fastModelPreference = ["gpt-6-luna", "gpt-6.2-sol"]

    /// Видимые модели из `codex debug models` (каталог без запросов к модели): `{"models":[{"slug","visibility",…}]}`.
    package static func listedModels(catalogJSON: String) -> [String] {
        guard let start = catalogJSON.firstIndex(of: "{"),
              let json = (try? JSONSerialization.jsonObject(with: Data(catalogJSON[start...].utf8))) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.filter { ($0["visibility"] as? String ?? "list") == "list" }.compactMap { $0["slug"] as? String }
    }

    package static func fastModel(listed: [String]) -> String? { fastModelPreference.first { listed.contains($0) } }

    /// Элементы `codex app-server` (v2, `ThreadItem.type`), которые не действуют: сообщения, рассуждение, план, сжатие
    /// истории. Всё остальное (команда, правка файла, MCP, веб-поиск, картинка, подагент…) — инструмент, ход останавливается.
    package static let appServerTextItems: Set<String> = ["userMessage", "agentMessage", "reasoning", "plan", "contextCompaction"]

    package static func isAppServerTool(_ kind: String) -> Bool { !appServerTextItems.contains(kind) }

    /// У `codex exec` нет системного текста: он идёт в начале запроса, отделённый от данных.
    package static func input(request: AIRequest) -> Data {
        let system = [request.system ?? AIRequest.defaultSystem, AIRequest.textOnly].joined(separator: "\n")
        return Data("\(system)\n\n---\n\n\(request.prompt)".utf8)
    }

    /// Элементы, которые не действуют: ответ, рассуждение, список шагов, ошибка. Всё остальное — инструмент.
    package static let textItems: Set<String> = ["agent_message", "assistant_message", "reasoning", "todo_list", "error"]

    /// Элемент-инструмент — белым списком: всё, что не `textItems` (команда, правка файла, MCP, веб-поиск, браузер
    /// и типы, которых ещё нет в этой версии codex). Ответ должен быть только текстом, поэтому незнакомое — тоже стоп.
    package static func isTool(_ kind: String) -> Bool { !textItems.contains(kind) }

    /// Строка `--json` → событие. Неизвестные события и не-JSON (предупреждения) — nil.
    /// `item.*` — признак жизни (`.progress`): у codex нет потоковых кусков, первый текст приходит вместе с готовым
    /// ответом, и ждать «первый кусок» — значит ждать весь ответ. `turn.started` жизнью не считается: он приходит
    /// сразу, ещё до связи с сервером (при обрыве сети дальше идут только «Reconnecting…»).
    package static func parse(_ line: String) -> AIEvent? {
        guard let json = jsonLine(line), let type = json["type"] as? String else { return nil }
        switch type {
        case "item.started", "item.updated", "item.completed":
            guard let item = json["item"] as? [String: Any], let kind = item["type"] as? String else { return .progress }
            if isTool(kind) { return .tool(kind) }
            guard type == "item.completed", kind == "agent_message" || kind == "assistant_message" else { return .progress }
            return .message(item["text"] as? String ?? "")
        case "turn.completed":
            return .done(nil)
        case "turn.failed":
            let error = json["error"] as? [String: Any]
            return .failure(error?["message"] as? String ?? "ход не удался")
        case "error":
            return .notice(json["message"] as? String ?? "ошибка")
        default:
            return nil
        }
    }

    /// `codex login status`: код 0 и нет «Not logged in».
    package static func isLoggedIn(status: Int32, output: String) -> Bool {
        status == 0 && !output.lowercased().contains("not logged in")
    }
}

// MARK: - Claude

/// `claude -p` (Claude Code 2.1): аргументы и разбор `--output-format stream-json`.
package enum ClaudeCLI {
    /// Аргументы: без инструментов (`--tools ""`), без MCP, хуков, плагинов и CLAUDE.md (`--safe-mode`),
    /// без сохранения сессии; системный текст — свой вместо текста для программирования.
    /// С картинками запрос идёт как stream-json (блоки image в base64), иначе — простой текст со stdin.
    package static func arguments(request: AIRequest, model: String? = nil) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        if !request.images.isEmpty { arguments += ["--input-format", "stream-json"] }
        arguments += safety + ["--system-prompt", [request.system ?? AIRequest.defaultSystem, AIRequest.textOnly].joined(separator: "\n")]
        if request.quick { arguments += ["--effort", "low"] }
        if let model, !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    /// Живая сессия (тёплый процесс подсказчика): те же запреты, что у `arguments`, вопросы — строками stream-json на stdin.
    package static func sessionArguments(system: String, model: String?, effort: String?) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        arguments += safety + ["--system-prompt", [system, AIRequest.textOnly].joined(separator: "\n")]
        if let effort, !effort.isEmpty { arguments += ["--effort", effort] }
        if let model, !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

    /// Без инструментов, MCP, хуков, плагинов, CLAUDE.md, команд и сохранения сессии.
    package static let safety = ["--tools", "", "--strict-mcp-config", "--safe-mode", "--disable-slash-commands", "--no-session-persistence"]

    /// Картинки, которые берёт API: тип по расширению.
    package static func mediaType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    /// stdin: текст запроса или одно сообщение stream-json с картинками и текстом.
    package static func input(request: AIRequest, read: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> Data {
        guard !request.images.isEmpty else { return Data(request.prompt.utf8) }
        var content: [[String: Any]] = []
        for url in request.images {
            guard let type = mediaType(for: url) else {
                throw AIFailure(.failed, provider: .claude, message: "Claude: картинка \(url.lastPathComponent) — не PNG, JPEG, GIF или WebP")
            }
            let data = try read(url)
            content.append(["type": "image", "source": ["type": "base64", "media_type": type, "data": data.base64EncodedString()]])
        }
        content.append(["type": "text", "text": request.prompt])
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        return data
    }

    /// Строка stream-json → событие.
    package static func parse(_ line: String) -> AIEvent? {
        guard let json = jsonLine(line), let type = json["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            guard let event = json["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
            return .delta(delta["text"] as? String ?? "")
        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return nil }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            return .message(text)
        case "result":
            let result = json["result"] as? String
            if json["is_error"] as? Bool == true || (json["subtype"] as? String).map({ $0 != "success" }) == true {
                let errors = (json["errors"] as? [String])?.joined(separator: "; ")
                return .failure(result ?? errors ?? (json["subtype"] as? String) ?? "ошибка")
            }
            return .done(result)
        default:
            return nil
        }
    }

    /// `claude auth status --json`: поле loggedIn; если его нет — код выхода.
    package static func isLoggedIn(status: Int32, output: String) -> Bool {
        if let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end,
           let json = (try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8))) as? [String: Any],
           let loggedIn = json["loggedIn"] as? Bool {
            return loggedIn
        }
        return status == 0 && !output.lowercased().contains("not logged in")
    }
}

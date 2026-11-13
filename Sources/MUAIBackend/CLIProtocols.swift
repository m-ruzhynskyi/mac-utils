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
}

/// Сборка ответа из событий: куски отдаются сразу; готовое сообщение — только если его куски не приходили.
package struct AIAnswer: Equatable, Sendable {
    private(set) package var text = ""
    private var streamedSinceMessage = false
    private(set) package var finished = false
    private(set) package var failure: String?
    private(set) package var lastNotice: String?

    package init() {}

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
            guard !streamedSinceMessage, !message.isEmpty else { return nil }
            let piece = text.isEmpty ? message : "\n\n" + message
            text += piece
            return piece
        case .done(let result):
            finished = true
            guard text.isEmpty, let result, !result.isEmpty else { return nil }
            text = result
            return result
        case .failure(let message):
            failure = message
            return nil
        case .notice(let message):
            lastNotice = message
            return nil
        }
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
    /// Аргументы: без сохранения сессии, без git-проверки, песочница «только чтение», рабочая папка — пустая,
    /// пользовательский config.toml и правила не читаются (вход в аккаунт — по-прежнему из CODEX_HOME).
    /// Картинки — `--image=<файл>`: с `=` значение одно, и следующий аргумент не принимается за ещё одну картинку.
    /// Запрос — со stdin (`-` последним аргументом).
    package static func arguments(request: AIRequest, workspace: String, model: String? = nil) -> [String] {
        // Картинки — сразу после exec: за ними всегда идёт флаг, а не `-` или другое значение.
        var arguments = ["exec"] + request.images.map { "--image=\($0.path)" }
        arguments += ["--json", "--color", "never", "--sandbox", "read-only", "--skip-git-repo-check",
                      "--ephemeral", "--ignore-user-config", "--ignore-rules", "--cd", workspace]
        if request.quick { arguments += ["-c", "model_reasoning_effort=\"low\""] }
        if let model, !model.isEmpty { arguments += ["--model", model] }
        arguments.append("-")
        return arguments
    }

    /// У `codex exec` нет системного текста: он идёт в начале запроса, отделённый от данных.
    package static func input(request: AIRequest) -> Data {
        let system = [request.system ?? AIRequest.defaultSystem, AIRequest.textOnly].joined(separator: "\n")
        return Data("\(system)\n\n---\n\n\(request.prompt)".utf8)
    }

    /// Строка `--json` → событие. Неизвестные события и не-JSON (предупреждения) — nil.
    package static func parse(_ line: String) -> AIEvent? {
        guard let json = jsonLine(line), let type = json["type"] as? String else { return nil }
        switch type {
        case "item.completed":
            guard let item = json["item"] as? [String: Any],
                  let kind = item["type"] as? String, kind == "agent_message" || kind == "assistant_message" else { return nil }
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
        arguments += ["--tools", "", "--strict-mcp-config", "--safe-mode", "--disable-slash-commands",
                      "--no-session-persistence",
                      "--system-prompt", [request.system ?? AIRequest.defaultSystem, AIRequest.textOnly].joined(separator: "\n")]
        if request.quick { arguments += ["--effort", "low"] }
        if let model, !model.isEmpty { arguments += ["--model", model] }
        return arguments
    }

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

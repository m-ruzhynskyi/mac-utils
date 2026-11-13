import Foundation

/// Сборка запроса к ИИ и разбор ответа. Без обращения к системе.
package enum CopilotPrompt {
    /// Сколько последних секунд расшифровки идёт в запрос.
    package static let contextSeconds: TimeInterval = 180
    /// Ответ модели, когда в расшифровке нет вопроса к пользователю.
    package static let noQuestionMarker = "NO_QUESTION"

    package static func languageName(_ code: String?) -> String? {
        CopilotSettings.languages.first { $0.code == code }?.title
    }

    /// Какую часть ответа просим: целиком или одну из двух (гибрид: первая строка — быстрой моделью, пункты — основной).
    package enum Part: Equatable { case full, sayOnly, pointsOnly }

    /// Первая строка не длиннее этого (знаков): её надо успеть сказать вслух.
    package static let maxSayLength = 140
    package static let maxSayWords = 20

    /// Первая строка для показа: если модель всё же длиннее 140 знаков или 20 слов — обрезаем по границе предложения,
    /// а если её нет — по слову с многоточием. Короткие строки не трогаем.
    package static func trimSay(_ say: String, maxLength: Int = maxSayLength, maxWords: Int = maxSayWords) -> String {
        let words = say.split(whereSeparator: \.isWhitespace)
        guard say.count > maxLength || words.count > maxWords else { return say }
        // Сначала пробуем закончить на предложении, которое помещается.
        var limited = say
        if words.count > maxWords { limited = words.prefix(maxWords).joined(separator: " ") }
        if limited.count > maxLength { limited = String(limited.prefix(maxLength)) }
        if let end = limited.lastIndex(where: { ".!?…".contains($0) }), limited.distance(from: limited.startIndex, to: end) >= 20 {
            return String(limited[...end])
        }
        // По слову: последнее слово целиком, без «висящих» знаков, и многоточие.
        var cut = limited
        if let space = cut.lastIndex(of: " "), cut.count < say.count { cut = String(cut[..<space]) }
        cut = cut.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:—-–"))
        return cut + "…"
    }

    package static func system(settings: CopilotSettings, part: Part = .full) -> String {
        var s = part == .full ? fullFormat : part == .sayOnly ? sayOnlyFormat : pointsOnlyFormat
        if let lang = answerLanguageInstruction(settings) { s += "\n" + lang }
        return s
    }

    private static let fullFormat = """
        Ты — подсказчик пользователя на живой встрече или собеседовании. Пользователь говорит с собеседниками, ты видишь расшифровку разговора \
        и подсказываешь, что ему ответить. Отвечай от его лица, коротко, по делу, без воды и без вступлений.

        Формат ответа строго такой:
        1) Первая строка — готовая фраза, которую можно сразу сказать вслух: одно предложение, НЕ БОЛЬШЕ 20 слов и не длиннее 140 знаков, без списков и кавычек.
        2) Затем 2–4 строки-пункта, каждая начинается с «- »: на что опереться, примеры, цифры, термины.

        Ответь ровно одним словом \(noQuestionMarker), если выполняется ХОТЯ БЫ ОДНО из условий:
        • последняя реплика собеседника — приветствие, светская беседа, вопрос «как дела», благодарность, шутка или утверждение;
        • собеседник что-то показывает или рассказывает, и просьбы ответить нет;
        • пользователь («Вы») уже ответил на этот вопрос по существу, а собеседник только кивает или подводит итог;
        • вопрос обращён не к пользователю.
        Сомневаешься, есть ли вопрос к пользователю, — \(noQuestionMarker).
        Не выдумывай факты о пользователе: опирайся только на блок «О себе и о встрече». Если данных не хватает, скажи это в пункте.
        """

    private static let sayOnlyFormat = """
        Ты — подсказчик пользователя на живой встрече или собеседовании. Ты видишь расшифровку разговора. Отвечай от лица пользователя.
        Ответь ОДНОЙ строкой: готовая фраза, которую можно сразу сказать вслух, одно предложение, НЕ БОЛЬШЕ 20 слов и не длиннее 140 знаков. Без списков, кавычек и пояснений.

        Ответь ровно одним словом \(noQuestionMarker), если выполняется ХОТЯ БЫ ОДНО из условий:
        • последняя реплика собеседника — приветствие, светская беседа, вопрос «как дела», благодарность, шутка или утверждение;
        • собеседник что-то показывает или рассказывает, и просьбы ответить нет;
        • пользователь («Вы») уже ответил на этот вопрос по существу, а собеседник только кивает или подводит итог;
        • вопрос обращён не к пользователю.
        Сомневаешься, есть ли вопрос к пользователю, — \(noQuestionMarker).
        Не выдумывай факты о пользователе: опирайся только на блок «О себе и о встрече».
        """

    private static let pointsOnlyFormat = """
        Ты — подсказчик пользователя на живой встрече или собеседовании. Ты видишь расшифровку разговора. Отвечай от лица пользователя.
        Ответь ТОЛЬКО 2–4 строками-пунктами, каждая начинается с «- »: на что опереться, примеры, цифры, термины. Без вступления и без готовой фразы.

        Ответь ровно одним словом \(noQuestionMarker), если выполняется ХОТЯ БЫ ОДНО из условий:
        • последняя реплика собеседника — приветствие, светская беседа, вопрос «как дела», благодарность, шутка или утверждение;
        • собеседник что-то показывает или рассказывает, и просьбы ответить нет;
        • пользователь («Вы») уже ответил на этот вопрос по существу, а собеседник только кивает или подводит итог;
        • вопрос обращён не к пользователю.
        Сомневаешься, есть ли вопрос к пользователю, — \(noQuestionMarker).
        Не выдумывай факты о пользователе: опирайся только на блок «О себе и о встрече».
        """

    private static func answerLanguageInstruction(_ settings: CopilotSettings) -> String? {
        if let code = settings.answerLanguage, let name = languageName(code) { return "Язык ответа: \(name)." }
        if let code = settings.meetingLanguage, let name = languageName(code) { return "Язык ответа: тот же, что на встрече — \(name)." }
        return "Язык ответа: тот же, на котором задан вопрос."
    }

    package enum Mode: Equatable {
        case lastQuestion
        case shorter
        case custom(String)
        case screen
    }

    /// Последние `contextSeconds` секунд, по строке на реплику: «Собеседник: …» / «Вы: …».
    package static func transcript(_ utterances: [Utterance], now: Date, maxChars: Int = 8000) -> String {
        let recent = utterances.filter { now.timeIntervalSince($0.at) <= contextSeconds }
        var lines = recent.map { ($0.speaker == .other ? "Собеседник: " : "Вы: ") + $0.text }
        var text = lines.joined(separator: "\n")
        while text.count > maxChars, lines.count > 1 { lines.removeFirst(); text = lines.joined(separator: "\n") }
        return text
    }

    package static func user(settings: CopilotSettings, utterances: [Utterance], now: Date, mode: Mode, previous: CopilotAnswer? = nil) -> String {
        var s = ""
        let about = settings.about.trimmingCharacters(in: .whitespacesAndNewlines)
        s += "О себе и о встрече:\n" + (about.isEmpty ? "(не указано)" : about) + "\n\n"
        s += "Расшифровка последних минут:\n" + transcript(utterances, now: now) + "\n\n"
        switch mode {
        case .lastQuestion:
            s += "Ответь на последний вопрос к пользователю."
        case .shorter:
            s += "Ответь на последний вопрос к пользователю ещё короче: фраза и не больше двух пунктов."
            if let previous, !previous.say.isEmpty { s += "\nПрошлый ответ был такой: \(previous.say)" }
        case .custom(let question):
            s += "Пользователь спрашивает сам: \(question)"
        case .screen:
            s += "К запросу приложен снимок экрана пользователя. Учти, что на нём, и ответь на последний вопрос или помоги с задачей на экране."
        }
        return s
    }

    // MARK: Разбор

    package enum Parsed: Equatable {
        case noQuestion
        case answer(CopilotAnswer)
    }

    /// Разбор накопленного (возможно, неполного) текста потока. Первая строка появляется, как только пришли её символы.
    package static func parse(_ raw: String) -> Parsed {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .answer(.empty) }
        if text == noQuestionMarker || (text.hasPrefix(noQuestionMarker) && text.count <= noQuestionMarker.count + 2) { return .noQuestion }
        // NO_QUESTION ещё дописывается: не показываем обрывок как фразу.
        if noQuestionMarker.hasPrefix(text) && text.count < noQuestionMarker.count { return .answer(.empty) }
        let lines = raw.components(separatedBy: "\n")
        var say = ""
        var points: [String] = []
        var sayComplete = false
        var seenSay = false
        for (i, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if seenSay { sayComplete = true }; continue }
            let isPoint = line.hasPrefix("- ") || line.hasPrefix("• ") || line.hasPrefix("* ") || line.hasPrefix("– ")
            if !seenSay && !isPoint {
                say = clean(line)
                seenSay = true
                sayComplete = i < lines.count - 1
            } else {
                if !isPoint, !seenSay { continue }
                sayComplete = true
                points.append(clean(isPoint ? String(line.dropFirst(2)) : line))
            }
        }
        return .answer(CopilotAnswer(say: say, points: Array(points.prefix(4)), sayComplete: sayComplete))
    }

    private static func clean(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["Скажите:", "Скажи:", "Say:"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        if s.count >= 2, (s.first == "«" && s.last == "»") || (s.first == "\"" && s.last == "\"") { s = String(s.dropFirst().dropLast()) }
        return s.replacingOccurrences(of: "**", with: "")
    }
}

/// Гибрид: первая строка от быстрой модели, пункты от основной; обе идут одновременно.
package struct HybridAnswer: Equatable {
    package private(set) var sayRaw = ""
    package private(set) var pointsRaw = ""
    package private(set) var sayDone = false
    package private(set) var pointsDone = false

    package init() {}

    package mutating func appendSay(_ piece: String) { sayRaw += piece }
    package mutating func appendPoints(_ piece: String) { pointsRaw += piece }
    package mutating func finishSay() { sayDone = true }
    package mutating func finishPoints() { pointsDone = true }

    /// Решение «нет вопроса» принимает любая из половин: пунктов без фразы не показываем.
    package var parsed: CopilotPrompt.Parsed {
        let say = CopilotPrompt.parse(sayRaw)
        if case .noQuestion = say { return .noQuestion }
        let points = CopilotPrompt.parse(pointsRaw)
        if case .noQuestion = points { return .noQuestion }
        var answer = CopilotAnswer.empty
        if case .answer(let s) = say {
            // Быстрая модель могла прислать и пункты — берём только фразу: пункты от основной.
            answer.say = s.say
            answer.sayComplete = sayDone || s.sayComplete
        }
        if case .answer(let p) = points {
            // Основная могла начать с фразы: пропускаем её, берём пункты.
            answer.points = p.points
        }
        return .answer(answer)
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
        return line(["id": id, "method": "turn/start", "params": params])
    }

    package static func codexReject(id: Any) -> Data {
        line(["id": id, "error": ["code": -32601, "message": "не поддерживается подсказчиком"]])
    }

    package enum CodexMessage: Equatable {
        case response(id: Int, threadID: String?, error: String?)
        case delta(threadID: String?, text: String)
        case completed(threadID: String?, failed: Bool, message: String?)
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

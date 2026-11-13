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

    package static func system(settings: CopilotSettings) -> String {
        var s = """
        Ты — подсказчик пользователя на живой встрече или собеседовании. Пользователь говорит с собеседниками, ты видишь расшифровку разговора \
        и подсказываешь, что ему ответить. Отвечай от его лица, коротко, по делу, без воды и без вступлений.

        Формат ответа строго такой:
        1) Первая строка — готовая фраза, которую можно сразу сказать вслух (1–2 предложения, без списков и кавычек).
        2) Затем 2–4 строки-пункта, каждая начинается с «- »: на что опереться, примеры, цифры, термины.
        Если в разговоре нет вопроса или просьбы к пользователю, ответь ровно одним словом: \(noQuestionMarker).
        Не выдумывай факты о пользователе: опирайся только на блок «О себе и о встрече». Если данных не хватает, скажи это в пункте.
        """
        if let lang = answerLanguageInstruction(settings) { s += "\n" + lang }
        return s
    }

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

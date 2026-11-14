import Foundation

/// Быстрое правило «это вопрос к вам»: по тексту собеседника, без обращения к модели.
/// Окончательное решение — за моделью в том же запросе, что и ответ (`NO_QUESTION`), поэтому правило может
/// ошибаться в сторону «похоже на вопрос».
package enum QuestionDetector {
    private static let starters: [String] = [
        // русский
        "как", "почему", "что", "зачем", "когда", "где", "какой", "какая", "какое", "какие", "каким", "сколько", "кто", "куда",
        "можете", "можешь", "расскажите", "расскажи", "объясните", "объясни", "опишите", "опиши", "приведите", "назовите", "скажите",
        "а как", "а почему", "а что", "чем", "для чего", "в чём", "в чем",
        // українська
        "як", "чому", "що", "навіщо", "коли", "де", "який", "яка", "яке", "які", "скільки", "хто", "куди",
        "можете", "розкажіть", "розкажи", "поясніть", "поясни", "опишіть", "наведіть", "назвіть", "скажіть",
        // English
        "how", "why", "what", "when", "where", "which", "who", "whom", "whose", "can you", "could you", "would you", "will you",
        "do you", "did you", "have you", "are you", "is there", "tell me", "explain", "describe", "walk me through", "give me",
    ]

    private static let inside: [String] = [
        "как бы вы", "что бы вы", "как вы", "что вы думаете", "как думаете", "ваш опыт", "ваше мнение",
        "як би ви", "що б ви", "як ви", "що ви думаєте", "як гадаєте",
        "how would you", "what would you", "how do you", "what do you think", "your experience", "your opinion",
    ]

    /// «Как видите…» и подобные — вводные слова, а не вопрос.
    private static let notQuestions: [String] = [
        "как видите", "как видно", "как известно", "как вы знаете", "как вы видите", "как я говорил", "как я уже", "как мы обсуждали", "как мы договорились",
        "як бачите", "як видно", "як відомо", "як ви знаєте", "як я казав", "як ми обговорювали",
        "as you can see", "as you know", "as we discussed", "as i said", "what i mean", "that's what",
    ]

    package static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    /// Похоже ли высказывание собеседника на вопрос к пользователю.
    package static func isQuestion(_ text: String, speaker: CopilotSpeaker = .other) -> Bool {
        guard speaker == .other else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let w = words(trimmed)
        guard w.count >= 3 else { return false }
        if trimmed.hasSuffix("?") { return true }
        let lower = trimmed.lowercased()
        if inside.contains(where: { lower.contains($0) }) { return true }
        // Вопрос — обычно последняя фраза; смотрим начало последнего предложения.
        let last = lastSentence(lower)
        let lw = words(last).joined(separator: " ")
        if notQuestions.contains(where: { lw.hasPrefix($0) }) { return false }
        return starters.contains { lw == $0 || lw.hasPrefix($0 + " ") }
    }

    /// Слова, на которых мысль не заканчивается.
    private static let dangling: Set<String> = [
        "и", "в", "на", "с", "со", "про", "о", "об", "к", "по", "для", "что", "чтобы", "если", "как", "а", "но", "или", "у", "из", "от", "ваш", "ваше", "вашем", "вашей", "ваших", "этом", "этой",
        "і", "й", "до", "з", "що", "якщо", "ваш", "вашому", "цьому",
        "the", "a", "an", "of", "to", "in", "on", "at", "with", "for", "about", "and", "or", "but", "if", "that", "your", "my", "our", "you", "usually", "how", "what", "this",
    ]

    /// Вопрос без «?» и без законченной мысли: короткий обрывок (до 4 слов) или фраза, оборванная на союзе, предлоге, «ваш».
    /// Такой кусок не отправляют сразу: вторая половина вопроса обычно приходит следом.
    package static func isIncomplete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !"?!.…".contains(last) else { return false }
        let w = words(trimmed)
        return w.count <= 4 || dangling.contains(w.last ?? "")
    }

    /// Последнее предложение (после . ! ?), чтобы «Хорошо. Как бы вы это сделали» нашлось.
    package static func lastSentence(_ text: String) -> String {
        let parts = text.split(whereSeparator: { ".!?…".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.last ?? text
    }

    /// Вопрос из окна расшифровки: последняя реплика собеседника, которая похожа на вопрос и после которой вы ещё не говорили.
    package static func pendingQuestion(in utterances: [Utterance]) -> Utterance? {
        for u in utterances.reversed() {
            if u.speaker == .me && words(u.text).count >= 4 { return nil }
            if isQuestion(u.text, speaker: u.speaker) { return u }
        }
        return nil
    }
}

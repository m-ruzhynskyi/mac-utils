import Foundation

/// Разбор ответов модели (без сети — для тестов).
package enum AIParsing {
    /// Первый JSON-объект в ответе: модели любят обрамлять его текстом или ```json.
    package static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let data = Data(text[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Имя файла из ответа: 2–6 слов, без кавычек, точек и запрещённых символов.
    package static func fileName(from answer: String, maxLength: Int = 60) -> String? {
        var line = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'«»`.")))
        for bad in ["/", ":", "\\", "*", "?", "<", ">", "|"] { line = line.replacingOccurrences(of: bad, with: " ") }
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if line.count > maxLength { line = String(line.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return line.count >= 2 ? line : nil
    }

    /// Ответ «как есть» без обрамляющих кавычек и пояснений вида «Исправленный текст:».
    package static func cleanedText(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Исправленный текст:", "Corrected text:", "Виправлений текст:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count > 1, let first = text.first, let last = text.last,
           (first == "\"" && last == "\"") || (first == "«" && last == "»") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// «ТекстовыеЗаметки» / «Счёт_Киевстар» → «Текстовые Заметки» / «Счёт Киевстар».
    package static func spaced(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for char in name.replacingOccurrences(of: "_", with: " ") {
            if let previous, char.isUppercase, previous.isLowercase { result.append(" ") }
            result.append(char)
            previous = char
        }
        return result
    }

    /// Регистр и пробелы по краям — как в исходном тексте (модель часто их теряет).
    package static func keepingEdges(of original: String, _ fixed: String) -> String {
        let leading = original.prefix { $0.isWhitespace }
        let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return leading + fixed.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
    }
}

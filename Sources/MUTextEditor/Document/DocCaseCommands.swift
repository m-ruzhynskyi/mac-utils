import AppKit

/// Регистр «Aa» на ленте (как «Регистр» в Word): меняются сами буквы, а не оформление — для `\caps` есть «Все прописные».
package enum DocCase: CaseIterable {
    case sentence, lower, upper, capitalized, toggle

    package var title: String {
        switch self {
        case .sentence: return "Как в предложениях"
        case .lower: return "все строчные"
        case .upper: return "ВСЕ ПРОПИСНЫЕ"
        case .capitalized: return "Начинать С Прописных"
        case .toggle: return "иЗМЕНИТЬ рЕГИСТР"
        }
    }

    /// Новый текст той же длины (UTF-16): буква, у которой другой регистр длиннее (ß → SS), остаётся как была —
    /// иначе разъехалась бы карта «символ ↔ исходник» у оформления. `startsSentence` — перед текстом конец предложения
    /// или начало абзаца (для «Как в предложениях»).
    package static func transform(_ text: String, _ mode: DocCase, startsSentence: Bool = true) -> String {
        var result = ""
        var sentenceStart = startsSentence, wordStart = true
        for character in text {
            var next: String
            switch mode {
            case .upper: next = character.uppercased()
            case .lower: next = character.lowercased()
            case .toggle: next = character.isUppercase ? character.lowercased() : character.uppercased()
            case .capitalized: next = wordStart ? character.uppercased() : character.lowercased()
            case .sentence: next = sentenceStart && character.isLetter ? character.uppercased() : character.lowercased()
            }
            if next.utf16.count != String(character).utf16.count { next = String(character) }
            result += next
            if character.isLetter || character.isNumber { sentenceStart = false }
            if ".!?…".contains(character) || character.isNewline { sentenceStart = true }
            wordStart = !(character.isLetter || character.isNumber || character == "'" || character == "’")
        }
        return result
    }
}

extension DocFormatter {
    /// Регистр выделения (без выделения — слова под курсором): одна правка файла и один шаг отмены. Оформление не меняется:
    /// у каждой изменившейся буквы переписывается только её кусок исходника (`\'hh` в кодовой странице её шрифта, ASCII,
    /// `\uN`), коды оформления вокруг остаются как были.
    package func changeCase(_ mode: DocCase) {
        guard let controller, let tab = controller.tab else { return }
        guard headerSession == nil else { return notify("Регистр в колонтитуле пока меняется в режиме «Код»") }
        let shown = controller.storage.mutableString
        let map = controller.rendering.map
        var units = controller.selectedUnits
        if units.length == 0 { units = LineCommands.word(shown, at: units.location) }
        units = NSIntersectionRange(units, NSRange(location: 0, length: min(shown.length, map.count)))
        guard units.length > 0 else { return notify("Выделите текст, у которого менять регистр") }

        let before = units.location == 0 ? "" : shown.substring(with: NSRange(location: max(0, units.location - 3), length: min(3, units.location)))
        let startsSentence = before.isEmpty || before.trimmingCharacters(in: .whitespaces).last.map { ".!?…\n\r\u{2029}".contains($0) } ?? true
        let changed = DocCase.transform(shown.substring(with: units), mode, startsSentence: startsSentence) as NSString

        var edits: [DocEdit] = []
        for offset in 0..<units.length {
            let unit = units.location + offset
            let old = shown.character(at: unit), new = changed.character(at: offset)
            guard old != new, map.kind(at: unit) == .text, !UTF16.isLeadSurrogate(old), !UTF16.isTrailSurrogate(old) else { continue }
            let source = map.range(at: unit)
            guard source.length > 0, NSMaxRange(source) <= tab.text.length else { continue }
            let props = (controller.storage.attribute(.docChar, at: unit, effectiveRange: nil) as? DocCharInfo)?.props
            let uc = DocTextEditor.run(atSource: source.location, story: controller.model.body)?.uc ?? 1
            let piece = DocTextEditor.encode(String(utf16CodeUnits: [new], count: 1), props: props, uc: uc, model: controller.model)
            guard !piece.isEmpty else { continue }
            edits.append(DocEdit(range: source, text: piece))
        }
        guard !edits.isEmpty else { return notify("Регистр уже такой") }
        let selection = units
        _ = controller.apply(edits, actionName: "Регистр") { _ in selection }
    }
}

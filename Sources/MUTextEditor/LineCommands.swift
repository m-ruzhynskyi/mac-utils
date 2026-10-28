import AppKit
import MUCore

/// Правка для `EditorTextView.replace`: диапазоны в координатах исходного текста и новое выделение.
package struct LineEdit: Equatable {
    package var ranges: [NSRange]
    package var strings: [String]
    package var selection: NSRange
}

/// Команды правки строк — чистые функции `(текст, выделение) → правка`; каждая применяется одним шагом отмены.
/// Перевод строки — CRLF, LF или CR (как в индексе строк), последняя строка может быть без перевода.
package enum LineCommands {
    /// Строки, которые задевает выделение: от начала первой до конца последней вместе с её переводом строки.
    /// Выделение, кончающееся в самом начале строки, эту строку не захватывает.
    package static func lineBlock(_ text: NSString, _ selection: NSRange) -> NSRange {
        var start = min(selection.location, text.length)
        // LF внутри CRLF принадлежит строке, которую CRLF заканчивает.
        if start > 0, start < text.length, text.character(at: start) == 0x0A, text.character(at: start - 1) == 0x0D { start -= 1 }
        while start > 0, !isBreak(text.character(at: start - 1)) { start -= 1 }
        var last = NSMaxRange(selection)
        if selection.length > 0, last > start, last <= text.length, isBreak(text.character(at: last - 1)) { last -= 1 }
        var end = min(max(last, start), text.length)
        while end < text.length, !isBreak(text.character(at: end)) { end += 1 }
        end += breakLength(text, at: end)
        return NSRange(location: start, length: end - start)
    }

    package static func isBreak(_ unit: UInt16) -> Bool { unit == 0x0A || unit == 0x0D }

    /// Длина перевода строки, начинающегося в `index` (0 — его там нет).
    package static func breakLength(_ text: NSString, at index: Int) -> Int {
        guard index < text.length else { return 0 }
        let unit = text.character(at: index)
        if unit == 0x0D { return index + 1 < text.length && text.character(at: index + 1) == 0x0A ? 2 : 1 }
        return unit == 0x0A ? 1 : 0
    }

    /// Текст блока без последнего перевода строки и сам перевод.
    private static func split(_ text: NSString, _ block: NSRange) -> (body: String, eol: String) {
        var bodyLength = block.length
        if bodyLength > 0, text.character(at: NSMaxRange(block) - 1) == 0x0A { bodyLength -= 1 }
        if bodyLength > 0, text.character(at: block.location + bodyLength - 1) == 0x0D { bodyLength -= 1 }
        return (text.substring(with: NSRange(location: block.location, length: bodyLength)),
                text.substring(with: NSRange(location: block.location + bodyLength, length: block.length - bodyLength)))
    }

    /// ⌘D: копия строк сразу под ними, курсор остаётся на месте.
    package static func duplicate(_ text: NSString, _ selection: NSRange, lineBreak: String) -> LineEdit? {
        let block = lineBlock(text, selection)
        let parts = split(text, block)
        let insertion = parts.eol.isEmpty ? lineBreak + parts.body : parts.body + parts.eol
        return LineEdit(ranges: [NSRange(location: NSMaxRange(block), length: 0)], strings: [insertion], selection: selection)
    }

    /// ⇧⌘K: удалить строки целиком. У последней строки без перевода убирается перевод перед ней.
    package static func delete(_ text: NSString, _ selection: NSRange, lineBreak: String) -> LineEdit? {
        guard text.length > 0 else { return nil }
        var block = lineBlock(text, selection)
        if split(text, block).eol.isEmpty, block.location > 0 {
            var start = block.location - 1
            if start > 0, text.character(at: start) == 0x0A, text.character(at: start - 1) == 0x0D { start -= 1 }
            block = NSRange(location: start, length: NSMaxRange(block) - start)
            let lineStart = lineBlock(text, NSRange(location: start, length: 0)).location
            return LineEdit(ranges: [block], strings: [""], selection: NSRange(location: lineStart, length: 0))
        }
        return LineEdit(ranges: [block], strings: [""], selection: NSRange(location: block.location, length: 0))
    }

    /// ⌥↑ / ⌥↓: строки меняются местами с соседней; переводы строк остаются на своих местах (последняя строка
    /// так и остаётся без перевода). На краю текста — ничего.
    package static func move(_ text: NSString, _ selection: NSRange, up: Bool) -> LineEdit? {
        let block = lineBlock(text, selection)
        if up {
            guard block.location > 0 else { return nil }
            let previous = lineBlock(text, NSRange(location: block.location - 1, length: 0))
            let top = split(text, previous), bottom = split(text, block)
            let whole = NSRange(location: previous.location, length: NSMaxRange(block) - previous.location)
            let string = bottom.body + top.eol + top.body + bottom.eol
            let shift = selection.location - block.location
            return LineEdit(ranges: [whole], strings: [string],
                            selection: NSRange(location: previous.location + shift, length: selection.length))
        }
        guard NSMaxRange(block) < text.length else { return nil }
        let next = lineBlock(text, NSRange(location: NSMaxRange(block), length: 0))
        let top = split(text, block), bottom = split(text, next)
        let whole = NSRange(location: block.location, length: NSMaxRange(next) - block.location)
        let string = bottom.body + top.eol + top.body + bottom.eol
        let newStart = block.location + (bottom.body as NSString).length + (top.eol as NSString).length
        return LineEdit(ranges: [whole], strings: [string],
                        selection: NSRange(location: newStart + selection.location - block.location, length: selection.length))
    }

    /// Пробелы и табы в конце строк (всего текста или выделенных строк). Начальные остаются.
    package static func trimTrailingWhitespace(_ text: NSString, _ selection: NSRange, lineBreak: String) -> LineEdit? {
        let scope = selection.length > 0 ? lineBlock(text, selection) : NSRange(location: 0, length: text.length)
        var ranges: [NSRange] = []
        var index = scope.location
        let end = NSMaxRange(scope)
        while index <= end {
            var lineEnd = index
            while lineEnd < end, !isBreak(text.character(at: lineEnd)) { lineEnd += 1 }
            var trim = lineEnd
            while trim > index, [0x20, 0x09].contains(text.character(at: trim - 1)) { trim -= 1 }
            if trim < lineEnd { ranges.append(NSRange(location: trim, length: lineEnd - trim)) }
            guard lineEnd < end else { break }
            index = lineEnd + max(1, breakLength(text, at: lineEnd))
        }
        guard !ranges.isEmpty else { return nil }
        let removedBefore = ranges.filter { NSMaxRange($0) <= selection.location }.reduce(0) { $0 + $1.length }
        let removedInside = ranges.filter { $0.location >= selection.location && NSMaxRange($0) <= NSMaxRange(selection) }
            .reduce(0) { $0 + $1.length }
        return LineEdit(ranges: ranges, strings: Array(repeating: "", count: ranges.count),
                        selection: NSRange(location: max(0, selection.location - removedBefore),
                                           length: max(0, selection.length - removedInside)))
    }

    // MARK: - Сортировка, дубли, табы

    /// Строки, к которым применяется команда: выделенные (если выделение есть) или весь текст.
    /// Возвращает тела строк и их переводы строк по порядку (у последней может не быть).
    package static func lines(_ text: NSString, _ selection: NSRange) -> (range: NSRange, bodies: [String], breaks: [String]) {
        let range = selection.length > 0 ? lineBlock(text, selection) : NSRange(location: 0, length: text.length)
        var bodies: [String] = [], breaks: [String] = []
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            var stop = index
            while stop < end, !isBreak(text.character(at: stop)) { stop += 1 }
            let eol = min(breakLength(text, at: stop), end - stop)
            bodies.append(text.substring(with: NSRange(location: index, length: stop - index)))
            breaks.append(text.substring(with: NSRange(location: stop, length: eol)))
            index = stop + max(eol, stop == end ? 1 : 0)
        }
        return (range, bodies, breaks)
    }

    /// Собрать строки обратно: переводы строк остаются на своих местах (последняя строка — как была, без перевода).
    private static func joined(_ bodies: [String], _ breaks: [String]) -> String {
        zip(bodies, breaks).map { $0 + $1 }.joined()
    }

    private static func edit(_ text: NSString, _ selection: NSRange, _ transform: ([String]) -> [String]) -> LineEdit? {
        let parts = lines(text, selection)
        guard parts.bodies.count > 1 else { return nil }
        var bodies = transform(parts.bodies)
        var breaks = parts.breaks
        // Строк стало меньше (удалены дубли) — лишние переводы строк уходят с конца, последний остаётся как был.
        if bodies.count < breaks.count {
            let last = breaks.last ?? ""
            breaks = Array(breaks.prefix(bodies.count))
            if !breaks.isEmpty { breaks[breaks.count - 1] = last }
        }
        bodies = Array(bodies.prefix(breaks.count))
        let result = joined(bodies, breaks)
        guard result != text.substring(with: parts.range) else { return nil }
        return LineEdit(ranges: [parts.range], strings: [result],
                        selection: selection.length > 0 ? NSRange(location: parts.range.location, length: (result as NSString).length)
                                                        : NSRange(location: min(selection.location, parts.range.location + (result as NSString).length), length: 0))
    }

    package enum SortOrder { case ascending, descending, caseInsensitive }

    /// Сортировка строк (стабильная: равные остаются в прежнем порядке). А→Я и Я→А — с учётом регистра.
    package static func sort(_ text: NSString, _ selection: NSRange, _ order: SortOrder) -> LineEdit? {
        edit(text, selection) { bodies in
            let indexed = Array(bodies.enumerated())
            let sorted = indexed.sorted { a, b in
                let result: ComparisonResult
                switch order {
                case .ascending, .descending: result = a.element.compare(b.element, options: [], range: nil, locale: Locale.current)
                case .caseInsensitive: result = a.element.compare(b.element, options: [.caseInsensitive], range: nil, locale: Locale.current)
                }
                if result == .orderedSame { return a.offset < b.offset }
                return order == .descending ? result == .orderedDescending : result == .orderedAscending
            }
            return sorted.map(\.element)
        }
    }

    /// Удалить повторяющиеся строки: остаётся первая. Без учёта регистра `beta` и `Beta` — одна строка.
    package static func removeDuplicates(_ text: NSString, _ selection: NSRange, caseSensitive: Bool) -> LineEdit? {
        edit(text, selection) { bodies in
            var seen = Set<String>()
            return bodies.filter { seen.insert(caseSensitive ? $0 : $0.lowercased()).inserted }
        }
    }

    /// Табы → N пробелов и обратно (каждые N пробелов подряд → таб): обратимо. Выделенные строки или весь текст.
    package static func tabsToSpaces(_ text: NSString, _ selection: NSRange, width: Int) -> LineEdit? {
        replaceInLines(text, selection) { $0.replacingOccurrences(of: "\t", with: String(repeating: " ", count: max(1, width))) }
    }

    package static func spacesToTabs(_ text: NSString, _ selection: NSRange, width: Int) -> LineEdit? {
        replaceInLines(text, selection) { $0.replacingOccurrences(of: String(repeating: " ", count: max(1, width)), with: "\t") }
    }

    private static func replaceInLines(_ text: NSString, _ selection: NSRange, _ transform: (String) -> String) -> LineEdit? {
        let parts = lines(text, selection)
        let result = joined(parts.bodies.map(transform), parts.breaks)
        guard result != text.substring(with: parts.range) else { return nil }
        let length = (result as NSString).length
        return LineEdit(ranges: [parts.range], strings: [result],
                        selection: selection.length > 0 ? NSRange(location: parts.range.location, length: length)
                                                        : NSRange(location: min(selection.location, parts.range.location + length), length: 0))
    }

    package enum Case { case upper, lower, sentence }

    /// Регистр выделения (без выделения — слова под курсором).
    package static func changeCase(_ text: NSString, _ selection: NSRange, _ mode: Case) -> LineEdit? {
        var range = selection
        if range.length == 0 { range = word(text, at: selection.location) }
        guard range.length > 0 else { return nil }
        let source = text.substring(with: range)
        let result: String
        switch mode {
        case .upper: result = source.uppercased()
        case .lower: result = source.lowercased()
        case .sentence: result = sentenceCase(source)
        }
        guard result != source || (result as NSString).length != (source as NSString).length else { return nil }
        return LineEdit(ranges: [range], strings: [result],
                        selection: NSRange(location: range.location, length: (result as NSString).length))
    }

    /// «Как в предложении»: всё строчными, первая буква каждого предложения — заглавная.
    package static func sentenceCase(_ text: String) -> String {
        var result = ""
        var capitalize = true
        for character in text.lowercased() {
            if capitalize, character.isLetter {
                result += character.uppercased()
                capitalize = false
            } else {
                result.append(character)
            }
            if ".!?".contains(character) || character.isNewline { capitalize = true }
        }
        return result
    }

    /// Слово (буквы, цифры, `_`) вокруг смещения.
    package static func word(_ text: NSString, at offset: Int) -> NSRange {
        func isWord(_ index: Int) -> Bool {
            guard index >= 0, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_"
        }
        var start = min(offset, text.length), end = start
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}

extension EditorTab {
    /// Применить команду правки одним шагом отмены.
    package func apply(_ command: (NSString, NSRange, String) -> LineEdit?, name: String) {
        guard let edit = command(text, textView.selectedRange(), textView.lineBreak) else {
            Feedback.beep()
            return
        }
        guard textView.replace(edit.ranges, with: edit.strings, actionName: name) else { return }
        textView.setSelectedRange(NSIntersectionRange(edit.selection, NSRange(location: 0, length: storage.length)).length == edit.selection.length
                                  ? edit.selection : NSRange(location: min(edit.selection.location, storage.length), length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    package func apply(_ command: (NSString, NSRange) -> LineEdit?, name: String) {
        apply({ text, selection, _ in command(text, selection) }, name: name)
    }
}

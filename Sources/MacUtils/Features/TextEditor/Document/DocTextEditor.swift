import Foundation

/// Правка текста в «Документе» → точечные правки исходника (план, § 3.2). Байты вне правок не трогаются по
/// построению: каждая правка — свой кусок исходника. Чистая функция — проверяется без окон.
enum DocTextEditor {
    struct Result: Equatable {
        var edits: [DocEdit] = []
        /// Место исходника, перед которым встанет курсор после правки (в координатах ПОСЛЕ правки).
        var caretSource = 0
        /// Показанные единицы, которые удалены (для проверок).
        var deletedUnits: [Int] = []
        /// Где в показанном тексте до правки встаёт набранное.
        var insertionUnit = 0
        /// Почему правку сделать нельзя (подсказка вместо правки).
        var refusal: String?
    }

    static let codeHint = "Изменить это можно в режиме «Код»"

    /// Заменить показанные единицы `units` текстом `text` (пустой — удаление). `story` — чей это текст: основной
    /// (по умолчанию) или колонтитул (тогда `map` — его карта).
    static func replace(_ units: NSRange, with text: String, model: RTFDocumentModel, story: RTFStory? = nil, map: DocSourceMap,
                        source: NSString) -> Result {
        let story = story ?? model.body
        var result = Result()
        let range = NSRange(location: min(units.location, map.count), length: max(0, min(NSMaxRange(units), map.count) - min(units.location, map.count)))
        var deletions: [NSRange] = []
        var fieldsDeleted = Set<Int>()
        var unit = range.location
        while unit < NSMaxRange(range) {
            let kind = map.kind(at: unit)
            let piece = map.range(at: unit)
            switch kind {
            case .text, .tab, .lineBreak, .hidden, .pageBreak:
                deletions.append(piece)
                result.deletedUnits.append(unit)
            case .paragraphEnd:
                if let merge = paragraphMerge(endingAt: piece, story: story) {
                    deletions.append(piece)
                    deletions.append(contentsOf: merge)
                    result.deletedUnits.append(unit)
                }
            case .field:
                // Поле (номер страницы) — неделимо: удаляется целиком, только если выделено.
                if let field = model.fields.firstIndex(where: { NSLocationInRange(piece.location, $0.group) && $0.kind.isComputed }) {
                    if !fieldsDeleted.contains(field) {
                        fieldsDeleted.insert(field)
                        deletions.append(model.fields[field].group)
                    }
                    result.deletedUnits.append(unit)
                }
            case .cellEnd, .sectionEnd, .storyEnd, .sectionBreak, .listText, .object:
                // Ячейки, разделы, рисунки и фигуры остаются (как в Word: стирается только текст ячеек).
                break
            }
            unit += 1
        }
        deletions = merged(deletions)
        // Ввод: куда встаёт текст и чем его записать.
        let insertion = insertionPoint(range, model: model, story: story, map: map)
        result.insertionUnit = insertion.unit
        if text.isEmpty {
            guard !deletions.isEmpty else {
                result.refusal = range.length > 0 ? refusalReason(range, map: map) : nil
                return result
            }
            result.edits = deletions.map { DocEdit(range: $0, text: delimiterAfterRemoval($0, source: source) ? " " : "") }
        } else {
            var encoded = encode(text, props: insertion.run?.props ?? insertion.paragraphEnd?.endProps,
                                 uc: insertion.run?.uc ?? insertion.paragraphEnd?.endUC ?? 1, model: model)
            // Пустой абзац со скрытым знаком конца: набранное иначе было бы невидимым.
            if insertion.run == nil, insertion.paragraphEnd?.endProps.hidden == true { encoded = "{\\v0 " + encoded + "}" }
            let prefix = needsDelimiter(before: insertion.source, source: source) ? " " : ""
            var edits = deletions.map { DocEdit(range: $0, text: "") }
            // Набранное — на месте первого удалённого куска (его свойства), иначе — отдельной вставкой.
            if let index = edits.firstIndex(where: { $0.range.location == insertion.source }) {
                edits[index].text = prefix + encoded
            } else {
                edits.append(DocEdit(range: NSRange(location: insertion.source, length: 0), text: prefix + encoded))
            }
            // Пустая вставка рядом с удалением в той же точке — склеить (куски не должны пересекаться).
            edits.sort { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
            var combined: [DocEdit] = []
            for edit in edits {
                if let last = combined.last, NSMaxRange(last.range) >= edit.range.location, last.range.location <= edit.range.location {
                    let union = NSUnionRange(last.range, edit.range)
                    combined[combined.count - 1] = DocEdit(range: union, text: last.text + edit.text)
                } else {
                    combined.append(edit)
                }
            }
            result.edits = combined
        }
        // Курсор — сразу после правки, в которой место ввода (набранное или удалённое), со сдвигом от правок левее.
        let edits = result.edits.sorted { $0.range.location < $1.range.location }
        if let anchor = edits.first(where: { $0.range.location <= insertion.source && insertion.source <= NSMaxRange($0.range) }) {
            let shift = edits.filter { $0.range.location < anchor.range.location }
                .reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
            result.caretSource = anchor.range.location + shift + (anchor.text as NSString).length
        } else {
            // Место ввода не тронуто (например, перед оставшейся заглушкой) — оно же, со сдвигом от правок левее.
            let shift = edits.filter { NSMaxRange($0.range) <= insertion.source }
                .reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
            result.caretSource = insertion.source + shift
        }
        return result
    }

    private static func refusalReason(_ range: NSRange, map: DocSourceMap) -> String? {
        for unit in range.location..<NSMaxRange(range) {
            switch map.kind(at: unit) {
            case .object: return "Рисунки и фигуры не правятся в «Документе». " + codeHint
            case .cellEnd: return "Ячейки таблиц не удаляются в этом выпуске. " + codeHint
            case .sectionEnd, .sectionBreak: return "Разрыв раздела не удаляется в «Документе». " + codeHint
            case .listText: return "Номера списков правятся в следующем выпуске. " + codeHint
            case .paragraphEnd: return "Абзацы таблицы и текста не склеиваются. " + codeHint
            default: continue
            }
        }
        return nil
    }

    // MARK: - Склейка абзацев

    /// Удаление `\par` склеивает абзацы; свойства — от первого (как в Word): у второго убираются его `\pard` и коды
    /// свойств перед текстом. Через границу таблицы — нельзя (`nil`).
    static func paragraphMerge(endingAt end: NSRange, story: RTFStory) -> [NSRange]? {
        let paragraphs = story.paragraphs
        guard let index = paragraphs.firstIndex(where: { $0.endRange == end && $0.end == .paragraph }) else { return [] }
        let first = paragraphs[index]
        guard index + 1 < paragraphs.count else { return [] }
        let second = paragraphs[index + 1]
        // Разные ячейки или таблица ↔ текст — не склеиваем.
        if first.props.inTable != second.props.inTable { return nil }
        if let a = first.cell, let b = second.cell, a != b { return nil }
        if first.props.inTable, first.cell == nil || second.cell == nil { return nil }
        let start = second.regionStart, contentStart = second.contentStart
        var tokens: [NSRange] = []
        if let pard = second.pard, pard.location >= start, NSMaxRange(pard) <= contentStart { tokens.append(pard) }
        for token in second.propTokens.values where token.location >= start && NSMaxRange(token) <= contentStart && token.location != end.location {
            tokens.append(token)
        }
        return tokens
    }

    // MARK: - Где вставлять

    struct Insertion {
        var source: Int
        var unit: Int
        /// Прогон, свойства которого получит набранное (для кодовой страницы и `\uc`).
        var run: RTFRun?
        /// Пустой абзац: свойства символа у его конца (прогонов нет).
        var paragraphEnd: RTFParagraph?
    }

    static func insertionPoint(_ range: NSRange, model: RTFDocumentModel, story: RTFStory, map: DocSourceMap) -> Insertion {
        func run(atSource location: Int, model: RTFDocumentModel) -> RTFRun? { Self.run(atSource: location, story: story) }
        func lastRun(before location: Int, model: RTFDocumentModel) -> RTFRun? { Self.lastRun(before: location, story: story) }
        var unit = range.location
        // Выделение: на место первой удаляемой единицы (её свойства), иначе — как курсор в начале выделения.
        if range.length > 0 {
            for candidate in range.location..<NSMaxRange(range) where map.kind(at: candidate).isEditable {
                return Insertion(source: map.range(at: candidate).location, unit: candidate, run: run(atSource: map.range(at: candidate).location, model: model))
            }
            unit = range.location
        }
        let count = map.count
        // Курсор перед разрывом раздела или страницы в начале абзаца: набранное — после разрыва, в начало абзаца.
        while unit < count - 1, [.sectionBreak, .pageBreak].contains(map.kind(at: unit)), unit == 0 || !map.kind(at: unit - 1).isEditable {
            unit += 1
        }
        let previous = unit > 0 ? map.kind(at: unit - 1) : nil
        let next = unit < count ? map.kind(at: unit) : nil
        // Внутри или на границе неделимого поля — снаружи поля.
        if previous == .field, let field = fieldIndex(at: map.range(at: unit - 1), model: model) {
            if next == .field, let nextField = fieldIndex(at: map.range(at: unit), model: model), nextField == field {
                let end = NSMaxRange(model.fields[field].group)
                return Insertion(source: end, unit: unit, run: run(atSource: map.range(at: unit - 1).location, model: model))
            }
            return Insertion(source: NSMaxRange(model.fields[field].group), unit: unit, run: run(atSource: map.range(at: unit - 1).location, model: model))
        }
        if next == .field, let field = fieldIndex(at: map.range(at: unit), model: model) {
            return Insertion(source: model.fields[field].group.location, unit: unit, run: run(atSource: map.range(at: unit).location, model: model))
        }
        // После символа того же абзаца — сразу за ним (его свойства); иначе — перед следующей единицей.
        if let previous, previous.isEditable {
            let location = NSMaxRange(map.range(at: unit - 1))
            return Insertion(source: location, unit: unit, run: run(atSource: map.range(at: unit - 1).location, model: model))
        }
        if unit < count {
            let piece = map.range(at: unit)
            // Перед заглушкой — перед её группой; перед концом пустого абзаца — перед его кодом, со свойствами ¶.
            if [.paragraphEnd, .cellEnd, .sectionEnd, .storyEnd].contains(map.kind(at: unit)),
               let paragraph = story.paragraphs.first(where: { $0.endRange == piece }) {
                return Insertion(source: piece.location, unit: unit, run: nil, paragraphEnd: paragraph)
            }
            return Insertion(source: piece.location, unit: unit, run: run(atSource: piece.location, model: model) ?? lastRun(before: piece.location, model: model))
        }
        let end = count > 0 ? NSMaxRange(map.range(at: count - 1)) : NSMaxRange(story.range)
        return Insertion(source: end, unit: unit, run: lastRun(before: end, model: model))
    }

    private static func fieldIndex(at piece: NSRange, model: RTFDocumentModel) -> Int? {
        model.fields.firstIndex { NSLocationInRange(piece.location, $0.group) && $0.kind.isComputed }
    }

    /// Прогон, в котором лежит место исходника.
    static func run(atSource location: Int, story: RTFStory) -> RTFRun? {
        for paragraph in story.paragraphs {
            if let first = paragraph.runs.first?.map.first, first.location > location { return nil }
            for run in paragraph.runs where run.map.contains(where: { NSLocationInRange(location, $0) }) { return run }
        }
        return nil
    }

    private static func lastRun(before location: Int, story: RTFStory) -> RTFRun? {
        var found: RTFRun?
        for paragraph in story.paragraphs {
            for run in paragraph.runs {
                guard let first = run.map.first, first.location < location else { return found }
                found = run
            }
        }
        return found
    }

    // MARK: - Кодирование набранного

    /// Текст → RTF: `\'hh` в кодовой странице шрифта (как пишет Word), иначе `\uN` с заменителями по `\ucN`.
    static func encode(_ text: String, props: RTFCharProps?, uc: Int, model: RTFDocumentModel) -> String {
        let font = model.font(props?.font)
        let encoding = RTFReader.encoding(charset: font?.charset ?? 0, codePage: font?.codePage, document: model.codePage)
        let table = SingleByteTable.table(for: encoding)
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x2029: out += "\\par "
            case 0x2028, 0x0B: out += "\\line "
            case 0x09: out += "\\tab "
            case 0x5C: out += "\\\\"
            case 0x7B: out += "\\{"
            case 0x7D: out += "\\}"
            case 0xA0: out += "\\~"
            case 0xAD: out += "\\-"
            case 0x2011: out += "\\_"
            case 0x20..<0x7F: out.unicodeScalars.append(scalar)
            case 0..<0x20, 0x7F: continue
            default:
                if let byte = table?.byte(for: scalar.value), byte >= 0x80 {
                    out += String(format: "\\'%02x", byte)
                } else {
                    for unit in String(scalar).utf16 {
                        out += "\\u\(Int16(bitPattern: unit))" + (uc == 0 ? " " : String(repeating: "\\'3f", count: uc))
                    }
                }
            }
        }
        return out
    }

    // MARK: - Разделители управляющих слов

    /// Место сразу после управляющего слова без разделителя (`\b0|`, `\cf2|`): вставка буквы, цифры или пробела
    /// изменила бы само слово или потерялась бы как разделитель — нужен пробел.
    static func needsDelimiter(before location: Int, source: NSString) -> Bool {
        guard location > 0, location <= source.length else { return false }
        // Управляющее слово — `\` + буквы + необязательное число со знаком. Буквы после цифр — уже текст (`\cf2x`).
        var index = location - 1
        while index >= 0, isDigit(source.character(at: index)) { index -= 1 }
        if index >= 0, index < location - 1, source.character(at: index) == 0x2D { index -= 1 }
        let lettersEnd = index
        while index >= 0, isLetter(source.character(at: index)) { index -= 1 }
        guard lettersEnd > index, index >= 0, source.character(at: index) == 0x5C else { return false }
        // `\\word`: обратная косая черта сама экранирована — это не управляющее слово.
        var slashes = 0
        var back = index
        while back >= 0, source.character(at: back) == 0x5C {
            slashes += 1
            back -= 1
        }
        return slashes % 2 == 1
    }

    /// После удаления куска соседями станут управляющее слово без разделителя и буква или цифра — склеились бы.
    static func delimiterAfterRemoval(_ range: NSRange, source: NSString) -> Bool {
        let after = NSMaxRange(range)
        guard after < source.length, needsDelimiter(before: range.location, source: source) else { return false }
        let next = source.character(at: after)
        return isLetter(next) || isDigit(next) || next == 0x2D || next == 0x20
    }

    private static func isLetter(_ unit: UInt16) -> Bool { (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit) }
    private static func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

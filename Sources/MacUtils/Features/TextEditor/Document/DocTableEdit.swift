import Foundation

/// Правка таблиц в «Документе» (E-1): вставить и удалить строку, Tab по ячейкам. Чистые функции — проверяются без
/// окон; результат — точечные правки исходника, байты вне правки не трогаются.
///
/// Строка в исходнике — от её `\trowd` до `\row` и закрывающих скобок групп, открытых внутри (Word пишет определение
/// строки ещё раз в конце: `{… \trowd … \row \ltrrow}`). Кусок строки сбалансирован по скобкам: его можно копировать и
/// вырезать целиком, структура соседей не меняется.
enum DocTableEdit {
    struct Result: Equatable {
        var edits: [DocEdit] = []
        /// Куда поставить курсор после правки (место исходника в координатах ПОСЛЕ правки).
        var caretSource = 0
        var refusal: String?
    }

    static let structureHint = "Строку этой таблицы не изменить без потерь. " + DocTextEditor.codeHint

    // MARK: - Где строка

    /// Абзацы строки `row` таблицы `table` (по порядку в истории).
    static func paragraphs(table: Int, row: Int, story: RTFStory) -> [Int] {
        story.tables[safe: table]?.rows[safe: row]?.paragraphs.flatMap { $0 } ?? []
    }

    /// Кусок исходника строки: от `\trowd` перед её первым абзацем (или начала области абзаца) до `\row` и скобок,
    /// закрывающих открытые внутри группы. `nil` — кусок не сбалансирован (такую строку не трогаем).
    static func rowSpan(table: Int, row: Int, story: RTFStory, source: NSString) -> NSRange? {
        guard let definition = story.tables[safe: table]?.rows[safe: row], let first = paragraphs(table: table, row: row, story: story).first,
              let paragraph = story.paragraphs[safe: first], definition.endRange.length > 0 else { return nil }
        // Область абзаца начинается сразу после последнего `\cell` предыдущей строки: в ней ещё хвост той строки
        // (`… \row …}`). Начало этой — первый `\trowd` после последнего `\row`, иначе — после `\row` и его скобок.
        let regionEnd = paragraph.contentStart
        var start = paragraph.regionStart
        if regionEnd > start {
            let tokens = RTFLexer.tokens(source, in: NSRange(location: start, length: regionEnd - start))
            let afterRow = (tokens.lastIndex { $0.kind == .word && $0.name == "row" }).map { $0 + 1 } ?? 0
            if let trowd = tokens[afterRow...].first(where: { $0.kind == .word && $0.name == "trowd" }) {
                start = trowd.range.location
            } else if afterRow > 0 {
                // Хвост предыдущей строки: скобки, переводы строк, пробелы, `\ltrrow`/`\rtlrow`.
                func tail(_ token: RTFToken) -> Bool {
                    switch token.kind {
                    case .close, .newline: return true
                    case .word: return token.name == "ltrrow" || token.name == "rtlrow"
                    case .text: return source.character(at: token.range.location) == 0x20
                    default: return false
                    }
                }
                let index = tokens[afterRow...].firstIndex { !tail($0) } ?? tokens.count
                start = index < tokens.count ? tokens[index].range.location : regionEnd
            }
        }
        var end = NSMaxRange(definition.endRange)
        guard end > start, end <= source.length else { return nil }
        var depth = 0
        for token in RTFLexer.tokens(source, in: NSRange(location: start, length: end - start)) {
            switch token.kind {
            case .open: depth += 1
            case .close:
                depth -= 1
                if depth < 0 { return nil }
            default: break
            }
        }
        // Закрыть группы, открытые внутри строки: после `\row` — только слова, пробелы и `}`.
        while depth > 0, end < source.length {
            let token = RTFLexer.tokens(source, in: NSRange(location: end, length: min(64, source.length - end))).first
            guard let token else { return nil }
            switch token.kind {
            case .close: depth -= 1
            case .word, .newline: break
            case .text where source.character(at: token.range.location) == 0x20: break
            default: return nil
            }
            end = NSMaxRange(token.range)
        }
        return depth == 0 ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: - Вставить строку

    /// Новая строка — копия строки `row` с пустыми ячейками (по одному абзацу; свойства абзацев и знаков — первых),
    /// выше или ниже неё. Объединение по вертикали: новая ячейка продолжает объединение, только если оно идёт через неё.
    static func insertRow(table: Int, row: Int, below: Bool, model: RTFDocumentModel, map: DocSourceMap, rendering: DocRendering,
                          source: NSString) -> Result {
        var result = Result()
        let story = model.body
        // Строка, где ячеек не столько, сколько `\cellx`, — уже не как у Word: не размножаем.
        guard let definition = story.tables[safe: table]?.rows[safe: row], definition.paragraphs.count == definition.cells.count,
              let span = rowSpan(table: table, row: row, story: story, source: source),
              var copy = emptied(table: table, row: row, span: span, model: model, map: map, rendering: rendering, source: source) else {
            result.refusal = structureHint
            return result
        }
        let rows = story.tables[table].rows
        let above = below ? rows[row] : rows[safe: row - 1]
        let beneath = below ? rows[safe: row + 1] : rows[row]
        copy = applied(mergeFlags(copy as NSString) { index in
            guard let cell = rows[row].cells[safe: index], let above, let beneath,
                  let up = matching(cell, in: above, of: rows[row]), let down = matching(cell, in: beneath, of: rows[row]) else { return nil }
            return (up.verticalMergeFirst || up.verticalMerged) && down.verticalMerged ? "clvmrg" : nil
        }, to: copy)
        let location = below ? NSMaxRange(span) : span.location
        if let head = (copy as NSString).length > 0 ? (copy as NSString).character(at: 0) : nil, head != 0x5C, head != 0x7B, head != 0x7D,
           DocTextEditor.needsDelimiter(before: location, source: source) {
            copy = " " + copy
        }
        result.edits = [DocEdit(range: NSRange(location: location, length: 0), text: copy)]
        // Курсор — в первую ячейку новой строки: перед первым `\cell` копии.
        let firstCell = RTFLexer.tokens(copy as NSString, in: NSRange(location: 0, length: (copy as NSString).length))
            .first { $0.kind == .word && $0.name == "cell" }
        result.caretSource = location + (firstCell?.range.location ?? 0)
        return result
    }

    /// Кусок строки без текста: правка «удалить всё» по показанным единицам строки (как в Word: текст ячеек стирается,
    /// абзацы ячейки склеиваются, ячейки остаются), применённая к копии куска.
    private static func emptied(table: Int, row: Int, span: NSRange, model: RTFDocumentModel, map: DocSourceMap, rendering: DocRendering,
                                source: NSString) -> String? {
        let indices = paragraphs(table: table, row: row, story: model.body)
        let ranges = indices.compactMap { rendering.paragraphRanges[safe: $0] }.filter { $0.length > 0 }
        var text = source.substring(with: span)
        guard let first = ranges.first, let last = ranges.last else { return text }
        let units = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let removal = DocTextEditor.replace(units, with: "", model: model, map: map, source: source)
        guard removal.refusal == nil || removal.edits.isEmpty else { return nil }
        let mutable = NSMutableString(string: text)
        for edit in removal.edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSIntersectionRange(edit.range, span) == edit.range else { return nil }
            mutable.replaceCharacters(in: NSRange(location: edit.range.location - span.location, length: edit.range.length), with: edit.text)
        }
        text = mutable as String
        return text
    }

    /// Ячейка соседней строки на тех же краях (`\cellx` и левый край), что ячейка строки `row`.
    private static func matching(_ cell: RTFCellDef, in other: RTFRow, of row: RTFRow) -> RTFCellDef? {
        guard let index = row.cells.firstIndex(of: cell) else { return nil }
        let left = index == 0 ? row.left : row.cells[index - 1].right
        var edge = other.left
        for candidate in other.cells {
            if edge == left, candidate.right == cell.right { return candidate }
            edge = candidate.right
        }
        return nil
    }

    /// Флаги объединения по вертикали в определениях строки (`\trowd` … `\cellx`, все копии определения): у ячейки
    /// `index` слово `\clvmgf`/`\clvmrg` заменяется на `flag(index)` или убирается (`nil`). Нового слова не добавляет.
    /// Правки — в координатах `text`.
    private static func mergeFlags(_ text: NSString, flag: (Int) -> String?) -> [DocEdit] {
        var edits: [DocEdit] = []
        var index = 0
        for token in RTFLexer.tokens(text, in: NSRange(location: 0, length: text.length)) where token.kind == .word {
            switch token.name {
            case "trowd": index = 0
            case "cellx": index += 1
            case "clvmgf", "clvmrg":
                let wanted = flag(index)
                if wanted != token.name {
                    edits.append(wanted.map { DocEdit(range: token.wordRange, text: "\\" + $0) } ?? DocEdit(range: token.range, text: ""))
                }
            default: break
            }
        }
        return edits
    }

    private static func applied(_ edits: [DocEdit], to text: String) -> String {
        let mutable = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) { mutable.replaceCharacters(in: edit.range, with: edit.text) }
        return mutable as String
    }

    // MARK: - Удалить строку

    /// Вырезать строку целиком. Ячейка, с которой начиналось объединение по вертикали, передаёт начало следующей строке
    /// (`\clvmrg` → `\clvmgf`). Единственная строка таблицы — удаляется вся таблица (как в Word).
    static func deleteRow(table: Int, row: Int, model: RTFDocumentModel, source: NSString) -> Result {
        var result = Result()
        let story = model.body
        guard let span = rowSpan(table: table, row: row, story: story, source: source) else {
            result.refusal = structureHint
            return result
        }
        result.edits = [DocEdit(range: span, text: "")]
        let rows = story.tables[table].rows
        if let next = rows[safe: row + 1] {
            // Следующая строка без своего `\trowd` живёт определением этой — без него она сломается.
            guard let nextSpan = rowSpan(table: table, row: row + 1, story: story, source: source),
                  !hasDefinition(span, source) || hasDefinition(nextSpan, source) else {
                result.refusal = structureHint
                result.edits = []
                return result
            }
            let current = rows[row]
            let fixes = mergeFlags(source.substring(with: nextSpan) as NSString) { index in
                guard let cell = next.cells[safe: index] else { return nil }
                if cell.verticalMergeFirst { return "clvmgf" }
                guard cell.verticalMerged else { return nil }
                let above = matching(cell, in: current, of: next)
                return above?.verticalMergeFirst == true ? "clvmgf" : "clvmrg"
            }
            result.edits += fixes.map { DocEdit(range: NSRange(location: nextSpan.location + $0.range.location, length: $0.range.length), text: $0.text) }
        }
        // Курсор — на место вырезанной строки (начало следующей или то, что после таблицы).
        result.caretSource = span.location
        return result
    }

    private static func hasDefinition(_ span: NSRange, _ source: NSString) -> Bool {
        RTFLexer.tokens(source, in: span).contains { $0.kind == .word && $0.name == "trowd" }
    }

    // MARK: - Tab по ячейкам

    /// Ячейка соседа по Tab (вперёд) или ⇧Tab (назад): по порядку в истории, без продолжений объединения по вертикали.
    static func neighbor(of cell: RTFCellRef, forward: Bool, story: RTFStory) -> RTFCellRef? {
        guard let table = story.tables[safe: cell.table] else { return nil }
        var refs: [RTFCellRef] = []
        for (rowIndex, row) in table.rows.enumerated() {
            for (index, def) in row.cells.enumerated() where !def.verticalMerged && !def.horizontalMerged {
                refs.append(RTFCellRef(table: cell.table, row: rowIndex, cell: index))
            }
        }
        guard let position = refs.firstIndex(of: cell) else { return nil }
        return refs[safe: forward ? position + 1 : position - 1]
    }

    /// Показанный текст ячейки (без её конца): что выделить при переходе по Tab.
    static func contentUnits(of cell: RTFCellRef, story: RTFStory, rendering: DocRendering) -> NSRange? {
        guard let indices = story.tables[safe: cell.table]?.rows[safe: cell.row]?.paragraphs[safe: cell.cell], let first = indices.first,
              let last = indices.last, let start = rendering.paragraphRanges[safe: first], let end = rendering.paragraphRanges[safe: last] else {
            return nil
        }
        return NSRange(location: start.location, length: max(0, NSMaxRange(end) - 1 - start.location))
    }
}

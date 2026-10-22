import Foundation

/// Таблицы, остальное (E-3): столбцы, ширина границы, объединить/разбить, границы и заливка, вставить таблицу.
/// Команда — один или несколько шагов по копии исходника (каждый шаг — точечные правки, перечитывание модели), итог —
/// одна правка: общее отличие от исходника. Байты вне неё те же по построению. Перед выдачей: скобок не хуже, разбор
/// открывает, нарушений структуры таблиц не больше — иначе отказ без правки.
extension DocTableEdit {
    /// Ячейки, на которые действует команда: строка и номер ячейки в строке.
    struct CellRef: Hashable {
        var row: Int
        var cell: Int
    }

    enum BorderPreset { case all, outer, none }

    static let rectangleHint = "Выделите прямоугольник целых ячеек. " + DocTextEditor.codeHint
    static let nestedHint = "Таблица внутри таблицы не вставляется. " + DocTextEditor.codeHint

    // MARK: - Геометрия строки

    /// Левый и правый край каждой ячейки строки, твипы.
    static func edges(_ row: RTFRow) -> [(left: Int, right: Int)] {
        var left = row.left
        return row.cells.map { cell in
            defer { left = max(cell.right, left) }
            return (left, max(cell.right, left))
        }
    }

    /// Ячейка строки, в которую попадает середина столбца `[left, right]`.
    static func cell(in row: RTFRow, column: (left: Int, right: Int)) -> Int? {
        let middle = (column.left + column.right) / 2
        return edges(row).firstIndex { $0.left <= middle && middle < $0.right }
    }

    // MARK: - Проверки (те же, что у тестов)

    /// Нарушения структуры: в строке ячеек (`\cell`) не столько, сколько `\cellx`; `\cellx` не возрастают.
    static func violations(_ model: RTFDocumentModel) -> Int {
        model.body.tables.reduce(0) { count, table in
            count + table.rows.reduce(0) { count, row in
                count + (row.paragraphs.count != row.cells.count ? 1 : 0)
                    + (zip(row.cells, row.cells.dropFirst()).contains { $0.right >= $1.right } ? 1 : 0)
            }
        }
    }

    /// Копии определения строки расходятся (разные `\cellx`): число строк с расхождением.
    static func definitionMismatches(_ model: RTFDocumentModel, source: NSString) -> Int {
        var count = 0
        for (index, table) in model.body.tables.enumerated() {
            for row in table.rows.indices {
                guard let span = rowSpan(table: index, row: row, story: model.body, source: source) else { continue }
                let copies = RTFRowDefinition.all(in: span, source: source).map { $0.cells.map(\.right) }
                if Set(copies.map { $0.map(String.init).joined(separator: ",") }).count > 1 { count += 1 }
            }
        }
        return count
    }

    // MARK: - Общая основа

    private static func applying(_ edits: [DocEdit], to source: NSString) -> NSString? {
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        for (a, b) in zip(sorted, sorted.dropFirst()) where NSMaxRange(a.range) > b.range.location { return nil }
        let result = NSMutableString(string: source)
        for edit in sorted.reversed() {
            guard NSMaxRange(edit.range) <= result.length else { return nil }
            result.replaceCharacters(in: edit.range, with: edit.text)
        }
        return result
    }

    /// Итог команды: одна правка (общее отличие) и курсор (`caret` — место в новом исходнике).
    private static func finish(_ old: NSString, _ new: NSString, caret: Int?) -> Result {
        var result = Result()
        let before = RTFReader.read(old), after = RTFReader.read(new)
        guard after.isRTF, DollarMarks.unbalancedBraces(in: new) <= DollarMarks.unbalancedBraces(in: old),
              violations(after) <= violations(before),
              definitionMismatches(after, source: new) <= definitionMismatches(before, source: old) else {
            result.refusal = structureHint
            return result
        }
        var prefix = 0
        let limit = min(old.length, new.length)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        guard prefix < old.length || prefix < new.length else { return result }
        let range = NSRange(location: prefix, length: old.length - prefix - suffix)
        result.edits = [DocEdit(range: range, text: new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix)))]
        result.caretSource = caret ?? prefix
        return result
    }

    /// Правки определений строки во всех копиях: `change` получает ячейки копии и меняет их (ширины, вставка,
    /// удаление, слова). `nil` — копию не разобрать (число ячеек не то) — команда отказывает.
    private static func definitionEdits(table: Int, row: Int, story: RTFStory, source: NSString,
                                        change: (inout [RTFRowDefinition.Cell]) -> Void) -> [DocEdit]? {
        guard let definition = story.tables[safe: table]?.rows[safe: row],
              let span = rowSpan(table: table, row: row, story: story, source: source) else { return nil }
        let copies = RTFRowDefinition.all(in: span, source: source)
        guard !copies.isEmpty else { return nil }
        var edits: [DocEdit] = []
        for copy in copies {
            guard copy.cells.count == definition.cells.count, let first = copy.cells.first, let last = copy.cells.last else { return nil }
            var cells = copy.cells
            change(&cells)
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            let text = cells.map(\.text).joined()
            if text != source.substring(with: range) { edits.append(DocEdit(range: range, text: text)) }
        }
        return edits
    }

    /// Конец ячейки (`\cell`) в исходнике.
    private static func cellEnd(_ table: Int, _ row: Int, _ cell: Int, story: RTFStory) -> NSRange? {
        story.tables[safe: table]?.rows[safe: row]?.paragraphs[safe: cell]?.last.flatMap { story.paragraphs[safe: $0]?.endRange }
    }

    /// В ячейке нет видимого текста.
    private static func isEmpty(_ table: Int, _ row: Int, _ cell: Int, story: RTFStory) -> Bool {
        let indices = story.tables[safe: table]?.rows[safe: row]?.paragraphs[safe: cell] ?? []
        return indices.allSatisfy { story.paragraphs[safe: $0]?.runs.allSatisfy { $0.text.isEmpty || $0.kind == .listText } ?? true }
    }

    /// Стереть содержимое ячейки: текст, поля, рисунки, концы абзацев внутри (`\par`), с `withEnd` — и её `\cell`.
    /// Коды свойств остаются — состояние для следующей ячейки то же.
    private static func clearing(_ table: Int, _ row: Int, _ cell: Int, withEnd: Bool, model: RTFDocumentModel, source: NSString) -> [DocEdit] {
        let story = model.body
        let indices = story.tables[safe: table]?.rows[safe: row]?.paragraphs[safe: cell] ?? []
        var ranges: [NSRange] = []
        for (position, index) in indices.enumerated() {
            guard let paragraph = story.paragraphs[safe: index] else { continue }
            for run in paragraph.runs {
                if case .field = run.kind, let first = run.map.first,
                   let field = model.fields.first(where: { NSLocationInRange(first.location, $0.group) }) {
                    ranges.append(field.group)
                } else {
                    ranges += run.map
                }
            }
            if position < indices.count - 1 || withEnd { ranges.append(paragraph.endRange) }
        }
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged.map { DocEdit(range: $0, text: DocTextEditor.delimiterAfterRemoval($0, source: source) ? " " : "") }
    }

    /// Куда вставить новую пустую ячейку перед ячейкой `cell`: за концом предыдущей; перед первой — за `\intbl` её
    /// первого абзаца (последним после `\row` предыдущей строки) и кодами свойств абзаца следом.
    private static func insertionBefore(_ table: Int, _ row: Int, _ cell: Int, story: RTFStory, source: NSString) -> Int? {
        if cell > 0 { return cellEnd(table, row, cell - 1, story: story).map(NSMaxRange) }
        guard let index = story.tables[safe: table]?.rows[safe: row]?.paragraphs.first?.first,
              let paragraph = story.paragraphs[safe: index], paragraph.contentStart > paragraph.regionStart else { return nil }
        let tokens = RTFLexer.tokens(source, in: NSRange(location: paragraph.regionStart, length: paragraph.contentStart - paragraph.regionStart))
        let afterRow = (tokens.lastIndex { $0.kind == .word && $0.name == "row" }).map { $0 + 1 } ?? 0
        guard var at = tokens[afterRow...].lastIndex(where: { $0.kind == .word && $0.name == "intbl" }) else { return nil }
        while at + 1 < tokens.count, tokens[at + 1].kind == .word || tokens[at + 1].kind == .newline { at += 1 }
        return NSMaxRange(tokens[at].range)
    }

    // MARK: - Столбцы

    /// Вставить столбец слева или справа от ячейки: в каждой строке — пустая ячейка той же ширины рядом с ячейкой
    /// того же столбца (по середине); правее — сдвиг. Свойства ячейки (границы, заливка) — от соседней, без объединения.
    static func insertColumn(table: Int, at ref: CellRef, right: Bool, model: RTFDocumentModel, source: NSString) -> Result {
        let story = model.body
        guard let rows = story.tables[safe: table]?.rows, let selected = rows[safe: ref.row], ref.cell < selected.cells.count else {
            return Result(refusal: structureHint)
        }
        let column = edges(selected)[ref.cell]
        let width = column.right - column.left
        var edits: [DocEdit] = []
        var caret: Int?
        for (index, row) in rows.enumerated() {
            guard let at = cell(in: row, column: column) else { continue }
            let left = edges(row)[at].left
            let definitions = definitionEdits(table: table, row: index, story: story, source: source) { cells in
                var added = cells[at]
                added.setMerge(nil)
                if right {
                    added.setRight(cells[at].right + width, width: width)
                    for k in (at + 1)..<cells.count { cells[k].setRight(cells[k].right + width, width: nil) }
                    cells.insert(added, at: at + 1)
                } else {
                    added.setRight(left + width, width: width)
                    for k in at..<cells.count { cells[k].setRight(cells[k].right + width, width: nil) }
                    cells.insert(added, at: at)
                }
            }
            guard let definitions,
                  let location = right ? cellEnd(table, index, at, story: story).map(NSMaxRange) : insertionBefore(table, index, at, story: story, source: source) else {
                return Result(refusal: structureHint)
            }
            edits += definitions
            edits.append(DocEdit(range: NSRange(location: location, length: 0), text: "\\cell "))
            if index == ref.row { caret = location }
        }
        guard let new = applying(edits, to: source) else { return Result(refusal: structureHint) }
        // Курсор — в новой ячейке выбранной строки: место вставки со сдвигом от правок левее.
        let shift = caret.map { place in edits.filter { $0.range.location < place }.reduce(0) { $0 + ($1.text as NSString).length - $1.range.length } } ?? 0
        return finish(source, new, caret: caret.map { $0 + shift })
    }

    /// Удалить столбец ячейки: в каждой строке — ячейка того же столбца с содержимым; правее — сдвиг влево. Строка из
    /// одной этой ячейки удаляется целиком.
    static func deleteColumn(table: Int, at ref: CellRef, model: RTFDocumentModel, source: NSString) -> Result {
        let story = model.body
        guard let rows = story.tables[safe: table]?.rows, let selected = rows[safe: ref.row], ref.cell < selected.cells.count else {
            return Result(refusal: structureHint)
        }
        let column = edges(selected)[ref.cell]
        var edits: [DocEdit] = []
        for (index, row) in rows.enumerated() {
            guard let at = cell(in: row, column: column) else { continue }
            if row.cells.count == 1 {
                guard let span = rowSpan(table: table, row: index, story: story, source: source) else { return Result(refusal: structureHint) }
                edits.append(DocEdit(range: span, text: ""))
                continue
            }
            let width = edges(row)[at].right - edges(row)[at].left
            guard let definitions = definitionEdits(table: table, row: index, story: story, source: source, change: { cells in
                for k in (at + 1)..<cells.count { cells[k].setRight(cells[k].right - width, width: nil) }
                cells.remove(at: at)
            }) else { return Result(refusal: structureHint) }
            edits += definitions + clearing(table, index, at, withEnd: true, model: model, source: source)
        }
        guard let new = applying(edits, to: source) else { return Result(refusal: structureHint) }
        let start = edits.map(\.range.location).min() ?? 0
        return finish(source, new, caret: start)
    }

    // MARK: - Ширина

    /// Перенести границу столбцов `boundary` (правый край ячеек, твипы) на `delta`: во всех строках, где граница там же.
    /// Соседние ячейки не уже `minimum`; правее границы ничего не сдвигается (ширина таблицы та же), кроме правого края.
    static func moveBoundary(table: Int, boundary: Int, delta: Int, model: RTFDocumentModel, source: NSString, minimum: Int = 100) -> Result {
        let story = model.body
        guard let rows = story.tables[safe: table]?.rows, delta != 0 else { return Result(refusal: nil) }
        var low = Int.min, high = Int.max
        var touched: [(row: Int, cell: Int)] = []
        for (index, row) in rows.enumerated() {
            let edges = edges(row)
            guard let at = edges.firstIndex(where: { abs($0.right - boundary) <= 1 }) else { continue }
            low = max(low, edges[at].left + minimum - edges[at].right)
            if at + 1 < edges.count { high = min(high, edges[at + 1].right - minimum - edges[at].right) }
            touched.append((index, at))
        }
        let shift = min(max(delta, low), high)
        guard !touched.isEmpty, shift != 0 else { return Result(refusal: nil) }
        var edits: [DocEdit] = []
        for (index, at) in touched {
            let edge = edges(rows[index])
            guard let definitions = definitionEdits(table: table, row: index, story: story, source: source, change: { cells in
                let moved = cells[at].right + shift
                cells[at].setRight(moved, width: moved - edge[at].left)
                if at + 1 < cells.count { cells[at + 1].setRight(cells[at + 1].right, width: cells[at + 1].right - moved) }
            }) else { return Result(refusal: structureHint) }
            edits += definitions
        }
        guard let new = applying(edits, to: source) else { return Result(refusal: structureHint) }
        return finish(source, new, caret: nil)
    }

    // MARK: - Объединить и разбить

    /// Объединить прямоугольник ячеек. В строке — одна широкая ячейка (как пишет Word), текст ячеек — её абзацами;
    /// несколько строк — объединение по вертикали (`\clvmgf`/`\clvmrg`), текст нижних ячеек переходит в верхнюю
    /// (абзацами, в формате её конца).
    static func merge(table: Int, cells selected: Set<CellRef>, model: RTFDocumentModel, source: NSString) -> Result {
        guard let rows = model.body.tables[safe: table]?.rows, !selected.isEmpty else { return Result(refusal: rectangleHint) }
        let first = selected.map(\.row).min()!, last = selected.map(\.row).max()!
        let left = selected.compactMap { rows[safe: $0.row].map { edges($0) }?[safe: $0.cell]?.left }.min() ?? 0
        let right = selected.compactMap { rows[safe: $0.row].map { edges($0) }?[safe: $0.cell]?.right }.max() ?? 0
        // В каждой строке — ячейки ровно от `left` до `right`.
        var spans: [Int: ClosedRange<Int>] = [:]
        for index in first...last {
            let edge = edges(rows[index])
            guard let a = edge.firstIndex(where: { $0.left == left }), let b = edge.firstIndex(where: { $0.right == right }), a <= b else {
                return Result(refusal: rectangleHint)
            }
            spans[index] = a...b
        }
        guard selected.count > 1 || first != last || spans.values.contains(where: { $0.count > 1 }) else { return Result(refusal: rectangleHint) }
        var text: NSString = source
        var current = model
        // Шаг 1: по горизонтали.
        var edits: [DocEdit] = []
        for (index, span) in spans where span.count > 1 {
            guard let definitions = definitionEdits(table: table, row: index, story: current.body, source: text, change: { cells in
                cells[span.lowerBound].setRight(right, width: right - left)
                cells.removeSubrange((span.lowerBound + 1)...span.upperBound)
            }) else { return Result(refusal: structureHint) }
            edits += definitions
            var accumulated = !isEmpty(table, index, span.lowerBound, story: current.body)
            for k in span.lowerBound..<span.upperBound {
                guard let end = cellEnd(table, index, k, story: current.body) else { return Result(refusal: structureHint) }
                let next = !isEmpty(table, index, k + 1, story: current.body)
                let keep = accumulated && next
                edits.append(DocEdit(range: end, text: keep ? "\\par " : (DocTextEditor.delimiterAfterRemoval(end, source: text) ? " " : "")))
                accumulated = accumulated || next
            }
        }
        if !edits.isEmpty {
            guard let new = applying(edits, to: text) else { return Result(refusal: structureHint) }
            text = new
            current = RTFReader.read(text)
        }
        // Шаг 2: по вертикали.
        if last > first, let rows = current.body.tables[safe: table]?.rows {
            edits = []
            var moved: [String] = []
            for index in first...last {
                guard let at = rows[safe: index].flatMap({ edges($0).firstIndex { $0.left == left && $0.right == right } }),
                      let definitions = definitionEdits(table: table, row: index, story: current.body, source: text, change: { cells in
                          cells[at].setMerge(index == first ? "clvmgf" : "clvmrg")
                      }) else { return Result(refusal: structureHint) }
                edits += definitions
                if index > first, !isEmpty(table, index, at, story: current.body) {
                    let indices = rows[index].paragraphs[at]
                    moved += indices.compactMap { current.body.paragraphs[safe: $0] }.map { paragraph in
                        paragraph.runs.filter { $0.kind == .text || $0.kind == .tab }.map(\.text).joined()
                    }
                    edits += clearing(table, index, at, withEnd: false, model: current, source: text)
                }
            }
            if !moved.isEmpty, let top = rows[safe: first].flatMap({ edges($0).firstIndex { $0.left == left && $0.right == right } }),
               let end = cellEnd(table, first, top, story: current.body), let lastIndex = rows[first].paragraphs[top].last,
               let paragraph = current.body.paragraphs[safe: lastIndex] {
                let props = paragraph.runs.last?.props ?? paragraph.endProps
                let encoded = moved.map { "\\par " + DocTextEditor.encode($0, props: props, uc: paragraph.runs.last?.uc ?? paragraph.endUC, model: current) }
                let topEmpty = isEmpty(table, first, top, story: current.body)
                var joined = encoded.joined()
                if topEmpty { joined = String(joined.dropFirst(5)) }
                let prefix = DocTextEditor.needsDelimiter(before: end.location, source: text) ? " " : ""
                edits.append(DocEdit(range: NSRange(location: end.location, length: 0), text: prefix + joined))
            }
            guard let new = applying(edits, to: text) else { return Result(refusal: structureHint) }
            text = new
        }
        return finish(source, text, caret: nil)
    }

    /// Разбить ячейку: объединённую по вертикали — на прежние ячейки (флаги снимаются во всём объединении), иначе —
    /// на две по ширине (правая — пустая).
    static func split(table: Int, at ref: CellRef, model: RTFDocumentModel, source: NSString) -> Result {
        let story = model.body
        guard let rows = story.tables[safe: table]?.rows, let row = rows[safe: ref.row], let def = row.cells[safe: ref.cell] else {
            return Result(refusal: structureHint)
        }
        let column = edges(row)[ref.cell]
        var edits: [DocEdit] = []
        if def.verticalMergeFirst || def.verticalMerged {
            var top = ref.row
            while top > 0, rows[top].cells[safe: cellIndex(rows[top], column) ?? -1]?.verticalMergeFirst != true,
                  rows[top].cells[safe: cellIndex(rows[top], column) ?? -1]?.verticalMerged == true { top -= 1 }
            var bottom = top
            while bottom + 1 < rows.count, rows[bottom + 1].cells[safe: cellIndex(rows[bottom + 1], column) ?? -1]?.verticalMerged == true { bottom += 1 }
            for index in top...bottom {
                guard let at = cellIndex(rows[index], column),
                      let definitions = definitionEdits(table: table, row: index, story: story, source: source, change: { $0[at].setMerge(nil) }) else {
                    return Result(refusal: structureHint)
                }
                edits += definitions
            }
        } else {
            let half = (column.right - column.left) / 2
            guard half >= 100, let definitions = definitionEdits(table: table, row: ref.row, story: story, source: source, change: { cells in
                var added = cells[ref.cell]
                added.setRight(column.right, width: column.right - column.left - half)
                cells[ref.cell].setRight(column.left + half, width: half)
                cells.insert(added, at: ref.cell + 1)
            }), let end = cellEnd(table, ref.row, ref.cell, story: story) else { return Result(refusal: structureHint) }
            edits += definitions
            edits.append(DocEdit(range: NSRange(location: NSMaxRange(end), length: 0), text: "\\cell "))
        }
        guard let new = applying(edits, to: source) else { return Result(refusal: structureHint) }
        return finish(source, new, caret: nil)
    }

    private static func cellIndex(_ row: RTFRow, _ column: (left: Int, right: Int)) -> Int? {
        edges(row).firstIndex { $0.left == column.left && $0.right == column.right }
    }

    // MARK: - Границы и заливка

    /// Границы выделенных ячеек: все, внешние (по контуру выделения) или нет (явно `\brdrnone`, и у соседей по контуру —
    /// их сторона к выделению, иначе общая линия осталась бы).
    static func borders(table: Int, cells selected: Set<CellRef>, preset: BorderPreset, model: RTFDocumentModel, source: NSString) -> Result {
        guard let rows = model.body.tables[safe: table]?.rows, !selected.isEmpty else { return Result(refusal: rectangleHint) }
        let first = selected.map(\.row).min()!, last = selected.map(\.row).max()!
        let boxes = selected.compactMap { ref in rows[safe: ref.row].flatMap { edges($0)[safe: ref.cell] } }
        let left = boxes.map(\.left).min() ?? 0, right = boxes.map(\.right).max() ?? 0
        var changes: [Int: [Int: (sides: [Character], visible: Bool)]] = [:]
        for ref in selected {
            guard let box = rows[safe: ref.row].flatMap({ edges($0)[safe: ref.cell] }) else { continue }
            switch preset {
            case .all: changes[ref.row, default: [:]][ref.cell] = (Array("tlbr"), true)
            case .none: changes[ref.row, default: [:]][ref.cell] = (Array("tlbr"), false)
            case .outer:
                var sides: [Character] = []
                if ref.row == first { sides.append("t") }
                if box.left == left { sides.append("l") }
                if ref.row == last { sides.append("b") }
                if box.right == right { sides.append("r") }
                if !sides.isEmpty { changes[ref.row, default: [:]][ref.cell] = (sides, true) }
            }
        }
        if preset == .none {
            // Соседи по контуру: сторона к выделению — тоже без линии.
            for ref in selected {
                guard let row = rows[safe: ref.row], let box = edges(row)[safe: ref.cell] else { continue }
                var around: [(Int, Int, Character)] = []
                if ref.cell > 0, !selected.contains(CellRef(row: ref.row, cell: ref.cell - 1)) { around.append((ref.row, ref.cell - 1, "r")) }
                if ref.cell + 1 < row.cells.count, !selected.contains(CellRef(row: ref.row, cell: ref.cell + 1)) { around.append((ref.row, ref.cell + 1, "l")) }
                for (other, side) in [(ref.row - 1, Character("b")), (ref.row + 1, Character("t"))] {
                    guard let neighbor = rows[safe: other], let at = cell(in: neighbor, column: box),
                          !selected.contains(CellRef(row: other, cell: at)) else { continue }
                    around.append((other, at, side))
                }
                for (row, cell, side) in around where changes[row]?[cell] == nil || changes[row]?[cell]?.visible == false {
                    var change = changes[row]?[cell] ?? ([], false)
                    if !change.sides.contains(side) { change.sides.append(side) }
                    changes[row, default: [:]][cell] = change
                }
            }
        }
        var edits: [DocEdit] = []
        for (row, cells) in changes {
            guard let definitions = definitionEdits(table: table, row: row, story: model.body, source: source, change: { defs in
                for (cell, change) in cells where cell < defs.count { defs[cell].setBorders(change.sides, visible: change.visible) }
            }) else { return Result(refusal: structureHint) }
            edits += definitions
        }
        guard let new = applying(edits, to: source) else { return Result(refusal: structureHint) }
        return finish(source, new, caret: nil)
    }

    /// Заливка выделенных ячеек цветом (`nil` — без заливки). Нового цвета нет в `\colortbl` — он дописывается в конец.
    static func shading(table: Int, cells selected: Set<CellRef>, color: RTFColor?, model: RTFDocumentModel, source: NSString) -> Result {
        guard !selected.isEmpty else { return Result(refusal: rectangleHint) }
        var tables = FormatTables(source: source, model: model)
        var index: Int?
        if let color {
            guard let found = tables.colorIndex(color) else { return Result(refusal: "В файле нет таблицы цветов. " + DocTextEditor.codeHint) }
            index = found
        }
        var edits = tables.edits().map { DocEdit(range: $0.range, text: $0.string) }
        for row in Set(selected.map(\.row)) {
            let cells = selected.filter { $0.row == row }.map(\.cell)
            guard let definitions = definitionEdits(table: table, row: row, story: model.body, source: source, change: { defs in
                for cell in cells where cell < defs.count { defs[cell].setShading(index) }
            }) else { return Result(refusal: structureHint) }
            edits += definitions
        }
        guard let new = applying(edits, to: source) else { return Result(refusal: structureHint) }
        return finish(source, new, caret: nil)
    }

    // MARK: - Вставить таблицу

    /// Таблица `rows` × `columns` на всю ширину полосы текста (`textWidth`, твипы) — после абзаца `paragraph`, с
    /// одинарными границами, как вставляет Word. Абзац после таблицы получает прежние свойства (если своих у него нет).
    static func insertTable(rows: Int, columns: Int, after paragraph: Int, textWidth: Int, model: RTFDocumentModel, source: NSString) -> Result {
        let story = model.body
        guard rows > 0, columns > 0, let current = story.paragraphs[safe: paragraph] else { return Result(refusal: structureHint) }
        guard current.cell == nil, !current.props.inTable else { return Result(refusal: nestedHint) }
        let border = "\\brdrs\\brdrw10 "
        var definition = "\\trowd \\trgaph108\\trleft-108"
        definition += ["t", "l", "b", "r", "h", "v"].map { "\\trbrdr" + $0 + border }.joined()
        definition += "\\trpaddl108\\trpaddr108\\trpaddfl3\\trpaddfr3"
        for column in 1...columns {
            definition += ["t", "l", "b", "r"].map { "\\clbrdr" + $0 + border }.joined()
            definition += "\\clftsWidth3\\clwWidth\(textWidth / columns)\\cellx\(-108 + textWidth * column / columns)"
        }
        var table = ""
        for _ in 0..<rows {
            table += definition + "\\pard\\intbl " + String(repeating: "\\cell ", count: columns) + "\\row "
        }
        // Конец абзаца, за которым таблица; абзац без `\par` (последний) — сначала закончить его.
        var prefix = ""
        var location = NSMaxRange(current.endRange)
        if current.end != .paragraph {
            prefix = "\\par "
            location = current.endRange.location
            if DocTextEditor.needsDelimiter(before: location, source: source) { prefix = " " + prefix }
        }
        // За таблицей — пустой абзац со свойствами этого (как в Word: остаток абзаца, где стоял курсор); следующий абзац
        // без своего `\pard` живёт ими же, как и прежде.
        let codes = current.propTokens.values.filter { $0.location >= current.regionStart }.sorted { $0.location < $1.location }
            .map { source.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
        let suffix = "\\pard " + codes + (codes.isEmpty ? "" : " ") + "\\par " 
        let text = prefix + table + suffix
        guard let new = applying([DocEdit(range: NSRange(location: location, length: 0), text: text)], to: source) else {
            return Result(refusal: structureHint)
        }
        // Курсор — в первую ячейку.
        let caret = location + (prefix as NSString).length + ((definition + "\\pard\\intbl ") as NSString).length
        return finish(source, new, caret: caret)
    }
}

extension DocTableEdit.Result {
    init(refusal: String?) {
        self.init()
        self.refusal = refusal
    }
}

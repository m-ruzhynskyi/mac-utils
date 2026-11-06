import AppKit

/// Мышь в таблицах «Документа» (TB2): ширина столбца и высота строки протяжкой границы (пунктирная линия, на отпускании — одна точечная
/// правка, ⌥ — только эта строка), выделение ячеек (протяжкой, щелчком у края ячейки, у левого края строки, над столбцом, ⇧+стрелками)
/// и заливка выделенных ячеек. Геометрия — по рамкам блоков ячеек (`NSTextTableBlock`) в раскладке страницы.
extension DocumentController {
    /// Что под мышью в таблице.
    package enum TableHit: Equatable {
        /// Правая граница ячеек (`\cellx`, твипы) и x линии в view; `row` — строка под мышью (для ⌥).
        case columnBoundary(table: Int, boundary: Int, x: CGFloat, row: Int)
        /// Горизонтальная граница под строкой `row`: y линии в view и текущая высота строки, пункты.
        case rowBoundary(table: Int, row: Int, y: CGFloat, height: CGFloat)
        case selectCell(table: Int, ref: DocTableEdit.CellRef)
        case selectRow(table: Int, row: Int)
        case selectColumn(table: Int, ref: DocTableEdit.CellRef)

        package var cursor: NSCursor {
            switch self {
            case .columnBoundary: return .resizeLeftRight
            case .rowBoundary: return .resizeUpDown
            case .selectCell, .selectRow, .selectColumn: return .arrow
            }
        }
    }

    /// Допуск попадания в границу, пункты.
    static let boundaryGrab: CGFloat = 3
    /// Зона выбора у края: левее/правее границы ячейки на столько пунктов (строка — снаружи и у самой границы, ячейка — чуть внутри).
    static let selectZone: CGFloat = 5
    package static let minimumRowHeight = 113

    /// Рамка блока ячейки в координатах view страницы.
    func cellRect(table: Int, row: Int, cell: Int, in view: DocTextView? = nil) -> (rect: NSRect, view: DocTextView)? {
        guard let paragraph = model.body.tables[safe: table]?.rows[safe: row]?.paragraphs[safe: cell]?.first,
              let range = rendering.paragraphRanges[safe: paragraph], range.location < storage.length,
              let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              let block = style.textBlocks.last as? NSTextTableBlock else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        guard let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil),
              let page = pagesView.pages.first(where: { $0.container === container }) else { return nil }
        let rect = layoutManager.boundsRect(for: block, glyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
        let origin = page.textView.textContainerOrigin
        return (rect.offsetBy(dx: origin.x, dy: origin.y), page.textView)
    }

    /// Что под точкой (координаты `view`) в таблице основного текста; `nil` — ничего особенного.
    package func tableHit(at point: NSPoint, in view: DocTextView) -> TableHit? {
        guard let container = view.textContainer, storage.length > 0 else { return nil }
        let origin = view.textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length, let index = rendering.paragraph(atUnit: character),
              let cell = model.body.paragraphs[safe: index]?.cell, model.body.paragraphs[index].outerCell == nil,
              model.body.tables[safe: cell.table]?.nested != true,
              let found = cellRect(table: cell.table, row: cell.row, cell: cell.cell, in: view), found.view === view else { return nil }
        let rect = found.rect
        guard point.y >= rect.minY - Self.boundaryGrab, point.y <= rect.maxY + Self.boundaryGrab else { return nil }
        guard let row = model.body.tables[safe: cell.table]?.rows[safe: cell.row] else { return nil }
        let edges = DocTableEdit.edges(row)
        // Вертикальная граница.
        if abs(point.x - rect.maxX) <= Self.boundaryGrab, let edge = edges[safe: cell.cell] {
            return .columnBoundary(table: cell.table, boundary: edge.right, x: rect.maxX, row: cell.row)
        }
        if abs(point.x - rect.minX) <= Self.boundaryGrab, cell.cell > 0, let edge = edges[safe: cell.cell - 1] {
            return .columnBoundary(table: cell.table, boundary: edge.right, x: rect.minX, row: cell.row)
        }
        // Горизонтальная граница: низ этой строки или верх (низ предыдущей).
        if abs(point.y - rect.maxY) <= Self.boundaryGrab, point.x > rect.minX + Self.boundaryGrab, point.x < rect.maxX - Self.boundaryGrab {
            return .rowBoundary(table: cell.table, row: cell.row, y: rect.maxY, height: rect.height)
        }
        if abs(point.y - rect.minY) <= Self.boundaryGrab, cell.row > 0, point.x > rect.minX + Self.boundaryGrab, point.x < rect.maxX - Self.boundaryGrab,
           let above = cellRect(table: cell.table, row: cell.row - 1, cell: min(cell.cell, DocTableEdit.edges(model.body.tables[cell.table].rows[cell.row - 1]).count - 1), in: view) {
            return .rowBoundary(table: cell.table, row: cell.row - 1, y: above.rect.maxY, height: above.rect.height)
        }
        // Щелчок у края: у левого края первой ячейки — строка, у левого края других ячеек — ячейка, у верха первой строки — столбец.
        if point.x < rect.minX + Self.selectZone, cell.cell == 0 { return .selectRow(table: cell.table, row: cell.row) }
        if point.x < rect.minX + 2 * Self.selectZone, point.x >= rect.minX + Self.boundaryGrab {
            return .selectCell(table: cell.table, ref: DocTableEdit.CellRef(row: cell.row, cell: cell.cell))
        }
        if cell.row == 0, point.y < rect.minY + Self.selectZone, point.x > rect.minX + Self.boundaryGrab, point.x < rect.maxX - Self.boundaryGrab {
            return .selectColumn(table: cell.table, ref: DocTableEdit.CellRef(row: 0, cell: cell.cell))
        }
        return nil
    }

    // MARK: - Протяжка границы

    /// Один шаг протяжки: что тянем и откуда (чистое состояние — отдельно от цикла событий, чтобы проверять без мыши).
    package struct BoundaryDrag: Equatable {
        package enum Kind: Equatable {
            case column(table: Int, boundary: Int, row: Int)
            case row(table: Int, row: Int, height: CGFloat)
        }
        package var kind: Kind
        /// Начало протяжки и положение линии до неё (view).
        package var start: NSPoint
        package var line: CGFloat
        package var delta: CGFloat = 0
        package var option = false
    }

    package func beginBoundaryDrag(at point: NSPoint, in view: DocTextView) -> BoundaryDrag? {
        switch tableHit(at: point, in: view) {
        case .columnBoundary(let table, let boundary, let x, let row)?:
            return BoundaryDrag(kind: .column(table: table, boundary: boundary, row: row), start: point, line: x)
        case .rowBoundary(let table, let row, let y, let height)?:
            return BoundaryDrag(kind: .row(table: table, row: row, height: height), start: point, line: y)
        default: return nil
        }
    }

    /// Сдвиг линии при положении мыши `point`: с учётом запрета (ближе 0,5 см к соседней границе не пускает).
    package func updateBoundaryDrag(_ drag: inout BoundaryDrag, to point: NSPoint, option: Bool) {
        drag.option = option
        switch drag.kind {
        case .column(let table, let boundary, let row):
            let delta = Int(((point.x - drag.start.x) * 20).rounded())
            let shift = DocTableEdit.clampedShift(table: table, boundary: boundary, delta: delta, model: model, rowOnly: option ? row : nil)
            drag.delta = CGFloat(shift) / 20
        case .row(_, _, let height):
            // Строка не ниже минимальной высоты.
            drag.delta = max(point.y - drag.start.y, CGFloat(Self.minimumRowHeight) / 20 - height)
        }
    }

    /// Положение линии-подсказки в view.
    package func guidePosition(_ drag: BoundaryDrag) -> CGFloat { drag.line + drag.delta }

    /// Отпускание: правка исходника — одна, с отменой. `false` — ничего не изменилось.
    @discardableResult
    package func finishBoundaryDrag(_ drag: BoundaryDrag) -> Bool {
        guard let tab else { return false }
        switch drag.kind {
        case .column(let table, let boundary, let row):
            let delta = Int((drag.delta * 20).rounded())
            guard delta != 0 else { return false }
            let result = DocTableEdit.moveBoundary(table: table, boundary: boundary, delta: delta, model: model, source: tab.text, rowOnly: drag.option ? row : nil)
            guard result.refusal != nil || !result.edits.isEmpty else { return false }
            return applyTable(result, actionName: "Ширина столбца")
        case .row(let table, let row, let height):
            let twips = Int(((height + drag.delta) * 20).rounded())
            guard abs(drag.delta) >= 0.05 else { return false }
            let result = DocTableEdit.setRowHeight(table: table, row: row, height: max(twips, Self.minimumRowHeight), model: model, source: tab.text)
            guard result.refusal != nil || !result.edits.isEmpty else { return false }
            return applyTable(result, actionName: "Высота строки")
        }
    }

    /// Нажатие у границы: тянем линию до отпускания и правим. `true` — нажатие обработано.
    func dragTableBoundary(_ event: NSEvent, in view: DocTextView) -> Bool {
        let start = view.convert(event.locationInWindow, from: nil)
        guard var drag = beginBoundaryDrag(at: start, in: view), let window = view.window else { return false }
        updateBoundaryDrag(&drag, to: start, option: event.modifierFlags.contains(.option))
        var isColumn = false
        if case .column = drag.kind { isColumn = true }
        let guide = DocGuideLine(vertical: isColumn, in: view.bounds)
        view.addSubview(guide)
        defer { guide.removeFromSuperview() }
        guide.position = guidePosition(drag)
        let nextEvent = dragEventSource ?? { $0.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) }
        while let next = nextEvent(window) {
            let point = view.convert(next.locationInWindow, from: nil)
            updateBoundaryDrag(&drag, to: point, option: next.modifierFlags.contains(.option))
            guide.position = guidePosition(drag)
            (isColumn ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            if next.type == .leftMouseUp { break }
        }
        finishBoundaryDrag(drag)
        return true
    }

    // MARK: - Выделение ячеек

    /// Выделить ячейки: коротко запомнить и показать заливкой; текстовое выделение — курсор в первой ячейке.
    package func selectCells(_ cells: Set<DocTableEdit.CellRef>, table: Int, anchor: DocTableEdit.CellRef? = nil, focus: DocTableEdit.CellRef? = nil) {
        guard !cells.isEmpty else { return clearCellSelection() }
        let ordered = cells.sorted { ($0.row, $0.cell) < ($1.row, $1.cell) }
        tableCellSelection = TableCellSelection(table: table, cells: cells, anchor: anchor ?? ordered[0], focus: focus ?? ordered[ordered.count - 1])
        if let first = ordered.first, let paragraph = model.body.tables[safe: table]?.rows[safe: first.row]?.paragraphs[safe: first.cell]?.first,
           let range = rendering.paragraphRanges[safe: paragraph], let view = textView(forUnit: range.location) {
            settingCellSelection = true
            view.setSelectedRange(NSRange(location: min(range.location, max(0, storage.length - 1)), length: 0))
            settingCellSelection = false
        }
        for view in textViews { view.needsDisplay = true }
        objectWillChange.send()
        DocFormatter.existing(for: self)?.updateState()
    }

    package func clearCellSelection() {
        guard tableCellSelection != nil else { return }
        tableCellSelection = nil
        for view in textViews { view.needsDisplay = true }
        objectWillChange.send()
    }

    /// Выделенные ячейки, которых больше нет (после правки), — выделение сбрасывается.
    var validCellSelection: TableCellSelection? {
        guard let selection = tableCellSelection, let rows = model.body.tables[safe: selection.table]?.rows else { return nil }
        let valid = selection.cells.allSatisfy { ref in rows[safe: ref.row].map { DocTableEdit.edges($0).indices.contains(ref.cell) } ?? false }
        return valid ? selection : nil
    }

    /// Нажатие у края ячейки / строки / столбца: выделить. `true` — обработано.
    func selectByEdgeClick(at point: NSPoint, in view: DocTextView) -> Bool {
        let story = model.body
        switch tableHit(at: point, in: view) {
        case .selectCell(let table, let ref)?:
            selectCells(DocTableEdit.selection(cell: ref, table: table, story: story), table: table)
        case .selectRow(let table, let row)?:
            selectCells(DocTableEdit.selection(row: row, table: table, story: story), table: table)
        case .selectColumn(let table, let ref)?:
            selectCells(DocTableEdit.selection(columnOf: ref, table: table, story: story), table: table)
        default: return false
        }
        return true
    }

    /// Выделение текста протянулось через несколько ячеек одной таблицы — это выделение ячеек (прямоугольник между первой и последней).
    /// `nil` — выделение внутри одной ячейки или вне таблицы.
    package func cellSelection(forTextRange range: NSRange) -> (table: Int, cells: Set<DocTableEdit.CellRef>, anchor: DocTableEdit.CellRef, focus: DocTableEdit.CellRef)? {
        guard range.length > 1, storage.length > 0 else { return nil }
        func cell(at unit: Int) -> DocTableEdit.CellRef? {
            guard let index = rendering.paragraph(atUnit: min(unit, storage.length - 1)), let ref = model.body.paragraphs[safe: index]?.cell else { return nil }
            return DocTableEdit.CellRef(row: ref.row, cell: ref.cell)
        }
        func table(at unit: Int) -> Int? {
            rendering.paragraph(atUnit: min(unit, storage.length - 1)).flatMap { model.body.paragraphs[safe: $0]?.cell?.table }
        }
        guard let first = cell(at: range.location), let last = cell(at: NSMaxRange(range) - 1),
              let tableIndex = table(at: range.location), tableIndex == table(at: NSMaxRange(range) - 1), first != last else { return nil }
        let cells = DocTableEdit.selection(from: first, to: last, table: tableIndex, story: model.body)
        return cells.count > 1 ? (tableIndex, cells, first, last) : nil
    }

    /// ⇧+стрелка при выделенных ячейках: сдвинуть вторую угловую ячейку (`dx` — по ячейкам строки, `dy` — по строкам с тем же столбцом).
    @discardableResult
    package func extendCellSelection(dx: Int, dy: Int) -> Bool {
        guard let selection = validCellSelection, let rows = model.body.tables[safe: selection.table]?.rows else { return false }
        var focus = selection.focus
        if dx != 0 {
            let count = DocTableEdit.edges(rows[focus.row]).count
            focus.cell = min(max(focus.cell + dx, 0), count - 1)
        }
        if dy != 0, let edge = DocTableEdit.edges(rows[focus.row])[safe: focus.cell] {
            let target = min(max(focus.row + dy, 0), rows.count - 1)
            let centre = (edge.left + edge.right) / 2
            if let index = DocTableEdit.edges(rows[target]).firstIndex(where: { $0.left <= centre && centre <= $0.right }) { focus = DocTableEdit.CellRef(row: target, cell: index) }
        }
        let cells = DocTableEdit.selection(from: selection.anchor, to: focus, table: selection.table, story: model.body)
        selectCells(cells, table: selection.table, anchor: selection.anchor, focus: focus)
        return true
    }

    /// Delete / Backspace при выделенных ячейках: очистить их содержимое (ячейки остаются).
    @discardableResult
    package func clearSelectedCells() -> Bool {
        guard let selection = validCellSelection, let tab else { return false }
        let result = DocTableEdit.clearCells(table: selection.table, cells: selection.cells, model: model, source: tab.text)
        return applyTable(result, actionName: "Очистить ячейки")
    }

    // MARK: - Рисунок выделения

    /// Заливка выделенных ячеек на странице `view` (вызывается из `DocTextView.draw`).
    func drawCellSelection(in view: DocTextView) {
        guard let selection = validCellSelection else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.28).setFill()
        for ref in selection.cells {
            guard let found = cellRect(table: selection.table, row: ref.row, cell: ref.cell), found.view === view else { continue }
            found.rect.fill()
        }
    }
}

/// Выделенные ячейки одной таблицы.
struct TableCellSelection: Equatable {
    var table: Int
    var cells: Set<DocTableEdit.CellRef>
    var anchor: DocTableEdit.CellRef
    var focus: DocTableEdit.CellRef
}

/// Линия-подсказка при протяжке границы: пунктир по высоте (столбец) или ширине (строка) страницы.
final class DocGuideLine: NSView {
    let vertical: Bool
    private let area: NSRect

    var position: CGFloat = 0 {
        didSet {
            frame = vertical ? NSRect(x: position - 1, y: area.minY, width: 2, height: area.height)
                : NSRect(x: area.minX, y: position - 1, width: area.width, height: 2)
            needsDisplay = true
        }
    }

    init(vertical: Bool, in area: NSRect) {
        self.vertical = vertical
        self.area = area
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        if vertical {
            path.move(to: NSPoint(x: bounds.midX, y: bounds.minY))
            path.line(to: NSPoint(x: bounds.midX, y: bounds.maxY))
        } else {
            path.move(to: NSPoint(x: bounds.minX, y: bounds.midY))
            path.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
        }
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

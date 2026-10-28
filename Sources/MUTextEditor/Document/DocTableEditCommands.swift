import AppKit
import MUCore

/// Команды таблиц «Документа» (E-1): строки и Tab по ячейкам. Правки — через `apply` (один шаг отмены, общий с «Кодом»).
extension DocumentController {
    /// Ячейка под курсором (начало выделения) в основном тексте.
    package var cellAtSelection: RTFCellRef? {
        guard let index = rendering.paragraph(atUnit: min(selectedUnits.location, max(0, rendering.length - 1))) else { return nil }
        return model.body.paragraphs[safe: index]?.cell
    }

    /// Вставить строку выше или ниже строки под курсором; курсор — в первую ячейку новой строки.
    @discardableResult
    package func insertTableRow(below: Bool) -> Bool {
        guard let tab, let cell = cellAtSelection else { return false }
        let result = DocTableEdit.insertRow(table: cell.table, row: cell.row, below: below, model: model, map: rendering.map,
                                            rendering: rendering, source: tab.text)
        return applyTable(result, actionName: "Вставка строки")
    }

    /// Удалить строку под курсором.
    @discardableResult
    package func deleteTableRow() -> Bool {
        guard let tab, let cell = cellAtSelection else { return false }
        return applyTable(DocTableEdit.deleteRow(table: cell.table, row: cell.row, model: model, source: tab.text), actionName: "Удаление строки")
    }

    /// Tab в ячейке — следующая ячейка (её текст выделяется), в последней — новая строка ниже; ⇧Tab — предыдущая.
    /// `false` — курсор не в таблице (Tab — обычная табуляция).
    package func tabInTable(forward: Bool) -> Bool {
        guard let cell = cellAtSelection else { return false }
        if let next = DocTableEdit.neighbor(of: cell, forward: forward, story: model.body) {
            guard let units = DocTableEdit.contentUnits(of: next, story: model.body, rendering: rendering),
                  let view = textView(forUnit: units.location) ?? textViews.first else { return true }
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(units)
            reveal(units)
        } else if forward {
            insertTableRow(below: true)
        } else {
            show(notice: "Это первая ячейка таблицы")
            Feedback.beep()
        }
        return true
    }

    func applyTable(_ result: DocTableEdit.Result, actionName: String) -> Bool {
        if let refusal = result.refusal {
            show(notice: refusal)
            Feedback.beep()
            return false
        }
        let caret = result.caretSource
        return apply(result.edits, actionName: actionName) { rendering in
            NSRange(location: rendering.map.firstUnit(atOrAfter: caret), length: 0)
        }
    }
}

// MARK: - E-3: столбцы, объединение, границы, заливка, вставка таблицы, ширина

extension DocumentController {
    /// Таблица и ячейки выделения (только одной таблицы основного текста); у курсора — его ячейка.
    var selectedTableCells: (table: Int, cells: Set<DocTableEdit.CellRef>)? {
        let units = selectedUnits
        let first = rendering.paragraph(atUnit: min(units.location, max(0, rendering.length - 1)))
        let last = rendering.paragraph(atUnit: min(max(units.location, NSMaxRange(units) - 1), max(0, rendering.length - 1)))
        guard let first, let last else { return nil }
        var table: Int?
        var cells = Set<DocTableEdit.CellRef>()
        for index in first...max(first, last) {
            guard let cell = model.body.paragraphs[safe: index]?.cell else { continue }
            if table == nil { table = cell.table }
            guard table == cell.table else { return nil }
            cells.insert(DocTableEdit.CellRef(row: cell.row, cell: cell.cell))
        }
        guard let table, !cells.isEmpty else { return nil }
        return (table, cells)
    }

    @discardableResult
    func runTableCommand(_ actionName: String, _ make: (_ table: Int, _ cells: Set<DocTableEdit.CellRef>, _ source: NSString) -> DocTableEdit.Result) -> Bool {
        guard let tab, let selection = selectedTableCells else { return false }
        return applyTable(make(selection.table, selection.cells, tab.text), actionName: actionName)
    }

    /// Ячейка под курсором — для команд одной ячейки (верхняя левая выделения).
    private func anchor(_ cells: Set<DocTableEdit.CellRef>) -> DocTableEdit.CellRef {
        cells.min { ($0.row, $0.cell) < ($1.row, $1.cell) }!
    }

    @discardableResult
    func insertTableColumn(right: Bool) -> Bool {
        runTableCommand("Вставка столбца") { table, cells, source in
            DocTableEdit.insertColumn(table: table, at: anchor(cells), right: right, model: model, source: source)
        }
    }

    @discardableResult
    func deleteTableColumn() -> Bool {
        runTableCommand("Удаление столбца") { table, cells, source in
            DocTableEdit.deleteColumn(table: table, at: anchor(cells), model: model, source: source)
        }
    }

    @discardableResult
    func mergeTableCells() -> Bool {
        runTableCommand("Объединение ячеек") { table, cells, source in
            DocTableEdit.merge(table: table, cells: cells, model: model, source: source)
        }
    }

    @discardableResult
    func splitTableCell() -> Bool {
        runTableCommand("Разбиение ячейки") { table, cells, source in
            DocTableEdit.split(table: table, at: anchor(cells), model: model, source: source)
        }
    }

    @discardableResult
    func setTableBorders(_ preset: DocTableEdit.BorderPreset) -> Bool {
        runTableCommand("Границы") { table, cells, source in
            DocTableEdit.borders(table: table, cells: cells, preset: preset, model: model, source: source)
        }
    }

    @discardableResult
    func setTableShading(_ color: RTFColor?) -> Bool {
        runTableCommand("Заливка") { table, cells, source in
            DocTableEdit.shading(table: table, cells: cells, color: color, model: model, source: source)
        }
    }

    /// Вставить таблицу после абзаца под курсором (на всю ширину полосы текста его раздела).
    @discardableResult
    func insertTable(rows: Int, columns: Int) -> Bool {
        guard let tab, let index = rendering.paragraph(atUnit: min(selectedUnits.location, max(0, rendering.length - 1))),
              let paragraph = model.body.paragraphs[safe: index] else { return false }
        let props = model.sections[safe: paragraph.section]?.props ?? RTFSectionProps()
        let width = Int((DocPageView.bodyRect(props).width * 20).rounded())
        return applyTable(DocTableEdit.insertTable(rows: rows, columns: columns, after: index, textWidth: width, model: model, source: tab.text),
                          actionName: "Вставка таблицы")
    }

    /// Пункты контекстного меню: в таблице — строки, столбцы, объединение, границы, заливка; вне — вставка таблицы.
    func tableMenuItems() -> [NSMenuItem] {
        func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let handler = DocMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(DocMenuAction.perform(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            return item
        }
        guard selectedTableCells != nil else {
            let sizes = [(2, 2), (3, 2), (3, 3), (4, 4), (5, 2)]
            return [submenu("Вставить таблицу", sizes.map { size in
                item("\(size.0) × \(size.1)") { [weak self] in self?.insertTable(rows: size.1, columns: size.0) }
            })]
        }
        let shades: [(String, RTFColor?)] = [("Без заливки", nil), ("Серая", RTFColor(red: 217, green: 217, blue: 217)),
                                             ("Жёлтая", RTFColor(red: 255, green: 242, blue: 204)),
                                             ("Голубая", RTFColor(red: 222, green: 234, blue: 246)),
                                             ("Зелёная", RTFColor(red: 226, green: 239, blue: 217))]
        return [submenu("Таблица", [
            item("Вставить строку выше") { [weak self] in self?.insertTableRow(below: false) },
            item("Вставить строку ниже") { [weak self] in self?.insertTableRow(below: true) },
            item("Вставить столбец слева") { [weak self] in self?.insertTableColumn(right: false) },
            item("Вставить столбец справа") { [weak self] in self?.insertTableColumn(right: true) },
            .separator(),
            item("Удалить строку") { [weak self] in self?.deleteTableRow() },
            item("Удалить столбец") { [weak self] in self?.deleteTableColumn() },
            .separator(),
            item("Объединить ячейки") { [weak self] in self?.mergeTableCells() },
            item("Разбить ячейку") { [weak self] in self?.splitTableCell() },
            .separator(),
            submenu("Границы", [
                item("Все границы") { [weak self] in self?.setTableBorders(.all) },
                item("Внешние границы") { [weak self] in self?.setTableBorders(.outer) },
                item("Без границ") { [weak self] in self?.setTableBorders(.none) },
            ]),
            submenu("Заливка", shades.map { shade in item(shade.0) { [weak self] in self?.setTableShading(shade.1) } }),
        ])]
    }

    // MARK: Ширина столбца перетаскиванием

    /// Граница ячеек под точкой (координаты страницы `view`): таблица, правый край ячейки (твипы) и x линии в view.
    func tableBoundary(at point: NSPoint, in view: DocTextView) -> (table: Int, boundary: Int, x: CGFloat)? {
        guard let container = view.textContainer, storage.length > 0 else { return nil }
        let origin = view.textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length,
              let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle,
              let block = style.textBlocks.last as? NSTextTableBlock,
              let index = rendering.paragraph(atUnit: character), let cell = model.body.paragraphs[safe: index]?.cell,
              let row = model.body.tables[safe: cell.table]?.rows[safe: cell.row] else { return nil }
        let frame = cellFrame(character, block: block)
        guard local.y >= frame.minY - 2, local.y <= frame.maxY + 2 else { return nil }
        let edges = DocTableEdit.edges(row)
        if abs(local.x - frame.maxX) <= 3, let edge = edges[safe: cell.cell] {
            return (cell.table, edge.right, frame.maxX + origin.x)
        }
        if abs(local.x - frame.minX) <= 3, cell.cell > 0, let edge = edges[safe: cell.cell - 1] {
            return (cell.table, edge.right, frame.minX + origin.x)
        }
        return nil
    }

    /// Рамка ячейки (в координатах контейнера): строка текста ячейки, расширенная на поля блока.
    func cellFrame(_ character: Int, block: NSTextBlock) -> NSRect {
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let left = block.width(for: .padding, edge: .minX) + block.width(for: .border, edge: .minX)
        let right = block.width(for: .padding, edge: .maxX) + block.width(for: .border, edge: .maxX)
        return NSRect(x: line.minX - left, y: line.minY, width: line.width + left + right, height: line.height)
    }

    /// Перетаскивание границы: линия-подсказка, на отпускании — правка ширины (одна, с отменой).
    func dragTableBoundary(_ event: NSEvent, in view: DocTextView) -> Bool {
        let start = view.convert(event.locationInWindow, from: nil)
        guard let hit = tableBoundary(at: start, in: view), let window = view.window else { return false }
        let guide = NSBox(frame: NSRect(x: hit.x, y: view.bounds.minY, width: 1, height: view.bounds.height))
        guide.boxType = .custom
        guide.borderWidth = 0
        guide.fillColor = .controlAccentColor
        view.addSubview(guide)
        defer { guide.removeFromSuperview() }
        var last = start
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            last = view.convert(next.locationInWindow, from: nil)
            guide.frame.origin.x = hit.x + last.x - start.x
            NSCursor.resizeLeftRight.set()
            if next.type == .leftMouseUp { break }
        }
        let delta = Int(((last.x - start.x) * 20).rounded())
        guard delta != 0, let tab else { return true }
        let result = DocTableEdit.moveBoundary(table: hit.table, boundary: hit.boundary, delta: delta, model: model, source: tab.text)
        if result.refusal != nil || !result.edits.isEmpty { _ = applyTable(result, actionName: "Ширина столбца") }
        return true
    }
}

/// Пункт меню с замыканием (цель пункта меню — слабая ссылка, поэтому обработчик лежит в `representedObject`).
final class DocMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func perform(_ sender: Any?) { action() }
}

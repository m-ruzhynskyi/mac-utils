import AppKit

/// Команды таблиц «Документа» (E-1): строки и Tab по ячейкам. Правки — через `apply` (один шаг отмены, общий с «Кодом»).
extension DocumentController {
    /// Ячейка под курсором (начало выделения) в основном тексте.
    var cellAtSelection: RTFCellRef? {
        guard let index = rendering.paragraph(atUnit: min(selectedUnits.location, max(0, rendering.length - 1))),
              let paragraph = model.body.paragraphs[safe: index], let cell = paragraph.cell else { return nil }
        // Строки с вложенной таблицей и строки самой вложенной таблицы команды строк пока не меняют (P-4).
        let tables = model.body.tables
        guard paragraph.outerCell == nil, tables[safe: cell.table]?.nested != true,
              !tables.contains(where: { $0.parent?.table == cell.table && $0.parent?.row == cell.row }) else { return nil }
        return cell
    }

    /// Вставить строку выше или ниже строки под курсором; курсор — в первую ячейку новой строки.
    @discardableResult
    func insertTableRow(below: Bool) -> Bool {
        guard let tab, let cell = cellAtSelection else { return false }
        let result = DocTableEdit.insertRow(table: cell.table, row: cell.row, below: below, model: model, map: rendering.map,
                                            rendering: rendering, source: tab.text)
        return applyTable(result, actionName: "Вставка строки")
    }

    /// Удалить строку под курсором.
    @discardableResult
    func deleteTableRow() -> Bool {
        guard let tab, let cell = cellAtSelection else { return false }
        return applyTable(DocTableEdit.deleteRow(table: cell.table, row: cell.row, model: model, source: tab.text), actionName: "Удаление строки")
    }

    /// Tab в ячейке — следующая ячейка (её текст выделяется), в последней — новая строка ниже; ⇧Tab — предыдущая.
    /// `false` — курсор не в таблице (Tab — обычная табуляция).
    func tabInTable(forward: Bool) -> Bool {
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
            Feedback.beep()
        }
        return true
    }

    private func applyTable(_ result: DocTableEdit.Result, actionName: String) -> Bool {
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

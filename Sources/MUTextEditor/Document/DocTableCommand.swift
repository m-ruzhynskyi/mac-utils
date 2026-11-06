import AppKit

/// Команды контекстной вкладки «Таблица» (TB1): список, названия и доступность — здесь, вид ленты рисует интерфейс.
/// Доступность решает чистая функция по `Context`: `.hidden` — кнопки нет совсем (команда к этому месту не относится),
/// `.disabled(причина)` — кнопка есть, но не нажимается, и подсказка говорит почему. Выполняют команды готовые `DocTableEdit*`
/// через `DocumentController` (одна правка — один шаг отмены).
package enum TableCommand: CaseIterable, Hashable {
    case insertTable, rowAbove, rowBelow, columnLeft, columnRight, deleteRow, deleteColumn, merge, split, bordersAll, bordersOuter, bordersNone, shading

    package var title: String {
        switch self {
        case .insertTable: return "Вставить таблицу"
        case .rowAbove: return "Вставить строку выше"
        case .rowBelow: return "Вставить строку ниже"
        case .columnLeft: return "Вставить столбец слева"
        case .columnRight: return "Вставить столбец справа"
        case .deleteRow: return "Удалить строку"
        case .deleteColumn: return "Удалить столбец"
        case .merge: return "Объединить ячейки"
        case .split: return "Разбить ячейку"
        case .bordersAll: return "Все границы"
        case .bordersOuter: return "Внешние границы"
        case .bordersNone: return "Без границ"
        case .shading: return "Заливка"
        }
    }

    package enum Availability: Equatable {
        case hidden
        case disabled(String)
        case enabled

        package var isEnabled: Bool { self == .enabled }
        package var isVisible: Bool { self != .hidden }
    }

    /// Что известно о месте курсора (без доступа к документу — для тестов).
    package struct Context: Equatable {
        /// Курсор или выделение в ячейках одной таблицы основного текста.
        package var inTable = false
        /// Строка под курсором меняется командами строк (вложенные таблицы и строки с ними пока нет).
        package var rowEditable = false
        /// Сколько ячеек выделено.
        package var selectedCells = 0
        /// Столбцов в строке под курсором.
        package var columns = 0
        /// Выделение задевает ячейки нескольких таблиц: курсор в таблице (вставки таблицы нет), но команды ячеек не применить.
        package var severalTables = false

        package init(inTable: Bool = false, rowEditable: Bool = false, selectedCells: Int = 0, columns: Int = 0, severalTables: Bool = false) {
            self.inTable = inTable
            self.rowEditable = rowEditable
            self.selectedCells = selectedCells
            self.columns = columns
            self.severalTables = severalTables
        }
    }

    package func availability(in context: Context) -> Availability {
        if self == .insertTable { return context.inTable ? .hidden : .enabled }
        guard context.inTable else { return .hidden }
        if context.severalTables { return .disabled("Выделение захватывает несколько таблиц — выделите ячейки одной") }
        switch self {
        case .insertTable: return .hidden
        case .rowAbove, .rowBelow, .deleteRow:
            return context.rowEditable ? .enabled : .disabled("Строки вложенных таблиц и строки с вложенной таблицей пока не меняются")
        case .columnLeft, .columnRight, .split, .bordersAll, .bordersOuter, .bordersNone, .shading:
            return .enabled
        case .deleteColumn:
            return context.columns > 1 ? .enabled : .disabled("В таблице остался один столбец: удалите таблицу целиком")
        case .merge:
            return context.selectedCells > 1 ? .enabled : .disabled("Выделите несколько ячеек")
        }
    }

    /// Команды, которые показывает вкладка «Таблица» в этом месте, в порядке ленты.
    package static func visible(in context: Context) -> [TableCommand] {
        allCases.filter { $0.availability(in: context).isVisible }
    }
}

extension DocumentController {
    /// Состояние курсора для `TableCommand.availability`.
    package var tableContext: TableCommand.Context {
        guard let selection = selectedTableCells else {
            // Ячеек одной таблицы нет, но выделение задевает таблицы (две и больше): это не «вне таблицы» — иначе «Вставить таблицу»
            // была бы доступна и отказала бы, а команды ячеек пропали бы.
            let touches = paragraphs(in: selectedUnits).contains { model.body.paragraphs[safe: $0].map { $0.cell != nil || $0.props.inTable } ?? false }
            return touches ? TableCommand.Context(inTable: true, severalTables: true) : TableCommand.Context()
        }
        let columns = model.body.tables[safe: selection.table]?.rows[safe: selection.cells.min { ($0.row, $0.cell) < ($1.row, $1.cell) }?.row ?? 0]?.cells.count ?? 0
        return TableCommand.Context(inTable: true, rowEditable: cellAtSelection != nil, selectedCells: selection.cells.count, columns: columns)
    }

    /// Выполнить команду вкладки; `rows`/`columns` — размер вставляемой таблицы, `color` — заливка (`nil` — убрать).
    /// `false` — команда сейчас недоступна или отказала (отказ показан подсказкой).
    @discardableResult
    package func perform(_ command: TableCommand, color: RTFColor? = nil, rows: Int = 2, columns: Int = 2) -> Bool {
        guard command.availability(in: tableContext).isEnabled else { return false }
        switch command {
        case .insertTable: return insertTable(rows: rows, columns: columns)
        case .rowAbove: return insertTableRow(below: false)
        case .rowBelow: return insertTableRow(below: true)
        case .columnLeft: return insertTableColumn(right: false)
        case .columnRight: return insertTableColumn(right: true)
        case .deleteRow: return deleteTableRow()
        case .deleteColumn: return deleteTableColumn()
        case .merge: return mergeTableCells()
        case .split: return splitTableCell()
        case .bordersAll: return setTableBorders(.all)
        case .bordersOuter: return setTableBorders(.outer)
        case .bordersNone: return setTableBorders(.none)
        case .shading: return setTableShading(color)
        }
    }
}

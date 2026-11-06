import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// TB1: команды вкладки «Таблица» — доступность по месту курсора и 1000 случайных команд на настоящем документе.
@MainActor
final class DocTableCommandTests: XCTestCase {
    private typealias Context = TableCommand.Context

    func testOutsideTableOnlyInsertIsOffered() {
        let outside = Context()
        XCTAssertEqual(TableCommand.visible(in: outside), [.insertTable])
        XCTAssertEqual(TableCommand.insertTable.availability(in: outside), .enabled)
        XCTAssertEqual(TableCommand.merge.availability(in: outside), .hidden, "нет команды — нет кнопки")
    }

    func testInsideTableInsertIsHiddenOthersOffered() {
        let inside = Context(inTable: true, rowEditable: true, selectedCells: 1, columns: 3)
        let visible = TableCommand.visible(in: inside)
        XCTAssertFalse(visible.contains(.insertTable))
        XCTAssertEqual(Set(visible), Set(TableCommand.allCases).subtracting([.insertTable]))
    }

    func testMergeNeedsSeveralCells() {
        XCTAssertEqual(TableCommand.merge.availability(in: Context(inTable: true, rowEditable: true, selectedCells: 1, columns: 3)).isEnabled, false)
        XCTAssertTrue(TableCommand.merge.availability(in: Context(inTable: true, rowEditable: true, selectedCells: 2, columns: 3)).isEnabled)
        if case .disabled(let reason) = TableCommand.merge.availability(in: Context(inTable: true, selectedCells: 1, columns: 3)) {
            XCTAssertFalse(reason.isEmpty, "кнопка с причиной, а не тишина")
        } else { XCTFail("кнопка должна быть, но не нажиматься") }
    }

    func testLastColumnCannotBeDeletedAndNestedRowsAreRefused() {
        XCTAssertFalse(TableCommand.deleteColumn.availability(in: Context(inTable: true, rowEditable: true, selectedCells: 1, columns: 1)).isEnabled)
        XCTAssertTrue(TableCommand.deleteColumn.availability(in: Context(inTable: true, rowEditable: true, selectedCells: 1, columns: 2)).isEnabled)
        for command in [TableCommand.rowAbove, .rowBelow, .deleteRow] {
            XCTAssertFalse(command.availability(in: Context(inTable: true, rowEditable: false, selectedCells: 1, columns: 3)).isEnabled, "\(command)")
        }
    }

    func testSelectionAcrossTablesDisablesCellCommands() {
        let across = Context(inTable: true, severalTables: true)
        XCTAssertEqual(TableCommand.insertTable.availability(in: across), .hidden, "курсор в таблице — вставки таблицы нет")
        for command in TableCommand.allCases where command != .insertTable {
            guard case .disabled(let reason) = command.availability(in: across) else { return XCTFail("\(command)") }
            XCTAssertFalse(reason.isEmpty)
        }
    }

    func testTitlesAreUnique() {
        XCTAssertEqual(Set(TableCommand.allCases.map(\.title)).count, TableCommand.allCases.count)
    }

    // MARK: - На документе

    private func open() throws -> (tab: EditorTab, document: DocumentController, window: NSWindow) {
        let (workspace, tab) = DocDemo.tab(DocTableEditTests.wordTable, name: "table_cmd.frm")
        tab.restoreMode(.document)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (tab, try XCTUnwrap(tab.documentController), window)
    }

    func testContextFollowsCaretAndCommandsUndo() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let view = try XCTUnwrap(document.textViews.first)
        let text = { document.storage.string as NSString }
        let original = tab.text as String
        view.setSelectedRange(NSRange(location: text().range(of: "After").location, length: 0))
        XCTAssertEqual(TableCommand.visible(in: document.tableContext), [.insertTable])
        XCTAssertFalse(document.perform(.merge), "вне таблицы команда не выполняется")
        view.setSelectedRange(NSRange(location: text().range(of: "B1").location, length: 0))
        let context = document.tableContext
        XCTAssertTrue(context.inTable)
        XCTAssertEqual(context.columns, 2)
        XCTAssertTrue(document.perform(.columnRight))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(document.model.body.tables[0].rows[0].cells.count, 3)
        tab.undo.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
    }

    /// Выделение от ячейки одной таблицы до другой: команды видны, но выключены, «Вставить таблицу» не предлагается (раньше — «вне таблицы»:
    /// вставка была доступна и отказывала).
    func testSelectionAcrossTwoTablesOnDocument() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let view = try XCTUnwrap(document.textViews.first)
        let text = { document.storage.string as NSString }
        view.setSelectedRange(NSRange(location: text().range(of: "After").location, length: 0))
        XCTAssertTrue(document.perform(.insertTable, rows: 1, columns: 2))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(document.model.body.tables.count, 2)
        let before = tab.text as String
        let from = text().range(of: "B3").location
        view.setSelectedRange(NSRange(location: from, length: text().length - from - 1))
        let context = document.tableContext
        XCTAssertTrue(context.inTable && context.severalTables, "\(context)")
        XCTAssertFalse(TableCommand.visible(in: context).contains(.insertTable))
        XCTAssertFalse(document.perform(.insertTable))
        XCTAssertFalse(document.perform(.bordersAll))
        XCTAssertEqual(tab.text as String, before, "ничего не изменилось")
    }

    /// Объединение и разбиение на краях таблицы через команды: последняя строка целиком, две верхние строки; разбить обратно.
    /// После каждой — `\cell` = `\cellx`; отмена всех шагов — байт в байт.
    func testMergeAndSplitAtTableEdges() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let view = try XCTUnwrap(document.textViews.first)
        let text = { document.storage.string as NSString }
        let original = tab.text as String
        func check(_ step: String) {
            let model = RTFReader.read(tab.text)
            XCTAssertEqual(DocTableEdit.violations(model), 0, step)
            XCTAssertEqual(DocTableEdit.definitionMismatches(model, source: tab.text), 0, step)
        }
        // Нижний край: A3 + B3 → одна ячейка во всю ширину.
        let a3 = text().range(of: "A3").location
        view.setSelectedRange(NSRange(location: a3, length: text().range(of: "B3").location - a3 + 1))
        XCTAssertEqual(document.tableContext.selectedCells, 2)
        XCTAssertTrue(document.perform(.merge))
        check("merge last row")
        XCTAssertEqual(document.model.body.tables[0].rows[2].cells.count, 1)
        // Верхний край: от B1 до B2 — выделение по тексту берёт строки 1–2 целиком (с объединённой по вертикали A1–A2), как в Word.
        let b1 = text().range(of: "B1").location
        view.setSelectedRange(NSRange(location: b1, length: text().range(of: "B2").location - b1 + 1))
        XCTAssertTrue(document.perform(.merge))
        check("merge top rows")
        XCTAssertEqual(document.model.body.tables[0].rows[0].cells.count, 1)
        XCTAssertTrue(document.model.body.tables[0].rows[1].cells[0].verticalMerged)
        // Разбить: верхняя (по вертикали) — обратно на строки, нижняя широкая — на две.
        view.setSelectedRange(NSRange(location: text().range(of: "B1").location, length: 0))
        XCTAssertTrue(document.perform(.split))
        check("split top rows")
        XCTAssertFalse(document.model.body.tables[0].rows[1].cells.contains(where: \.verticalMerged))
        view.setSelectedRange(NSRange(location: text().range(of: "A3").location, length: 0))
        XCTAssertTrue(document.perform(.split))
        check("split last row")
        XCTAssertEqual(document.model.body.tables[0].rows[2].cells.count, 2)
        for _ in 0..<4 { tab.undo.undo() }
        XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
    }

    /// Случайные команды вкладки через контроллер: после каждой в каждой строке `\cell` = `\cellx` и `\cellx` возрастают.
    /// По умолчанию 200 шагов (≈ 2 с); полный прогон на 1000 — `MU_TABLE_STEPS=1000` (≈ 6 мин).
    func testThousandRandomCommandsKeepCellsEqualCellx() throws {
        let steps = Int(ProcessInfo.processInfo.environment["MU_TABLE_STEPS"] ?? "") ?? 200
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        var random = SeededRandom(seed: 20_261_105)
        let commands = TableCommand.allCases
        var done = 0, refused = 0
        for step in 0..<steps {
            let view = try XCTUnwrap(document.textViews.first)
            let shown = document.storage.string as NSString
            // Курсор — в случайное место; иногда выделение на несколько знаков (несколько ячеек).
            let at = random.next(max(1, shown.length))
            let length = random.next(3) == 0 ? min(random.next(60), shown.length - at) : 0
            view.setSelectedRange(NSRange(location: at, length: max(0, length)))
            let command = commands[random.next(commands.count)]
            let color = random.next(2) == 0 ? nil : RTFColor(red: 200 + random.next(50), green: 220, blue: 240)
            let allowed = command.availability(in: document.tableContext).isEnabled
            let ok = document.perform(command, color: color, rows: 1 + random.next(3), columns: 1 + random.next(3))
            if !allowed { XCTAssertFalse(ok, "шаг \(step): \(command) недоступна, но выполнилась") }
            if allowed, command == .insertTable { XCTAssertTrue(ok, "шаг \(step): «Вставить таблицу» доступна, но отказала") }
            ok ? (done += 1) : (refused += 1)
            if step % 25 == 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            let model = RTFReader.read(tab.text)
            XCTAssertEqual(DocTableEdit.violations(model), 0, "шаг \(step): \(command) — \\cell ≠ \\cellx")
            XCTAssertEqual(DocTableEdit.definitionMismatches(model, source: tab.text), 0, "шаг \(step): \(command) — копии определения строки")
            if DocTableEdit.violations(model) != 0 { break }
        }
        XCTAssertGreaterThan(done, steps / 10, "команды реально выполнялись (выполнено \(done), отказов \(refused))")
    }
}

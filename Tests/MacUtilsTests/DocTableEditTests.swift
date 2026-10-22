import AppKit
import SwiftUI
import XCTest
@testable import MacUtils

/// Правка таблиц в «Документе» (E-1): склейка и удаление в ячейках, через границу ячеек, вставить/удалить строку,
/// Tab по ячейкам. Проверки «без потерь»: байты вне правок те же, скобок не хуже, разбор открывает, отмена — байт в байт,
/// у каждой строки `\cell` столько же, сколько `\cellx`, и `\cellx` возрастают.
@MainActor
final class DocTableEditTests: XCTestCase {
    /// Демо (выдуманный текст) по структуре форм Word: определение строки ещё раз в конце (`{… \trowd … \row \ltrrow}`),
    /// абзацы в ячейках, объединение по вертикали через две строки, кириллица `\'hh`.
    static let wordTable = #"""
    {\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}
    \pard\plain\f0\fs24 {\insrsid1 Before}{\insrsid1 \par \ltrrow}\trowd \irow0\irowband0\ltrrow\trgaph108\trleft-108\clvmgf\clbrdrt\brdrs\brdrw10 \cellx2000\clbrdrt\brdrs\brdrw10 \cellx5000\pard \ltrpar\qc\intbl {\fs20 A1 first\par A1 second}{\fs20 \cell }{\b B1\cell }\pard \ltrpar\intbl {\trowd \irow0\irowband0\ltrrow\trgaph108\trleft-108\clvmgf\clbrdrt\brdrs\brdrw10 \cellx2000\clbrdrt\brdrs\brdrw10 \cellx5000\row \ltrrow}
    \trowd \irow1\irowband1\ltrrow\trgaph108\trleft-108\clvmrg\cellx2000\cellx5000\pard \ltrpar\intbl {\cell }{B2 \'c4\'e0\'ed\'ee\cell }\pard \ltrpar\intbl {\trowd \irow1\irowband1\ltrrow\trgaph108\trleft-108\clvmrg\cellx2000\cellx5000\row \ltrrow}
    \trowd \irow2\irowband2\lastrow\ltrrow\trgaph108\trleft-108\cellx2000\cellx5000\pard \ltrpar\intbl {A3\cell }{B3\par B3 more\cell }\pard \ltrpar\intbl {\trowd \irow2\irowband2\lastrow\ltrrow\trgaph108\trleft-108\cellx2000\cellx5000\row }
    \pard\plain\f0\fs24 After\par}
    """#

    // MARK: - Проверки

    /// Нарушения структуры: строка, где число ячеек (`\cell`) не равно числу `\cellx`, или `\cellx` не возрастают.
    static func structureViolations(_ model: RTFDocumentModel) -> Int {
        var count = 0
        for table in model.body.tables {
            for row in table.rows {
                if row.paragraphs.count != row.cells.count { count += 1 }
                if zip(row.cells, row.cells.dropFirst()).contains(where: { $0.right >= $1.right }) { count += 1 }
            }
        }
        return count
    }

    /// Применить правки таблицы и проверить: только указанные куски, скобки, разбор, структура не хуже, отмена.
    @discardableResult
    static func apply(_ result: DocTableEdit.Result, to source: inout String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard result.refusal == nil, !result.edits.isEmpty else { return false }
        let before = source as NSString
        let model = RTFReader.read(before)
        let after = NSMutableString(string: source)
        var undo: [(NSRange, String)] = []
        var shift = 0
        for edit in result.edits.sorted(by: { $0.range.location < $1.range.location }) {
            let location = edit.range.location + shift
            undo.append((NSRange(location: location, length: (edit.text as NSString).length), before.substring(with: edit.range)))
            after.replaceCharacters(in: NSRange(location: location, length: edit.range.length), with: edit.text)
            shift += (edit.text as NSString).length - edit.range.length
        }
        XCTAssertLessThanOrEqual(DollarMarks.unbalancedBraces(in: after), DollarMarks.unbalancedBraces(in: before), "скобки", file: file, line: line)
        let reread = RTFReader.read(after)
        XCTAssertTrue(reread.isRTF, file: file, line: line)
        XCTAssertLessThanOrEqual(structureViolations(reread), structureViolations(model), "структура таблиц", file: file, line: line)
        let restored = NSMutableString(string: after)
        for (range, text) in undo.reversed() { restored.replaceCharacters(in: range, with: text) }
        XCTAssertEqual(restored as String, before as String, "отмена — байт в байт", file: file, line: line)
        source = after as String
        return true
    }

    private static func rendering(_ source: String) -> (RTFDocumentModel, DocRendering) {
        let model = RTFReader.read(source as NSString)
        return (model, DocRenderer().render(model, previous: nil).0)
    }

    private static func insertRow(_ source: inout String, table: Int, row: Int, below: Bool, file: StaticString = #filePath,
                                  line: UInt = #line) -> DocTableEdit.Result {
        let (model, rendering) = rendering(source)
        let result = DocTableEdit.insertRow(table: table, row: row, below: below, model: model, map: rendering.map, rendering: rendering,
                                            source: source as NSString)
        apply(result, to: &source, file: file, line: line)
        return result
    }

    private static func deleteRow(_ source: inout String, table: Int, row: Int, file: StaticString = #filePath, line: UInt = #line) -> DocTableEdit.Result {
        let result = DocTableEdit.deleteRow(table: table, row: row, model: RTFReader.read(source as NSString), source: source as NSString)
        apply(result, to: &source, file: file, line: line)
        return result
    }

    private func visible(_ source: String) -> String { DocReaderTests.visibleText(RTFReader.read(source as NSString).body) }

    // MARK: - Абзацы в ячейке и границы ячеек

    func testMergeParagraphsInsideCell() throws {
        var harness = DocEditTests.Harness(source: Self.wordTable)
        XCTAssertTrue(visible(harness.source).contains("A1 first\nA1 second\u{7}"))
        // ⌫ в начале второго абзаца ячейки — абзацы склеиваются (свойства первого), ячейка та же.
        let second = (harness.display().0 as NSString).range(of: "A1 second").location
        let result = harness.edit(NSRange(location: second - 1, length: 1), "")
        XCTAssertNil(result.refusal)
        XCTAssertTrue(visible(harness.source).contains("A1 firstA1 second\u{7}"))
        // Delete в конце первого абзаца ячейки B3 — тоже.
        let end = NSMaxRange((harness.display().0 as NSString).range(of: "B3"))
        harness.edit(NSRange(location: end, length: 1), "")
        XCTAssertTrue(visible(harness.source).contains("B3B3 more\u{7}"))
        let model = harness.model
        XCTAssertEqual(model.body.tables.first?.rows.map(\.paragraphs.count), [2, 2, 2])
        XCTAssertEqual(Self.structureViolations(model), 0)
    }

    func testDeleteAcrossCellsKeepsStructure() throws {
        var harness = DocEditTests.Harness(source: Self.wordTable)
        let shown = harness.display().0 as NSString
        // От середины A1 до середины B3: стирается текст, ячейки и строки остаются (как в Word).
        let from = shown.range(of: "first").location
        let to = shown.range(of: "more").location
        harness.edit(NSRange(location: from, length: to - from), "")
        let model = harness.model
        XCTAssertEqual(model.body.tables.first?.rows.count, 3)
        XCTAssertEqual(model.body.tables.first?.rows.map(\.paragraphs.count), [2, 2, 2])
        XCTAssertEqual(Self.structureViolations(model), 0)
        XCTAssertTrue(visible(harness.source).hasPrefix("Before\nA1 \u{7}\u{7}\u{7}\u{7}\u{7}more\u{7}"), visible(harness.source))
        // ⌫ в начале ячейки (только конец предыдущей) — ничего не меняется и без подсказки «в коде».
        let (shownNow, map) = harness.display()
        let more = (shownNow as NSString).range(of: "more").location
        let refused = DocTextEditor.replace(NSRange(location: more - 1, length: 1), with: "", model: harness.model, map: map,
                                            source: harness.source as NSString)
        XCTAssertTrue(refused.edits.isEmpty)
        XCTAssertNil(refused.refusal, "как в Word — тихо")
    }

    // MARK: - Строки

    func testRowSpanIsBalanced() throws {
        let source = Self.wordTable as NSString
        let model = RTFReader.read(source)
        for row in 0..<3 {
            let span = try XCTUnwrap(DocTableEdit.rowSpan(table: 0, row: row, story: model.body, source: source))
            let text = source.substring(with: span)
            XCTAssertTrue(text.hasPrefix("\\trowd"), "строка \(row) — от \\trowd")
            XCTAssertTrue(text.hasSuffix("}"), "и до скобки после \\row")
            XCTAssertEqual(DollarMarks.unbalancedBraces(in: text as NSString), 0)
        }
    }

    func testInsertRowBelowAndAbove() throws {
        var source = Self.wordTable
        // Ниже последней — пустая строка тех же ячеек; объединения нет.
        var result = Self.insertRow(&source, table: 0, row: 2, below: true)
        XCTAssertNil(result.refusal)
        XCTAssertEqual(result.edits.count, 1, "одна вставка")
        XCTAssertEqual(result.edits.first?.range.length, 0)
        var rows = RTFReader.read(source as NSString).body.tables[0].rows
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[3].cells.map(\.right), [2000, 5000])
        XCTAssertTrue(visible(source).hasSuffix("B3\nB3 more\u{7}\u{7}\u{7}After\n"), visible(source))
        // Ниже первой (внутри объединения A1–A2): новая ячейка продолжает объединение.
        result = Self.insertRow(&source, table: 0, row: 0, below: true)
        rows = RTFReader.read(source as NSString).body.tables[0].rows
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows[1].cells[0].verticalMerged)
        XCTAssertFalse(rows[1].cells[0].verticalMergeFirst)
        XCTAssertTrue(rows[0].cells[0].verticalMergeFirst, "начало объединения — прежнее")
        XCTAssertTrue(rows[2].cells[0].verticalMerged)
        // Выше первой: копия первой строки без начала объединения (объединение начинается ниже).
        Self.insertRow(&source, table: 0, row: 0, below: false)
        rows = RTFReader.read(source as NSString).body.tables[0].rows
        XCTAssertEqual(rows.count, 6)
        XCTAssertFalse(rows[0].cells[0].verticalMergeFirst || rows[0].cells[0].verticalMerged)
        XCTAssertTrue(rows[1].cells[0].verticalMergeFirst)
        XCTAssertTrue(visible(source).hasPrefix("Before\n\u{7}\u{7}A1 first\nA1 second\u{7}B1\u{7}"), visible(source))
        // Свойства первого абзаца ячейки сохраняются (жирный B1 → пустая ячейка тоже с \b).
        XCTAssertEqual(Self.structureViolations(RTFReader.read(source as NSString)), 0)
    }

    func testDeleteRows() throws {
        var source = Self.wordTable
        // Первая строка начинала объединение A1–A2: начало переходит ко второй.
        Self.deleteRow(&source, table: 0, row: 0)
        var rows = RTFReader.read(source as NSString).body.tables[0].rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].cells[0].verticalMergeFirst)
        XCTAssertTrue(visible(source).hasPrefix("Before\n\u{7}B2 Дано\u{7}A3\u{7}"), visible(source))
        XCTAssertTrue(source.contains("\\irow1\\irowband1\\ltrrow\\trgaph108\\trleft-108\\clvmgf\\cellx2000"))
        // Все строки — таблицы нет, текст вокруг цел.
        Self.deleteRow(&source, table: 0, row: 1)
        Self.deleteRow(&source, table: 0, row: 0)
        XCTAssertTrue(RTFReader.read(source as NSString).body.tables.isEmpty)
        XCTAssertEqual(visible(source), "Before\nAfter\n")
        XCTAssertFalse(source.contains("\\trowd"))
    }

    func testRowsOfSimpleTable() throws {
        // Таблица без повторного определения в конце строки (`\trowd … \cell \row`).
        var source = DocReaderTests.table
        Self.insertRow(&source, table: 0, row: 1, below: true)
        XCTAssertEqual(RTFReader.read(source as NSString).body.tables[0].rows.count, 3)
        Self.deleteRow(&source, table: 0, row: 0)
        let rows = RTFReader.read(source as NSString).body.tables[0].rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].cells[0].verticalMergeFirst, "продолжение объединения стало началом")
    }

    // MARK: - Tab

    func testTabOrder() throws {
        let (model, rendering) = Self.rendering(Self.wordTable)
        let story = model.body
        let a1 = RTFCellRef(table: 0, row: 0, cell: 0)
        XCTAssertEqual(DocTableEdit.neighbor(of: a1, forward: true, story: story), RTFCellRef(table: 0, row: 0, cell: 1))
        // A2 — продолжение объединения: Tab его пропускает.
        XCTAssertEqual(DocTableEdit.neighbor(of: RTFCellRef(table: 0, row: 0, cell: 1), forward: true, story: story),
                       RTFCellRef(table: 0, row: 1, cell: 1))
        XCTAssertNil(DocTableEdit.neighbor(of: RTFCellRef(table: 0, row: 2, cell: 1), forward: true, story: story), "последняя — новая строка")
        XCTAssertNil(DocTableEdit.neighbor(of: a1, forward: false, story: story))
        let units = try XCTUnwrap(DocTableEdit.contentUnits(of: RTFCellRef(table: 0, row: 2, cell: 1), story: story, rendering: rendering))
        let shown = DocRenderer().render(model, previous: nil).1.string.string as NSString
        XCTAssertEqual(shown.substring(with: units), "B3\nB3 more")
    }

    /// В окне (офскрин): Tab — следующая ячейка с выделенным текстом, в последней — новая строка; ⇧Tab — назад; отмена.
    func testTabInDocumentWindow() throws {
        let (workspace, tab) = DocDemo.tab(Self.wordTable, name: "table_demo.frm")
        tab.restoreMode(.document)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let document = try XCTUnwrap(tab.documentController)
        let view = try XCTUnwrap(document.textViews.first)
        let text = { document.storage.string as NSString }
        view.setSelectedRange(NSRange(location: text().range(of: "B1").location, length: 0))
        view.insertTab(nil)
        XCTAssertEqual(text().substring(with: view.selectedRange()), "B2 Дано")
        view.insertBacktab(nil)
        XCTAssertEqual(text().substring(with: view.selectedRange()), "B1")
        let original = tab.text as String
        view.setSelectedRange(NSRange(location: text().range(of: "B3 more").location, length: 0))
        view.insertTab(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(document.model.body.tables[0].rows.count, 4, "Tab в последней ячейке — новая строка")
        XCTAssertEqual(document.cellAtSelection, RTFCellRef(table: 0, row: 3, cell: 0), "курсор — в первой ячейке новой строки")
        XCTAssertTrue(document.deleteTableRow())
        XCTAssertEqual(document.model.body.tables[0].rows.count, 3)
        tab.undo.undo()
        tab.undo.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
        // Вне таблицы Tab — обычная табуляция.
        view.setSelectedRange(NSRange(location: text().range(of: "After").location, length: 0))
        view.insertTab(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(document.storage.string.contains("\tAfter"))
    }

    // MARK: - Случайные правки

    /// 1 000 случайных правок (семя) на демо: ввод и удаление (проверки `DocEditTests.Harness`), вставка и удаление строк.
    func testRandomTableEditsStayLossless() throws {
        var random = SeededRandom(seed: 20_261_022)
        let pieces = ["a", "Я", " ", "\n", "", "", "Текст"]
        var done = 0, rows = 0
        for document in [Self.wordTable, DocReaderTests.table, DocDemo.expertReport] {
            var harness = DocEditTests.Harness(source: document)
            for _ in 0..<334 {
                let before = harness.source
                if Self.randomStep(&harness, random: &random, pieces: pieces).hasPrefix("row"), harness.source != before { rows += 1 }
                done += 1
            }
            XCTAssertEqual(Self.structureViolations(harness.model), 0)
        }
        XCTAssertGreaterThanOrEqual(done, 1_000)
        XCTAssertGreaterThan(rows, 100, "строки вставлялись и удалялись")
        print("table-edits demo: steps \(done), row operations \(rows)")
    }

    /// Один случайный шаг: строка (вставить выше/ниже, удалить) или правка текста — чаще внутри таблиц.
    @discardableResult
    static func randomStep(_ harness: inout DocEditTests.Harness, random: inout SeededRandom, pieces: [String], check: Bool = true) -> String {
        let model = harness.model
        let tables = model.body.tables
        let choice = random.next(10)
        if choice < 3, !tables.isEmpty {
            let table = random.next(tables.count)
            let row = random.next(tables[table].rows.count)
            if choice == 2 {
                deleteRow(&harness.source, table: table, row: row)
            } else {
                _ = insertRow(&harness.source, table: table, row: row, below: choice == 0)
            }
            return "row \(choice) table \(table) row \(row)"
        }
        let (_, map) = harness.display()
        guard map.count > 0 else { return "" }
        // Половина правок — в таблице: место из показанных единиц ячеек. Курсора после последнего ¶ нет (как в Word).
        var location = random.next(map.count)
        if random.next(2) == 0, let table = tables.indices.randomElement(using: &random) {
            let rendering = Self.rendering(harness.source).1
            let indices = tables[table].rows.flatMap { $0.paragraphs.flatMap { $0 } }
            if let index = indices.randomElement(using: &random), let range = rendering.paragraphRanges[safe: index] {
                location = range.location + random.next(range.length + 1)
            }
        }
        let length = random.next(3) == 0 ? random.next(min(10, map.count - min(location, map.count)) + 1) : 0
        let piece = random.next(pieces.count)
        harness.edit(NSRange(location: location, length: length), pieces[piece], check: check)
        return "text \(location) \(length) piece \(piece)"
    }

    // MARK: - Копии форм (по переменной)

    /// `MU_REAL_FRM_DIR` — папка КОПИЙ форм: 100 случайных правок на файл, 0 нарушений структуры. В отчёт — только числа.
    func testRealFormsTableEdits() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_REAL_FRM_DIR"], !path.isEmpty else {
            throw XCTSkip("MU_REAL_FRM_DIR не задан")
        }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.lowercased().hasSuffix(".frm") }.sorted()
        var files = 0, steps = 0, violations = 0, rowOps = 0
        let started = Date()
        let only = ProcessInfo.processInfo.environment["MU_TABLE_EDIT_ONLY"].flatMap { Int($0) }
        for (number, name) in names.enumerated() {
            if let only, only != number { continue }
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { continue }
            let text = EditorDocument(data: data).decodedText as String
            let model = RTFReader.read(text as NSString)
            guard model.isRTF, !model.body.tables.isEmpty else { continue }
            let baseline = Self.structureViolations(model)
            var harness = DocEditTests.Harness(source: text)
            var random = SeededRandom(seed: 100 + UInt64(number))
            autoreleasepool {
                for step in 0..<100 {
                    let before = harness.source
                    let failures = testRun?.failureCount ?? 0
                    let operation = Self.randomStep(&harness, random: &random, pieces: ["x", "Ж", "\n", "", " "])
                    if (testRun?.failureCount ?? 0) > failures { print("table-edits: file #\(number) step \(step): \(operation)") }
                    if harness.source != before, !harness.model.body.tables.isEmpty || !model.body.tables.isEmpty { rowOps += 1 }
                    steps += 1
                }
            }
            violations += max(0, Self.structureViolations(harness.model) - baseline)
            files += 1
        }
        print("table-edits: files \(files), steps \(steps), changed \(rowOps), structure violations \(violations), "
              + String(format: "%.0f s", Date().timeIntervalSince(started)))
        XCTAssertGreaterThan(files, 0)
        XCTAssertEqual(violations, 0)
    }
}

extension SeededRandom: RandomNumberGenerator {
    mutating func next() -> UInt64 { UInt64(next(Int.max)) &* 2 &+ UInt64(next(2)) }
}

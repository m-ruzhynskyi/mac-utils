import AppKit
import SwiftUI
import XCTest
@testable import MacUtils

/// Таблицы, остальное (E-3): столбцы, ширина, объединить/разбить, границы, заливка, вставка таблицы; хвосты E-1 —
/// пустой абзац у таблицы и ввод после последнего ¶. После каждой команды: скобок не хуже, разбор открывает,
/// `\cell` = `\cellx` и `\cellx` возрастают, копии определения строки одинаковые, отмена — байт в байт.
@MainActor
final class DocTableEditCellsTests: XCTestCase {
    typealias Ref = DocTableEdit.CellRef

    private static func model(_ source: String) -> RTFDocumentModel { RTFReader.read(source as NSString) }

    /// Применить команду и проверить; вернуть правку (если была).
    @discardableResult
    static func run(_ source: inout String, file: StaticString = #filePath, line: UInt = #line,
                    _ make: (RTFDocumentModel, NSString) -> DocTableEdit.Result) -> DocTableEdit.Result {
        let before = source as NSString
        let model = RTFReader.read(before)
        let result = make(model, before)
        guard result.refusal == nil, !result.edits.isEmpty else { return result }
        XCTAssertEqual(result.edits.count, 1, "одна правка", file: file, line: line)
        DocTableEditTests.apply(result, to: &source, file: file, line: line)
        let after = RTFReader.read(source as NSString)
        XCTAssertLessThanOrEqual(DocTableEdit.definitionMismatches(after, source: source as NSString),
                                 DocTableEdit.definitionMismatches(model, source: before), "копии определения строки", file: file, line: line)
        return result
    }

    private func rights(_ source: String, table: Int = 0) -> [[Int]] {
        Self.model(source).body.tables[safe: table]?.rows.map { $0.cells.map(\.right) } ?? []
    }

    private func visible(_ source: String) -> String { DocReaderTests.visibleText(Self.model(source).body) }

    // MARK: - Определение строки

    func testDefinitionsRoundTrip() throws {
        let source = DocTableEditTests.wordTable as NSString
        let model = RTFReader.read(source)
        let span = try XCTUnwrap(DocTableEdit.rowSpan(table: 0, row: 0, story: model.body, source: source))
        let copies = RTFRowDefinition.all(in: span, source: source)
        XCTAssertEqual(copies.count, 2, "Word пишет определение дважды")
        for copy in copies {
            XCTAssertEqual(copy.cells.map(\.right), [2000, 5000])
            for cell in copy.cells { XCTAssertEqual(cell.text, source.substring(with: cell.range), "разбор без потерь") }
        }
        XCTAssertEqual(DocTableEdit.definitionMismatches(model, source: source), 0)
    }

    // MARK: - Столбцы

    func testInsertColumns() throws {
        var source = DocTableEditTests.wordTable
        Self.run(&source) { DocTableEdit.insertColumn(table: 0, at: Ref(row: 0, cell: 1), right: true, model: $0, source: $1) }
        XCTAssertEqual(rights(source), [[2000, 5000, 8000], [2000, 5000, 8000], [2000, 5000, 8000]])
        XCTAssertTrue(visible(source).contains("B1\u{7}\u{7}"), visible(source))
        // Слева от первого: ширина 2108 (от \trleft-108); объединение A1–A2 остаётся у прежних ячеек.
        Self.run(&source) { DocTableEdit.insertColumn(table: 0, at: Ref(row: 1, cell: 0), right: false, model: $0, source: $1) }
        let rows = Self.model(source).body.tables[0].rows
        XCTAssertEqual(rows.map { $0.cells.map(\.right) }, [[2000, 4108, 7108, 10108], [2000, 4108, 7108, 10108], [2000, 4108, 7108, 10108]])
        XCTAssertFalse(rows[0].cells[0].verticalMergeFirst || rows[1].cells[0].verticalMerged, "новая ячейка без объединения")
        XCTAssertTrue(rows[0].cells[1].verticalMergeFirst && rows[1].cells[1].verticalMerged)
        XCTAssertTrue(visible(source).hasPrefix("Before\n\u{7}A1 first\nA1 second\u{7}B1\u{7}\u{7}"), visible(source))
    }

    func testDeleteColumns() throws {
        var source = DocTableEditTests.wordTable
        Self.run(&source) { DocTableEdit.deleteColumn(table: 0, at: Ref(row: 2, cell: 0), model: $0, source: $1) }
        XCTAssertEqual(rights(source), [[2892], [2892], [2892]])
        XCTAssertEqual(visible(source), "Before\nB1\u{7}B2 Дано\u{7}B3\nB3 more\u{7}After\n")
        // Последний столбец — таблицы нет, текст вокруг цел.
        Self.run(&source) { DocTableEdit.deleteColumn(table: 0, at: Ref(row: 0, cell: 0), model: $0, source: $1) }
        XCTAssertTrue(Self.model(source).body.tables.isEmpty)
        XCTAssertEqual(visible(source), "Before\nAfter\n")
    }

    // MARK: - Ширина

    func testMoveBoundary() throws {
        var source = DocTableEditTests.wordTable
        Self.run(&source) { DocTableEdit.moveBoundary(table: 0, boundary: 2000, delta: 500, model: $0, source: $1) }
        XCTAssertEqual(rights(source), [[2500, 5000], [2500, 5000], [2500, 5000]])
        // Не уже 100 твипов: левая ячейка от -108.
        Self.run(&source) { DocTableEdit.moveBoundary(table: 0, boundary: 2500, delta: -10_000, model: $0, source: $1) }
        XCTAssertEqual(rights(source).first, [-8, 5000])
        // Правый край таблицы — только последняя ячейка.
        Self.run(&source) { DocTableEdit.moveBoundary(table: 0, boundary: 5000, delta: 700, model: $0, source: $1) }
        XCTAssertEqual(rights(source).first, [-8, 5700])
    }

    // MARK: - Объединить и разбить

    func testMergeHorizontallyAndVertically() throws {
        var source = DocTableEditTests.wordTable
        // Строка: одна широкая ячейка, текст ячеек — её абзацами.
        Self.run(&source) { DocTableEdit.merge(table: 0, cells: [Ref(row: 2, cell: 0), Ref(row: 2, cell: 1)], model: $0, source: $1) }
        XCTAssertEqual(rights(source)[2], [5000])
        XCTAssertTrue(visible(source).hasSuffix("A3\nB3\nB3 more\u{7}After\n"), visible(source))
        // Столбец: B1–B2 — объединение по вертикали, текст B2 — в B1.
        Self.run(&source) { DocTableEdit.merge(table: 0, cells: [Ref(row: 0, cell: 1), Ref(row: 1, cell: 1)], model: $0, source: $1) }
        let rows = Self.model(source).body.tables[0].rows
        XCTAssertTrue(rows[0].cells[1].verticalMergeFirst)
        XCTAssertTrue(rows[1].cells[1].verticalMerged)
        XCTAssertTrue(visible(source).contains("B1\nB2 Дано\u{7}\u{7}\u{7}"), visible(source))
        // Не прямоугольник (у строки 2 граница 3000, у строки 1 — 2000) — отказ без правки.
        let irregular = DocTableEditTests.wordTable.components(separatedBy: "\n")
            .map { $0.contains("irow2") ? $0.replacingOccurrences(of: "cellx2000", with: "cellx3000") : $0 }.joined(separator: "\n")
        let refused = DocTableEdit.merge(table: 0, cells: [Ref(row: 1, cell: 0), Ref(row: 2, cell: 0)], model: Self.model(irregular),
                                         source: irregular as NSString)
        XCTAssertNotNil(refused.refusal)
        XCTAssertTrue(refused.edits.isEmpty)
    }

    func testSplit() throws {
        var source = DocTableEditTests.wordTable
        // A1–A2 объединены по вертикали — разбиваются обратно.
        Self.run(&source) { DocTableEdit.split(table: 0, at: Ref(row: 1, cell: 0), model: $0, source: $1) }
        let rows = Self.model(source).body.tables[0].rows
        XCTAssertFalse(rows[0].cells[0].verticalMergeFirst || rows[1].cells[0].verticalMerged)
        // B3 — на две по ширине, правая пустая.
        Self.run(&source) { DocTableEdit.split(table: 0, at: Ref(row: 2, cell: 1), model: $0, source: $1) }
        XCTAssertEqual(rights(source)[2], [2000, 3500, 5000])
        XCTAssertTrue(visible(source).hasSuffix("A3\u{7}B3\nB3 more\u{7}\u{7}After\n"), visible(source))
    }

    // MARK: - Границы и заливка

    func testBordersAndShading() throws {
        var source = DocTableEditTests.wordTable
        Self.run(&source) { DocTableEdit.borders(table: 0, cells: [Ref(row: 1, cell: 1)], preset: .all, model: $0, source: $1) }
        var rows = Self.model(source).body.tables[0].rows
        XCTAssertTrue([rows[1].cells[1].borderTop, rows[1].cells[1].borderLeft, rows[1].cells[1].borderBottom, rows[1].cells[1].borderRight]
            .allSatisfy(\.isVisible))
        Self.run(&source) { DocTableEdit.borders(table: 0, cells: [Ref(row: 0, cell: 1)], preset: .none, model: $0, source: $1) }
        rows = Self.model(source).body.tables[0].rows
        XCTAssertFalse(rows[0].cells[1].borderTop.isVisible)
        XCTAssertFalse(rows[1].cells[1].borderTop.isVisible, "у соседа снизу — тоже, общая линия")
        XCTAssertTrue(rows[1].cells[1].borderBottom.isVisible)
        Self.run(&source) {
            DocTableEdit.shading(table: 0, cells: [Ref(row: 2, cell: 0)], color: RTFColor(red: 217, green: 217, blue: 217), model: $0, source: $1)
        }
        let model = Self.model(source)
        XCTAssertEqual(model.color(model.body.tables[0].rows[2].cells[0].shading), RTFColor(red: 217, green: 217, blue: 217))
        Self.run(&source) { DocTableEdit.shading(table: 0, cells: [Ref(row: 2, cell: 0)], color: nil, model: $0, source: $1) }
        XCTAssertEqual(Self.model(source).body.tables[0].rows[2].cells[0].shading, 0)
    }

    // MARK: - Вставить таблицу

    func testInsertTable() throws {
        var source = DocTableEditTests.wordTable
        Self.run(&source) { DocTableEdit.insertTable(rows: 2, columns: 3, after: 0, textWidth: 9000, model: $0, source: $1) }
        let model = Self.model(source)
        XCTAssertEqual(model.body.tables.count, 2)
        XCTAssertEqual(model.body.tables[0].rows.map { $0.cells.map(\.right) }, [[2892, 5892, 8892], [2892, 5892, 8892]])
        XCTAssertTrue(visible(source).hasPrefix("Before\n\u{7}\u{7}\u{7}\u{7}\u{7}\u{7}\nA1 first"), visible(source))
        // После последнего абзаца: таблица и пустой абзац за ней (документ кончается абзацем).
        let last = model.body.paragraphs.count - 1
        Self.run(&source) { DocTableEdit.insertTable(rows: 1, columns: 1, after: last, textWidth: 9000, model: $0, source: $1) }
        XCTAssertEqual(Self.model(source).body.tables.count, 3)
        XCTAssertTrue(visible(source).hasSuffix("After\n\u{7}\n"), visible(source))
        // В ячейке — нельзя.
        let cell = Self.model(source).body.paragraphs.firstIndex { $0.cell != nil }!
        XCTAssertNotNil(DocTableEdit.insertTable(rows: 1, columns: 1, after: cell, textWidth: 9000, model: Self.model(source),
                                                 source: source as NSString).refusal)
    }

    // MARK: - Хвосты E-1

    static let emptyAround = DocReaderTests.table
        .replacingOccurrences(of: "\\pard\\plain Before\\par\n", with: "\\pard\\plain Before\\par\n\\pard\\plain\\par\n")
        .replacingOccurrences(of: "\\pard\\plain After\\par", with: "\\pard\\plain\\par\n\\pard\\plain After\\par")

    func testEmptyParagraphsAroundTable() throws {
        var harness = DocEditTests.Harness(source: Self.emptyAround)
        XCTAssertTrue(visible(harness.source).hasPrefix("Before\n\nA1"))
        // Delete в пустом абзаце перед таблицей — абзаца нет.
        let shown = harness.display().0 as NSString
        let result = harness.edit(NSRange(location: shown.range(of: "Before").length + 1, length: 1), "")
        XCTAssertNil(result.refusal)
        XCTAssertTrue(visible(harness.source).hasPrefix("Before\nA1"), visible(harness.source))
        // ⌫ в пустом абзаце после таблицы — тоже.
        let now = harness.display().0 as NSString
        let after = now.range(of: "After").location
        harness.edit(NSRange(location: after - 2, length: 1), "")
        XCTAssertTrue(visible(harness.source).hasSuffix("B2\u{7}After\n"), visible(harness.source))
        XCTAssertEqual(DocTableEditTests.structureViolations(harness.model), 0)
    }

    func testTypingAfterLastParagraphMark() throws {
        var harness = DocEditTests.Harness(source: DocReaderTests.letter)
        let count = harness.display().1.count
        harness.edit(NSRange(location: count, length: 0), "x")
        XCTAssertTrue(DocReaderTests.visibleText(harness.model.body).hasSuffix("x\n"), "в конец последнего абзаца")
    }

    // MARK: - В окне

    /// Офскрин: меню «Таблица» у ячейки и «Вставить таблицу» вне её, граница ячейки под указателем, команды и отмена.
    func testCommandsInDocumentWindow() throws {
        let (workspace, tab) = DocDemo.tab(DocTableEditTests.wordTable, name: "table_demo.frm")
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
        let original = tab.text as String
        view.setSelectedRange(NSRange(location: text().range(of: "After").location, length: 0))
        XCTAssertEqual(document.tableMenuItems().map(\.title), ["Вставить таблицу"])
        view.setSelectedRange(NSRange(location: text().range(of: "B1").location, length: 0))
        let menu = try XCTUnwrap(document.tableMenuItems().first?.submenu)
        XCTAssertTrue(menu.items.map(\.title).contains("Вставить столбец справа"))
        // Граница A1|B1 под указателем — правый край первой ячейки (\cellx2000).
        let manager = document.layoutManager
        for page in document.textViews { manager.ensureLayout(for: page.textContainer!) }
        let character = text().range(of: "A1 first").location
        let style = try XCTUnwrap(document.storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.last)
        let frame = document.cellFrame(character, block: block)
        let point = NSPoint(x: frame.maxX + view.textContainerOrigin.x, y: frame.midY + view.textContainerOrigin.y)
        let hit = try XCTUnwrap(document.tableBoundary(at: point, in: view))
        XCTAssertEqual(hit.boundary, 2000)
        XCTAssertNil(document.tableBoundary(at: NSPoint(x: frame.midX + view.textContainerOrigin.x, y: point.y), in: view))
        // Команды через меню и контроллер: столбец справа, объединение строки, отмена — байт в байт.
        let insert = try XCTUnwrap(menu.items.first { $0.title == "Вставить столбец справа" })
        _ = (insert.target as? DocMenuAction)?.perform(insert)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(document.model.body.tables[0].rows[0].cells.count, 3)
        let a3 = text().range(of: "A3").location, more = NSMaxRange(text().range(of: "B3 more"))
        view.setSelectedRange(NSRange(location: a3, length: more - a3))
        XCTAssertTrue(document.mergeTableCells())
        XCTAssertTrue(document.applyTable(DocTableEdit.moveBoundary(table: 0, boundary: hit.boundary, delta: 400, model: document.model,
                                                                    source: tab.text), actionName: "Ширина столбца"))
        XCTAssertEqual(document.model.body.tables[0].rows[0].cells.first?.right, 2400)
        for _ in 0..<3 { tab.undo.undo() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
    }

    // MARK: - Случайные команды

    /// Случайная команда E-3 (или E-1, или правка текста) на таблице документа.
    @discardableResult
    static func randomStep(_ harness: inout DocEditTests.Harness, random: inout SeededRandom) -> String {
        let model = harness.model
        let tables = model.body.tables
        let choice = random.next(12)
        guard choice < 8, !tables.isEmpty else {
            if choice == 8 {
                let paragraph = random.next(max(1, model.body.paragraphs.count))
                run(&harness.source) { DocTableEdit.insertTable(rows: 1 + random.next(3), columns: 1 + random.next(3), after: paragraph,
                                                                textWidth: 9000, model: $0, source: $1) }
                return "table"
            }
            return DocTableEditTests.randomStep(&harness, random: &random, pieces: ["x", "Ж", "\n", "", " "])
        }
        let table = random.next(tables.count)
        let rows = tables[table].rows
        let row = random.next(rows.count)
        let ref = Ref(row: row, cell: random.next(rows[row].cells.count))
        var cells: Set<Ref> = [ref]
        if random.next(2) == 0, row + 1 < rows.count, let below = DocTableEdit.cell(in: rows[row + 1], column: DocTableEdit.edges(rows[row])[ref.cell]) {
            cells.insert(Ref(row: row + 1, cell: below))
        }
        if random.next(2) == 0, ref.cell + 1 < rows[row].cells.count { cells.insert(Ref(row: row, cell: ref.cell + 1)) }
        switch choice {
        case 0: run(&harness.source) { DocTableEdit.insertColumn(table: table, at: ref, right: random.next(2) == 0, model: $0, source: $1) }
        case 1: run(&harness.source) { DocTableEdit.deleteColumn(table: table, at: ref, model: $0, source: $1) }
        case 2: run(&harness.source) { DocTableEdit.merge(table: table, cells: cells, model: $0, source: $1) }
        case 3: run(&harness.source) { DocTableEdit.split(table: table, at: ref, model: $0, source: $1) }
        case 4:
            let preset = [DocTableEdit.BorderPreset.all, .outer, .none][random.next(3)]
            run(&harness.source) { DocTableEdit.borders(table: table, cells: cells, preset: preset, model: $0, source: $1) }
        case 5:
            let color = random.next(2) == 0 ? nil : RTFColor(red: 200 + random.next(50), green: 220, blue: 240)
            run(&harness.source) { DocTableEdit.shading(table: table, cells: cells, color: color, model: $0, source: $1) }
        case 6:
            let boundary = DocTableEdit.edges(rows[row])[ref.cell].right
            let delta = random.next(2001) - 1000
            run(&harness.source) { DocTableEdit.moveBoundary(table: table, boundary: boundary, delta: delta, model: $0, source: $1) }
        default:
            return DocTableEditTests.randomStep(&harness, random: &random, pieces: ["x", "Ж", "\n", "", " "])
        }
        return "command \(choice)"
    }

    /// 1 000 случайных шагов (семя) на демо: команды E-3 вперемешку со строками и правкой текста.
    func testRandomCommandsStayLossless() throws {
        var random = SeededRandom(seed: 20_261_023)
        var steps = 0, changed = 0
        for document in [DocTableEditTests.wordTable, DocReaderTests.table, DocDemo.expertReport] {
            var harness = DocEditTests.Harness(source: document)
            for _ in 0..<334 {
                let before = harness.source
                Self.randomStep(&harness, random: &random)
                if harness.source != before { changed += 1 }
                steps += 1
            }
            XCTAssertEqual(DocTableEditTests.structureViolations(harness.model), 0)
            XCTAssertEqual(DocTableEdit.definitionMismatches(harness.model, source: harness.source as NSString), 0)
        }
        print("table-cells demo: steps \(steps), changed \(changed)")
        XCTAssertGreaterThan(changed, 500)
    }

    /// `MU_REAL_FRM_DIR` — папка КОПИЙ форм: 100 случайных шагов на файл, нарушений структуры не больше исходных.
    func testRealFormsCommands() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_REAL_FRM_DIR"], !path.isEmpty else {
            throw XCTSkip("MU_REAL_FRM_DIR не задан")
        }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.lowercased().hasSuffix(".frm") }.sorted()
        var files = 0, steps = 0, changed = 0, violations = 0
        let started = Date()
        for (number, name) in names.enumerated() {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { continue }
            let text = EditorDocument(data: data).decodedText as String
            let model = RTFReader.read(text as NSString)
            guard model.isRTF, !model.body.tables.isEmpty else { continue }
            let baseline = DocTableEditTests.structureViolations(model)
            let mismatches = DocTableEdit.definitionMismatches(model, source: text as NSString)
            var harness = DocEditTests.Harness(source: text)
            var random = SeededRandom(seed: 300 + UInt64(number))
            autoreleasepool {
                for step in 0..<100 {
                    let before = harness.source
                    let failures = testRun?.failureCount ?? 0
                    let operation = Self.randomStep(&harness, random: &random)
                    if harness.source != before { changed += 1 }
                    if (testRun?.failureCount ?? 0) > failures { print("table-cells: file #\(number) step \(step): \(operation)") }
                    steps += 1
                }
            }
            violations += max(0, DocTableEditTests.structureViolations(harness.model) - baseline)
            violations += max(0, DocTableEdit.definitionMismatches(harness.model, source: harness.source as NSString) - mismatches)
            files += 1
        }
        print("table-cells: files \(files), steps \(steps), changed \(changed), violations \(violations), "
              + String(format: "%.0f s", Date().timeIntervalSince(started)))
        XCTAssertGreaterThan(files, 0)
        XCTAssertEqual(violations, 0)
    }
}

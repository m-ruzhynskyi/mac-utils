import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// TB2: ширина столбца и высота строки протяжкой границы, выделение ячеек — чистая логика и мышь на `DocumentView` синтетическими событиями
/// внутри процесса (в систему ничего не уходит).
@MainActor
final class DocTableDragTests: XCTestCase {
    typealias Ref = DocTableEdit.CellRef

    /// Таблица 3 × 3 (строки без `\trrh`, границы 3000/6000/9000) и абзацы вокруг.
    static let grid: String = {
        func row(_ n: Int, extra: String = "") -> String {
            let def = #"\trowd \irow\#(n)\trgaph108\trleft0"# + extra + #"\cellx3000\cellx6000\cellx9000"#
            return def + #"\pard\intbl\f0\fs24 R\#(n)A\cell R\#(n)B\cell R\#(n)C\cell\row "#
        }
        return #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}"# + "\n"
            + #"\paperw11906\paperh16838\margl1134\margr1134\margt1134\margb1134\sectd\pard\plain\f0\fs24 Before\par"# + "\n"
            + row(0) + "\n" + row(1) + "\n" + row(2) + "\n"
            + #"\pard\plain\f0\fs24 After\par}"#
    }()

    /// Последний `\cellx` каждой строки — общая ширина.
    private func rights(_ source: String) -> [[Int]] {
        RTFReader.read(source as NSString).body.tables[0].rows.map { $0.cells.map(\.right) }
    }

    private func height(_ source: String, row: Int) -> Int { RTFReader.read(source as NSString).body.tables[0].rows[row].height }

    @discardableResult
    private func run(_ source: inout String, _ make: (RTFDocumentModel, NSString) -> DocTableEdit.Result) -> DocTableEdit.Result {
        DocTableEditCellsTests.run(&source, make)
    }

    // MARK: - Чистая логика: ширина

    func testColumnDragMovesBoundaryInEveryRowAndKeepsTableWidth() {
        var source = Self.grid
        run(&source) { DocTableEdit.moveBoundary(table: 0, boundary: 3000, delta: 500, model: $0, source: $1) }
        XCTAssertEqual(rights(source), Array(repeating: [3500, 6000, 9000], count: 3), "граница на 500 правее во всех строках, общая ширина та же")
        XCTAssertEqual(DocTableEdit.violations(RTFReader.read(source as NSString)), 0)
    }

    func testOptionMovesOnlyTheCurrentRow() {
        var source = Self.grid
        run(&source) { DocTableEdit.moveBoundary(table: 0, boundary: 6000, delta: -700, model: $0, source: $1, rowOnly: 1) }
        XCTAssertEqual(rights(source), [[3000, 6000, 9000], [3000, 5300, 9000], [3000, 6000, 9000]])
        XCTAssertEqual(DocTableEdit.violations(RTFReader.read(source as NSString)), 0, "\\cell = \\cellx")
    }

    func testBoundaryStaysHalfCentimetreFromNeighbours() {
        let minimum = DocTableEdit.minimumColumnWidth
        XCTAssertEqual(minimum, 283, "0,5 см")
        var source = Self.grid
        // Вправо до упора: соседний столбец (6000 − 3000 = 3000 шириной) не уже 0,5 см.
        run(&source) { DocTableEdit.moveBoundary(table: 0, boundary: 3000, delta: 100_000, model: $0, source: $1) }
        XCTAssertEqual(rights(source)[0], [6000 - minimum, 6000, 9000])
        // Влево до упора: свой столбец не уже 0,5 см.
        var left = Self.grid
        run(&left) { DocTableEdit.moveBoundary(table: 0, boundary: 3000, delta: -100_000, model: $0, source: $1) }
        XCTAssertEqual(rights(left)[0], [minimum, 6000, 9000])
        let model = RTFReader.read(Self.grid as NSString)
        XCTAssertEqual(DocTableEdit.clampedShift(table: 0, boundary: 3000, delta: 100_000, model: model), 3000 - minimum, "линия-подсказка не заходит дальше")
        XCTAssertEqual(DocTableEdit.clampedShift(table: 0, boundary: 3000, delta: 10, model: model), 10)
    }

    func testRightEdgeDragChangesWholeWidthOnly() {
        var source = Self.grid
        run(&source) { DocTableEdit.moveBoundary(table: 0, boundary: 9000, delta: 400, model: $0, source: $1) }
        XCTAssertEqual(rights(source)[0], [3000, 6000, 9400], "правый край — ширина таблицы, остальное на месте")
    }

    // MARK: - Чистая логика: высота строки

    func testRowHeightInsertsAndReplacesTrrh() {
        var source = Self.grid
        XCTAssertEqual(height(source, row: 1), 0)
        let original = source
        run(&source) { DocTableEdit.setRowHeight(table: 0, row: 1, height: 900, model: $0, source: $1) }
        XCTAssertEqual(height(source, row: 1), 900, "вписан \\trrh900 («не меньше»)")
        XCTAssertEqual(height(source, row: 0), 0)
        XCTAssertEqual(height(source, row: 2), 0)
        run(&source) { DocTableEdit.setRowHeight(table: 0, row: 1, height: 1500, model: $0, source: $1) }
        XCTAssertEqual(height(source, row: 1), 1500, "свой \\trrh заменён")
        XCTAssertEqual(source.components(separatedBy: "\\trrh").count - 1, 1, "один код, не два")
        XCTAssertNotEqual(source, original)
        // «Точно» (отрицательный) становится «не меньше».
        var exact = Self.grid.replacingOccurrences(of: #"\irow1\trgaph108"#, with: #"\irow1\trrh-600\trgaph108"#)
        XCTAssertEqual(height(exact, row: 1), -600)
        run(&exact) { DocTableEdit.setRowHeight(table: 0, row: 1, height: 800, model: $0, source: $1) }
        XCTAssertEqual(height(exact, row: 1), 800)
    }

    func testRowHeightSameValueIsNoEdit() {
        let model = RTFReader.read(Self.grid as NSString)
        XCTAssertTrue(DocTableEdit.setRowHeight(table: 0, row: 0, height: 0 + 1, model: model, source: Self.grid as NSString).edits.count > 0)
        var source = Self.grid
        run(&source) { DocTableEdit.setRowHeight(table: 0, row: 0, height: 700, model: $0, source: $1) }
        let again = DocTableEdit.setRowHeight(table: 0, row: 0, height: 700, model: RTFReader.read(source as NSString), source: source as NSString)
        XCTAssertTrue(again.edits.isEmpty && again.refusal == nil)
    }

    // MARK: - Чистая логика: выделение ячеек

    func testCellSelectionShapes() {
        let story = RTFReader.read(Self.grid as NSString).body
        XCTAssertEqual(DocTableEdit.selection(cell: Ref(row: 1, cell: 1), table: 0, story: story), [Ref(row: 1, cell: 1)])
        XCTAssertEqual(DocTableEdit.selection(row: 2, table: 0, story: story), [Ref(row: 2, cell: 0), Ref(row: 2, cell: 1), Ref(row: 2, cell: 2)])
        XCTAssertEqual(DocTableEdit.selection(columnOf: Ref(row: 0, cell: 1), table: 0, story: story),
                       [Ref(row: 0, cell: 1), Ref(row: 1, cell: 1), Ref(row: 2, cell: 1)])
        // Прямоугольник между углами — и в обратном порядке то же.
        let rect = DocTableEdit.selection(from: Ref(row: 0, cell: 1), to: Ref(row: 1, cell: 2), table: 0, story: story)
        XCTAssertEqual(rect.count, 4)
        XCTAssertEqual(rect, DocTableEdit.selection(from: Ref(row: 1, cell: 2), to: Ref(row: 0, cell: 1), table: 0, story: story))
        XCTAssertEqual(DocTableEdit.selection(from: Ref(row: 0, cell: 2), to: Ref(row: 2, cell: 0), table: 0, story: story).count, 9, "диагональные углы — весь прямоугольник")
        XCTAssertFalse(DocTableEdit.isCellSelection([Ref(row: 0, cell: 0)]))
        XCTAssertTrue(DocTableEdit.isCellSelection(rect))
    }

    func testSelectionFollowsGeometryWhenBoundariesDiffer() {
        // Вторая строка с другими границами: столбец — ячейки, чей интервал пересекает интервал выбранной.
        let source = Self.grid.replacingOccurrences(of: #"\irow1\trgaph108\trleft0\cellx3000\cellx6000\cellx9000"#, with: #"\irow1\trgaph108\trleft0\cellx4500\cellx9000"#)
            .replacingOccurrences(of: "R1A\\cell R1B\\cell R1C\\cell", with: "R1A\\cell R1B\\cell")
        let model = RTFReader.read(source as NSString)
        guard model.body.tables[0].rows[1].cells.count == 2 else { return XCTFail("фикстура") }
        let column = DocTableEdit.selection(columnOf: Ref(row: 0, cell: 0), table: 0, story: model.body)
        XCTAssertEqual(column, [Ref(row: 0, cell: 0), Ref(row: 1, cell: 0), Ref(row: 2, cell: 0)], "первая ячейка второй строки (0–4500) над тем же столбцом")
    }

    func testClearCellsKeepsCellsAndStructure() {
        var source = Self.grid
        run(&source) { DocTableEdit.clearCells(table: 0, cells: [Ref(row: 0, cell: 1), Ref(row: 1, cell: 1)], model: $0, source: $1) }
        let model = RTFReader.read(source as NSString)
        let text = model.body.paragraphs.flatMap(\.runs).map(\.text).joined()
        XCTAssertFalse(text.contains("R0B") || text.contains("R1B"))
        XCTAssertTrue(text.contains("R0A") && text.contains("R1C") && text.contains("R2B"))
        XCTAssertEqual(model.body.tables[0].rows.map { $0.cells.count }, [3, 3, 3])
        XCTAssertEqual(DocTableEdit.violations(model), 0)
    }

    // MARK: - Окно: мышь

    private func open(_ source: String = DocTableDragTests.grid) throws -> (EditorTab, DocumentController, DocTextView, NSWindow) {
        let (workspace, tab) = DocDemo.tab(source, name: "table_drag.frm")
        tab.restoreMode(.document)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        window.acceptsMouseMovedEvents = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let document = try XCTUnwrap(tab.documentController)
        for page in document.textViews { document.layoutManager.ensureLayout(for: page.textContainer!) }
        return (tab, document, try XCTUnwrap(document.textViews.first), window)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }

    private func event(_ type: NSEvent.EventType, view: DocTextView, at point: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        let window = view.window!
        let inWindow = view.convert(point, to: nil)
        return NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Нажатие, протяжка (очередь событий) и отпускание.
    private func drag(_ document: DocumentController, view: DocTextView, from start: NSPoint, to end: NSPoint, option: Bool = false) {
        var queue = [event(.leftMouseDragged, view: view, at: NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), flags: option ? .option : []),
                     event(.leftMouseUp, view: view, at: end, flags: option ? .option : [])]
        document.dragEventSource = { _ in queue.isEmpty ? nil : queue.removeFirst() }
        defer { document.dragEventSource = nil }
        view.mouseDown(with: event(.leftMouseDown, view: view, at: start, flags: option ? .option : []))
        settle()
    }

    private func cell(_ document: DocumentController, row: Int, cell: Int) throws -> NSRect {
        try XCTUnwrap(document.cellRect(table: 0, row: row, cell: cell)).rect
    }

    func testHitTestZones() throws {
        let (_, document, view, window) = try open()
        defer { window.contentView = nil; window.close() }
        let a = try cell(document, row: 1, cell: 0), b = try cell(document, row: 1, cell: 1)
        guard case .columnBoundary(_, let boundary, _, let row)? = document.tableHit(at: NSPoint(x: a.maxX, y: a.midY), in: view) else { return XCTFail("граница столбца") }
        XCTAssertEqual(boundary, 3000)
        XCTAssertEqual(row, 1)
        guard case .rowBoundary(_, let boundaryRow, _, let rowHeight)? = document.tableHit(at: NSPoint(x: a.midX, y: a.maxY), in: view) else { return XCTFail("граница строки") }
        XCTAssertEqual(boundaryRow, 1)
        XCTAssertEqual(rowHeight, a.height, accuracy: 0.5)
        XCTAssertEqual(document.tableHit(at: NSPoint(x: a.minX + 1, y: a.midY), in: view), .selectRow(table: 0, row: 1), "у левого края строки")
        XCTAssertEqual(document.tableHit(at: NSPoint(x: b.minX + 7, y: b.midY), in: view), .selectCell(table: 0, ref: Ref(row: 1, cell: 1)), "у левого края ячейки")
        let first = try cell(document, row: 0, cell: 1)
        XCTAssertEqual(document.tableHit(at: NSPoint(x: first.midX, y: first.minY + 1), in: view), .selectColumn(table: 0, ref: Ref(row: 0, cell: 1)), "над столбцом")
        XCTAssertNil(document.tableHit(at: NSPoint(x: b.midX, y: b.midY), in: view), "в тексте ячейки — обычное выделение")
    }

    func testDraggingColumnBoundaryChangesWidthOneUndoStep() throws {
        let (tab, document, view, window) = try open()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        let a = try cell(document, row: 1, cell: 0)
        // Протяжка вправо на 30 pt = 600 твипов: граница 3000 → 3600 во всех строках.
        drag(document, view: view, from: NSPoint(x: a.maxX, y: a.midY), to: NSPoint(x: a.maxX + 30, y: a.midY))
        XCTAssertEqual(rights(tab.text as String), Array(repeating: [3600, 6000, 9000], count: 3))
        XCTAssertEqual(tab.undo.undoActionName, "Ширина столбца")
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original, "один шаг отмены — байт в байт")
    }

    func testOptionDragMovesOnlyThisRow() throws {
        let (tab, document, view, window) = try open()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        let b = try cell(document, row: 1, cell: 1)
        drag(document, view: view, from: NSPoint(x: b.maxX, y: b.midY), to: NSPoint(x: b.maxX - 20, y: b.midY), option: true)
        XCTAssertEqual(rights(tab.text as String), [[3000, 6000, 9000], [3000, 5600, 9000], [3000, 6000, 9000]])
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original)
    }

    func testDragNeverGoesCloserThanHalfCentimetre() throws {
        let (tab, document, view, window) = try open()
        defer { window.contentView = nil; window.close() }
        let a = try cell(document, row: 0, cell: 0)
        drag(document, view: view, from: NSPoint(x: a.maxX, y: a.midY), to: NSPoint(x: a.maxX + 5_000, y: a.midY))
        XCTAssertEqual(rights(tab.text as String)[0], [6000 - DocTableEdit.minimumColumnWidth, 6000, 9000])
    }

    func testDraggingRowBoundarySetsMinimumHeight() throws {
        let (tab, document, view, window) = try open()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        let a = try cell(document, row: 1, cell: 0)
        drag(document, view: view, from: NSPoint(x: a.midX, y: a.maxY), to: NSPoint(x: a.midX, y: a.maxY + 25))
        let expected = Int(((a.height + 25) * 20).rounded())
        XCTAssertEqual(height(tab.text as String, row: 1), expected, accuracy: 20, "\\trrh — высота строки + 25 pt, «не меньше»")
        XCTAssertGreaterThan(height(tab.text as String, row: 1), 0)
        XCTAssertEqual(tab.undo.undoActionName, "Высота строки")
        XCTAssertEqual(height(tab.text as String, row: 0), 0)
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original, "один шаг отмены — байт в байт")
    }

    func testGuideLineIsDashedAndFollowsClampedPosition() throws {
        let (_, document, view, window) = try open()
        defer { window.contentView = nil; window.close() }
        let a = try cell(document, row: 1, cell: 0)
        var drag = try XCTUnwrap(document.beginBoundaryDrag(at: NSPoint(x: a.maxX, y: a.midY), in: view))
        document.updateBoundaryDrag(&drag, to: NSPoint(x: a.maxX + 5_000, y: a.midY), option: false)
        XCTAssertEqual(document.guidePosition(drag), a.maxX + CGFloat(3000 - DocTableEdit.minimumColumnWidth) / 20, accuracy: 0.1, "линия упирается в минимум")
        let guide = DocGuideLine(vertical: true, in: view.bounds)
        guide.position = 100
        XCTAssertEqual(guide.frame.width, 2)
        XCTAssertEqual(guide.frame.height, view.bounds.height, "по высоте страницы")
    }

    // MARK: - Окно: выделение ячеек

    func testEdgeClicksSelectCellRowColumnWithFill() throws {
        let (_, document, view, window) = try open()
        defer { window.contentView = nil; window.close() }
        let b = try cell(document, row: 1, cell: 1)
        view.mouseDown(with: event(.leftMouseDown, view: view, at: NSPoint(x: b.minX + 7, y: b.midY)))
        XCTAssertEqual(document.tableCellSelection?.cells, [Ref(row: 1, cell: 1)], "щелчок у левого края ячейки — вся ячейка")
        let a = try cell(document, row: 2, cell: 0)
        view.mouseDown(with: event(.leftMouseDown, view: view, at: NSPoint(x: a.minX + 1, y: a.midY)))
        XCTAssertEqual(document.tableCellSelection?.cells.count, 3, "у левого края строки — строка")
        XCTAssertEqual(Set((document.tableCellSelection?.cells ?? []).map(\.row)), [2])
        let top = try cell(document, row: 0, cell: 2)
        view.mouseDown(with: event(.leftMouseDown, view: view, at: NSPoint(x: top.midX, y: top.minY + 1)))
        XCTAssertEqual(document.tableCellSelection?.cells, [Ref(row: 0, cell: 2), Ref(row: 1, cell: 2), Ref(row: 2, cell: 2)], "над столбцом — столбец")
        XCTAssertEqual(document.tableContext.selectedCells, 3, "счётчик ячеек в ленте")
        // Заливка видна: средний цвет внутри выделенной ячейки темнее (по красному каналу), чем у невыделенной. Снимок всего окна.
        let content = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let selected = try cell(document, row: 1, cell: 2), plain = try cell(document, row: 1, cell: 0)
        let scale = CGFloat(bitmap.pixelsWide) / content.bounds.width
        func average(_ rect: NSRect) -> (r: CGFloat, b: CGFloat) {
            let r0 = view.convert(rect, to: content)
            let top = content.isFlipped ? r0.minY : content.bounds.height - r0.maxY
            var r: CGFloat = 0, b: CGFloat = 0, n: CGFloat = 0
            for x in stride(from: Int((r0.minX + 4) * scale), to: Int((r0.maxX - 4) * scale), by: 6) {
                for y in stride(from: Int((top + 2) * scale), to: Int((top + r0.height - 2) * scale), by: 4) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    r += c.redComponent; b += c.blueComponent; n += 1
                }
            }
            return (r / max(n, 1), b / max(n, 1))
        }
        let chosen = average(selected), none = average(plain)
        XCTAssertLessThan(chosen.r, none.r - 0.02, "заливка выделения темнее по красному каналу: \(chosen) против \(none)")
        // Курсор в тексте — выделение ячеек уходит.
        view.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertNil(document.tableCellSelection)
    }

    func testTextDragAcrossCellsBecomesCellRectangle() throws {
        let (_, document, view, window) = try open()
        defer { window.contentView = nil; window.close() }
        let shown = document.storage.string as NSString
        let start = shown.range(of: "R0B").location, end = NSMaxRange(shown.range(of: "R1C"))
        let range = NSRange(location: start, length: end - start)
        let cross = try XCTUnwrap(document.cellSelection(forTextRange: range))
        XCTAssertEqual(cross.cells.count, 4, "прямоугольник между первой и последней ячейкой: строки 0–1, столбцы B–C")
        // Программное выделение (поиск, переходы) — обычное: ячейки не выделяются.
        _ = document.textView(view, willChangeSelectionFromCharacterRange: NSRange(location: start, length: 0), toCharacterRange: range)
        XCTAssertNil(document.tableCellSelection, "не жест пользователя — выделение текста как было")
        // Через делегат при жесте пользователя (протяжка, ⇧+стрелки): состояние ячеек, текст не подсвечивается.
        document.isUserSelectionGesture = { true }
        let collapsed = document.textView(view, willChangeSelectionFromCharacterRange: NSRange(location: start, length: 0), toCharacterRange: range)
        XCTAssertEqual(collapsed.length, 0)
        XCTAssertEqual(document.tableCellSelection?.cells.count, 4)
        XCTAssertNil(document.cellSelection(forTextRange: shown.range(of: "R0B")), "внутри одной ячейки — обычное выделение")
    }

    func testShiftArrowsExtendCellSelection() throws {
        let (_, document, _, window) = try open()
        defer { window.contentView = nil; window.close() }
        document.selectCells([Ref(row: 0, cell: 0)], table: 0)
        XCTAssertTrue(document.extendCellSelection(dx: 1, dy: 0))
        XCTAssertEqual(document.tableCellSelection?.cells.count, 2)
        XCTAssertTrue(document.extendCellSelection(dx: 0, dy: 1))
        XCTAssertEqual(document.tableCellSelection?.cells.count, 4)
        XCTAssertTrue(document.extendCellSelection(dx: -1, dy: 0))
        XCTAssertEqual(document.tableCellSelection?.cells.count, 2, "вернулись к столбцу A")
        document.clearCellSelection()
        XCTAssertFalse(document.extendCellSelection(dx: 1, dy: 0), "без выделения ячеек — обычное выделение текста")
    }

    func testCommandsWorkOnSelectedCells() throws {
        let (tab, document, _, window) = try open()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        // Объединить: прямоугольник 1 × 2.
        document.selectCells([Ref(row: 0, cell: 0), Ref(row: 0, cell: 1)], table: 0)
        XCTAssertTrue(document.mergeTableCells())
        settle()
        XCTAssertEqual(document.model.body.tables[0].rows[0].cells.count, 2)
        XCTAssertNil(document.tableCellSelection, "после объединения выделение сброшено")
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original)
        // Заливка: выделение остаётся, ячейки те же.
        document.selectCells([Ref(row: 1, cell: 0), Ref(row: 1, cell: 1), Ref(row: 2, cell: 0), Ref(row: 2, cell: 1)], table: 0)
        XCTAssertTrue(document.setTableShading(RTFColor(red: 217, green: 217, blue: 217)))
        settle()
        XCTAssertEqual(document.tableCellSelection?.cells.count, 4)
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original)
        // Выравнивание: все абзацы выделенных ячеек.
        document.selectCells(DocTableEdit.selection(row: 1, table: 0, story: document.model.body), table: 0)
        DocFormatter.of(document).setAlignment(.center)
        settle()
        let aligned = document.model.body.paragraphs.filter { $0.cell?.row == 1 }
        XCTAssertEqual(aligned.count, 3)
        XCTAssertTrue(aligned.allSatisfy { $0.props.alignment == .center })
        XCTAssertTrue(document.model.body.paragraphs.filter { $0.cell?.row == 0 }.allSatisfy { $0.props.alignment != .center }, "соседняя строка не тронута")
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original)
        // Delete: очистить содержимое выделенных ячеек.
        document.selectCells([Ref(row: 2, cell: 0), Ref(row: 2, cell: 2)], table: 0)
        XCTAssertTrue(document.clearSelectedCells())
        settle()
        XCTAssertFalse(document.storage.string.contains("R2A") || document.storage.string.contains("R2C"))
        XCTAssertTrue(document.storage.string.contains("R2B"))
        XCTAssertEqual(DocTableEdit.violations(document.model), 0)
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original)
    }

    // MARK: - Снимки

    func testTb2Snapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["MU_DOC_FORMAT_SNAPSHOTS"] else { throw XCTSkip("MU_DOC_FORMAT_SNAPSHOTS не задан") }
        for dark in [false, true] {
            let (_, document, view, window) = try open()
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            defer { window.contentView = nil; window.close() }
            // Выделенный столбец.
            document.selectCells(DocTableEdit.selection(columnOf: Ref(row: 0, cell: 1), table: 0, story: document.model.body), table: 0)
            settle()
            try write(view: view, to: directory, name: "tb2-column\(dark ? "-dark" : "")")
            // Линия протяжки: берём границу и показываем линию (рисуем один кадр с пунктиром).
            document.clearCellSelection()
            let a = try cell(document, row: 1, cell: 0)
            var drag = try XCTUnwrap(document.beginBoundaryDrag(at: NSPoint(x: a.maxX, y: a.midY), in: view))
            document.updateBoundaryDrag(&drag, to: NSPoint(x: a.maxX + 40, y: a.midY), option: false)
            let guide = DocGuideLine(vertical: true, in: view.bounds)
            view.addSubview(guide)
            guide.position = document.guidePosition(drag)
            settle()
            try write(view: view, to: directory, name: "tb2-drag\(dark ? "-dark" : "")")
            guide.removeFromSuperview()
        }
    }

    private func write(view: NSView, to directory: String, name: String) throws {
        guard let window = view.window, let content = window.contentView else { return }
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, message, file: file, line: line)
}

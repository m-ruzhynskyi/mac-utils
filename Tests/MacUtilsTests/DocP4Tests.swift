import AppKit
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// P-4: хвосты показа — вложенные таблицы (`\nestrow`) и др. Фикстуры — `Tests/Fixtures/DocP4` (выдуманный текст,
/// `make_p4.py`).
@MainActor
final class DocP4Tests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/DocP4", isDirectory: true)

    static func fixture(_ name: String) throws -> String {
        EditorDocument(data: try Data(contentsOf: folder.appendingPathComponent(name))).decodedText
    }

    static func paragraph(_ model: RTFDocumentModel, _ text: String) -> Int? {
        model.body.paragraphs.firstIndex { $0.plainText.contains(text) }
    }

    // MARK: - Вложенные таблицы

    func testNestedTableIsReadAsTableInsideCell() throws {
        let model = RTFReader.read(try Self.fixture("01-nested-table.rtf") as NSString)
        XCTAssertEqual(model.body.tables.count, 2)
        let nested = try XCTUnwrap(model.body.tables.first { $0.nested })
        let outer = try XCTUnwrap(model.body.tables.first { !$0.nested })
        XCTAssertEqual(nested.rows.count, 2, "две строки вложенной")
        XCTAssertEqual(nested.rows[0].cells.map(\.right), [3200, 6400])
        XCTAssertEqual(outer.rows.count, 1)
        XCTAssertEqual(outer.rows[0].cells.map(\.right), [3000, 9800], "строка внешней не затёрта определением вложенной")
        XCTAssertEqual(nested.parent, RTFCellRef(table: model.body.tables.firstIndex { !$0.nested }!, row: 0, cell: 1))
        let lease = try XCTUnwrap(Self.paragraph(model, "договора"))
        XCTAssertEqual(model.body.paragraphs[lease].end, .nestedCell)
        XCTAssertEqual(model.body.paragraphs[lease].cell?.cell, 0)
        XCTAssertEqual(model.body.paragraphs[lease].outerCell, nested.parent)
        let sheets = try XCTUnwrap(Self.paragraph(model, "1 лист"))
        XCTAssertEqual(model.body.paragraphs[sheets].cell, RTFCellRef(table: model.body.tables.firstIndex { $0.nested }!, row: 1, cell: 1))
        let total = try XCTUnwrap(Self.paragraph(model, "Итого"))
        XCTAssertNil(model.body.paragraphs[total].outerCell)
        XCTAssertEqual(model.body.paragraphs[total].cell, nested.parent, "абзац после вложенной — снова во внешней ячейке")
        XCTAssertFalse(model.body.paragraphs.contains { $0.plainText.isEmpty && $0.props.nesting >= 2 && $0.end == .paragraph },
                       "запасной абзац {\\nonesttables} не читается")
    }

    func testNestedCellsRenderInsideOuterCell() throws {
        let model = RTFReader.read(try Self.fixture("01-nested-table.rtf") as NSString)
        let (rendering, patch) = DocRenderer().render(model, previous: nil)
        let shown = patch.string.string as NSString
        let lease = shown.range(of: "Копия").location
        let style = try XCTUnwrap(patch.string.attribute(.paragraphStyle, at: lease, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.textBlocks.count, 2, "блок ячейки вложенной — внутри блока внешней")
        let inner = try XCTUnwrap(style.textBlocks.last as? NSTextTableBlock)
        let outerBlock = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertNotIdentical(inner.table, outerBlock.table)
        XCTAssertEqual(inner.table.numberOfColumns, 2)
        XCTAssertEqual(outerBlock.startingColumn, 1, "во второй ячейке внешней")
        // Конец вложенной ячейки — как `\cell`: не удаляется.
        let end = NSMaxRange(shown.range(of: "аренды"))
        XCTAssertEqual(rendering.map.kind(at: end), .cellEnd)
        let deletion = DocTextEditor.replace(NSRange(location: end, length: 1), with: "", model: model, map: rendering.map,
                                             source: try Self.fixture("01-nested-table.rtf") as NSString)
        XCTAssertTrue(deletion.edits.isEmpty, "\\nestcell не вырезается")
        // Абзац внешней ячейки после вложенной — один блок.
        let total = shown.range(of: "Итого").location
        let totalStyle = try XCTUnwrap(patch.string.attribute(.paragraphStyle, at: total, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(totalStyle.textBlocks.count, 1)
        XCTAssertIdentical((totalStyle.textBlocks.first as? NSTextTableBlock)?.table, outerBlock.table)
    }

    func testTypingInNestedCellIsLossless() throws {
        let source = try Self.fixture("01-nested-table.rtf")
        let model = RTFReader.read(source as NSString)
        let (rendering, patch) = DocRenderer().render(model, previous: nil)
        let at = NSMaxRange((patch.string.string as NSString).range(of: "2 листа"))
        let result = DocTextEditor.replace(NSRange(location: at, length: 0), with: " (копия)", model: model, map: rendering.map, source: source as NSString)
        XCTAssertNil(result.refusal)
        let outcome = DocListsTests.Outcome(source: DocListText.applied(result.edits, to: source as NSString) as String, edits: result.edits, caret: 0)
        XCTAssertEqual(DocListsTests.violations(source, outcome, synced: false), [])
        let after = RTFReader.read(outcome.source as NSString)
        XCTAssertEqual(after.body.tables.filter(\.nested).first?.rows.count, 2)
        XCTAssertTrue(after.body.paragraphs.contains { $0.plainText == "2 листа (копия)" && $0.end == .nestedCell })
    }
}

/// Отладка P-4 по эталону (`MU_WORD_REF_DIR`, `MU_P4_DEBUG`): размеры вложенных таблиц — только числа.
final class DocP4DebugTests: XCTestCase {
    func testNestedNumbers() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], ProcessInfo.processInfo.environment["MU_P4_DEBUG"] != nil else {
            throw XCTSkip("отладка")
        }
        for name in (ProcessInfo.processInfo.environment["MU_WORD_REF_ONLY"] ?? "f077").split(separator: ",") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("rtf/\(name).rtf")
            let document = EditorDocument(data: try Data(contentsOf: url))
            let model = RTFReader.read(document.decodedText as NSString, fallback: document.encoding)
            let story = model.body
            print("[p4] \(name): таблиц \(story.tables.count), вложенных \(story.tables.filter(\.nested).count), без родителя \(story.tables.filter { $0.nested && $0.parent == nil }.count)")
            for (index, table) in story.tables.enumerated() where table.nested {
                let parent = table.parent.flatMap { story.tables[safe: $0.table]?.rows[safe: $0.row] }
                let parentCell = table.parent.flatMap { ref in parent?.cells[safe: ref.cell] }
                let parentLeft = table.parent.flatMap { ref in ref.cell == 0 ? parent?.left : parent?.cells[safe: ref.cell - 1]?.right }
                let rows = table.rows.map { "\($0.left):\($0.cells.map(\.right))" }.prefix(3).joined(separator: " ")
                print("[p4]  #\(index) строк \(table.rows.count), родитель \(table.parent.map { "\($0.table)/\($0.row)/\($0.cell)" } ?? "-") "
                      + "ячейка \(parentLeft ?? -1)…\(parentCell?.right ?? -1) поля \(parent.map { $0.margins(parentCell ?? RTFCellDef()) }.map { "\($0.left)/\($0.right)" } ?? "-"); \(rows)")
            }
        }
    }
}

extension DocP4DebugTests {
    /// Шаг строк вложенных таблиц в нашей раскладке (TextKit без окна), только числа.
    @MainActor
    func testNestedRowPitch() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], ProcessInfo.processInfo.environment["MU_P4_DEBUG"] != nil else {
            throw XCTSkip("отладка")
        }
        let name = ProcessInfo.processInfo.environment["MU_WORD_REF_ONLY"] ?? "f077"
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("rtf/\(name).rtf")
        let document = EditorDocument(data: try Data(contentsOf: url))
        let model = RTFReader.read(document.decodedText as NSString, fallback: document.encoding)
        let renderer = DocRenderer()
        let props = model.sections[0].props
        renderer.contentWidth = DocPageView.bodyRect(props).width
        let (rendering, patch) = renderer.render(model, previous: nil)
        let storage = NSTextStorage(attributedString: patch.string)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: DocPageView.bodyRect(props).width, height: 100_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        var rows: [Int: [CGFloat]] = [:]
        for (index, paragraph) in model.body.paragraphs.enumerated() {
            guard let cell = paragraph.cell, model.body.tables[cell.table].nested, cell.cell == 0 else { continue }
            let unit = rendering.paragraphRanges[index].location
            let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: unit), effectiveRange: nil)
            rows[cell.table, default: []].append(rect.minY)
            if rows[cell.table]!.count == 1 { print("[p4] таблица \(cell.table) строка 0: y \(rect.minY), высота строки текста \(rect.height)") }
        }
        for (table, ys) in rows.sorted(by: { $0.key < $1.key }).prefix(4) {
            print("[p4] таблица \(table): шаг строк \(zip(ys, ys.dropFirst()).map { String(format: "%.1f", $1 - $0) }), trrh \(model.body.tables[table].rows.map(\.height))")
        }
    }
}

extension DocP4Tests {
    /// Шаг строк вложенной таблицы: минимальная высота `\trrh` у вложенных строк — как у внешних.
    func testNestedRowHeight() throws {
        let source = try Self.fixture("01-nested-table.rtf").replacingOccurrences(of: #"{\*\nesttableprops\trowd \irow0\irowband0\trgaph108"#,
                                                                                    with: #"{\*\nesttableprops\trowd \irow0\irowband0\trrh900\trgaph108"#)
        let model = RTFReader.read(source as NSString)
        XCTAssertEqual(model.body.tables.first { $0.nested }?.rows.map(\.height), [900, 900])
        let renderer = DocRenderer()
        let (rendering, patch) = renderer.render(model, previous: nil)
        let storage = NSTextStorage(attributedString: patch.string)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 481, height: 10_000))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let y = { (text: String) -> CGFloat in
            let index = try XCTUnwrap(Self.paragraph(model, text))
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: rendering.paragraphRanges[index].location), effectiveRange: nil).minY
        }
        XCTAssertEqual(try y("Справка") - y("Копия"), 45, accuracy: 1, "строка вложенной — не ниже 900 твипов")
    }
}

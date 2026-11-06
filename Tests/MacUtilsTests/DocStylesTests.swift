import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// S1: стили из `\stylesheet` и «применить стиль» — точечные правки, отмена байт в байт.
@MainActor
final class DocStylesTests: XCTestCase {
    /// Стили: 0 «Normal» (по умолчанию), 1 «heading 1» (по центру, 12 пт после, полужирный 16 пт), 2 «Основной» с кириллицей в имени,
    /// знаковый 10 «Strong» (жирный), 11 «Акцент» (курсив, цвет 2).
    static let sheet = #"{\stylesheet{\ql \li0\ri0\widctlpar\f0\fs24 \snext0 Normal;}"#
        + #"{\s1\qc\li0\ri0\sb240\sa120\keepn\f0\fs32\b \sbasedon0 \snext0 heading 1;}"#
        + #"{\s2\qj\li567\ri0\fi-284\sa60\f0\fs22 \sbasedon0 \'ce\'f1\'ed\'ee\'e2\'ed\'ee\'e9;}"#
        + #"{\*\cs10 \additive\b \sbasedon222 Strong;}{\*\cs11 \additive\i\cf2 \sbasedon222 \'c0\'ea\'f6\'e5\'ed\'f2;}}"#

    static let source = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}{\colortbl;\red0\green0\blue0;\red200\green0\blue0;}"#
        + sheet
        + #"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134\sectd"#
        + #"\pard\plain\f0\fs24 First paragraph plain.\par"#
        + #"\pard\plain\s2\qj\li567\fi-284\f0\fs22 Second paragraph styled.\par"#
        + #"\pard\plain\f0\fs24 Third paragraph plain.\par"#
        + #"\trowd\trgaph108\cellx3000\cellx6000\pard\plain\intbl\f0\fs24 Cell one text\cell Cell two\cell\row"#
        + #"\pard\plain\f0\fs24 Last paragraph with some words.\par}"#

    private func open(_ source: String = DocStylesTests.source) throws -> (EditorTab, DocumentController, NSWindow) {
        let (workspace, tab) = DocDemo.tab(source, name: "styles.frm")
        tab.restoreMode(.document)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (tab, try XCTUnwrap(tab.documentController), window)
    }

    private func select(_ document: DocumentController, _ text: String, length: Int? = nil) throws {
        let shown = document.storage.string as NSString
        let range = shown.range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, text)
        try XCTUnwrap(document.textViews.first).setSelectedRange(NSRange(location: range.location, length: length ?? 0))
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    // MARK: - Список стилей

    func testStyleListNamesTypesAndBasedOn() throws {
        let (_, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let sheet = document.styleSheet
        XCTAssertEqual(sheet.styles.map(\.id), ["s0", "s1", "s2", "cs10", "cs11"].filter { id in sheet.styles.contains { $0.id == id } })
        XCTAssertEqual(sheet.paragraphStyles.map(\.displayName), ["Обычный", "Заголовок 1", "Основной"], "встроенные — по-русски, остальные — как в файле")
        XCTAssertEqual(sheet.characterStyles.map(\.displayName), ["Выделение жирным", "Акцент"])
        XCTAssertEqual(sheet.style(.paragraph, 1)?.name, "heading 1")
        XCTAssertEqual(sheet.style(.paragraph, 1)?.basedOn, 0)
        XCTAssertNil(sheet.style(.character, 10)?.basedOn, "\\sbasedon222 — без основы")
    }

    func testCurrentStyleUnderCaret() throws {
        let (_, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        try select(document, "Second")
        XCTAssertEqual(document.currentParagraphStyle?.number, 2)
        try select(document, "First")
        XCTAssertNil(document.currentParagraphStyle, "у абзаца нет \\sN")
    }

    // MARK: - Применение

    private func apply(_ style: DocStyle.Kind, _ number: Int, _ document: DocumentController) throws -> Bool {
        document.applyStyle(try XCTUnwrap(document.styleSheet.style(style, number)))
    }

    func testApplyParagraphStyleToOneParagraph() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        try select(document, "Third")
        XCTAssertTrue(try apply(.paragraph, 1, document))
        settle()
        let paragraph = try XCTUnwrap(document.model.body.paragraphs.first { $0.runs.contains { $0.text.contains("Third") } })
        XCTAssertEqual(paragraph.props.style, 1)
        XCTAssertEqual(paragraph.props.alignment, .center)
        XCTAssertEqual(paragraph.props.spaceBefore, 240)
        XCTAssertEqual(paragraph.props.spaceAfter, 120)
        XCTAssertTrue(paragraph.runs.contains { $0.props.bold && $0.props.halfPoints == 32 }, "знаки по стилю: жирный 16 пт")
        let others = document.model.body.paragraphs.filter { !$0.runs.contains { $0.text.contains("Third") } }
        XCTAssertEqual(others.first?.props.style, nil, "соседние абзацы не тронуты")
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original, "один шаг отмены — байт в байт")
    }

    func testApplyParagraphStyleToSeveralParagraphsIsOneUndoStep() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        let shown = document.storage.string as NSString
        let start = shown.range(of: "First").location
        let end = NSMaxRange(shown.range(of: "Third"))
        try XCTUnwrap(document.textViews.first).setSelectedRange(NSRange(location: start, length: end - start))
        XCTAssertTrue(try apply(.paragraph, 2, document))
        settle()
        let styled = document.model.body.paragraphs.filter { $0.props.style == 2 }
        XCTAssertEqual(styled.count, 3, "три абзаца выделения")
        XCTAssertTrue(styled.allSatisfy { $0.props.alignment == .justify && $0.props.left == 567 && $0.props.firstLine == -284 })
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original, "один шаг отмены на все абзацы")
    }

    func testApplyParagraphStyleInsideTableCell() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        try select(document, "Cell one")
        XCTAssertTrue(try apply(.paragraph, 1, document))
        settle()
        let paragraph = try XCTUnwrap(document.model.body.paragraphs.first { $0.runs.contains { $0.text.contains("Cell one") } })
        XCTAssertEqual(paragraph.props.style, 1)
        XCTAssertNotNil(paragraph.cell, "абзац остался в ячейке")
        XCTAssertEqual(document.model.body.tables.count, 1)
        XCTAssertEqual(DocTableEdit.violations(document.model), 0, "\\cell = \\cellx")
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original)
    }

    func testApplyCharacterStyleToSelection() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        try select(document, "some words", length: 10)
        XCTAssertTrue(try apply(.character, 11, document))
        settle()
        let italic = document.model.body.paragraphs.flatMap(\.runs).filter { $0.props.italic && $0.props.color != 0 }
        XCTAssertEqual(italic.map(\.text).joined(), "some words", "стиль только на выделении")
        XCTAssertTrue((tab.text as String).contains("\\cs11"), "знаковый стиль записан как \\csN")
        // Курсор внутри — стиль под курсором.
        try select(document, "words")
        XCTAssertEqual(document.currentCharacterStyle?.number, 11)
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
    }

    func testAvailability() throws {
        let (_, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let paragraphStyle = try XCTUnwrap(document.styleSheet.style(.paragraph, 1))
        let characterStyle = try XCTUnwrap(document.styleSheet.style(.character, 10))
        XCTAssertEqual(DocStyleCommand.availability(paragraphStyle, in: .init(isDocument: false)), .hidden)
        XCTAssertTrue(DocStyleCommand.availability(paragraphStyle, in: .init()).isEnabled)
        XCTAssertFalse(DocStyleCommand.availability(paragraphStyle, in: .init(inHeader: true)).isEnabled)
        XCTAssertFalse(DocStyleCommand.availability(characterStyle, in: .init(hasText: false)).isEnabled, "знаковый — только к выделенному тексту")
        XCTAssertTrue(DocStyleCommand.availability(characterStyle, in: .init(hasText: true)).isEnabled)
        try select(document, "First")
        XCTAssertFalse(document.applyStyle(characterStyle), "курсор без выделения — знаковый стиль не применяется")
    }

    // MARK: - Копии форм

    func testRealFormsApplyAndUndoKeepFile() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else { throw XCTSkip("MU_WORD_REF_DIR") }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("rtf")
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".rtf") }.sorted()
        var checked = 0, applied = 0, failures = 0, withStyles = 0
        for file in names where file.hashValue != 0 {
            guard checked < 18, let data = try? Data(contentsOf: base.appendingPathComponent(file)), data.count < 300_000 else { continue }
            let text = EditorDocument(data: data).decodedText
            let sheet = DocStyleSheet.parse(text as NSString)
            guard let style = sheet.paragraphStyles.first(where: { $0.number != 0 }) ?? sheet.paragraphStyles.first else { continue }
            withStyles += 1
            let (tab, document, window) = try open(text)
            defer { window.contentView = nil; window.close() }
            let before = tab.text as String
            checked += 1
            // Первый абзац с текстом.
            guard let paragraph = document.model.body.paragraphs.first(where: { $0.runs.contains { $0.kind == .text && !$0.text.isEmpty } && $0.cell == nil }),
                  let run = paragraph.runs.first(where: { $0.kind == .text && !$0.text.isEmpty }), let unit = run.map.first else { continue }
            let units = document.rendering.map.unit(forSource: unit.location)
            document.textViews.first?.setSelectedRange(NSRange(location: units, length: 0))
            let model = DocumentController.words(document.model.body)
            if document.applyStyle(style) {
                applied += 1
                settle()
                // Текст тот же, разбор открывается.
                if DocumentController.words(document.model.body) != model { failures += 1 }
                tab.undo.undo()
                settle()
            }
            if (tab.text as String) != before { failures += 1 }
        }
        print("STYLES forms checked=\(checked) withStyles=\(withStyles) applied=\(applied) failures=\(failures)")
        XCTAssertGreaterThan(checked, 5)
        XCTAssertEqual(failures, 0)
    }

    // MARK: - Ревью: наследование свойств и то, что стиль не пишет

    /// Абзацы без своего `\pard` наследуют свойства предыдущего, и `\sN` тоже: стиль, применённый к одному абзацу, не должен
    /// переходить на следующие, которые его свойства наследовали (как у остальных команд абзаца — возврат прежнего значения).
    func testParagraphStyleDoesNotLeakIntoInheritingParagraphs() throws {
        let body = #"\pard\plain\s2\qj\li567\fi-284\f0\fs22 Shared A.\par Shared B.\par Shared C.\par"#
            + #"\pard\plain\f0\fs24 Tail.\par}"#
        let source = Self.source.components(separatedBy: #"\pard\plain\f0\fs24 First"#)[0] + body
        let (tab, document, window) = try open(source)
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        func props(_ text: String) -> RTFParaProps? {
            document.model.body.paragraphs.first { $0.runs.map(\.text).joined().hasPrefix(text) }?.props
        }
        XCTAssertEqual(props("Shared B")?.style, 2, "B и C наследуют \\s2 от A")
        // К первому — заголовок: B и C остаются «Основной».
        try select(document, "Shared A")
        XCTAssertTrue(try apply(.paragraph, 1, document))
        settle()
        XCTAssertEqual(props("Shared A")?.style, 1)
        XCTAssertEqual(props("Shared B")?.style, 2, "стиль не перешёл на следующий абзац")
        XCTAssertEqual(props("Shared C")?.style, 2)
        XCTAssertEqual(props("Shared B")?.alignment, .justify)
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original, "один шаг отмены — байт в байт")
        settle()
        // К среднему (своего `\pard` нет): C остаётся «Основной».
        try select(document, "Shared B")
        XCTAssertTrue(try apply(.paragraph, 1, document))
        settle()
        XCTAssertEqual(props("Shared B")?.style, 1)
        XCTAssertEqual(props("Shared C")?.style, 2, "стиль не перешёл на следующий абзац")
        XCTAssertEqual(props("Shared A")?.style, 2)
        XCTAssertEqual(DocTableEdit.violations(RTFReader.read(tab.text)), 0)
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original)
    }

    /// В стиле есть то, что `ParaChange` не пишет (границы, табуляции): стиль применяется (номер, выравнивание, знаки), а абзац
    /// не ломается — свои табуляции и рамка остаются, текст тот же, отмена байт в байт.
    func testStyleWithBordersAndTabsKeepsParagraph() throws {
        let sheet = Self.sheet.replacingOccurrences(of: #"{\*\cs10"#, with: #"{\s3\qr\brdrb\brdrs\brdrw10\tx1440\f0\fs24\i \sbasedon0 Bordered;}{\*\cs10"#)
        let source = Self.source.replacingOccurrences(of: Self.sheet, with: sheet)
            .replacingOccurrences(of: #"\pard\plain\f0\fs24 Third paragraph plain.\par"#,
                                  with: #"\pard\plain\brdrt\brdrs\brdrw10\tx2880\f0\fs24 Name\tab Value\par"#)
        let (tab, document, window) = try open(source)
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        let shownBefore = document.storage.string
        let style = try XCTUnwrap(document.styleSheet.style(.paragraph, 3))
        try select(document, "Name")
        XCTAssertTrue(document.applyStyle(style), document.notice ?? "")
        settle()
        let paragraph = try XCTUnwrap(document.model.body.paragraphs.first { $0.runs.map(\.text).joined().hasPrefix("Name") })
        XCTAssertEqual(paragraph.props.style, 3)
        XCTAssertEqual(paragraph.props.alignment, .right, "выравнивание стиля")
        XCTAssertEqual(paragraph.props.tabs.map(\.position), [2880], "свои табуляции абзаца на месте")
        XCTAssertTrue(paragraph.props.borderTop.isVisible, "своя рамка абзаца на месте")
        XCTAssertTrue(paragraph.runs.filter { FormatEdits.isTarget($0.kind) }.allSatisfy(\.props.italic), "знаки стиля")
        XCTAssertEqual(document.storage.string, shownBefore, "текст тот же")
        XCTAssertEqual(DocTableEdit.violations(RTFReader.read(tab.text)), 0)
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original, "один шаг отмены — байт в байт")
    }

    /// Подсветка в галерее (25f91d6) — стиль под курсором и в ячейке таблицы, и в правке колонтитула: в колонтитуле — стиль его
    /// абзаца, а знаковый стиль — не тот, что у курсора основного текста.
    func testGalleryHighlightInTableAndHeader() throws {
        let source = Self.source
            .replacingOccurrences(of: #"\sectd"#, with: #"\sectd{\header \pard\plain\s1\qc\f0\fs32\b Header title\par}"#)
            .replacingOccurrences(of: #"\pard\plain\intbl\f0\fs24 Cell one text"#, with: #"\pard\plain\intbl\s2\f0\fs22 Cell one text"#)
            .replacingOccurrences(of: #"\pard\plain\f0\fs24 Last paragraph with some words.\par}"#,
                                  with: #"\pard\plain\f0\fs24 Last paragraph with {\cs11\i\cf2 some} words.\par}"#)
        let (_, document, window) = try open(source)
        defer { window.contentView = nil; window.close() }
        let formatter = DocFormatter.of(document)
        try select(document, "Cell one")
        settle()
        XCTAssertEqual(DocRibbonStyles.currentNumber(formatter.state.paragraph), 2, "ячейка: стиль её абзаца")
        try select(document, "some")
        settle()
        XCTAssertEqual(formatter.state.characterStyle, 11, "знаковый стиль у курсора тела")
        formatter.beginHeaderEditing(page: try XCTUnwrap(document.pagesView.pages.first), header: true)
        let session = try XCTUnwrap(formatter.headerSession)
        session.textView.setSelectedRange(NSRange(location: 2, length: 0))
        formatter.updateState()
        XCTAssertEqual(DocRibbonStyles.currentNumber(formatter.state.paragraph), 1, "колонтитул: стиль его абзаца (\\s1)")
        XCTAssertNil(formatter.state.characterStyle, "в колонтитуле — не знаковый стиль курсора тела")
        formatter.endHeaderEditing()
    }
}

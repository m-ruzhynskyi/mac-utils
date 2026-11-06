import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUTextEditor

/// R4: «Параметры страницы» — что и куда пишется в RTF; чистая логика на модели, затем на документе в окне.
@MainActor
final class DocPageSetupTests: XCTestCase {
    private typealias Change = DocPageSetup.Change
    private static let font = #"{\fonttbl{\f0\froman Times New Roman;}}"#

    /// Документ без кодов страницы вообще.
    static let bare = #"{\rtf1\ansi\deff0"# + font + #"\pard\plain\f0 Only text.\par}"#
    /// Коды документа (как у Word-файла без раздельных): `\paperw/\paperh/\margl…`, `\sectd` без своих.
    static let docCodes = #"{\rtf1\ansi\deff0"# + font + #"\paperw11906\paperh16838\margl1701\margr851\margt1134\margb1134\sectd\pard\plain\f0 Doc codes.\par}"#
    /// Коды раздела: поверх кодов документа свои после `\sectd`.
    static let sectionCodes = #"{\rtf1\ansi\deff0"# + font + #"\paperw11906\paperh16838\margl1701\margr851\margt1134\margb1134\sectd\pgwsxn11906\pghsxn16838\marglsxn1134\margrsxn1134\margtsxn1134\margbsxn1134\pard\plain\f0 Section codes.\par}"#
    /// Три раздела: первый и третий на кодах документа, второй со своими.
    static let three = #"{\rtf1\ansi\deff0"# + font + #"\paperw11906\paperh16838\margl1701\margr851\margt1134\margb1134\sectd\pard\plain\f0 One.\par\sect"#
        + #"\sectd\pgwsxn11906\pghsxn16838\marglsxn567\margrsxn567\margtsxn567\margbsxn567\pard\plain\f0 Two.\par\sect"#
        + #"\sectd\pard\plain\f0 Three.\par}"#

    private func apply(_ change: Change, section: Int = 0, to source: String) throws -> String {
        let model = RTFReader.read(source as NSString)
        let plan = try DocPageSetup.plan(change, section: section, source: source as NSString, model: model).get()
        return try XCTUnwrap(FormatCheck.apply(plan.edits, to: source as NSString)) as String
    }

    private func page(_ source: String, section: Int = 0) -> DocPageSetup.Page {
        DocPageSetup.page(of: RTFReader.read(source as NSString).sections[section].props)
    }

    // MARK: - Чистая логика

    func testPresetsAndPaperAndMarksFollowPage() {
        XCTAssertEqual(DocPageSetup.Preset.allCases.map(\.title), ["Обычные", "Узкие", "Средние", "Широкие"])
        XCTAssertEqual(DocPageSetup.Margins.normal, .init(left: 1701, right: 851, top: 1134, bottom: 1134), "2 / 2 / 3 / 1,5 см")
        XCTAssertEqual(DocPageSetup.Margins.narrow.left, 720, "1,27 см")
        XCTAssertEqual(DocPageSetup.preset(of: .init(left: 1700, right: 850, top: 1134, bottom: 1134)), .normal, "допуск в несколько твипов")
        XCTAssertNil(DocPageSetup.preset(of: .init(left: 1000, right: 1000, top: 1000, bottom: 1000)))
        XCTAssertEqual(DocPageSetup.paper(of: .init(width: 11906, height: 16838, margins: .normal)), .a4)
        XCTAssertEqual(DocPageSetup.paper(of: .init(width: 16838, height: 11906, margins: .normal)), .a4, "альбомная A4 — тоже A4")
        XCTAssertEqual(DocPageSetup.paper(of: .init(width: 12240, height: 15840, margins: .normal)), .letter)
        XCTAssertNil(DocPageSetup.paper(of: .init(width: 10000, height: 10000, margins: .normal)))
        XCTAssertEqual(DocPageSetup.twips(cm: 2), 1134)
        XCTAssertEqual(DocPageSetup.twips(cm: 1.5), 851)
        XCTAssertEqual(DocPageSetup.parse(cm: "2,5 см"), 2.5)
        XCTAssertNil(DocPageSetup.parse(cm: "abc"))
        XCTAssertEqual(DocRibbonPageSetup.text(cm: 1134), "2")
        XCTAssertEqual(DocRibbonPageSetup.text(cm: 720), "1,27")
        XCTAssertNotNil(DocPageSetup.problem(.init(left: 6000, right: 6000, top: 1000, bottom: 1000), page: .init(width: 11906, height: 16838, margins: .normal)))
        XCTAssertNil(DocPageSetup.problem(.normal, page: .init(width: 11906, height: 16838, margins: .normal)))
    }

    func testResultOfChange() {
        let a4 = DocPageSetup.Page(width: 11906, height: 16838, margins: .normal)
        let landscape = DocPageSetup.result(of: .landscape(true), on: a4)
        XCTAssertEqual([landscape.width, landscape.height], [16838, 11906])
        XCTAssertEqual(DocPageSetup.result(of: .landscape(true), on: landscape), landscape, "уже альбомная — без перестановки")
        XCTAssertEqual(DocPageSetup.result(of: .landscape(false), on: landscape), a4)
        let letterLandscape = DocPageSetup.result(of: .paper(.letter), on: landscape)
        XCTAssertEqual([letterLandscape.width, letterLandscape.height], [15840, 12240], "размер меняется, ориентация остаётся")
    }

    // MARK: - Правка исходника

    func testDocumentWithoutCodesGetsDocumentCodes() throws {
        let after = try apply(.margins(.narrow), to: Self.bare)
        XCTAssertTrue(after.contains(#"\margl720"#) && after.contains(#"\margr720"#) && after.contains(#"\margt720"#) && after.contains(#"\margb720"#))
        XCTAssertFalse(after.contains("sxn"), "своих кодов раздела нет — пишутся коды документа")
        XCTAssertEqual(page(after).margins, .narrow)
        XCTAssertEqual(DocPageSetup.visibleOnly(after), DocPageSetup.visibleOnly(Self.bare))
    }

    func testDocumentCodesAreReplaced() throws {
        let after = try apply(.margins(.wide), to: Self.docCodes)
        XCTAssertEqual(after, Self.docCodes
            .replacingOccurrences(of: #"\margl1701"#, with: #"\margl2880"#).replacingOccurrences(of: #"\margr851"#, with: #"\margr2880"#)
            .replacingOccurrences(of: #"\margt1134\margb1134"#, with: #"\margt1440\margb1440"#), "только числа в тех же кодах")
        XCTAssertEqual(page(after).margins, .wide)
    }

    func testSectionCodesWinOverDocumentCodes() throws {
        let after = try apply(.margins(.moderate), to: Self.sectionCodes)
        XCTAssertTrue(after.contains(#"\marglsxn1083"#) && after.contains(#"\margtsxn1440"#), "заменены коды раздела")
        XCTAssertTrue(after.contains(#"\margl1701\margr851"#), "коды документа не тронуты")
        XCTAssertEqual(page(after).margins, .moderate)
    }

    func testLandscapePortraitRoundTripReturnsOriginal() throws {
        for source in [Self.docCodes, Self.sectionCodes] {
            let landscape = try apply(.landscape(true), to: source)
            let current = page(landscape)
            XCTAssertEqual([current.width, current.height], [16838, 11906])
            XCTAssertTrue(landscape.contains("landscape") || landscape.contains("lndscpsxn"), "метка ориентации записана")
            let back = try apply(.landscape(false), to: landscape)
            XCTAssertEqual(back, source, "книжная → альбомная → книжная даёт исходный текст")
        }
    }

    func testPaperSizesKeepOrientation() throws {
        for paper in DocPageSetup.Paper.allCases {
            let portrait = try apply(.paper(paper), to: Self.docCodes)
            XCTAssertEqual(DocPageSetup.paper(of: page(portrait)), paper)
            XCTAssertFalse(page(portrait).isLandscape)
            let landscapeFirst = try apply(.landscape(true), to: Self.docCodes)
            let both = try apply(.paper(paper), to: landscapeFirst)
            XCTAssertEqual(DocPageSetup.paper(of: page(both)), paper)
            XCTAssertTrue(page(both).isLandscape, "ориентация осталась")
        }
    }

    func testDocumentWithoutCodesRoundTripKeepsPageAndTextOnly() throws {
        let landscape = try apply(.landscape(true), to: Self.bare)
        let back = try apply(.landscape(false), to: landscape)
        XCTAssertEqual(page(back), page(Self.bare), "страница та же")
        XCTAssertEqual(DocPageSetup.visibleOnly(back), DocPageSetup.visibleOnly(Self.bare))
    }

    func testSeveralSectionsOnlyTheCaretSectionChanges() throws {
        let model = RTFReader.read(Self.three as NSString)
        XCTAssertEqual(model.sections.count, 3)
        // Раздел 1 (на кодах документа): пишется после его `\sectd`, раздел 3 остаётся как был.
        let first = try apply(.margins(.narrow), section: 0, to: Self.three)
        XCTAssertEqual(page(first, section: 0).margins, .narrow)
        XCTAssertEqual(page(first, section: 1).margins, page(Self.three, section: 1).margins)
        XCTAssertEqual(page(first, section: 2).margins, page(Self.three, section: 2).margins, "третий раздел не изменился")
        // Раздел 2 (свои коды): заменяются они.
        let second = try apply(.landscape(true), section: 1, to: Self.three)
        XCTAssertTrue(page(second, section: 1).isLandscape)
        XCTAssertFalse(page(second, section: 0).isLandscape)
        XCTAssertFalse(page(second, section: 2).isLandscape)
        XCTAssertEqual(try apply(.landscape(false), section: 1, to: second), Self.three, "туда-обратно — исходный текст")
        // Раздел 3 (коды документа): свои коды после его `\sectd`.
        let third = try apply(.paper(.letter), section: 2, to: Self.three)
        XCTAssertEqual(DocPageSetup.paper(of: page(third, section: 2)), .letter)
        XCTAssertEqual(DocPageSetup.paper(of: page(third, section: 0)), .a4)
        XCTAssertEqual(DocPageSetup.paper(of: page(third, section: 1)), .a4)
    }

    func testNothingToDoIsEmptyPlan() throws {
        let model = RTFReader.read(Self.docCodes as NSString)
        XCTAssertTrue(try DocPageSetup.plan(.margins(.normal), section: 0, source: Self.docCodes as NSString, model: model).get().edits.isEmpty)
        XCTAssertTrue(try DocPageSetup.plan(.landscape(false), section: 0, source: Self.docCodes as NSString, model: model).get().edits.isEmpty)
    }

    func testHeadersCodesUntouched() throws {
        let withHeader = #"{\rtf1\ansi\deff0"# + Self.font + #"\paperw11906\paperh16838\margl1701\margr851\margt1134\margb1134\sectd\headery500\footery400"#
            + #"{\header \pard\plain\f0 Head.\par}\pard\plain\f0 Body.\par}"#
        let after = try apply(.margins(.narrow), to: withHeader)
        XCTAssertTrue(after.contains(#"\headery500\footery400"#), "\\headery/\\footery не тронуты")
    }

    // MARK: - На документе в окне

    private func open(_ source: String) throws -> (EditorTab, DocumentController, NSWindow) {
        let (workspace, tab) = DocDemo.tab(source, name: "page_setup.frm")
        tab.restoreMode(.document)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (tab, try XCTUnwrap(tab.documentController), window)
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }

    func testCommandsRelayoutAndUndoByteForByte() throws {
        let (tab, document, window) = try open(Self.docCodes)
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        let before = try XCTUnwrap(document.pagesView.pages.first).frame.size
        XCTAssertTrue(document.perform(.landscape(true)))
        settle()
        let after = try XCTUnwrap(document.pagesView.pages.first).frame.size
        XCTAssertGreaterThan(after.width, before.width, "страница стала шире")
        XCTAssertLessThan(after.height, before.height)
        XCTAssertEqual(document.currentPageSetup?.isLandscape, true)
        XCTAssertEqual(tab.undo.undoActionName, "Ориентация страницы")
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original, "один шаг отмены — байт в байт")
        XCTAssertEqual(try XCTUnwrap(document.pagesView.pages.first).frame.size.width, before.width, accuracy: 0.5, "после отмены страница прежняя")
        XCTAssertTrue(document.perform(.margins(.wide)))
        settle()
        XCTAssertEqual(document.currentPageSetup?.margins, .wide)
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original)
    }

    func testBadMarginsAreRefusedWithReason() throws {
        let (tab, document, window) = try open(Self.docCodes)
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        XCTAssertFalse(document.perform(.margins(.init(left: 9000, right: 9000, top: 1134, bottom: 1134))))
        XCTAssertEqual(tab.text as String, original, "правки не было")
        let availability = DocPageSetupCommand.availability(.margins(.init(left: 9000, right: 9000, top: 1, bottom: 1)), isDocument: true, page: document.currentPageSetup)
        if case .disabled(let reason) = availability { XCTAssertFalse(reason.isEmpty) } else { XCTFail("должна быть недоступна с причиной") }
        XCTAssertEqual(DocPageSetupCommand.availability(.landscape(true), isDocument: false, page: nil), .hidden)
    }

    /// Копии форм: чтение без правки — поля те же; применение пресета и возврат отменой — файл тот же.
    func testRealFormsKeepPageAndUndo() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else { throw XCTSkip("MU_WORD_REF_DIR") }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("rtf")
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".rtf") }.sorted()
        var checked = 0, failures = 0
        for file in names {
            guard checked < 12, let data = try? Data(contentsOf: base.appendingPathComponent(file)), data.count < 300_000 else { continue }
            let text = EditorDocument(data: data).decodedText
            let model = RTFReader.read(text as NSString)
            let page = DocPageSetup.page(of: model.sections[0].props)
            // Без правки: те же коды читаются заново — та же страница.
            if DocPageSetup.page(of: RTFReader.read(text as NSString).sections[0].props) != page { failures += 1 }
            let (tab, document, window) = try open(text)
            defer { window.contentView = nil; window.close() }
            checked += 1
            if document.currentPageSetup != page { failures += 1 }
            let before = tab.text as String
            for change in [Change.margins(.narrow), .landscape(true), .paper(.letter)] {
                if document.perform(change) {
                    settle()
                    tab.undo.undo()
                    settle()
                }
                if (tab.text as String) != before { failures += 1 }
            }
        }
        print("PAGESETUP forms checked=\(checked) failures=\(failures)")
        XCTAssertGreaterThan(checked, 2)
        XCTAssertEqual(failures, 0)
    }
}

extension DocPageSetup {
    /// Текст без управляющих слов — для сравнения «текст тот же».
    static func visibleOnly(_ source: String) -> String {
        RTFReader.read(source as NSString).body.paragraphs.flatMap(\.runs).map(\.text).joined()
    }
}


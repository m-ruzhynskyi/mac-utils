import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// «Как в предыдущем» (H3): связь и развязка колонтитула раздела на документе в трёх разделах; правка — одна вставка или одно
/// удаление группы, байты вне неё те же, отмена возвращает файл байт в байт. «Особый первой» и «Чётные/нечётные» — по разделам.
@MainActor
final class DocHeaderLinkTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.set(false, forKey: Pref.editorInvisibles)
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    /// Три раздела; колонтитул (с номером страницы) записан только у первого, второй и третий показывают его же.
    static let threeSections = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}}\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134"#
        + #"\sectd\headery709\footery709{\headerr \pard\plain Header one {\field{\*\fldinst PAGE }{\fldrslt 1}}\par}"# + "\r\n"
        + #"\pard\plain First section text\par\sect"# + "\r\n"
        + #"\sectd\headery709\footery709 \pard\plain Second section text\par\sect"# + "\r\n"
        + #"\sectd\headery709\footery709 \pard\plain Third section text\par}"#

    private func settle(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func open(_ source: String) throws -> (EditorTab, DocumentController, DocFormatter) {
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: Data(source.utf8), url: URL(fileURLWithPath: "/tmp/link.rtf")))
        tab.restoreMode(.document)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace).environment(\.controlActiveState, .key))
        window.orderBack(nil)
        windows.append(window)
        settle()
        let document = try XCTUnwrap(tab.documentController)
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
        settle()
        return (tab, document, DocFormatter.of(document))
    }

    private func apply(_ plan: FormatPlan, to source: String) -> String {
        FormatCheck.apply(plan.edits, to: source as NSString)! as String
    }

    func testPureLinkAndUnlinkOnThreeSections() throws {
        let source = Self.threeSections
        let model = RTFReader.read(source as NSString)
        XCTAssertEqual(model.sections.count, 3)
        XCTAssertNotNil(model.sections[0].headers[.headerRight])
        XCTAssertTrue(DocHeaderFooterEdits.isLinkedToPrevious(.headerRight, section: 1, model: model))
        XCTAssertTrue(DocHeaderFooterEdits.isLinkedToPrevious(.headerRight, section: 2, model: model))
        XCTAssertFalse(DocHeaderFooterEdits.isLinkedToPrevious(.headerRight, section: 0, model: model), "у первого раздела предыдущего нет")
        // Отвязать второй: ему записывается копия группы первого.
        let plan: FormatPlan
        switch DocHeaderFooterEdits.unlink(.headerRight, section: 1, source: source as NSString, model: model) {
        case .success(let value): plan = value
        case .failure(let failure): return XCTFail(failure.reason)
        }
        XCTAssertEqual(plan.edits.count, 1)
        XCTAssertEqual(plan.edits[0].range.length, 0, "одна вставка")
        let group = (source as NSString).substring(with: try XCTUnwrap(model.sections[0].headers[.headerRight]).group)
        XCTAssertEqual(plan.edits[0].string, group, "копия той же группы, поле PAGE внутри")
        let unlinked = apply(plan, to: source)
        let after = RTFReader.read(unlinked as NSString)
        XCTAssertNotNil(after.sections[1].headers[.headerRight])
        XCTAssertFalse(DocHeaderFooterEdits.isLinkedToPrevious(.headerRight, section: 1, model: after))
        XCTAssertTrue(DocHeaderFooterEdits.isLinkedToPrevious(.headerRight, section: 2, model: after), "третий теперь показывает колонтитул второго")
        XCTAssertEqual(after.sections[1].headers[.headerRight]?.story.paragraphs.first?.plainText, model.sections[0].headers[.headerRight]?.story.paragraphs.first?.plainText)
        // Вставка — единственное отличие: вырезаем её — получаем исходник.
        let removed = (unlinked as NSString).replacingCharacters(in: NSRange(location: plan.edits[0].range.location, length: (group as NSString).length), with: "")
        XCTAssertEqual(removed, source)
        // Связать обратно — файл как был, байт в байт.
        switch DocHeaderFooterEdits.link(.headerRight, section: 1, source: unlinked as NSString, model: after) {
        case .success(let back): XCTAssertEqual(apply(back, to: unlinked), source)
        case .failure(let failure): XCTFail(failure.reason)
        }
        // Нельзя: связать колонтитул первого раздела и отвязать уже свой.
        if case .success = DocHeaderFooterEdits.link(.headerRight, section: 0, source: source as NSString, model: model) { XCTFail("у первого раздела связывать не с чем") }
        if case .success = DocHeaderFooterEdits.unlink(.headerRight, section: 0, source: source as NSString, model: model) { XCTFail("уже свой") }
        // Колонтитула другого вида ни у кого нет.
        XCTAssertFalse(DocHeaderFooterEdits.isLinkedToPrevious(.footer, section: 1, model: model))
    }

    func testFormatterCommandsUndoByteForByte() throws {
        let (tab, document, formatter) = try open(Self.threeSections)
        let original = tab.text as String
        let page = try XCTUnwrap(document.pagesView.pages.first { $0.section == 1 })
        formatter.beginHeaderEditing(page: page, header: true)
        XCTAssertEqual(formatter.headerLink, .linked, "второй раздел показывает колонтитул первого")
        XCTAssertEqual(formatter.headerSession?.section, 0, "правка идёт в раздел, где колонтитул записан")
        XCTAssertEqual(tab.text as String, original, "вход в правку связанного колонтитула файл не меняет")
        formatter.setLinkedToPrevious(false)
        XCTAssertEqual(formatter.headerLink, .own)
        XCTAssertEqual(formatter.headerSession?.section, 1, "правка перешла на собственный колонтитул раздела")
        XCTAssertNotNil(document.model.sections[1].headers[.headerRight])
        XCTAssertNotEqual(tab.text as String, original)
        // Правка собственного колонтитула первого раздела не задевает.
        let firstGroup = document.model.sections[0].headers[.headerRight]?.group
        let firstText = firstGroup.map { (tab.text as NSString).substring(with: $0) }
        let session = try XCTUnwrap(formatter.headerSession)
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        session.textView.insertText("Другой ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(session.storage.string.contains("Другой"), session.storage.string)
        XCTAssertEqual(document.model.sections[1].headers[.headerRight]?.story.paragraphs.first?.plainText.hasPrefix("Другой"), true)
        XCTAssertEqual(document.model.sections[0].headers[.headerRight].map { (tab.text as NSString).substring(with: $0.group) }, firstText, "колонтитул первого раздела не тронут")
        // Связать обратно: свой пропадает вместе с набранным.
        formatter.setLinkedToPrevious(true)
        XCTAssertEqual(formatter.headerLink, .linked)
        XCTAssertNil(document.model.sections[1].headers[.headerRight])
        XCTAssertEqual(formatter.headerSession?.section, 0)
        // Отмена трёх шагов — файл как был.
        for _ in 0..<3 { tab.undo.undo() }
        XCTAssertEqual(tab.text as String, original)
        formatter.endHeaderEditing()
    }

    func testNoLinkButtonForFirstSection() throws {
        let (_, document, formatter) = try open(Self.threeSections)
        let page = try XCTUnwrap(document.pagesView.pages.first { $0.section == 0 })
        formatter.beginHeaderEditing(page: page, header: true)
        XCTAssertNil(formatter.headerLink, "первый раздел: кнопки нет")
        formatter.setLinkedToPrevious(true)
        formatter.setLinkedToPrevious(false)
        XCTAssertNotNil(document.model.sections[0].headers[.headerRight], "команды без состояния ничего не делают")
        formatter.endHeaderEditing()
    }

    func testTitlePageAndFacingPerSectionBytes() throws {
        let (tab, document, formatter) = try open(Self.threeSections)
        let original = tab.text as String
        let page = try XCTUnwrap(document.pagesView.pages.first { $0.section == 1 })
        formatter.beginHeaderEditing(page: page, header: true)
        formatter.setTitlePage(true)
        XCTAssertTrue(document.model.sections[1].props.titlePage)
        XCTAssertFalse(document.model.sections[0].props.titlePage, "только у своего раздела")
        XCTAssertFalse(document.model.sections[2].props.titlePage)
        formatter.setFacingPages(true)
        XCTAssertTrue(document.model.facingPages)
        XCTAssertTrue(formatter.facingPagesOn)
        var steps = 0
        while tab.text as String != original, tab.undo.canUndo, steps < 10 { tab.undo.undo(); steps += 1 }
        XCTAssertEqual(tab.text as String, original, "отмены возвращают файл как был")
        settle()
        XCTAssertFalse(document.model.sections[1].props.titlePage)
        formatter.endHeaderEditing()
    }

    /// Копии настоящих форм (`MU_WORD_REF_DIR`): у многораздельных — отвязать и связать каждый унаследованный колонтитул: файл как был, Cocoa открывает.
    func testRealFormsUnlinkLinkRoundTrip() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else { throw XCTSkip("MU_WORD_REF_DIR") }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("rtf")
        let rtf: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        var forms = 0, pairs = 0, failures = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: base.path).filter({ $0.hasSuffix(".rtf") }).sorted() {
            guard let data = try? Data(contentsOf: base.appendingPathComponent(name)), data.count < 600_000 else { continue }
            let source = EditorDocument(data: data).decodedText as NSString
            let model = RTFReader.read(source)
            guard model.sections.count > 1 else { continue }
            var touched = false
            for section in 1..<model.sections.count {
                for kind in RTFHeaderKind.allCases where DocHeaderFooterEdits.isLinkedToPrevious(kind, section: section, model: model) {
                    guard case .success(let plan) = DocHeaderFooterEdits.unlink(kind, section: section, source: source, model: model) else { failures += 1; XCTFail("\(name): не отвязалось"); continue }
                    let unlinked = FormatCheck.apply(plan.edits, to: source)!
                    guard case .success(let back) = DocHeaderFooterEdits.link(kind, section: section, source: unlinked, model: RTFReader.read(unlinked)),
                          FormatCheck.apply(back.edits, to: unlinked) as String? == source as String else { failures += 1; XCTFail("\(name): связь не вернула файл"); continue }
                    if (try? NSAttributedString(data: Data((unlinked as String).utf8), options: rtf, documentAttributes: nil)) == nil,
                       (try? NSAttributedString(data: data, options: rtf, documentAttributes: nil)) != nil { failures += 1; XCTFail("\(name): Cocoa") }
                    pairs += 1
                    touched = true
                }
            }
            if touched { forms += 1 }
        }
        print("H3-AUDIT forms=\(forms) pairs=\(pairs) failures=\(failures)")
        XCTAssertEqual(failures, 0)
    }
}

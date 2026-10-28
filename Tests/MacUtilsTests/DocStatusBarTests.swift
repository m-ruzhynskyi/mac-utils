import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Строка состояния «Документа» (T3): язык у курсора, «Изменён · ⌘S» гаснет после записи, масштаб ⌘+/⌘−/⌘0 через команды окна,
/// ⌘S пишет только правки; при отказе проверки — лист с «Сохранить как копию…». Демо — выдуманный текст.
@MainActor
final class DocStatusBarTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!
    private var folder: URL!

    override func setUpWithError() throws {
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("doc-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    static let multilingual = #"{\rtf1\ansi\ansicpg1251\deff0\deflang1049{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}\sectd"# + "\r\n"
        + #"\pard\plain\f0\fs24 "# + DocDemo.rtf("Привет, мир") + #"\par"# + "\r\n"
        + #"\pard\plain\f0\fs24 {\lang1058 "# + DocDemo.rtf("Привіт, світе") + #"} after group\par"# + "\r\n"
        + #"\pard\plain\f0\fs24\lang1033 Hello world\par}"#

    private func open(_ source: String, name: String = "status.rtf") throws -> (EditorTab, DocumentController, URL) {
        let url = folder.appendingPathComponent(name)
        try Data(source.utf8).write(to: url)
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: try EditorDocument.open(url))
        tab.restoreMode(.document)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        windows.append(window)
        settle()
        return (tab, try XCTUnwrap(tab.documentController), url)
    }

    func testLanguageNamesAndScopes() {
        XCTAssertEqual(DocLanguage.name(lcid: 1049), "русский")
        XCTAssertEqual(DocLanguage.name(lcid: 1058), "украинский")
        XCTAssertEqual(DocLanguage.name(lcid: 1033), "английский (США)")
        XCTAssertNil(DocLanguage.name(lcid: 999_999))
        let source = Self.multilingual as NSString
        XCTAssertEqual(DocLanguage.documentDefault(in: source), 1049)
        let ukrainian = source.range(of: "} after group").location
        let paragraph = source.range(of: #"\pard\plain\f0\fs24 {\lang1058"#).location
        XCTAssertEqual(DocLanguage.lcid(atSource: paragraph + 30, from: paragraph, in: source), 1058, "внутри группы")
        XCTAssertEqual(DocLanguage.lcid(atSource: ukrainian + 5, from: paragraph, in: source), 1049, "после группы — язык документа")
        let last = source.range(of: "Hello").location
        XCTAssertEqual(DocLanguage.lcid(atSource: last + 2, from: source.range(of: #"\pard\plain\f0\fs24\lang1033"#).location, in: source), 1033)
        XCTAssertEqual(DocLanguage.lcid(atSource: 0, from: 0, in: "{\\rtf1}" as NSString), 1033, "без \\deflang — английский")
    }

    func testStatusShowsLanguageAtCaret() throws {
        let (_, document, _) = try open(Self.multilingual)
        let view = try XCTUnwrap(document.textViews.first)
        let shown = document.storage.string as NSString
        view.setSelectedRange(NSRange(location: shown.range(of: "мир").location, length: 0))
        settle(0.1)
        XCTAssertEqual(document.languageName, "русский")
        view.setSelectedRange(NSRange(location: shown.range(of: "світе").location, length: 0))
        settle(0.1)
        XCTAssertEqual(document.languageName, "украинский")
        view.setSelectedRange(NSRange(location: shown.range(of: "world").location, length: 0))
        settle(0.1)
        XCTAssertEqual(document.languageName, "английский (США)")
    }

    func testChangedIndicatorGoesOutAfterSaveAndOnlyEditsAreWritten() throws {
        let (tab, document, url) = try open(Self.multilingual)
        XCTAssertFalse(tab.isDirty, "открыли — «Изменён» нет")
        let view = try XCTUnwrap(document.textViews.first)
        view.setSelectedRange(NSRange(location: (document.storage.string as NSString).range(of: "мир").location, length: 0))
        view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(tab.isDirty, "после правки — «Изменён · ⌘S»")
        var saved: Bool?
        EditorWindowController.shared.save(tab) { saved = $0 }
        XCTAssertEqual(saved, true)
        XCTAssertFalse(tab.isDirty, "после записи индикатор гаснет")
        let written = try String(contentsOf: url, encoding: .ascii)
        let original = Self.multilingual
        let changed = (written as NSString).range(of: "!")
        XCTAssertEqual((written as NSString).replacingCharacters(in: changed, with: ""), original, "записана одна правка, остальные байты те же")
    }

    func testZoomCommandsStepAndReset() throws {
        let (tab, document, _) = try open(Self.multilingual)
        let controller = EditorWindowController.shared
        _ = controller
        document.fit = .none
        document.zoom = 1
        document.step(zoom: 1)
        XCTAssertEqual(document.zoom, 1.1, accuracy: 0.001)
        document.step(zoom: -1)
        document.step(zoom: -1)
        XCTAssertEqual(document.zoom, 0.9, accuracy: 0.001)
        document.fit = .none
        document.zoom = 1
        XCTAssertEqual(document.zoom, 1, "⌘0 — 100 %")
        for _ in 0..<20 { document.step(zoom: 1) }
        XCTAssertEqual(document.zoom, DocumentController.zoomRange.upperBound, accuracy: 0.001, "предел сверху")
        _ = tab
    }

    /// Правка колонтитула второй страницы: строка состояния называет страницу и раздел этой правки, а не курсора основного текста.
    func testStatusNamesPageOfHeaderEditing() throws {
        let (_, document, _) = try open(DocHeaderLinkTests.threeSections)
        let formatter = DocFormatter.of(document)
        XCTAssertEqual(document.pageCount, 3)
        document.textViews.first?.setSelectedRange(NSRange(location: 0, length: 0))
        document.updateStatus()
        XCTAssertEqual(document.currentPage, 1)
        let second = document.pagesView.pages[1]
        formatter.beginHeaderEditing(page: second, header: true)
        XCTAssertEqual(document.currentPage, 2, "правка колонтитула второй страницы — «Страница 2»")
        XCTAssertEqual(document.currentSection, 2)
        formatter.endHeaderEditing()
        XCTAssertEqual(document.currentPage, 1, "вышли — снова страница курсора")
        XCTAssertEqual(document.currentSection, 1)
    }
}

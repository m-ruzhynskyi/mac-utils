import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Разрывы страниц и отступы у страницы как у Word (`DocPagination`, `DocLineMetrics`): отступ «перед» у верха страницы,
/// большее из «после»/«перед» между абзацами, `\keepn`, `\widctlpar`, повторный проход без устаревших пределов. Демо — выдуманный текст.
@MainActor
final class DocPaginationTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    /// A4, поля 2 см сверху и снизу: тело ≈ 728 pt, строка Times New Roman 12 у Word — 13,8 pt, то есть 52 строки.
    private static let head = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}}"#
        + #"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134\sectd\headery709\footery709 "#

    private func open(_ body: String) throws -> DocumentController {
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: Data((Self.head + body + "}").utf8), url: URL(fileURLWithPath: "/tmp/pagination.rtf")))
        tab.restoreMode(.document)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        windows.append(window)
        let document = try XCTUnwrap(tab.documentController)
        for _ in 0..<4 {
            if let last = document.layoutManager.textContainers.last { document.layoutManager.ensureLayout(for: last) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        return document
    }

    private func filler(_ count: Int, props: String = "") -> String {
        (1...count).map { #"\pard\plain\f0\fs24 "# + props + " Строка \($0)\\par\n" }.joined().replacingOccurrences(of: "Строка", with: "Line")
    }

    /// Номер страницы и рамка использованной части первой строки абзаца с `marker`.
    private func first(_ document: DocumentController, _ marker: String) throws -> (page: Int, used: NSRect) {
        let text = document.storage.string as NSString
        let found = text.range(of: marker)
        XCTAssertNotEqual(found.location, NSNotFound, marker)
        let manager = document.layoutManager
        let glyph = manager.glyphIndexForCharacter(at: found.location)
        let container = try XCTUnwrap(manager.textContainer(forGlyphAt: glyph, effectiveRange: nil))
        let page = try XCTUnwrap(document.pagesView.pages.firstIndex { $0.container === container })
        return (page, manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil))
    }

    func testSpaceBeforeIsDroppedAtTopOfNaturalPageButKeptOnFirstPage() throws {
        let document = try open((1...80).map { #"\pard\plain\f0\fs24\sb240 Para\#($0)\par"# + "\n" }.joined())
        XCTAssertGreaterThan(document.pagesView.pages.count, 1)
        let onFirstPage = try first(document, "Para1\n"), top = try first(document, "Para1\n")
        XCTAssertEqual(onFirstPage.used.minY, 12, accuracy: 0.6, "первая страница: отступ «перед» остаётся")
        XCTAssertEqual(top.page, 0)
        // Первый абзац второй страницы: определяем по контейнеру.
        let manager = document.layoutManager
        let glyphs = manager.glyphRange(for: document.pagesView.pages[1].container)
        let used = manager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        XCTAssertEqual(used.minY, 0, accuracy: 0.6, "страница началась сама: отступ «перед» пропадает")
    }

    func testPageBreakBeforeKeepsSpaceBefore() throws {
        let document = try open(filler(3) + #"\pard\plain\f0\fs24\sb240\pagebb Next\par"#)
        let next = try first(document, "Next")
        XCTAssertEqual(next.page, 1)
        XCTAssertEqual(next.used.minY, 12, accuracy: 0.6, "после \\pagebb отступ «перед» остаётся")
    }

    func testBiggerOfSpaceAfterAndBeforeBetweenParagraphs() throws {
        let document = try open(#"\pard\plain\f0\fs24\sa240 Upper\par\pard\plain\f0\fs24\sb240 Lower\par\pard\plain\f0\fs24 Third\par"#)
        let upper = try first(document, "Upper"), lower = try first(document, "Lower")
        let manager = document.layoutManager
        let text = document.storage.string as NSString
        let upperRect = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: text.range(of: "Upper").location), effectiveRange: nil)
        let lowerRect = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: text.range(of: "Lower").location), effectiveRange: nil)
        XCTAssertEqual(upper.page, lower.page)
        // 13,8 строка + max(12, 12), а не 13,8 + 24.
        XCTAssertEqual(lowerRect.minY - upperRect.minY, 13.8 + 12, accuracy: 0.8)
    }

    func testKeepWithNextMovesHeadingFromPageBottom() throws {
        let body = filler(51) + #"\pard\plain\f0\fs24\keepn Heading\par\pard\plain\f0\fs24 After heading\par"#
        let kept = try open(body)
        XCTAssertEqual(try first(kept, "Heading").page, 1, "заголовок с \\keepn вместе со следующим абзацем")
        XCTAssertEqual(try first(kept, "After heading").page, 1)
        let free = try open(body.replacingOccurrences(of: #"\keepn"#, with: ""))
        XCTAssertEqual(try first(free, "Heading").page, 0, "без \\keepn заголовок остаётся внизу")
    }

    func testWidowControlMovesSingleLineAtPageBottom() throws {
        let long = String(repeating: "Lorem ipsum dolor sit amet consectetur adipiscing elit. ", count: 6)
        let controlled = try open(filler(51) + #"\pard\plain\f0\fs24\widctlpar Orphan "# + long + #"\par"#)
        XCTAssertEqual(try first(controlled, "Orphan").page, 1, "одна строка внизу — абзац целиком на следующей странице")
        let plain = try open(filler(51) + #"\pard\plain\f0\fs24\nowidctlpar Orphan "# + long + #"\par"#)
        XCTAssertEqual(try first(plain, "Orphan").page, 0, "без \\widctlpar абзац рвётся как есть")
    }

    func testRepeatedPassKeepsTheSameLimits() throws {
        let long = String(repeating: "Lorem ipsum dolor sit amet consectetur adipiscing elit. ", count: 6)
        let document = try open(filler(51) + #"\pard\plain\f0\fs24\widctlpar Orphan "# + long + #"\par"# + filler(60))
        let before = document.pagesView.pages.map { $0.breakLimit }
        XCTAssertNotNil(before[0], "предел первой страницы поставлен")
        for _ in 0..<3 {
            document.pagesView.paginationDone = nil
            DocPagination.apply(document.pagesView, layoutManager: document.layoutManager)
        }
        let after = document.pagesView.pages.map { $0.breakLimit }
        XCTAssertEqual(after.count, before.count)
        for (a, b) in zip(after, before) { XCTAssertEqual(a ?? -1, b ?? -1, accuracy: 0.5, "предел не уходит вниз с каждым проходом") }
    }
}

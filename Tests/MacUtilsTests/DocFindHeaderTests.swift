import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// Поиск и замена в колонтитулах «Документа» (DOCFINDHF): три раздела — первый со своим колонтитулом, второй «как в предыдущем»
/// (своего нет), третий со своим.
@MainActor
final class DocFindHeaderTests: XCTestCase {
    static let head = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}"#
    /// Раздел 1: колонтитулы «Ромашка» (верх) и «Ромашка стр.» (низ); раздел 2: свои не заданы (наследует); раздел 3: свои «Лютик Ромашка».
    static let source = head
        + #"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134\sectd\sbkpage"#
        + #"{\header \pard\plain\f0\fs24 \'d0\'ee\'ec\'e0\'f8\'ea\'e0 \'c0\'e4\'f0\'e5\'f1\par}"#
        + #"{\footer \pard\plain\f0\fs24 \'d0\'ee\'ec\'e0\'f8\'ea\'e0 \'f1\'f2\'f0\par}"#
        + #"\pard\plain\f0\fs24 First section body.\par"#
        + #"\sect\sectd\sbkpage\pard\plain\f0\fs24 Second section body.\par"#
        + #"\sect\sectd\sbkpage"#
        + #"{\header \pard\plain\f0\fs24 \'cb\'fe\'f2\'e8\'ea \'d0\'ee\'ec\'e0\'f8\'ea\'e0\par}"#
        + #"\pard\plain\f0\fs24 Third section body.\par}"#

    private func open() throws -> (tab: EditorTab, document: DocumentController, window: NSWindow) {
        let (workspace, tab) = DocDemo.tab(Self.source, name: "find_hf.frm")
        tab.restoreMode(.document)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return (tab, try XCTUnwrap(tab.documentController), window)
    }

    func testThreeSectionsPagesAndLinkedHeaderCountedOnce() throws {
        let (_, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        XCTAssertEqual(document.pagesView.pages.map(\.section), [0, 1, 2], "три раздела — три страницы")
        let targets = document.headerFindTargets()
        // Верхний и нижний раздела 1 (на странице раздела 2 показаны те же), верхний раздела 3 (нижний он наследует от раздела 1).
        XCTAssertEqual(targets.map { "\($0.section)-\($0.kind.rawValue)" }, ["0-header", "0-footer", "2-header"], "связанные — один раз")
        let matches = try document.headerFindMatches(query: "Ромашка", options: SearchOptions())
        XCTAssertEqual(matches.count, 3, "верх 1 (он же на странице 2), низ 1 (общий), верх 3 — каждое по разу")
        XCTAssertEqual(matches.map(\.page), [0, 0, 2], "в порядке страниц")
    }

    /// Пока колонтитулы не заменяются, «Заменить все» говорит об этом (не молчит).
    func testReplaceAllReportsHeadersNotReplaced() throws {
        let (workspace, tab) = DocDemo.tab(Self.source, name: "find_hf_note.frm")
        tab.restoreMode(.document)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        workspace.findMode = false
        workspace.search.query = "Ромашка"
        workspace.search.replacement = "Лютик"
        workspace.search.refresh()
        let original = tab.text as String
        workspace.search.replaceAll()
        XCTAssertEqual(workspace.search.note, "В тексте совпадений нет; в колонтитулах не заменено: 3")
        XCTAssertEqual(tab.text as String, original, "правок не было")
        workspace.search.query = "body"
        workspace.search.replacement = "text"
        workspace.search.refresh()
        workspace.search.replaceAll()
        XCTAssertEqual(workspace.search.note, "Заменено: 3", "в колонтитулах «body» нет — ничего не добавляется")
    }
}

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
        + #"\pard\plain\f0\fs24 First section body \'d0\'ee\'ec\'e0\'f8\'ea\'e0.\par"#
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

    private func openWithWorkspace(_ source: String = DocFindHeaderTests.source) throws -> (EditorWorkspace, EditorTab, DocumentController, NSWindow) {
        let (workspace, tab) = DocDemo.tab(source, name: "find_hf_ws.frm")
        tab.restoreMode(.document)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        workspace.findMode = false
        return (workspace, tab, try XCTUnwrap(tab.documentController), window)
    }

    private func settle(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// «Заменить все» по телу и колонтитулам — один шаг отмены, байт в байт; связанный колонтитул заменяется один раз.
    func testReplaceAllInBodyAndHeadersIsOneUndoStep() throws {
        let (workspace, tab, document, window) = try openWithWorkspace()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        workspace.search.query = "Ромашка"
        workspace.search.replacement = "Лютик"
        workspace.search.refresh()
        XCTAssertEqual(workspace.search.count, 4, "тело 1 + верх 1 + низ 1 + верх 3 (связанный раздела 2 не считается дважды)")
        workspace.search.replaceAll()
        settle()
        XCTAssertEqual(workspace.search.note, "Заменено: 4 (в колонтитулах: 3)")
        XCTAssertFalse((tab.text as String).contains(DocDemo.rtf("Ромашка")), "старого текста нет нигде")
        XCTAssertEqual(try document.headerFindMatches(query: "Ромашка", options: SearchOptions()).count, 0)
        XCTAssertEqual(try document.headerFindMatches(query: "Лютик", options: SearchOptions()).count, 4, "верх 1, низ 1 и две в верхнем колонтитуле раздела 3 («Лютик Лютик»)")
        XCTAssertEqual((tab.text as String).components(separatedBy: DocDemo.rtf("Лютик")).count - 1, 5, "в файле — четыре замены и «Лютик», который был в колонтитуле раздела 3")
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original, "один шаг отмены — байт в байт")
        XCTAssertFalse(tab.undo.canUndo && tab.undo.undoActionName == "Заменить все", "второго шага нет")
    }

    /// Переход по совпадениям: тело и колонтитулы в порядке страниц; переход к колонтитулу открывает его правку и выделяет найденное.
    func testNextVisitsHeadersAndBodyInPageOrder() throws {
        let (workspace, _, document, window) = try openWithWorkspace()
        defer { window.contentView = nil; window.close() }
        workspace.search.query = "Ромашка"
        workspace.search.refresh()
        XCTAssertEqual(workspace.search.count, 4)
        var visited: [String] = []
        var wrappedAfter: [Bool] = []
        for _ in 0..<5 {
            workspace.search.next()
            settle(0.1)
            wrappedAfter.append(workspace.search.wrapped)
            if let session = document.openHeaderSession {
                let selected = (session.storage.string as NSString).substring(with: session.textView.selectedRange())
                visited.append("\(session.isHeader ? "верх" : "низ")\(session.section):\(selected.count)")
            } else {
                visited.append("тело:\((document.storage.string as NSString).substring(with: document.selectedUnits).count)")
            }
        }
        // Курсор в начале тела: тело (стр. 1), низ раздела 1 (стр. 1), верх раздела 3 (стр. 3); дальше по кругу — верх раздела 1, тело.
        XCTAssertEqual(visited, ["тело:7", "низ0:7", "верх2:7", "верх0:7", "тело:7"])
        XCTAssertEqual(wrappedAfter, [false, false, false, true, false], "с начала — только на переходе через край")
    }

    /// «Заменить» в открытом колонтитуле — точечная правка, отмена — байт в байт.
    func testReplaceOneInHeader() throws {
        let (workspace, tab, document, window) = try openWithWorkspace()
        defer { window.contentView = nil; window.close() }
        let original = tab.text as String
        workspace.search.query = "Ромашка"
        workspace.search.replacement = "Лютик"
        workspace.search.refresh()
        for _ in 0..<4 {
            workspace.search.next()
            settle(0.1)
        }
        XCTAssertEqual(document.openHeaderSession?.isHeader, true, "четвёртый переход — по кругу в верхний колонтитул раздела 1")
        workspace.search.replaceOne()
        settle(0.2)
        XCTAssertEqual(try document.headerFindMatches(query: "Лютик", options: SearchOptions()).count, 2, "заменён верхний колонтитул раздела 1 (+ свой у раздела 3)")
        XCTAssertEqual(try document.headerFindMatches(query: "Ромашка", options: SearchOptions()).count, 2, "низ 1 и верх 3 остались")
        tab.undo.undo()
        settle(0.2)
        XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
    }

    /// Копии форм (`MU_WORD_REF_DIR`): слово из колонтитула заменяется везде, отмена возвращает файл байт в байт, число разделов то же.
    func testRealFormsReplaceInHeadersAndUndo() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else { throw XCTSkip("MU_WORD_REF_DIR") }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("rtf")
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".rtf") }.sorted()
        var checked = 0, replaced = 0, failures = 0
        for file in names {
            guard checked < 14, let data = try? Data(contentsOf: base.appendingPathComponent(file)), data.count < 300_000 else { continue }
            let document = EditorDocument(data: data)
            let probe = RTFReader.read(document.decodedText as NSString, fallback: document.encoding)
            var words: [String] = []
            for header in probe.sections.flatMap({ Array($0.headers.values) }) {
                for run in header.story.paragraphs.flatMap(\.runs) where run.kind == .text && !run.props.hidden {
                    for token in run.text.split(whereSeparator: \.isWhitespace) where token.count >= 4 && token.allSatisfy(\.isLetter) {
                        words.append(String(token))
                    }
                }
            }
            guard let word = words.first else { continue }
            let (workspace, tab, controller, window) = try openWithWorkspace(document.decodedText)
            defer { window.contentView = nil; window.close() }
            _ = tab
            let before = tab.text as String
            workspace.search.query = word
            workspace.search.replacement = "ЗЗЗЗ"
            workspace.search.options.wholeWord = true
            workspace.search.refresh()
            let expected = try controller.headerFindMatches(query: word, options: workspace.search.options).count
            guard expected > 0 else { continue }
            checked += 1
            workspace.search.replaceAll()
            settle()
            let left = try controller.headerFindMatches(query: word, options: workspace.search.options).count
            replaced += expected - left
            if left != 0 || (tab.text as String) == before { failures += 1 }
            tab.undo.undo()
            settle()
            if (tab.text as String) != before { failures += 1 }
        }
        print("FINDHF forms checked=\(checked) headerMatchesReplaced=\(replaced) failures=\(failures)")
        XCTAssertGreaterThan(checked, 3)
        XCTAssertEqual(failures, 0)
    }
}

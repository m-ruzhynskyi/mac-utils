import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Автозамена (T5): «--» → «—», `"` → «ёлочки»; выключена по умолчанию; точечные правки без потерь (1000 случайных вводов).
@MainActor
final class DocAutoCorrectTests: XCTestCase {
    private func resolve(_ shown: String, caret: Int, typed: String, length: Int = 0) -> DocAutoCorrect.Replacement? {
        DocAutoCorrect.resolve(units: NSRange(location: caret, length: length), typed: typed, shown: shown as NSString, isPlainText: { _ in true })
    }

    func testDoubleHyphenBecomesEmDash() {
        XCTAssertEqual(resolve("a-", caret: 2, typed: "-"), .init(units: NSRange(location: 1, length: 1), text: "—"))
        XCTAssertNil(resolve("a", caret: 1, typed: "-"), "первый дефис остаётся")
        XCTAssertNil(resolve("a--", caret: 3, typed: "-"), "три дефиса — линия, не трогаем")
        XCTAssertNil(resolve("a--b", caret: 2, typed: "-"), "дефис справа тоже — это линия")
        XCTAssertNil(resolve("a-", caret: 2, typed: "-", length: 1), "выделение заменяется как обычно")
        XCTAssertNil(DocAutoCorrect.resolve(units: NSRange(location: 2, length: 0), typed: "-", shown: "a-" as NSString, isPlainText: { _ in false }), "не обычный текст (поле, номер)")
    }

    func testQuotesOpenAndClose() {
        XCTAssertEqual(resolve("", caret: 0, typed: "\"")?.text, "«", "начало абзаца")
        XCTAssertEqual(resolve("Он сказал ", caret: 10, typed: "\"")?.text, "«", "после пробела")
        XCTAssertEqual(resolve("Он сказал «да", caret: 13, typed: "\"")?.text, "»", "после слова")
        XCTAssertEqual(resolve("(", caret: 1, typed: "\"")?.text, "«", "после скобки")
        XCTAssertEqual(resolve("слово — ", caret: 8, typed: "\"")?.text, "«", "после тире и пробела")
        XCTAssertEqual(resolve("a\n", caret: 2, typed: "\"")?.text, "«", "после перевода строки")
        XCTAssertNil(resolve("a", caret: 1, typed: "x"), "обычные знаки не трогаем")
        XCTAssertNil(resolve("a", caret: 1, typed: "--"), "вставка не одного знака")
    }

    func testThousandRandomInputsStayLossless() throws {
        let documents = [DocReaderTests.letter, DocReaderTests.table, DocDemo.expertReport]
        let keys = ["-", "-", "\"", "a", "Я", " ", "\n", "—", "1"]
        var random = SeededRandom(seed: 5_2026)
        var replaced = 0
        for document in documents {
            var harness = DocEditTests.Harness(source: document)
            for _ in 0..<340 {
                let (shown, map) = harness.display()
                let count = map.count
                guard count > 0 else { break }
                let caret = random.next(count + 1)
                let typed = keys[random.next(keys.count)]
                var units = NSRange(location: caret, length: 0)
                var text = typed
                if let fix = DocAutoCorrect.resolve(units: units, typed: typed, shown: shown as NSString, isPlainText: { map.kind(at: $0) == .text }) {
                    units = fix.units
                    text = fix.text
                    replaced += 1
                }
                harness.edit(units, text)
            }
            XCTAssertTrue(RTFReader.read(harness.source as NSString).isRTF)
        }
        XCTAssertGreaterThan(replaced, 100, "автозамена действительно срабатывала")
    }

    func testOffByDefaultAndWorksInWindowThroughOneUndoStep() throws {
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Pref.docAutocorrect), "по умолчанию выключена")
        let defaults = EditorDefaultsSnapshot()
        defer { defaults.restore(); UserDefaults.standard.removeObject(forKey: Pref.docAutocorrect) }
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        let (workspace, tab) = DocDemo.tab()
        tab.restoreMode(nil)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let document = try XCTUnwrap(tab.documentController)
        let view = try XCTUnwrap(document.textViews.first)
        let original = tab.text as String
        let city = (document.storage.string as NSString).range(of: "Демоград")
        view.setSelectedRange(NSRange(location: NSMaxRange(city), length: 0))
        view.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(document.storage.string.contains("Демоград--"), "выключено — два дефиса как набрали")
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original)
        UserDefaults.standard.set(true, forKey: Pref.docAutocorrect)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.setSelectedRange(NSRange(location: NSMaxRange((document.storage.string as NSString).range(of: "Демоград")), length: 0))
        view.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(document.storage.string.contains("Демоград—"), document.storage.string)
        XCTAssertFalse(document.storage.string.contains("Демоград-"))
        view.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(document.storage.string.contains("Демоград—«"), "после тире — открывающая")
        let source = tab.text as String
        XCTAssertTrue(source.contains("\\'97") && source.contains("\\'ab"), "в cp1251: — и «")
    }
}

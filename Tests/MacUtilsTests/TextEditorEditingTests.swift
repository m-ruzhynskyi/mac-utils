import AppKit
import XCTest
@testable import MacUtils
@testable import MUAudio
@testable import MUTextEditor

/// Этап 2.6: сортировка, повторы, табы ↔ пробелы, закладки, ввод в прямоугольное выделение.
final class LineCommandsMoreTests: XCTestCase {
    /// Документ из CHECKLIST 11 (в первой строке по 2 пробела в начале и в конце).
    private let sample = "  beta  \nalpha\ngamma\nalpha\nBeta" as NSString

    private func apply(_ edit: LineEdit?, to text: NSString) -> String {
        guard let edit else { return text as String }
        let result = NSMutableString(string: text)
        for index in edit.ranges.indices.sorted(by: { edit.ranges[$0].location > edit.ranges[$1].location }) {
            result.replaceCharacters(in: edit.ranges[index], with: edit.strings[index])
        }
        return result as String
    }

    private let none = NSRange(location: 0, length: 0)

    func testSortKeepsLineBreaksInPlace() {
        let text = "b\r\na\r\nc" as NSString
        XCTAssertEqual(apply(LineCommands.sort(text, none, .ascending), to: text), "a\r\nb\r\nc", "последняя строка без перевода")
        XCTAssertEqual(apply(LineCommands.sort(text, none, .descending), to: text), "c\r\nb\r\na")
        let mixed = "beta\nAlpha\nalpha\nBeta" as NSString
        XCTAssertEqual(apply(LineCommands.sort(mixed, none, .caseInsensitive), to: mixed), "Alpha\nalpha\nbeta\nBeta",
                       "без учёта регистра — равные в прежнем порядке")
        XCTAssertNil(LineCommands.sort("a\nb" as NSString, none, .ascending), "уже по порядку — правки нет")
        XCTAssertNil(LineCommands.sort("one line" as NSString, none, .ascending))
        let cyrillic = "яблоко\nёж\nарбуз" as NSString
        XCTAssertEqual(apply(LineCommands.sort(cyrillic, none, .ascending), to: cyrillic), "арбуз\nёж\nяблоко")
    }

    func testSortOnlySelectedLines() {
        let text = "z\nc\nb\na\n" as NSString
        // Выделены строки 2–3 («c», «b»).
        let edit = LineCommands.sort(text, NSRange(location: 2, length: 3), .ascending)
        XCTAssertEqual(apply(edit, to: text), "z\nb\nc\na\n")
        XCTAssertEqual(edit?.selection, NSRange(location: 2, length: 4), "выделены те же строки")
    }

    func testRemoveDuplicates() {
        XCTAssertEqual(apply(LineCommands.removeDuplicates(sample, none, caseSensitive: true), to: sample),
                       "  beta  \nalpha\ngamma\nBeta", "alpha ×2 → ×1, остаётся первая")
        let words = "beta\nalpha\nBeta" as NSString
        XCTAssertEqual(apply(LineCommands.removeDuplicates(words, none, caseSensitive: false), to: words), "beta\nalpha",
                       "без учёта регистра beta и Beta — одна строка; у последней нет перевода, как и было")
        let trailing = "a\na\n" as NSString
        XCTAssertEqual(apply(LineCommands.removeDuplicates(trailing, none, caseSensitive: true), to: trailing), "a\n")
        XCTAssertNil(LineCommands.removeDuplicates("a\nb" as NSString, none, caseSensitive: true))
    }

    func testTabsAndSpacesAreReversible() {
        let text = "\tif x\n\t\ty\n" as NSString
        let spaces = apply(LineCommands.tabsToSpaces(text, none, width: 4), to: text)
        XCTAssertEqual(spaces, "    if x\n        y\n")
        XCTAssertEqual(apply(LineCommands.spacesToTabs(spaces as NSString, none, width: 4), to: spaces as NSString), text as String)
        XCTAssertEqual(apply(LineCommands.tabsToSpaces("\ta" as NSString, none, width: 2), to: "\ta" as NSString), "  a")
        XCTAssertNil(LineCommands.tabsToSpaces("no tabs" as NSString, none, width: 4))
    }

    func testBookmarksShiftWithEdits() {
        XCTAssertEqual(EditorTab.shiftBookmarks([2, 5, 9], editLine: 3, lineDelta: 2), [2, 7, 11], "две строки вставлены в строке 3")
        XCTAssertEqual(EditorTab.shiftBookmarks([2, 5, 9], editLine: 3, lineDelta: -3), [2, 3, 6], "удалены строки 4–6: закладка 5 встаёт на 3")
        XCTAssertEqual(EditorTab.shiftBookmarks([2, 5], editLine: 3, lineDelta: 0), [2, 5])
    }
}

@MainActor
final class EditorMultiSelectionTests: XCTestCase {
    private var window: NSWindow!
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        _ = NSApplication.shared
    }

    override func tearDown() {
        window?.contentView = nil
        window?.close()
        defaults.restore()
        super.tearDown()
    }

    private func tab(_ text: String) -> EditorTab {
        let tab = EditorTab(document: EditorDocument(data: Data(text.utf8)))
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 300), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tab.container.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        window.contentView = tab.container
        window.orderBack(nil)
        tab.container.layoutSubtreeIfNeeded()
        return tab
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    /// Прямоугольное выделение (⌥ + перетаскивание даёт по диапазону на строку): ввод заменяет все, один шаг отмены.
    func testTypingIntoColumnSelection() {
        let tab = tab("abc\ndef\nghi\n")
        tab.textView.setSelectedRanges([NSRange(location: 1, length: 1), NSRange(location: 5, length: 1), NSRange(location: 9, length: 1)]
            .map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
        XCTAssertEqual(tab.caret.cursors, 3)
        tab.textView.insertText("XY", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tab.text as String, "aXYc\ndXYf\ngXYi\n")
        XCTAssertEqual(tab.textView.cursorCount, 3, "курсор за каждой вставкой")
        XCTAssertEqual(tab.textView.editTargets.map(\.location), [3, 8, 13])
        settle()   // отдельное нажатие — отдельный шаг отмены (в тесте без событий шаги склеились бы)
        // Удаление назад — во всех строках, но не через перевод строки.
        tab.textView.deleteBackward(nil)
        XCTAssertEqual(tab.text as String, "aXc\ndXf\ngXi\n")
        settle()
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, "aXYc\ndXYf\ngXYi\n", "одна отмена — одно удаление")
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, "abc\ndef\nghi\n", "и ещё одна — весь ввод")
    }

    func testCopyColumnAndCollapseByEscape() {
        let tab = tab("abc\ndef\n")
        tab.textView.setSelectedRanges([NSRange(location: 0, length: 2), NSRange(location: 4, length: 2)].map { NSValue(range: $0) },
                                       affinity: .downstream, stillSelecting: false)
        let board = NSPasteboard(name: NSPasteboard.Name("editor-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        // Свой буфер обмена, не общий: копирование пользователя не трогаем.
        XCTAssertTrue(tab.textView.writeSelection(to: board, types: tab.textView.writablePasteboardTypes))
        XCTAssertEqual(board.string(forType: .string), "ab\nde", "копируется столбец")
        tab.textView.cancelOperation(nil)
        XCTAssertEqual(tab.caret.cursors, 1)
        // Курсоры на нескольких строках: ввод в каждую.
        tab.textView.setCarets([0, 4])
        XCTAssertEqual(tab.caret.cursors, 2)
        tab.textView.insertText("> ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tab.text as String, "> abc\n> def\n")
        // Клик в другое место (обычное выделение) — снова один курсор.
        tab.textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertEqual(tab.caret.cursors, 1)
        XCTAssertTrue(tab.textView.extraCarets.isEmpty)
    }

    func testBookmarksToggleAndCycle() {
        let tab = tab("1\n2\n3\n4\n5\n")
        tab.goTo(line: 2)
        tab.toggleBookmark()
        tab.goTo(line: 4)
        tab.toggleBookmark()
        XCTAssertEqual(tab.bookmarks, [2, 4])
        tab.goTo(line: 5)
        tab.goToBookmark(backwards: false)
        XCTAssertEqual(tab.caret.line, 2, "по кругу")
        tab.goToBookmark(backwards: false)
        XCTAssertEqual(tab.caret.line, 4)
        tab.goToBookmark(backwards: true)
        XCTAssertEqual(tab.caret.line, 2)
        // Строка вставлена выше закладок — они едут вниз.
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        tab.textView.insertText("0\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(tab.bookmarks, [3, 5])
        // Enter в самом начале строки с закладкой — строка уезжает вниз вместе с закладкой (замечание тестировщика).
        tab.textView.setSelectedRange(NSRange(location: tab.lines.starts[2], length: 0))
        tab.textView.insertNewline(nil)
        XCTAssertEqual(tab.bookmarks, [4, 6])
        // Enter в середине строки — закладка остаётся на ней.
        tab.textView.setSelectedRange(NSRange(location: tab.lines.starts[3] + 1, length: 0))
        tab.textView.insertNewline(nil)
        XCTAssertEqual(tab.bookmarks, [4, 7])
        tab.toggleBookmark(line: 4)
        XCTAssertEqual(tab.bookmarks, [7])
        tab.clearBookmarks()
        XCTAssertTrue(tab.bookmarks.isEmpty)
    }
}

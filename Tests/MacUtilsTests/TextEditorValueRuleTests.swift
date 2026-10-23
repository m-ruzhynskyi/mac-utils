import AppKit
import XCTest
@testable import MacUtils
@testable import MUCore

/// Окончательное правило панели «$» (1.7.1): значение — все символы исходника после `$` до конца строки или
/// следующего `$`; RTF не разбирается. После «Убрать значения» — проверка баланса `{}`.
@MainActor
final class TextEditorValueRuleTests: XCTestCase {
    /// Строки 4235–4238 реального .frm пользователя (только коды, без данных) — до и после «Убрать значения».
    static let userLines = [
        #"\v\fs16\cf6\lang1033\langfe1049\cgrid0\langnp1033\insrsid5789151\charrsid4025840 $"#,
        #"\par }{\rtlch\fcs1 \af0\afs16 \ltrch\fcs0 \v\fs16\cf6\lang1033\langfe1049\langnp1033\insrsid5789151\charrsid4025840 $"#,
        #"\par $}{\rtlch\fcs1 \af0\afs16 \ltrch\fcs0 \v\fs16\cf6\lang1033\langfe1049\langnp1033\insrsid5789151"#,
        #"\par }\pard \ltrpar\ql "#,
    ]
    static let userAfter = [userLines[0], userLines[1], #"\par $"#, userLines[3]]

    private func tab(_ text: String, skip: Int? = nil) throws -> (EditorTab, Data) {
        UserDefaults.standard.set(skip != nil, forKey: Pref.editorSkipFirst)
        if let skip { UserDefaults.standard.set(skip, forKey: Pref.editorSkipCount) }
        let data = try XCTUnwrap(TextEncoding.windows1252.encode(text))
        let tab = EditorTab(document: EditorDocument(data: data, url: URL(fileURLWithPath: "/tmp/demo.frm")))
        let count = DollarMarks.scan(text).count
        let deadline = Date().addingTimeInterval(3)
        while tab.dollars.entries.count != count, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(tab.dollars.entries.count, count)
        return (tab, data)
    }

    func testUserExampleByteForByte() throws {
        let defaults = EditorDefaultsSnapshot()
        defer { defaults.restore() }
        for eol in ["\r\n", "\n"] {
            let before = "{\\rtf1\\ansi{" + Self.userLines.joined(separator: eol) + eol + "}"
            let after = "{\\rtf1\\ansi{" + Self.userAfter.joined(separator: eol) + eol + "}"
            let values = DollarMarks.scan(before).map { (before as NSString).substring(with: $0.value) }
            XCTAssertEqual(values, ["", "", "}{\\rtlch\\fcs1 \\af0\\afs16 \\ltrch\\fcs0 \\v\\fs16\\cf6\\lang1033\\langfe1049\\langnp1033\\insrsid5789151"])
            XCTAssertEqual(DollarMarks.unbalancedBraces(in: before as NSString), 0)

            let (tab, data) = try tab(before)
            XCTAssertEqual(tab.dollarRule, .source, ".frm — то же правило, что и у всех")
            XCTAssertEqual(tab.removeHighlightedValues(), 1)
            XCTAssertEqual(try tab.document.data(for: tab.text as String), TextEncoding.windows1252.encode(after), "байт в байт")
            XCTAssertNil(tab.dollars.unbalancedAfterRemoval, "удалены `}` и `{` — баланс сохранился")
            tab.undo.undo()
            XCTAssertEqual(try tab.document.data(for: tab.text as String), data, "одна отмена")
        }
    }

    func testSpacesTwoDollarsAndEndOfFile() {
        let text = "a $first value; x\r\n$one $two\n$last at eof" as NSString
        let marks = DollarMarks.scan(text)
        XCTAssertEqual(marks.map { text.substring(with: $0.value) }, ["first value; x", "one ", "two", "last at eof"])
        XCTAssertEqual(DollarMarks.removingValues(of: marks, in: text as String), "a $\r\n$$\n$")
    }

    func testBraceBalance() {
        XCTAssertEqual(DollarMarks.unbalancedBraces(in: "{a{b}c}" as NSString), 0)
        XCTAssertEqual(DollarMarks.unbalancedBraces(in: "{a" as NSString), 1)
        XCTAssertEqual(DollarMarks.unbalancedBraces(in: "}{" as NSString), 2)
        XCTAssertEqual(DollarMarks.unbalancedBraces(in: #"{\{\}\\}"# as NSString), 0, "экранированные — не скобки")
        XCTAssertEqual(DollarMarks.unbalancedBraces(in: "" as NSString), 0)
        XCTAssertEqual(DollarPanelView.unbalancedPhrase(1), "стала 1 непарная скобка")
        XCTAssertEqual(DollarPanelView.unbalancedPhrase(3), "стало 3 непарные скобки")
        XCTAssertEqual(DollarPanelView.unbalancedPhrase(12), "стало 12 непарных скобок")
    }

    /// Был баланс, после удаления нет — не запрещаем, но предупреждаем; отмена снимает предупреждение.
    func testWarningWhenRemovalBreaksBalance() throws {
        let defaults = EditorDefaultsSnapshot()
        defer { defaults.restore() }
        let text = "{\\rtf1{\\b $v}\r\n}"
        let (tab, data) = try tab(text)
        XCTAssertEqual(tab.removeHighlightedValues(), 1)
        XCTAssertEqual(tab.text as String, "{\\rtf1{\\b $\r\n}")
        XCTAssertEqual(tab.dollars.unbalancedAfterRemoval, 1)
        tab.undo.undo()
        XCTAssertEqual(try tab.document.data(for: tab.text as String), data)
        let deadline = Date().addingTimeInterval(1)
        while tab.dollars.removedCount != nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertNil(tab.dollars.unbalancedAfterRemoval)

        // Баланса не было и до удаления — не наше дело, без предупреждения.
        let (broken, _) = try self.tab("{\\rtf1 $x}}\r\n")
        XCTAssertEqual(broken.removeHighlightedValues(), 1)
        XCTAssertNil(broken.dollars.unbalancedAfterRemoval)
    }

    /// Пропущенные первые N: значения видны в «Пропущено», «Убрать значения» их не трогает, × — убирает.
    func testSkippedShowValuesAndRemoveOnlyExplicitly() throws {
        let defaults = EditorDefaultsSnapshot()
        defer { defaults.restore() }
        let text = "$a 1\n$b 2\n$c 3\n$d 4\n$e 5\n"
        let (tab, _) = try tab(text, skip: 3)
        XCTAssertEqual(tab.dollars.split.skipped.map(\.value), ["a 1", "b 2", "c 3"])
        XCTAssertEqual(tab.removeHighlightedValues(), 2)
        XCTAssertEqual(tab.text as String, "$a 1\n$b 2\n$c 3\n$\n$\n")
        tab.dollars.scanNow(tab.text)
        let second = try XCTUnwrap(tab.dollars.split.skipped.dropFirst().first)
        XCTAssertEqual(tab.removeValues([second]), 1)
        XCTAssertEqual(tab.text as String, "$a 1\n$\n$c 3\n$\n$\n")
    }
}

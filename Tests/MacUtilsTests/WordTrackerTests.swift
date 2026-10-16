import Carbon.HIToolbox
import XCTest
@testable import MacUtils

final class WordTrackerTests: XCTestCase {
    private func type(_ tracker: inout WordTracker, _ text: String, modifiers: WordTracker.Modifiers = []) {
        for character in text {
            tracker.feed(keyCode: kVK_ANSI_A, modifiers: modifiers, characters: String(character))
        }
    }

    func testTypingBuildsWordAndTrailingSpaces() {
        var tracker = WordTracker()
        type(&tracker, "ghbdtn")
        XCTAssertEqual(tracker.word, "ghbdtn")
        XCTAssertEqual(tracker.trailing, "")
        type(&tracker, "  ")
        XCTAssertEqual(tracker.trailing, "  ")
        type(&tracker, "x")
        XCTAssertEqual(tracker.word, "x", "новое слово после пробелов заменяет прежнее")
        XCTAssertEqual(tracker.trailing, "")
    }

    func testSpacesWithoutWordAreIgnored() {
        var tracker = WordTracker()
        type(&tracker, "   ")
        XCTAssertEqual(tracker, WordTracker())
    }

    func testBackspaceRemovesFromTrailingFirstThenWord() {
        var tracker = WordTracker()
        type(&tracker, "abc  ")
        tracker.feed(keyCode: kVK_Delete, modifiers: [], characters: nil)
        XCTAssertEqual(tracker.trailing, " ")
        tracker.feed(keyCode: kVK_Delete, modifiers: [], characters: nil)
        tracker.feed(keyCode: kVK_Delete, modifiers: [], characters: nil)
        XCTAssertEqual(tracker.word, "ab")
        XCTAssertEqual(tracker.trailing, "")
        tracker.feed(keyCode: kVK_Delete, modifiers: [.shift], characters: nil)
        XCTAssertEqual(tracker.word, "a")
    }

    func testBackspaceOnEmptyDoesNothing() {
        var tracker = WordTracker()
        tracker.feed(keyCode: kVK_Delete, modifiers: [], characters: nil)
        XCTAssertEqual(tracker, WordTracker())
    }

    /// Регрессия: ⌥⌫ стирает слово целиком, а трекер хранил его и стирал бы лишние буквы предыдущего текста.
    func testOptionBackspaceResetsWord() {
        var tracker = WordTracker()
        type(&tracker, "привет ")
        tracker.feed(keyCode: kVK_Delete, modifiers: [.option], characters: nil)
        XCTAssertEqual(tracker, WordTracker())
        type(&tracker, "abc")
        tracker.feed(keyCode: kVK_Delete, modifiers: [.option, .shift], characters: nil)
        XCTAssertEqual(tracker.word, "")
    }

    func testOptionArrowsResetWord() {
        for key in [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow] {
            var tracker = WordTracker()
            type(&tracker, "слово")
            tracker.feed(keyCode: key, modifiers: [.option], characters: nil)
            XCTAssertEqual(tracker, WordTracker(), "⌥+стрелка \(key)")
        }
    }

    func testNavigationAndEditingKeysReset() {
        let keys = [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_ForwardDelete, kVK_LeftArrow, kVK_RightArrow,
                    kVK_UpArrow, kVK_DownArrow, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]
        for key in keys {
            for modifiers: WordTracker.Modifiers in [[], [.shift], [.option]] {
                var tracker = WordTracker()
                type(&tracker, "abc ")
                tracker.feed(keyCode: key, modifiers: modifiers, characters: nil)
                XCTAssertEqual(tracker, WordTracker(), "клавиша \(key) с \(modifiers)")
            }
        }
    }

    func testCommandAndControlReset() {
        for modifiers: WordTracker.Modifiers in [[.command], [.control], [.command, .shift], [.command, .option]] {
            var tracker = WordTracker()
            type(&tracker, "abc")
            tracker.feed(keyCode: kVK_LeftArrow, modifiers: modifiers, characters: nil)
            XCTAssertEqual(tracker, WordTracker())
            type(&tracker, "abc")
            tracker.feed(keyCode: kVK_ANSI_V, modifiers: modifiers, characters: "v")
            XCTAssertEqual(tracker, WordTracker())
        }
    }

    func testOptionPlusLetterResetsButOptionWithoutTextLeavesWordUntouched() {
        var tracker = WordTracker()
        type(&tracker, "abc")
        tracker.feed(keyCode: kVK_ANSI_A, modifiers: [.option], characters: nil)
        tracker.feed(keyCode: kVK_ANSI_A, modifiers: [.option], characters: "")
        tracker.feed(keyCode: kVK_ANSI_A, modifiers: [.option], characters: "…")
        XCTAssertEqual(tracker.word, "abc", "⌥ без буквы слово не меняет")
        // «ą» с ⌥ напечатана, но трекер её не учёл бы: слово сбрасывается, а не остаётся короче набранного.
        tracker.feed(keyCode: kVK_ANSI_A, modifiers: [.option], characters: "ą")
        XCTAssertEqual(tracker, WordTracker())
    }

    func testWordIsTruncatedToLast64Characters() {
        var tracker = WordTracker()
        type(&tracker, String(repeating: "a", count: 100) + "b")
        XCTAssertEqual(tracker.word.count, 64)
        XCTAssertTrue(tracker.word.hasSuffix("ab"))
        XCTAssertEqual(WordTracker.maxWordLength, 64)
    }

    func testDigitsPunctuationAndSymbolsBelongToWord() {
        var tracker = WordTracker()
        type(&tracker, "ghbdtn,1+")
        XCTAssertEqual(tracker.word, "ghbdtn,1+")
    }

    func testNonPrintingCharactersResetAndEmptyCharactersAreIgnored() {
        var tracker = WordTracker()
        type(&tracker, "abc")
        tracker.feed(keyCode: kVK_ANSI_A, modifiers: [], characters: "")
        tracker.feed(keyCode: kVK_ANSI_A, modifiers: [], characters: nil)
        XCTAssertEqual(tracker.word, "abc")
        tracker.feed(keyCode: kVK_F1, modifiers: [], characters: "\u{F704}")
        XCTAssertEqual(tracker, WordTracker(), "служебный символ (F-клавиша) сбрасывает слово")
    }

    func testReplaceAndReset() {
        var tracker = WordTracker()
        tracker.replace(word: "привет", trailing: "  ")
        XCTAssertEqual(tracker.word, "привет")
        XCTAssertEqual(tracker.trailing, "  ")
        tracker.reset()
        XCTAssertEqual(tracker, WordTracker())
    }
}

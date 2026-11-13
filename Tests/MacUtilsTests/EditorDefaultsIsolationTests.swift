import XCTest
@testable import MUCore
@testable import MUTextEditor

/// Настройки редактора между тестами и между запусками: снимок возвращает то, что было в начале теста, и знает все ключи,
/// которые тесты редактора и «Документа» меняют.
final class EditorDefaultsIsolationTests: XCTestCase {
    func testSnapshotCoversEveryKeyTestsTouch() {
        for key in [Pref.editorSkipFirst, Pref.editorSkipCount, Pref.editorDollarPanel, Pref.editorViewModes, Pref.docSpelling, Pref.docAutocorrect] {
            XCTAssertTrue(EditorDefaultsSnapshot.keys.contains(key), key)
        }
    }

    func testRestoreReturnsValuesFromTheStartOfTheTest() {
        let outer = EditorDefaultsSnapshot()
        defer { outer.restore() }
        UserDefaults.standard.set(true, forKey: Pref.editorSkipFirst)
        UserDefaults.standard.set(7, forKey: Pref.editorSkipCount)
        let inner = EditorDefaultsSnapshot()
        UserDefaults.standard.set(false, forKey: Pref.editorSkipFirst)
        UserDefaults.standard.removeObject(forKey: Pref.editorSkipCount)
        UserDefaults.standard.set(true, forKey: Pref.docSpelling)
        inner.restore()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Pref.editorSkipFirst))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: Pref.editorSkipCount), 7)
        XCTAssertNil(UserDefaults.standard.object(forKey: Pref.docSpelling), "ключа не было — его и нет")
    }
}

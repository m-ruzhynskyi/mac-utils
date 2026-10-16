import XCTest
@testable import MacUtils

final class FocusSnapshotTests: XCTestCase {
    private func snap(_ pid: pid_t, _ field: Int?) -> FocusSnapshot { FocusSnapshot(pid: pid, field: field) }

    func testSameAppAndFieldPastes() {
        XCTAssertEqual(FocusSnapshot.decide(before: snap(10, 777), now: snap(10, 777)), .paste)
    }

    func testOtherAppGoesToClipboard() {
        guard case .clipboard(let reason) = FocusSnapshot.decide(before: snap(10, 777), now: snap(11, 777)) else { return XCTFail() }
        XCTAssertTrue(reason.contains("другую программу"))
    }

    func testOtherFieldInSameAppGoesToClipboard() {
        guard case .clipboard(let reason) = FocusSnapshot.decide(before: snap(10, 777), now: snap(10, 888)) else { return XCTFail() }
        XCTAssertTrue(reason.contains("другое поле"))
    }

    func testFieldDisappearedGoesToClipboard() {
        XCTAssertNotEqual(FocusSnapshot.decide(before: snap(10, 777), now: snap(10, nil)), .paste)
    }

    func testAppWithoutAccessibleFieldIsComparedByAppOnly() {
        XCTAssertEqual(FocusSnapshot.decide(before: snap(10, nil), now: snap(10, nil)), .paste)
        XCTAssertEqual(FocusSnapshot.decide(before: snap(10, nil), now: snap(10, 5)), .paste, "до запроса поле не определялось — сверяем программу")
        XCTAssertNotEqual(FocusSnapshot.decide(before: snap(10, nil), now: snap(11, nil)), .paste)
    }

    func testUnknownFocusNeverPastes() {
        XCTAssertNotEqual(FocusSnapshot.decide(before: nil, now: snap(10, 1)), .paste)
        XCTAssertNotEqual(FocusSnapshot.decide(before: snap(10, 1), now: nil), .paste)
        XCTAssertNotEqual(FocusSnapshot.decide(before: nil, now: nil), .paste)
    }

    // MARK: MAJOR-1: выделение должно остаться тем же

    private func snap(_ pid: pid_t, _ field: Int?, selection: String?) -> FocusSnapshot {
        FocusSnapshot(pid: pid, field: field, selection: selection)
    }

    func testSameFieldButAnotherSelectionGoesToClipboard() {
        guard case .clipboard(let reason) = FocusSnapshot.decide(before: snap(10, 7, selection: "A"), now: snap(10, 7, selection: "B"), original: "A")
        else { return XCTFail("выделили другой абзац — вставка затёрла бы его") }
        XCTAssertTrue(reason.contains("Выделение изменилось"))
    }

    func testCaretWithoutSelectionGoesToClipboard() {
        XCTAssertNotEqual(FocusSnapshot.decide(before: snap(10, 7, selection: "A"), now: snap(10, 7, selection: ""), original: "A"), .paste,
                          "выделение снято, курсор ушёл — текст не вставляем")
    }

    func testSameFieldAndSameSelectionPastes() {
        XCTAssertEqual(FocusSnapshot.decide(before: snap(10, 7, selection: "A"), now: snap(10, 7, selection: "A"), original: "A"), .paste)
    }

    func testSelectionCompareIsExact() {
        XCTAssertNotEqual(FocusSnapshot.decide(before: snap(10, 7, selection: "A"), now: snap(10, 7, selection: "A "), original: "A"), .paste)
        XCTAssertNotEqual(FocusSnapshot.decide(before: snap(10, 7, selection: "A"), now: snap(10, 7, selection: "a"), original: "A"), .paste)
    }

    func testUnreadableSelectionPastesOnlyIfUserDidNothing() {
        let before = snap(10, nil, selection: nil), now = snap(10, nil, selection: nil)
        XCTAssertEqual(FocusSnapshot.decide(before: before, now: now, original: "A", inputSinceRequest: false), .paste)
        guard case .clipboard(let reason) = FocusSnapshot.decide(before: before, now: now, original: "A", inputSinceRequest: true)
        else { return XCTFail("после клика или набора вставлять вслепую нельзя") }
        XCTAssertTrue(reason.contains("продолжили работу"))
    }

    func testReadableSelectionIgnoresInputFlagWhenItMatches() {
        XCTAssertEqual(FocusSnapshot.decide(before: snap(10, 7, selection: "A"), now: snap(10, 7, selection: "A"), original: "A", inputSinceRequest: true), .paste,
                       "выделение то же — клавиши (например, прокрутка) не мешают")
    }

    func testOtherAppStillWinsOverSelectionMatch() {
        XCTAssertNotEqual(FocusSnapshot.decide(before: snap(10, 7, selection: "A"), now: snap(11, 7, selection: "A"), original: "A"), .paste)
    }

    func testHadInputReturnsFalseForZeroWindow() {
        XCTAssertFalse(FocusSnapshot.hadInput(within: 0))
    }
}

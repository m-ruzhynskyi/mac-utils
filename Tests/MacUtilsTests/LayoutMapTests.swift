import XCTest
@testable import MacUtils

final class LayoutMapTests: XCTestCase {
    func testEnglishToRussian() {
        XCTAssertEqual(LayoutMap.convert("ghbdtn", .toRussian), "привет")
        XCTAssertEqual(LayoutMap.direction(of: "ghbdtn"), .toRussian)
    }

    func testRussianToEnglish() {
        XCTAssertEqual(LayoutMap.direction(of: "руддщ"), .toEnglish)
        XCTAssertEqual(LayoutMap.convert("Руддщ цщкдв", .toEnglish), "Hello world")
    }

    func testCaseAndPunctuation() {
        XCTAssertEqual(LayoutMap.convert("Ghbdtn? rfr ltkf", .toRussian), "Привет, как дела")
        XCTAssertEqual(LayoutMap.convert("[jhjij", .toRussian), "хорошо")
        XCTAssertEqual(LayoutMap.convert(";'`", .toRussian), "жэё")
    }

    func testRoundTrip() {
        let text = "Съешь же ещё этих мягких французских булок"
        let english = LayoutMap.convert(text, .toEnglish)
        XCTAssertEqual(LayoutMap.convert(english, .toRussian), text)
    }

    func testUnmappedCharactersStay() {
        XCTAssertEqual(LayoutMap.convert("123 ghbdtn!", .toRussian), "123 привет!")
    }
}

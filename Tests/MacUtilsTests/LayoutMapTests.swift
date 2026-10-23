import XCTest
@testable import MacUtils
@testable import MULayoutFix

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

/// Украинская раскладка (ЙЦУКЕН uk): і, ї, є, ґ и апостроф.
final class UkrainianLayoutTests: XCTestCase {
    func testEnglishToUkrainian() {
        XCTAssertEqual(LayoutMap.convert("ghbdsn", .toUkrainian), "привіт")
        XCTAssertEqual(LayoutMap.convert("Ckfdf", .toUkrainian), "Слава")
        XCTAssertEqual(LayoutMap.convert("123 ghbdsn!", .toUkrainian), "123 привіт!", "цифры и неизвестные символы остаются")
        XCTAssertEqual(LayoutMap.convert("Ghbdsn? ls", .toUkrainian), "Привіт, ді")
    }

    func testUkrainianOnlyLetters() {
        XCTAssertEqual(LayoutMap.convert("]", .toUkrainian), "ї")
        XCTAssertEqual(LayoutMap.convert("}", .toUkrainian), "Ї")
        XCTAssertEqual(LayoutMap.convert("'", .toUkrainian), "є")
        XCTAssertEqual(LayoutMap.convert("\"", .toUkrainian), "Є")
        XCTAssertEqual(LayoutMap.convert("s", .toUkrainian), "і")
        XCTAssertEqual(LayoutMap.convert("S", .toUkrainian), "І")
        XCTAssertEqual(LayoutMap.convert("\\", .toUkrainian), "ґ")
        XCTAssertEqual(LayoutMap.convert("|", .toUkrainian), "Ґ")
        XCTAssertEqual(LayoutMap.convert("`", .toUkrainian), "ʼ")
    }

    func testOnlyUkrainianKeysDifferFromRussian() {
        XCTAssertEqual(LayoutMap.convert("s", .toRussian), "ы")
        XCTAssertEqual(LayoutMap.convert("]", .toRussian), "ъ")
        XCTAssertEqual(LayoutMap.convert("'", .toRussian), "э")
        XCTAssertEqual(LayoutMap.convert("\\", .toRussian), "\\", "в русской раскладке ґ нет")
        // Остальные буквенные клавиши обеих раскладок совпадают.
        for key in "qwertyuiop[adfghjkl;zxcvbnm,./" {
            XCTAssertEqual(LayoutMap.convert(String(key), .toUkrainian), LayoutMap.convert(String(key), .toRussian), "клавиша \(key)")
        }
    }

    func testUkrainianToEnglish() {
        XCTAssertEqual(LayoutMap.convert("привіт", .toEnglish), "ghbdsn")
        XCTAssertEqual(LayoutMap.convert("їжак ґанок єдність", .toEnglish), "];fr \\fyjr 'lyscnm")
        XCTAssertEqual(LayoutMap.convert("Їжак Є Ґ І", .toEnglish), "};fr \" | S")
        XCTAssertEqual(LayoutMap.convert("ʼ", .toEnglish), "`")
    }

    func testRussianStillConvertsToEnglishAndMixedAlphabets() {
        XCTAssertEqual(LayoutMap.convert("руддщ", .toEnglish), "hello")
        // Один текст с русскими и украинскими буквами тоже переводится на английскую целиком.
        XCTAssertEqual(LayoutMap.convert("ыі", .toEnglish), "ss")
    }

    func testRoundTripUkrainian() {
        let text = "Щасливої дороги, їжачку! Ґрунт, єдність, Київ; Львів"
        let english = LayoutMap.convert(text, .toEnglish)
        XCTAssertEqual(LayoutMap.convert(english, .toUkrainian), text)
    }

    func testDirectionUsesChosenCyrillicLayoutForLatin() {
        XCTAssertEqual(LayoutMap.direction(of: "ghbdsn"), .toRussian, "по умолчанию русская")
        XCTAssertEqual(LayoutMap.direction(of: "ghbdsn", cyrillic: .ukrainian), .toUkrainian)
        XCTAssertEqual(LayoutMap.direction(of: "привіт", cyrillic: .ukrainian), .toEnglish)
        XCTAssertEqual(LayoutMap.direction(of: "привіт"), .toEnglish)
        XCTAssertEqual(LayoutMap.direction(of: "123", cyrillic: .ukrainian), .toUkrainian)
    }

    func testCyrillicLayoutSetting() {
        XCTAssertEqual(LayoutMap.cyrillicLayout(setting: "russian", enabledLanguages: ["uk"]), .russian)
        XCTAssertEqual(LayoutMap.cyrillicLayout(setting: "ukrainian", enabledLanguages: ["ru", "en"]), .ukrainian)
        XCTAssertEqual(LayoutMap.cyrillicLayout(setting: "auto", enabledLanguages: ["en", "uk"]), .ukrainian)
        XCTAssertEqual(LayoutMap.cyrillicLayout(setting: nil, enabledLanguages: ["en", "uk", "ru"]), .russian, "обе включены — русская, как раньше")
        XCTAssertEqual(LayoutMap.cyrillicLayout(setting: "auto", enabledLanguages: ["en"]), .russian)
        XCTAssertEqual(LayoutMap.cyrillicLayout(setting: "мусор", enabledLanguages: []), .russian)
    }

    func testInputLanguage() {
        XCTAssertEqual(LayoutMap.inputLanguage(for: .toRussian), "ru")
        XCTAssertEqual(LayoutMap.inputLanguage(for: .toUkrainian), "uk")
        XCTAssertEqual(LayoutMap.inputLanguage(for: .toEnglish), "en")
    }
}

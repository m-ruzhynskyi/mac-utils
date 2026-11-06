import XCTest
@testable import MUCore
@testable import MUTextEditor

/// Словари ABBYY Lingvo (`.dsl`) открываются читаемо и без правок сохраняются теми же байтами: UTF-16 LE с BOM (обычно),
/// UTF-8 и Windows-1251 (без BOM — по языку заголовка). Файлы синтетические.
final class DSLEncodingTests: XCTestCase {
    private static let text = "#NAME \"Демо-словарь\"\r\n#INDEX_LANGUAGE \"Russian\"\r\n#CONTENTS_LANGUAGE \"English\"\r\n\r\n"
        + "словарь\r\n\t[m1][trn]dictionary[/trn][/m1]\r\nпривет\r\n\t[m1][trn]hello[/trn][/m1]\r\n"
    private static let url = URL(fileURLWithPath: "/tmp/demo.dsl")

    private func roundTrip(_ data: Data, expect encoding: TextEncoding, file: StaticString = #filePath, line: UInt = #line) throws {
        let document = EditorDocument(data: data, url: Self.url)
        XCTAssertEqual(document.encoding, encoding, file: file, line: line)
        XCTAssertEqual(document.decodedText, Self.text, "читается как есть", file: file, line: line)
        XCTAssertFalse(document.lossyDecode, file: file, line: line)
        XCTAssertEqual(try document.data(for: document.decodedText), data, "без правок — те же байты", file: file, line: line)
    }

    func testUTF16LittleEndianWithBOM() throws {
        var data = Data([0xFF, 0xFE])
        data.append(Self.text.data(using: .utf16LittleEndian)!)
        try roundTrip(data, expect: .utf16LE)
    }

    func testUTF8() throws {
        try roundTrip(Data(Self.text.utf8), expect: .utf8)
        var bom = Data([0xEF, 0xBB, 0xBF])
        bom.append(Data(Self.text.utf8))
        try roundTrip(bom, expect: .utf8BOM)
    }

    func testWindows1251ByHeaderLanguage() throws {
        let data = try XCTUnwrap(TextEncoding.windows1251.encode(Self.text))
        XCTAssertEqual(TextEncoding.detect(data).encoding, .windows1252, "без подсказки — как раньше")
        XCTAssertEqual(TextEncoding.detectDSL(data).reason, .dslLanguage("Russian"))
        try roundTrip(data, expect: .windows1251)
        // Тот же файл не .dsl — прежнее определение (правило только для словарей).
        XCTAssertEqual(EditorDocument(data: data, url: URL(fileURLWithPath: "/tmp/demo.txt")).encoding, .windows1252)
    }

    func testHeaderLanguages() {
        XCTAssertEqual(TextEncoding.dslLanguages(Data(Self.text.utf8)), ["Russian", "English"])
        let western = "#NAME \"Demo\"\r\n#INDEX_LANGUAGE \"German\"\r\n#CONTENTS_LANGUAGE \"English\"\r\nStra\u{DF}e\r\n"
        let data = TextEncoding.windows1252.encode(western)!
        XCTAssertEqual(TextEncoding.detectDSL(data).encoding, .windows1252, "немецкий словарь — Windows-1252, как раньше")
        XCTAssertEqual(EditorDocument(data: data, url: Self.url).decodedText, western)
    }

    /// `.dsl` — простой текст: открывается в «Коде», не в плеере.
    func testOpensAsPlainTextInCode() {
        let document = EditorDocument(data: Data(Self.text.utf8), url: Self.url)
        XCTAssertEqual(document.language, .plain)
    }
}

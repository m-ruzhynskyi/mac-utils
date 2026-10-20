import CryptoKit
import XCTest
@testable import MacUtils

/// Приёмка ядра редактора по независимым данным тестировщика: `Tests/Fixtures/TextEditor/` (17 .frm и `expected.json`).
/// Каждая фикстура проходит через то же, что делает редактор: автоопределение кодировки → текст → знаки `$` →
/// «Убрать значения» → байты в той же кодировке.
final class TextEditorAcceptanceTests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/TextEditor", isDirectory: true)

    private struct Expected: Decodable {
        let files: [String: Fixture]
        let skip_default_n: Int
    }

    private struct Fixture: Decodable {
        let bytes_sha256: String
        let size_bytes: Int
        let encoding: String
        let eol: String
        let line_count: Int
        let text_length: Int
        let dollar_count: Int
        let occurrences: [Occurrence]
        let highlighted_skip3: [Int]
        let highlighted_all: [Int]
        let dimmed_skip3: [Int]
        let strip_skip3_text: String
        let strip_all_text: String
        let strip_skip3_bytes_sha256: String
        let strip_all_bytes_sha256: String
        let rescan_after_strip_skip3: [String]
        let rescan_after_strip_all: [String]
        let strip_single_text: [String: String]?
    }

    private struct Occurrence: Decodable {
        let index: Int
        let offset: Int
        let line: Int
        let column: Int
        let value: String
        let skipped_by_default: Bool
    }

    private func load() throws -> Expected {
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("expected.json"))
        return try JSONDecoder().decode(Expected.self, from: data)
    }

    private static func encoding(_ name: String) -> TextEncoding? {
        switch name {
        case "windows-1252": return .windows1252
        case "windows-1251": return .windows1251
        case "utf-8": return .utf8
        case "utf-8-bom": return .utf8BOM
        default: return nil
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func lineEnding(_ text: String) -> String {
        let counts = LineEnding.count(in: text)
        if counts.isMixed {
            return "mixed:" + [("CRLF", counts.crlf), ("LF", counts.lf), ("CR", counts.cr)].filter { $0.1 > 0 }.map(\.0).joined(separator: "+")
        }
        return LineEnding.detect(text)?.title ?? "none"
    }

    func testAllFixturesListed() throws {
        let expected = try load()
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path).filter { $0.hasSuffix(".frm") }
        XCTAssertEqual(Set(onDisk), Set(expected.files.keys), "каждая .frm описана в expected.json")
        XCTAssertEqual(expected.files.count, 17)
        XCTAssertEqual(expected.skip_default_n, 3)
    }

    func testFixturesThroughCore() throws {
        let expected = try load()
        let skip = expected.skip_default_n
        for (name, fixture) in expected.files.sorted(by: { $0.key < $1.key }) {
            let bytes = try Data(contentsOf: Self.folder.appendingPathComponent(name))
            XCTAssertEqual(Self.sha256(bytes), fixture.bytes_sha256, "\(name): фикстура не изменена")
            XCTAssertEqual(bytes.count, fixture.size_bytes, name)

            // Кодировка и текст.
            let detected = TextEncoding.detect(bytes).encoding
            XCTAssertEqual(detected, Self.encoding(fixture.encoding), "\(name): кодировка")
            let text = try XCTUnwrap(detected.decode(bytes), name)
            let string = text as NSString
            XCTAssertEqual(string.length, fixture.text_length, "\(name): длина текста")
            XCTAssertEqual(detected.encode(text), bytes, "\(name): открыть → сохранить без правок — те же байты")
            XCTAssertEqual(Self.lineEnding(text), fixture.eol, "\(name): переводы строк")
            let lines = LineIndex(string)
            XCTAssertEqual(lines.lineCount, fixture.line_count, "\(name): строк")

            // Знаки `$`.
            let marks = DollarMarks.scan(string)
            XCTAssertEqual(marks.count, fixture.dollar_count, "\(name): число `$`")
            XCTAssertEqual(marks.count, fixture.occurrences.count, name)
            for (mark, occurrence) in zip(marks, fixture.occurrences) {
                XCTAssertEqual(mark.dollar, occurrence.offset, "\(name) #\(occurrence.index): смещение")
                XCTAssertEqual(string.substring(with: mark.value), occurrence.value, "\(name) #\(occurrence.index): значение")
                let position = lines.position(at: mark.dollar)
                XCTAssertEqual(position.line, occurrence.line, "\(name) #\(occurrence.index): строка")
                XCTAssertEqual(position.column, occurrence.column, "\(name) #\(occurrence.index): столбец")
                XCTAssertEqual(occurrence.index < skip, occurrence.skipped_by_default, name)
            }

            // Пропуск первых N и подсветка.
            let on = DollarMarks.split(marks, skipFirst: skip)
            let off = DollarMarks.split(marks, skipFirst: nil)
            XCTAssertEqual(on.active.indices.map { $0 }, fixture.highlighted_skip3, "\(name): подсвечено при пропуске \(skip)")
            XCTAssertEqual(on.skipped.indices.map { $0 }, fixture.dimmed_skip3, "\(name): приглушено при пропуске \(skip)")
            XCTAssertEqual(off.active.indices.map { $0 }, fixture.highlighted_all, "\(name): подсвечено без пропуска")
            XCTAssertTrue(off.skipped.isEmpty, name)

            // «Убрать значения» в обоих режимах: текст, байты, повторный скан.
            for (mode, active, expectedText, expectedSHA, rescan) in [
                ("пропуск \(skip)", on.active, fixture.strip_skip3_text, fixture.strip_skip3_bytes_sha256, fixture.rescan_after_strip_skip3),
                ("без пропуска", off.active, fixture.strip_all_text, fixture.strip_all_bytes_sha256, fixture.rescan_after_strip_all),
            ] {
                let stripped = DollarMarks.removingValues(of: active, in: text)
                XCTAssertEqual(stripped, expectedText, "\(name): «Убрать значения», \(mode)")
                let saved = try XCTUnwrap(detected.encode(stripped), name)
                XCTAssertEqual(Self.sha256(saved), expectedSHA, "\(name): байты после «Убрать значения», \(mode)")
                let again = DollarMarks.scan(stripped)
                XCTAssertEqual(again.map { (stripped as NSString).substring(with: $0.value) }, rescan, "\(name): повторный скан, \(mode)")
                XCTAssertEqual(DollarMarks.removingValues(of: DollarMarks.split(again, skipFirst: mode == "без пропуска" ? nil : skip).active,
                                                          in: stripped), stripped, "\(name): повторное «Убрать значения» ничего не меняет")
            }

            // «Убрать значение» у одного вхождения — и у приглушённых тоже.
            for (key, expectedText) in fixture.strip_single_text ?? [:] {
                let index = try XCTUnwrap(Int(key), name)
                XCTAssertEqual(DollarMarks.removingValues(of: [marks[index]], in: text), expectedText, "\(name): убрать у #\(index)")
            }
        }
    }
}

import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio

/// Ядро текстового редактора: правило «$ и значение», кодировки без потери байтов, переводы строк.
final class DollarMarksTests: XCTestCase {
    private func values(_ text: String) -> [String] {
        let string = text as NSString
        return DollarMarks.scan(text).map { string.substring(with: $0.value) }
    }

    /// Значение — всё после `$` до конца строки исходника, следующего `$` или конца текста; RTF не разбирается.
    func testValueRunsToEndOfLine() {
        XCTAssertEqual(values("a $name b"), ["name b"], "пробелы входят")
        XCTAssertEqual(values("$a\\par }{\\rtlch x;y'1"), ["a\\par }{\\rtlch x;y'1"], "коды, скобки, ; и ' входят")
        XCTAssertEqual(values("$x\ty"), ["x\ty"], "табуляция входит")
        XCTAssertEqual(values("$x\r\ny"), ["x"], "CRLF не входит")
        XCTAssertEqual(values("$x\ny"), ["x"])
        XCTAssertEqual(values("$x\ry"), ["x"])
        XCTAssertEqual(values("$a b $c d\n"), ["a b ", "c d"], "два $ на одной строке")
        XCTAssertEqual(values("end $last value"), ["last value"], "до конца текста без перевода строки")
    }

    func testEmptyValues() {
        XCTAssertEqual(values("$"), [""])
        XCTAssertEqual(values("$\r\nx"), [""])
        XCTAssertEqual(values("$\nx"), [""])
        XCTAssertEqual(values("$$x"), ["", "x"], "второй `$` — свой знак со своим значением")
        XCTAssertEqual(values("$a$b$"), ["a", "b", ""])
    }

    func testNonASCIIValuesAndUTF16Offsets() {
        XCTAssertEqual(values("$Привет мир\n"), ["Привет мир"])
        let text = "é $a😀b\nc"
        let marks = DollarMarks.scan(text)
        XCTAssertEqual(marks, [DollarMark(dollar: 2, value: NSRange(location: 3, length: 4))], "😀 — два знака UTF-16")
        XCTAssertEqual((text as NSString).substring(with: marks[0].whole), "$a😀b")
        XCTAssertTrue(DollarMarks.scan("").isEmpty)
        XCTAssertTrue(DollarMarks.scan("нет знаков").isEmpty)
    }

    func testSkipFirstN() {
        let marks = DollarMarks.scan("$a$b$c$d$e")
        let on = DollarMarks.split(marks, skipFirst: 3)
        XCTAssertEqual(on.skipped.map(\.dollar), [0, 2, 4])
        XCTAssertEqual(on.active.map(\.dollar), [6, 8])
        let off = DollarMarks.split(marks, skipFirst: nil)
        XCTAssertTrue(off.skipped.isEmpty)
        XCTAssertEqual(off.active.count, 5)
        XCTAssertEqual(DollarMarks.split(marks, skipFirst: 9).active.count, 0)
        XCTAssertEqual(DollarMarks.split(marks, skipFirst: -1).active.count, 5)
        XCTAssertEqual(DollarMarks.split([], skipFirst: 3).active.count, 0)
    }

    func testRemoveValuesKeepsDollarsAndSkipped() {
        let text = "{\\rtf1 $keep1\r\n$keep 2\\par\r\n$x1 $$y2;\r\n$z\n$}"
        let marks = DollarMarks.scan(text)
        XCTAssertEqual(marks.count, 7)
        let active = DollarMarks.split(marks, skipFirst: 2).active
        XCTAssertEqual(DollarMarks.removingValues(of: active, in: text), "{\\rtf1 $keep1\r\n$keep 2\\par\r\n$$$\r\n$\n$")
        XCTAssertEqual(DollarMarks.removingValues(of: marks, in: text), "{\\rtf1 $\r\n$\r\n$$$\r\n$\n$")
        // Одного выбранного.
        XCTAssertEqual(DollarMarks.removingValues(of: [marks[4]], in: text), "{\\rtf1 $keep1\r\n$keep 2\\par\r\n$x1 $$\r\n$z\n$}")
        // Диапазоны идут с конца и без пустых — так их можно удалить одной правкой (один шаг отмены).
        let ranges = DollarMarks.valueRanges(active)
        XCTAssertEqual(ranges.map(\.location), ranges.map(\.location).sorted(by: >))
        XCTAssertFalse(ranges.contains { $0.length == 0 })
    }

    func testLineIndex() {
        let index = LineIndex("a\r\nb\nc\rd")
        XCTAssertEqual(index.lineCount, 4, "CRLF — один перевод строки")
        XCTAssertEqual(index.line(at: 0), 1)
        XCTAssertEqual(index.line(at: 3), 2)
        XCTAssertEqual(index.position(at: 5).line, 3)
        XCTAssertEqual(index.position(at: 7).line, 4)
        XCTAssertEqual(index.position(at: 7).column, 1)
        XCTAssertEqual(LineIndex("").lineCount, 1)
        XCTAssertEqual(LineIndex("x\n").lineCount, 2)
    }

    /// Поиск `$` в 10 МБ — быстрее 300 мс (в отладочной сборке без оптимизации — с запасом).
    func testScanTenMegabytesIsFast() {
        let chunk = String(repeating: "\\f0\\fs20 $value_123 text {\\b bold}\\par ", count: 64)
        let text = String(repeating: chunk + "\r\n", count: 10_000_000 / (chunk.utf16.count + 2)) as NSString
        let start = Date()
        let marks = DollarMarks.scan(text)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(marks.count, 200_000)
        #if DEBUG
        XCTAssertLessThan(elapsed, 3)
        #else
        XCTAssertLessThan(elapsed, 0.3)
        #endif
        print("DollarMarks.scan: \(text.length) UTF-16, \(marks.count) знаков — \(Int(elapsed * 1000)) мс")
    }
}

final class TextEncodingTests: XCTestCase {
    private let allBytes = Data((0...255).map { UInt8($0) })

    func testEverySingleByteEncodingRoundTripsAllBytes() throws {
        for encoding in TextEncoding.allCases where encoding.group != .unicode {
            let table = try XCTUnwrap(SingleByteTable.table(for: encoding), encoding.title)
            XCTAssertEqual(Set(table.decodeTable).count, 256, "\(encoding.title): у каждого байта свой символ")
            let text = try XCTUnwrap(encoding.decode(allBytes), encoding.title)
            XCTAssertEqual(encoding.encode(text), allBytes, encoding.title)
        }
    }

    func testKnownCharacters() {
        XCTAssertEqual(TextEncoding.windows1252.decode(Data([0x80, 0xE9, 0x81])), "€é\u{81}")
        XCTAssertEqual(TextEncoding.windows1251.decode(Data([0xCF, 0xF0, 0xE8])), "При")
        XCTAssertEqual(TextEncoding.koi8R.decode(Data([0xF0, 0xD2, 0xC9])), "При")
        XCTAssertEqual(TextEncoding.cp866.decode(Data([0x8F, 0xE0, 0xA8])), "При")
        XCTAssertEqual(TextEncoding.iso8859_5.decode(Data([0xBF, 0xE0, 0xD8])), "При")
        XCTAssertEqual(TextEncoding.macRoman.decode(Data([0x8E])), "é")
        XCTAssertEqual(TextEncoding.windows1250.decode(Data([0x8A])), "Š")
    }

    func testUnrepresentableCharacters() {
        XCTAssertNil(TextEncoding.windows1252.encode("Привет"))
        XCTAssertEqual(TextEncoding.windows1252.unrepresentable(in: "aПрП"), ["П", "р"])
        XCTAssertNotNil(TextEncoding.windows1251.encode("Привет"))
        XCTAssertTrue(TextEncoding.utf8.unrepresentable(in: "Привет").isEmpty)
    }

    /// Открыть → сохранить без правок → те же байты: cp1252 с 0x80–0xFF и CRLF.
    func testCP1252FileWithHighBytesAndCRLFIsByteIdentical() throws {
        var data = Data("{\\rtf1\\ansi\\deff0 $name\\par\r\n".utf8)
        data.append(Data((0x80...0xFF).map { UInt8($0) }))
        data.append(Data("\r\n$total\\par\r\n}".utf8))
        let detected = TextEncoding.detect(data)
        XCTAssertEqual(detected.encoding, .windows1252)
        XCTAssertEqual(detected.reason, .fallback)
        let text = try XCTUnwrap(detected.encoding.decode(data))
        XCTAssertEqual(LineEnding.detect(text), .crlf)
        XCTAssertEqual(detected.encoding.encode(text), data)
    }

    func testRTFCodePageWins() throws {
        var data = Data("{\\rtf1\\adeflang1025\\ansi\\ansicpg1251\\uc1 ".utf8)
        data.append(Data([0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]))
        data.append(Data(" $name\\par}\r\n".utf8))
        let detected = TextEncoding.detect(data)
        XCTAssertEqual(detected.encoding, .windows1251)
        XCTAssertEqual(detected.reason, .rtfCodePage(1251))
        let text = try XCTUnwrap(detected.encoding.decode(data))
        XCTAssertTrue(text.contains("Привет"))
        XCTAssertEqual(detected.encoding.encode(text), data)
        // Чистый ASCII с кодовой страницей — это кодовая страница (RTF пишет в ней), без неё — UTF-8.
        XCTAssertEqual(TextEncoding.detect(Data("{\\rtf1\\ansi\\ansicpg1252 $a}".utf8)).encoding, .windows1252)
        XCTAssertEqual(TextEncoding.detect(Data("plain $a".utf8)).encoding, .utf8)
        XCTAssertEqual(TextEncoding.rtfCodePage(Data("{\\rtf1\\ansicpg866}".utf8)), 866)
        XCTAssertNil(TextEncoding.rtfCodePage(Data("{\\rtf1\\ansicpg}".utf8)))
        // Неизвестная страница — по умолчанию.
        var unknown = Data("{\\rtf1\\ansicpg932 ".utf8)
        unknown.append(0x82)
        XCTAssertEqual(TextEncoding.detect(unknown).encoding, .windows1252)
    }

    func testUTF8WithCRLFIsByteIdentical() throws {
        let data = Data("Строка 1 $значение\r\nLine 2 — €\r\n😀\r\n".utf8)
        let detected = TextEncoding.detect(data)
        XCTAssertEqual(detected.encoding, .utf8)
        XCTAssertEqual(detected.reason, .validUTF8)
        let text = try XCTUnwrap(detected.encoding.decode(data))
        XCTAssertEqual(detected.encoding.encode(text), data)
        XCTAssertNil(TextEncoding.utf8.decode(Data([0x41, 0xC3, 0x28])), "неверный UTF-8 — не UTF-8")
        XCTAssertEqual(TextEncoding.detect(Data([0x41, 0xC3, 0x28])).encoding, .windows1252)
    }

    func testBOMs() throws {
        let utf8 = TextEncoding.bomUTF8 + Data("$a\r\n".utf8)
        XCTAssertEqual(TextEncoding.detect(utf8).encoding, .utf8BOM)
        let text = try XCTUnwrap(TextEncoding.utf8BOM.decode(utf8))
        XCTAssertEqual(text, "$a\r\n")
        XCTAssertEqual(TextEncoding.utf8BOM.encode(text), utf8)
        XCTAssertEqual(TextEncoding.utf8.decode(utf8), "\u{FEFF}$a\r\n", "UTF-8 без BOM — BOM остаётся символом")

        for encoding in [TextEncoding.utf16LE, .utf16BE] {
            let data = try XCTUnwrap(encoding.encode("$Привет 😀\r\n"))
            XCTAssertEqual(TextEncoding.detect(data).encoding, encoding)
            let decoded = try XCTUnwrap(encoding.decode(data))
            XCTAssertEqual(decoded, "$Привет 😀\r\n")
            XCTAssertEqual(encoding.encode(decoded), data)
        }
        XCTAssertNil(TextEncoding.utf16LE.decode(Data([0xFF, 0xFE, 0x41])), "нечётная длина")
        XCTAssertNil(TextEncoding.utf16LE.decode(Data([0xFF, 0xFE, 0x00, 0xD8])), "одинокий суррогат")
    }

    func testReopenInAnotherEncodingReinterpretsBytes() throws {
        let data = Data([0xCF, 0xF0, 0xE8])
        XCTAssertEqual(TextEncoding.windows1252.decode(data), "Ïðè")
        let text = try XCTUnwrap(TextEncoding.windows1251.decode(data))
        XCTAssertEqual(text, "При")
        // «Преобразовать в…» — те же символы другими байтами.
        XCTAssertEqual(TextEncoding.koi8R.encode(text), Data([0xF0, 0xD2, 0xC9]))
        XCTAssertEqual(TextEncoding.utf8.encode(text), Data("При".utf8))
    }

    func testCodePages() {
        XCTAssertEqual(TextEncoding(codePage: 1251), .windows1251)
        XCTAssertEqual(TextEncoding(codePage: 65001), .utf8)
        XCTAssertEqual(TextEncoding(codePage: 10000), .macRoman)
        XCTAssertNil(TextEncoding(codePage: 932))
        XCTAssertEqual(Set(TextEncoding.allCases.map(\.codePage)).count, TextEncoding.allCases.count - 1, "UTF-8 и UTF-8 с BOM — 65001")
    }
}

final class LineEndingTests: XCTestCase {
    func testDetectAndCount() {
        XCTAssertEqual(LineEnding.detect("a\r\nb\r\nc\n"), .crlf)
        XCTAssertEqual(LineEnding.detect("a\nb"), .lf)
        XCTAssertEqual(LineEnding.detect("a\rb"), .cr)
        XCTAssertNil(LineEnding.detect("abc"))
        XCTAssertEqual(LineEnding.count(in: "a\r\nb\nc\r\r\n"), LineEnding.Counts(crlf: 2, lf: 1, cr: 1))
        XCTAssertTrue(LineEnding.count(in: "a\r\nb\n").isMixed)
        XCTAssertFalse(LineEnding.count(in: "a\r\nb\r\n").isMixed)
    }

    func testConvert() {
        let mixed = "a\r\nb\nc\rd"
        XCTAssertEqual(LineEnding.convert(mixed, to: .lf), "a\nb\nc\nd")
        XCTAssertEqual(LineEnding.convert(mixed, to: .crlf), "a\r\nb\r\nc\r\nd")
        XCTAssertEqual(LineEnding.convert(mixed, to: .cr), "a\rb\rc\rd")
        XCTAssertEqual(LineEnding.convert("\r\r\n\n", to: .lf), "\n\n\n")
    }
}

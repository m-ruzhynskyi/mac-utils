import XCTest
@testable import MacUtils

/// Замеры редактора на файле 10 МБ (как `Tests/Fixtures/TextEditor/generate-big.sh`; файл создаётся во временной папке).
/// Числа печатаются в лог; тест падает, если порог превышен больше чем в полтора раза (запас под CI и отладочную сборку).
final class TextEditorPerformanceTests: XCTestCase {
    /// Тот же файл, что делает `generate-big.sh`: длинные строки по 8 знаков `$vNNNNN`, cp1252/ASCII, CRLF.
    /// `paragraphs` — строк `\pard …`; всего строк в тексте на 3 больше (заголовок, `}` и пустая после последнего CRLF).
    static func bigFile(target: Int = 10_485_760) -> (data: Data, dollars: Int, paragraphs: Int) {
        var out = [UInt8]()
        out.reserveCapacity(target + 30_000)
        let header = "{\\rtf1\\adeflang1025\\ansi\\ansicpg1252\\uc1\\deff0{\\fonttbl{\\f0\\fswiss\\fcharset0 Arial;}}{\\colortbl;\\red0\\green0\\blue0;}\\viewkind1\\f0\\fs20\r\n"
        out += Array(header.utf8)
        var segment = ""
        while segment.utf8.count < 2500 { segment += "lorem ipsum dolor sit amet " }
        let seg = Array(segment.utf8.prefix(2500))
        var n = 0, lines = 0
        while out.count < target {
            out += Array("\\pard ".utf8)
            for _ in 0..<8 {
                n += 1
                out += seg
                out += Array(String(format: "$v%05d ", n).utf8)
            }
            out += Array("\\par\r\n".utf8)
            lines += 1
        }
        out += Array("}\r\n".utf8)
        return (Data(out), n, lines)
    }

    /// Порог с запасом: ×1,5 в оптимизированной сборке (как у приложения), ×10 в отладочной — там циклы по байтам
    /// медленнее в разы, и тест ловит только грубый регресс. Замер для отчёта:
    ///   swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter TextEditorPerformance
    static func limit(_ milliseconds: Double) -> Double {
        milliseconds * (_isDebugAssertConfiguration() ? 10 : 1.5)
    }

    static var build: String { _isDebugAssertConfiguration() ? "debug" : "release" }

    static func measure(_ block: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testDecodeAndScan10MB() throws {
        let big = Self.bigFile()
        var text = ""
        let decode = Self.measure {
            let encoding = TextEncoding.detect(big.data).encoding
            text = encoding.decode(big.data) ?? ""
        }
        XCTAssertEqual(TextEncoding.detect(big.data).encoding, .windows1252)
        let string = text as NSString
        var marks: [DollarMark] = []
        let scan = Self.measure { marks = DollarMarks.scan(string) }
        var lines = LineIndex("")
        let index = Self.measure { lines = LineIndex(string) }
        XCTAssertEqual(marks.count, big.dollars)
        XCTAssertEqual(lines.lineCount, big.paragraphs + 3)
        print(String(format: "[editor-perf] %@ 10 МБ: декодирование %.0f мс, скан $ %.0f мс (%d знаков), индекс строк %.0f мс",
                     Self.build, decode, scan, marks.count, index))
        XCTAssertLessThan(decode + scan, Self.limit(300), "декодирование + скан `$` < 300 мс")
    }
}

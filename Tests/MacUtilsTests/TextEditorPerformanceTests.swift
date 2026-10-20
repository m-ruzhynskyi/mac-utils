import AppKit
import XCTest
@testable import MacUtils

/// Замеры редактора на файле 10 МБ (как `Tests/Fixtures/TextEditor/generate-big.sh`; файл создаётся во временной папке).
/// Числа печатаются в лог; тест падает, если порог превышен больше чем в полтора раза (запас под CI и отладочную сборку).
final class TextEditorPerformanceTests: XCTestCase {
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
    }

    override func tearDown() {
        defaults.restore()
        super.tearDown()
    }

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

    /// Порог с запасом ×1,5 — только в оптимизированной сборке (как у приложения). В отладочной время только печатается:
    /// под нагрузкой (параллельные сборки, CI) оно скачет в разы, и тест падал бы без регресса. Замер для отчёта:
    ///   swift test -c release -Xswiftc -enable-testing -Xswiftc -DDEBUG --filter TextEditorPerformance
    static func limit(_ milliseconds: Double) -> Double {
        _isDebugAssertConfiguration() ? .infinity : milliseconds * 1.5
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

    /// Открытие 10 МБ в редакторе (TextKit 1) до первого экрана, ввод символа в середину, «Убрать значения» и отмена.
    @MainActor
    func testEditorOpenTypeRemove10MB() throws {
        _ = NSApplication.shared
        DSFonts.registerAll()
        UserDefaults.standard.set(true, forKey: Pref.editorSkipFirst)
        UserDefaults.standard.set(3, forKey: Pref.editorSkipCount)
        let big = Self.bigFile()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.orderBack(nil)
        var tab: EditorTab!
        let open = Self.measure {
            let document = EditorDocument(data: big.data, url: URL(fileURLWithPath: "/tmp/big-10mb.frm"))
            tab = EditorTab(document: document)
            tab.container.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
            window.contentView = tab.container
            tab.container.layoutSubtreeIfNeeded()
            tab.applyHighlights()
            tab.container.displayIfNeeded()
        }
        XCTAssertEqual(tab.storage.length, big.data.count)

        // Скан `$` идёт в фоне — ждём список (под нагрузкой полного прогона — дольше).
        let deadline = Date().addingTimeInterval(30)
        while tab.dollars.entries.count != big.dollars, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(tab.dollars.entries.count, big.dollars)

        // Ввод: символ в середину текста, раскладка и отрисовка видимого, подсветка.
        let middle = tab.storage.length / 2
        tab.reveal(NSRange(location: middle, length: 0))
        tab.container.displayIfNeeded()
        var samples: [Double] = []
        // Как при наборе: вставка (с подсветкой правленого места) и отрисовка. Полная перекраска — после паузы.
        // Строки здесь по 20 000 символов: без переноса TextKit раскладывает такую строку целиком на каждое нажатие.
        for i in 0..<50 {
            samples.append(Self.measure {
                tab.textView.insertText("x", replacementRange: NSRange(location: middle + i, length: 0))
                tab.container.displayIfNeeded()
            })
        }
        let repaint = Self.measure { tab.applyHighlights() }
        samples.sort()
        let typing = samples[samples.count / 2]
        // С переносом строк длинная строка — это короткие отрезки.
        tab.textView.setWraps(true)
        tab.reveal(NSRange(location: middle, length: 0))
        tab.container.displayIfNeeded()
        var wrapped: [Double] = []
        for i in 0..<50 {
            wrapped.append(Self.measure {
                tab.textView.insertText("x", replacementRange: NSRange(location: middle + 50 + i, length: 0))
                tab.container.displayIfNeeded()
            })
        }
        wrapped.sort()
        let typingWrapped = wrapped[wrapped.count / 2]
        tab.textView.setWraps(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        while tab.dollars.entries.count != big.dollars, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        // «Вид → Невидимые символы» на таком файле и ввод с ними (замечание тестировщика к 2.5: было ~3 с и 60 мс).
        let invisiblesOn = Self.measure {
            tab.showsInvisibles = true
            tab.container.displayIfNeeded()
        }
        var withInvisibles: [Double] = []
        for i in 0..<20 {
            withInvisibles.append(Self.measure {
                tab.textView.insertText("y", replacementRange: NSRange(location: middle + 200 + i, length: 0))
                tab.container.displayIfNeeded()
            })
        }
        withInvisibles.sort()
        tab.showsInvisibles = false
        print(String(format: "[editor-perf] %@ «Невидимые символы»: включение %.0f мс, ввод с ними %.1f мс (медиана из 20)",
                     Self.build, invisiblesOn, withInvisibles[10]))
        XCTAssertLessThan(invisiblesOn, Self.limit(1_000))
        XCTAssertLessThan(withInvisibles[10], Self.limit(50))
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        while tab.dollars.entries.count != big.dollars, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        // «Убрать значения» у 4 181 подсвеченного и одна отмена.
        var removed = 0
        let remove = Self.measure { removed = tab.removeHighlightedValues() }
        XCTAssertEqual(removed, big.dollars - 3, "все, кроме трёх пропущенных")
        let undo = Self.measure { tab.undo.undo() }
        XCTAssertEqual(tab.storage.length, big.data.count + 120)

        print(String(format: "[editor-perf] %@ 10 МБ в редакторе: открытие до первого экрана %.0f мс, ввод символа в строку 20 000 символов %.1f мс без переноса (медиана из 50, макс. %.1f) и %.1f мс с переносом, перекраска экрана после паузы %.1f мс, «Убрать значения» (%d) %.0f мс, отмена %.0f мс",
                     Self.build, open, typing, samples.last ?? 0, typingWrapped, repaint, removed, remove, undo))
        XCTAssertLessThan(open, Self.limit(2_000), "открытие < 2 с")
        XCTAssertLessThan(typing, Self.limit(50), "ввод в строку 20 000 символов без переноса — без заметных лагов (< 50 мс)")
        XCTAssertLessThan(typingWrapped, Self.limit(16), "ввод с переносом — меньше кадра")
        XCTAssertLessThan(remove, Self.limit(1_000), "«Убрать значения» < 1 с")
    }

    /// 10 МБ обычного текста (строки по 30 символов, 360 000 строк): ввод в середину меньше кадра.
    @MainActor
    func testTypingInTenMegabytesOfShortLines() {
        _ = NSApplication.shared
        DSFonts.registerAll()
        let text = String(repeating: "lorem $ipsum dolor sit amet\r\n", count: 360_000)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.orderBack(nil)
        let tab = EditorTab(document: EditorDocument(data: Data(text.utf8), url: nil))
        tab.container.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        window.contentView = tab.container
        tab.container.layoutSubtreeIfNeeded()
        let middle = tab.storage.length / 2
        tab.reveal(NSRange(location: middle, length: 0))
        tab.container.displayIfNeeded()
        var samples: [Double] = []
        for i in 0..<50 {
            samples.append(Self.measure {
                tab.textView.insertText("x", replacementRange: NSRange(location: middle + i, length: 0))
                tab.container.displayIfNeeded()
            })
        }
        samples.sort()
        print(String(format: "[editor-perf] %@ 10 МБ коротких строк: ввод символа %.1f мс (медиана из 50, макс. %.1f)",
                     Self.build, samples[25], samples.last ?? 0))
        XCTAssertLessThan(samples[25], Self.limit(16))
    }
}

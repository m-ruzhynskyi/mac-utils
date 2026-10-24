import XCTest
@testable import MacUtils
@testable import MUVideoPlayer

/// Этап 2 плеера: разбор SRT, ASS-подмножества и WebVTT, кодировки, поиск реплик и файлов рядом с видео.
final class SubtitleParserTests: XCTestCase {
    private var folder: URL?

    override func setUpWithError() throws { folder = try DemoVideo.makeFolder() }
    override func tearDown() { DemoVideo.cleanup(folder) }

    // MARK: - SRT

    func testSRTTimingsAndMultilineCues() {
        let track = SubtitleParser.parse(DemoSubtitles.srt)
        XCTAssertEqual(track.format, .srt)
        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.cues[0].start, 0.5, accuracy: 0.0001)
        XCTAssertEqual(track.cues[0].end, 1.5, accuracy: 0.0001)
        XCTAssertEqual(track.cues[0].text, "Привет, это первая реплика")
        XCTAssertEqual(track.cues[1].text, "Вторая реплика\nв две строки")
        XCTAssertTrue(track.cues[1].runs[0].italic, "<i>")
        XCTAssertFalse(track.cues[1].runs[1].italic)
    }

    func testSRTWithoutBlankLinesBetweenCues() {
        let text = """
        1
        00:00:01,000 --> 00:00:02,000
        Первая
        2
        00:00:02,500 --> 00:00:03,000
        Вторая
        3
        00:00:03,500 --> 00:00:04,000
        Третья
        """
        let track = SubtitleParser.parse(text)
        XCTAssertEqual(track.cues.map(\.text), ["Первая", "Вторая", "Третья"], "номер следующей реплики — не текст")
    }

    func testSRTCRLFAndBOMAndDotSeparator() {
        let data = DemoSubtitles.data("1\n00:00:01.5 --> 00:00:02.250\nТочка вместо запятой\n", .utf8BOM, crlf: true)
        let decoded = SubtitleText.decode(data)
        let track = SubtitleParser.parse(decoded.text)
        XCTAssertEqual(decoded.encoding, .utf8BOM)
        XCTAssertEqual(track.cues.first?.start ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(track.cues.first?.end ?? 0, 2.25, accuracy: 0.0001)
        XCTAssertEqual(track.cues.first?.text, "Точка вместо запятой", "без \\r и BOM")
    }

    func testSRTInWindows1251IsReadAsRussian() throws {
        let url = try DemoSubtitles.write(DemoSubtitles.srt, .windows1251, crlf: true, to: try XCTUnwrap(folder).appendingPathComponent("a.srt"))
        let loaded = try SubtitleParser.load(url)
        XCTAssertEqual(loaded.encoding, .windows1251)
        XCTAssertEqual(loaded.track.cues.first?.text, "Привет, это первая реплика")
        // Ручной выбор кодировки перечитывает те же байты.
        let forced = try SubtitleParser.load(url, encoding: .koi8R)
        XCTAssertEqual(forced.encoding, .koi8R)
        XCTAssertNotEqual(forced.track.cues.first?.text, "Привет, это первая реплика")
    }

    func testCyrillicSingleByteGuess() {
        let text = "Съешь же ещё этих мягких французских булок, да выпей чаю. Привет, мир!"
        func data(_ encoding: CFStringEncodings) -> Data {
            text.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue))))!
        }
        XCTAssertEqual(SubtitleText.guessSingleByte(data(.windowsCyrillic)), .windows1251)
        XCTAssertEqual(SubtitleText.guessSingleByte(data(.KOI8_R)), .koi8R)
        XCTAssertEqual(SubtitleText.guessSingleByte(data(.dosRussian)), .cp866)
        let western = "Où est la bibliothèque? Ça va très bien, merci beaucoup.".data(using: .windowsCP1252)!
        XCTAssertEqual(SubtitleText.guessSingleByte(western), .windows1252, "мало байтов выше 0x7F — западная")
    }

    func testSRTMarkupTagsAndColors() {
        let track = SubtitleParser.parse("""
        1
        00:00:01,000 --> 00:00:02,000
        <b>Жирный</b> <u>подчёркнутый</u> <font color="#FF0000">красный</font> <s>зачёркнутый</s> &amp; <unknown>тег</unknown>

        2
        00:00:03,000 --> 00:00:04,000
        {\\an8}Сверху
        """)
        let runs = track.cues[0].runs
        XCTAssertTrue(runs.first { $0.text == "Жирный" }?.bold ?? false)
        XCTAssertTrue(runs.first { $0.text == "подчёркнутый" }?.underline ?? false)
        XCTAssertEqual(runs.first { $0.text == "красный" }?.color, SubtitleColor(red: 255, green: 0, blue: 0))
        XCTAssertTrue(runs.first { $0.text == "зачёркнутый" }?.strike ?? false)
        XCTAssertEqual(track.cues[0].text, "Жирный подчёркнутый красный зачёркнутый & тег")
        XCTAssertEqual(track.cues[1].alignment, 8)
        XCTAssertEqual(track.cues[1].text, "Сверху")
    }

    func testGarbageAndEmptyCuesDoNotCrash() {
        let inputs = [
            "", "\n\n\n", "WEBVTT", "[Script Info]", "1\n00:00:01,000 --> \n", "абв\u{0}где", "00:00:05,000 --> 00:00:01,000\nНазад",
            "1\n00:00:01,000 --> 00:00:02,000\n\n2\n00:00:03,000 --> 00:00:04,000\n   \n",
            "{\\b1", "<b><i><u>", String(repeating: "-->", count: 1000), "99:99:99,999 --> 99:99:99,999\nX",
        ]
        for input in inputs {
            let track = SubtitleParser.parse(input)
            XCTAssertTrue(track.cues.allSatisfy { $0.end > $0.start && !$0.text.isEmpty }, input)
        }
        XCTAssertTrue(SubtitleParser.parse("00:00:05,000 --> 00:00:01,000\nНазад").cues.isEmpty, "конец раньше начала — отброшено")
    }

    func testRandomBytesDoNotCrash() {
        var random = PlayerTestRandom(7)
        for _ in 0..<200 {
            let bytes = (0..<Int(random.next() % 600)).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            let decoded = SubtitleText.decode(Data(bytes))
            _ = SubtitleParser.parse(decoded.text, fileExtension: ["srt", "ass", "vtt"][Int(random.next() % 3)])
        }
    }

    func testEmptyFileIsAnError() throws {
        let url = try XCTUnwrap(folder).appendingPathComponent("empty.srt")
        try Data().write(to: url)
        XCTAssertThrowsError(try SubtitleParser.load(url))
    }

    // MARK: - ASS

    func testASSStylesAndOverrides() {
        let track = SubtitleParser.parse(DemoSubtitles.ass, fileExtension: "ass")
        XCTAssertEqual(track.format, .ass)
        XCTAssertEqual(track.playResolution, CGSize(width: 640, height: 360))
        XCTAssertEqual(track.cues.count, 2, "Comment не показывается")
        let first = track.cues[0]
        XCTAssertEqual(first.text, "Привет, жирный текст", "запятые в тексте сохранены")
        XCTAssertTrue(first.runs.first { $0.text == "жирный" }?.bold ?? false)
        XCTAssertFalse(first.runs.first { $0.text.hasPrefix("Привет") }?.bold ?? true)
        XCTAssertEqual(first.alignment, 2)
        let sign = track.cues[1]
        XCTAssertEqual(sign.text, "Табличка\nвверху", "\\N — перевод строки")
        XCTAssertEqual(sign.alignment, 8)
        XCTAssertTrue(sign.runs[0].bold, "стиль Sign жирный (-1)")
        XCTAssertEqual(sign.runs[0].color, SubtitleColor(red: 255, green: 0, blue: 0), "\\c&H0000FF& — красный (BGR)")
    }

    func testASSUnsupportedEffectsLeaveNoBraces() {
        let body = """
        [Script Info]
        PlayResX: 1920
        PlayResY: 1080

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\k20}Ка{\\k30}ра{\\k50}оке
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\move(0,0,100,100)\\t(0,500,\\fs40\\c&HFF0000&)\\fad(200,200)}Движение
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\pos(960,100)\\i1\\u1\\s1\\blur3\\bord2\\shad1}Место
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\p1}m 0 0 l 100 0 100 100{\\p0}После рисунка
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Незакрытая {\\b1 вставка
        Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Пробел\\hнеразрывный{\\r}сброс
        """
        let track = SubtitleParser.parse(body)
        let texts = track.cues.map(\.text)
        XCTAssertEqual(texts, ["Караоке", "Движение", "Место", "После рисунка", "Незакрытая", "Пробел\u{00A0}неразрывныйсброс"])
        for cue in track.cues {
            XCTAssertFalse(cue.text.contains("{"), cue.text)
            XCTAssertFalse(cue.text.contains("\\"), cue.text)
        }
        let place = track.cues[2]
        XCTAssertEqual(place.position, CGPoint(x: 960, y: 100))
        XCTAssertTrue(place.runs[0].italic && place.runs[0].underline && place.runs[0].strike)
        XCTAssertNil(track.cues[1].runs[0].color, "\\t(…) не применяет цвет изнутри анимации")
    }

    func testSSALegacyAlignment() {
        XCTAssertEqual(SubtitleParser.numpad(legacy: 2), 2)
        XCTAssertEqual(SubtitleParser.numpad(legacy: 6), 8, "2 + 4 — сверху по центру")
        XCTAssertEqual(SubtitleParser.numpad(legacy: 9), 4, "1 + 8 — посередине слева")
        let body = """
        [Script Info]
        ScriptType: v4.00

        [V4 Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
        Style: Top,Arial,20,16777215,65535,65535,0,0,0,1,2,0,6,10,10,10,0,1

        [Events]
        Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: Marked=0,0:00:01.00,0:00:02.00,Top,,0,0,0,,Наверху
        """
        let track = SubtitleParser.parse(body)
        XCTAssertEqual(track.cues.first?.alignment, 8)
        XCTAssertEqual(track.cues.first?.runs.first?.color, .white, "десятичный цвет SSA")
    }

    func testASSColorParsing() {
        XCTAssertEqual(SubtitleColor(ass: "&H00FFFFFF"), SubtitleColor(red: 255, green: 255, blue: 255))
        XCTAssertEqual(SubtitleColor(ass: "&H80FF0000&")?.alpha, 127)
        XCTAssertEqual(SubtitleColor(ass: "&HFF0000&")?.blue, 255)
        XCTAssertNil(SubtitleColor(ass: "мусор"))
    }

    // MARK: - WebVTT

    func testVTT() {
        let track = SubtitleParser.parse("""
        WEBVTT

        NOTE комментарий

        intro
        00:01.000 --> 00:02.500 align:start line:0
        <v Анна>Привет</v> <c.yellow>всем</c>

        00:00:03.000 --> 00:00:04.000
        Вторая &lt;реплика&gt; <00:00:03.500>караоке
        """)
        XCTAssertEqual(track.format, .vtt)
        XCTAssertEqual(track.cues.map(\.text), ["Привет всем", "Вторая <реплика> караоке"])
        XCTAssertEqual(track.cues[0].start, 1)
        XCTAssertEqual(track.cues[0].alignment, 8)
    }

    // MARK: - Поиск реплик

    func testCueLookupWithOverlaps() {
        let cues = [
            SubtitleCue(start: 0, end: 10, runs: [SubtitleRun(text: "долгая")]),
            SubtitleCue(start: 2, end: 3, runs: [SubtitleRun(text: "a")]),
            SubtitleCue(start: 4, end: 5, runs: [SubtitleRun(text: "b")]),
            SubtitleCue(start: 12, end: 13, runs: [SubtitleRun(text: "c")]),
        ]
        let track = SubtitleTrack(format: .srt, cues: cues.reversed())
        XCTAssertEqual(track.cues(at: 2.5).map(\.text), ["долгая", "a"])
        XCTAssertEqual(track.cues(at: 3).map(\.text), ["долгая"], "конец не включается")
        XCTAssertEqual(track.cues(at: 11).map(\.text), [])
        XCTAssertEqual(track.cues(at: 12).map(\.text), ["c"])
        XCTAssertEqual(track.cues(at: -1).map(\.text), [])
    }

    func testLookupIsFastOnLargeTrack() {
        let cues = (0..<20_000).map { SubtitleCue(start: Double($0) * 2, end: Double($0) * 2 + 1.5, runs: [SubtitleRun(text: "\($0)")]) }
        let track = SubtitleTrack(format: .srt, cues: cues)
        let start = Date()
        for i in 0..<20_000 { _ = track.cues(at: Double(i) * 2 + 0.5) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "бинарный поиск, а не перебор")
        XCTAssertEqual(track.cues(at: 30_001).map(\.text), ["15000"])
    }

    // MARK: - Файлы рядом с видео

    func testFinderPrefersSystemLanguage() {
        let video = URL(fileURLWithPath: "/m/Night City.mp4")
        let names = ["Night City.en.srt", "night city.srt", "Night City.ru.srt", "Night City.ass", "Other.srt", "Night City.mp4",
                     "Night City.rus.forced.srt", "Night City.director's cut edition.srt"]
        let found = SubtitleFinder.candidates(for: video, names: names, preferredLanguages: ["ru-RU", "en"])
        XCTAssertEqual(found.map(\.url.lastPathComponent),
                       ["Night City.ru.srt", "Night City.rus.forced.srt", "Night City.en.srt", "Night City.ass", "night city.srt"])
        XCTAssertEqual(found.first?.language, "ru")
        XCTAssertEqual(SubtitleFinder.languageCode("English"), "en")
        XCTAssertEqual(SubtitleFinder.languageCode("ru-RU"), "ru")
    }
}

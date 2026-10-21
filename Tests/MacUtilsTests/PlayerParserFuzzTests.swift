import XCTest
@testable import MacUtils

/// Разборщики плеера не падают ни на каком входе (ревью 2, B1): случайные тексты собираются из «опасных» кусков —
/// длинные числа на месте времени, разделители, `-->`, вставки ASS, теги, заголовки — и мутации настоящих файлов.
/// Зерно фиксировано: упавший случай воспроизводится. Проверка — сам факт, что процесс жив, и что реплики осмысленны.
final class PlayerParserFuzzTests: XCTestCase {
    private static let pieces = [
        "999999999999999999", "18446744073709551616", "9223372036854775807", "-1", "00", "0", "1", "59", "60", "99999", "12345678901",
        ":", ",", ".", " ", "\n", "\r\n", "\r", "-->", " --> ", "\u{FEFF}", "\u{0}", "١٢٣", "\u{202E}",
        "{", "}", "{\\", "\\N", "\\n", "\\h", "\\pos(", "\\pos(1e308,nan)", "\\an99999999999999999999", "\\b-9", "\\c&H", "&HFFFFFFFFFF&",
        "\\t(", "\\p1", "\\p0", "\\k", "\\r", "(", ")", "<", ">", "</", "<font color=", "\"", "<b>", "</i>", "&amp;", "&",
        "[Script Info]", "[V4+ Styles]", "[V4 Styles]", "[Events]", "Format: Layer, Start, End, Style, Text", "Format:",
        "Dialogue: 0,", "Style: Default,", "PlayResX: ", "PlayResY: 1e400", "ScriptType: v4.00", "WEBVTT", "NOTE", "line:0",
        "Текст", "текст с ё", "€", "😀", String(repeating: "9", count: 400), String(repeating: "<", count: 50), String(repeating: "{", count: 50),
    ]

    private func garbage(_ random: inout PlayerTestRandom, length: Int) -> String {
        (0..<length).map { _ in Self.pieces[Int(random.next() % UInt64(Self.pieces.count))] }.joined()
    }

    /// Таймкод с мусором: правильная форма, но числа любой длины.
    private func timing(_ random: inout PlayerTestRandom) -> String {
        func number() -> String { Self.pieces[Int(random.next() % 14)] }
        let separator = random.next() % 2 == 0 ? "," : "."
        return "\(number()):\(number()):\(number())\(separator)\(number()) --> \(number()):\(number()):\(number())\(separator)\(number())"
    }

    func testSubtitleParsersSurviveAnyText() {
        var random = PlayerTestRandom(20261020)
        for iteration in 0..<3_000 {
            var text = garbage(&random, length: Int(random.next() % 60))
            if iteration % 3 == 0 { text = "1\n\(timing(&random))\n\(text)\n" }
            if iteration % 5 == 0 {
                text = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,"
                    + "\(garbage(&random, length: 4)),\(garbage(&random, length: 4)),Default,,0,0,0,,\(text)"
            }
            if iteration % 7 == 0 { text = "WEBVTT\n\n\(timing(&random).replacingOccurrences(of: ",", with: "."))\n\(text)" }
            for ext in ["srt", "ass", "vtt", ""] {
                let track = SubtitleParser.parse(text, fileExtension: ext)
                for cue in track.cues {
                    XCTAssertTrue(cue.start.isFinite && cue.end.isFinite && cue.end > cue.start)
                    XCTAssertLessThanOrEqual(cue.end, SubtitleParser.maxSeconds)
                    XCTAssertFalse(cue.text.contains("{\\"), "вставки ASS не доходят до экрана")
                }
                _ = track.cues(at: Double(random.next() % 100_000))
            }
            _ = SubtitleParser.markup(text)
            _ = SubtitleParser.assText(text, style: .init())
            _ = SubtitleParser.seconds(garbage(&random, length: 5))
            _ = SubtitleParser.timingLine(timing(&random))
        }
    }

    func testMutatedRealFilesSurvive() {
        var random = PlayerTestRandom(7)
        let sources = [DemoSubtitles.srt, DemoSubtitles.ass,
                       "WEBVTT\n\n00:01.000 --> 00:02.500 line:0\n<v Анна>Привет</v>\n\n00:00:03.000 --> 00:00:04.000\nВторая\n"]
        for _ in 0..<2_000 {
            var characters = Array(sources[Int(random.next() % UInt64(sources.count))])
            for _ in 0..<Int(1 + random.next() % 6) {
                let position = Int(random.next() % UInt64(characters.count + 1))
                switch random.next() % 3 {
                case 0: characters.insert(contentsOf: Array(Self.pieces[Int(random.next() % UInt64(Self.pieces.count))]), at: position)
                case 1: if position < characters.count { characters.remove(at: position) }
                default: characters.insert(contentsOf: Array(String(repeating: "9", count: Int(10 + random.next() % 40))), at: position)
                }
            }
            let text = String(characters)
            for ext in ["srt", "ass", "vtt"] { _ = SubtitleParser.parse(text, fileExtension: ext) }
        }
    }

    func testDecodingAnyBytes() {
        var random = PlayerTestRandom(11)
        for _ in 0..<1_000 {
            let bytes = Data((0..<Int(random.next() % 300)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
            let decoded = SubtitleText.decode(bytes)
            _ = SubtitleParser.parse(decoded.text)
            for encoding in [TextEncoding.utf16LE, .utf16BE, .koi8R, .cp866] { _ = SubtitleText.decode(bytes, encoding: encoding) }
        }
    }

    /// Атомы MP4 / `chpl` и образцы tx3g / WebVTT: размеры из данных никогда не принимаются на веру.
    func testBinaryParsersSurviveAnyBytes() {
        var random = PlayerTestRandom(13)
        func box(_ type: String, size: [UInt8], payload: Data) -> Data { Data(size) + Data(type.utf8) + payload }
        for _ in 0..<3_000 {
            let payload = Data((0..<Int(random.next() % 64)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
            let sizes: [[UInt8]] = [[0, 0, 0, 0], [0, 0, 0, 1], [0xFF, 0xFF, 0xFF, 0xFF], [0, 0, 0, 7],
                                    [0, 0, 0, UInt8(truncatingIfNeeded: random.next())]]
            let size = sizes[Int(random.next() % UInt64(sizes.count))]
            let large = Data((0..<8).map { _ in UInt8(truncatingIfNeeded: random.next() | (random.next() % 2 == 0 ? 0x80 : 0)) })
            let type = ["moov", "udta", "chpl", "vttc", "payl", "vtte", "junk"][Int(random.next() % 7)]
            var data = box(type, size: size, payload: size == [0, 0, 0, 1] ? large + payload : payload)
            if random.next() % 2 == 0 { data = box("udta", size: [0, 0, 0, UInt8(truncatingIfNeeded: data.count + 8)], payload: data) }
            _ = NeroChapters.boxes(in: data)
            _ = NeroChapters.chapters(inMoov: data)
            _ = NeroChapters.parse(chpl: payload)
            _ = SubtitleController.tx3gText(data)
            _ = SubtitleController.webVTTText(data)
            _ = ChapterClassifier.words(String(decoding: payload, as: UTF8.self))
        }
    }

    func testBinaryFilesOnDisk() throws {
        let folder = try DemoVideo.makeFolder()
        defer { DemoVideo.cleanup(folder) }
        var random = PlayerTestRandom(17)
        let url = folder.appendingPathComponent("junk.mp4")
        for _ in 0..<200 {
            var data = Data()
            for _ in 0..<Int(1 + random.next() % 4) {
                let large = random.next() % 2 == 0
                data += Data(large ? [0, 0, 0, 1] : [0, 0, 0, UInt8(truncatingIfNeeded: random.next())])
                data += Data((random.next() % 2 == 0 ? "moov" : "free").utf8)
                if large { data += Data((0..<8).map { _ in UInt8(truncatingIfNeeded: random.next()) }) }
                data += Data((0..<Int(random.next() % 32)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
            }
            try data.write(to: url)
            _ = NeroChapters.read(url)
        }
    }
}

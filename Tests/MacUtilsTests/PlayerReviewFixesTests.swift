import AVFoundation
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUAudio
@testable import MUScreenshot
@testable import MUVideoPlayer
@testable import MUTextEditor

/// Исправления по ревью плеера (`.audit/review-video.md`): мусор в файлах не роняет приложение,
/// закрытое окно освобождается, перетаскивание видео с субтитрами, долгие реплики.
final class SubtitleGarbageTests: XCTestCase {
    /// B1: длинная строка цифр во времени переполняла `Int` и роняла весь Mac Utils (SIGTRAP и в релизе).
    func testHugeNumbersInTimingsAreIgnored() {
        let digits = "999999999999999999"
        let srt = "1\n\(digits):00:00,000 --> \(digits):00:01,000\nМусор\n\n2\n00:00:01,000 --> 00:00:02,000\nНормальная\n"
        XCTAssertEqual(SubtitleParser.parse(srt).cues.map(\.text), ["Нормальная"])
        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,\(digits):00:00.00,\(digits):00:01.00,Default,,0,0,0,,Мусор
        Dialogue: 0,0:00:00.\(digits),0:00:01.00,Default,,0,0,0,,Дробь
        Dialogue: 0,0:\(digits):00.00,0:00:01.00,Default,,0,0,0,,Минуты
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Нормальная
        """
        XCTAssertEqual(SubtitleParser.parse(ass).cues.map(\.text), ["Нормальная"])
        let vtt = "WEBVTT\n\n\(digits):00:00.000 --> \(digits):00:01.000\nМусор\n\n00:01.000 --> 00:02.000\nНормальная\n"
        XCTAssertEqual(SubtitleParser.parse(vtt).cues.map(\.text), ["Нормальная"])
    }

    func testSecondsLimits() {
        XCTAssertEqual(SubtitleParser.seconds("2777:00:00,000"), 9_997_200)
        XCTAssertNil(SubtitleParser.seconds("999999:00:00,000"), "часы — до 5 цифр")
        XCTAssertNil(SubtitleParser.seconds("0:123:00,000"), "минуты — до 2 цифр")
        XCTAssertNil(SubtitleParser.seconds("0:00:00,1234"), "дробь — до 3 цифр")
        XCTAssertNil(SubtitleParser.seconds("٣:00:00,000"), "только ASCII-цифры")
        XCTAssertNil(SubtitleParser.seconds("5000:00:00,000"), "дальше ≈ 115 суток — мусор")
        XCTAssertEqual(SubtitleParser.seconds("1:02:03,5"), 3723.5)
    }

    func testHugeNumbersFileNextToVideoDoesNotCrashLoading() throws {
        let folder = try DemoVideo.makeFolder()
        defer { DemoVideo.cleanup(folder) }
        let url = folder.appendingPathComponent("film.srt")
        try Data("1\n999999999999999999:00:00,000 --> 999999999999999999:00:01,000\nМусор\n".utf8).write(to: url)
        XCTAssertThrowsError(try SubtitleParser.load(url), "пустой результат — понятная ошибка, а не падение")
    }

    /// M1: «<» и «{» без пары разбирались квадратично — 20k знаков занимали секунды.
    func testUnmatchedBracketsAreLinear() {
        let text = String(repeating: "< { ", count: 50_000)
        let start = Date()
        let cue = SubtitleParser.markup(text)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertFalse(cue.text.isEmpty, "без пары — это текст")
        XCTAssertEqual(SubtitleParser.markup("a <i>b</i> < c").text, "a b < c")
    }

    /// M6: одна долгая ASS-надпись на весь фильм не должна заставлять поиск отступать на весь фильм.
    func testLongCueDoesNotSlowLookup() {
        var cues = (0..<20_000).map { SubtitleCue(start: Double($0) * 2, end: Double($0) * 2 + 1.5, runs: [SubtitleRun(text: "\($0)")]) }
        cues.append(SubtitleCue(start: 0, end: 40_000, runs: [SubtitleRun(text: "надпись")]))
        let track = SubtitleTrack(format: .ass, cues: cues)
        let start = Date()
        for i in 0..<20_000 { _ = track.cues(at: Double(i) * 2 + 0.5) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(track.cues(at: 30_001).map(\.text), ["надпись", "15000"], "долгая и обычная — по началу")
        XCTAssertEqual(track.cues(at: 30_001.8).map(\.text), ["надпись"])
    }

    /// M5: пустой образец tx3g или WebVTT не роняет чтение.
    func testEmptySamples() {
        XCTAssertEqual(SubtitleController.tx3gText(Data()), "")
        XCTAssertEqual(SubtitleController.tx3gText(Data([0, 0])), "")
        XCTAssertEqual(SubtitleController.tx3gText(Data([0, 9, 0x41])), "", "длина больше данных")
        XCTAssertEqual(SubtitleController.webVTTText(Data()), "")
    }
}

final class NeroChaptersSafetyTests: XCTestCase {
    /// S1: 64-битный размер атома `0xFFFF…` переполнял `offset + size`.
    func testHugeLargeSizeInBoxes() {
        var data = Data([0, 0, 0, 1]) + Data("junk".utf8) + Data(repeating: 0xFF, count: 8)
        XCTAssertTrue(NeroChapters.boxes(in: data).isEmpty)
        data += Data(repeating: 0, count: 64)
        XCTAssertTrue(NeroChapters.boxes(in: data).isEmpty)
        XCTAssertTrue(NeroChapters.chapters(inMoov: data).isEmpty)
        let vtt = Data([0, 0, 0, 1]) + Data("vttc".utf8) + Data([0x7F] + Array(repeating: 0xFF, count: 7))
        XCTAssertEqual(SubtitleController.webVTTText(vtt), "", "полезная нагрузка WebVTT тоже без доверия")
    }

    func testHugeLargeSizeInFile() throws {
        let folder = try DemoVideo.makeFolder()
        defer { DemoVideo.cleanup(folder) }
        let url = folder.appendingPathComponent("junk.mp4")
        try (Data([0, 0, 0, 1]) + Data("junk".utf8) + Data(repeating: 0xFF, count: 8)).write(to: url)
        XCTAssertTrue(NeroChapters.read(url).isEmpty)
        let second = folder.appendingPathComponent("junk2.mp4")
        try (Data([0, 0, 0, 16]) + Data("free".utf8) + Data(repeating: 0, count: 8)
             + Data([0, 0, 0, 1]) + Data("moov".utf8) + Data([0x7F] + Array(repeating: 0xFF, count: 7))).write(to: second)
        XCTAssertTrue(NeroChapters.read(second).isEmpty)
    }
}

@MainActor
final class PlayerWindowLifetimeTests: XCTestCase {
    private var folder: URL?

    override func setUp() async throws {
        _ = NSApplication.shared
        Pref.register()
        folder = try DemoVideo.makeFolder()
        PlayerSystem.shared.integratesWithSystem = false
        PlayerWindowController.syncDock = { _ in }
    }

    override func tearDown() async throws {
        for controller in PlayerWindowController.windows { controller.window.close() }
        DemoVideo.cleanup(folder)
        PlayerSystem.shared.integratesWithSystem = true
        PlayerWindowController.syncDock = { AppDelegate.syncDock(playerOpen: $0) }
    }

    private func waitUntil(_ what: String, timeout: Double = 30, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("не дождались: \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func demo(_ name: String) async throws -> URL {
        var options = DemoVideo.Options()
        options.duration = 3
        options.width = 160
        options.height = 90
        return try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: name)
    }

    /// S2: виды держали контроллер, окно — виды; закрытое окно с AVPlayer жило до выхода из программы.
    func testClosedWindowIsReleased() async throws {
        weak var weakController: PlayerWindowController?
        weak var weakModel: PlayerModel?
        let url = try await demo("a.mp4")
        do {
            let controller = PlayerWindowController(model: PlayerModel(silent: true, positions: PositionStore(file: nil)))
            weakController = controller
            weakModel = controller.model
            controller.model.open([url])
            try await waitUntil("ready") { controller.model.phase == .ready }
            controller.window.close()
            // Повторный показ закрытого окна (возврат из PiP) его не оживляет.
            controller.present()
            XCTAssertTrue(controller.isClosed)
            XCTAssertFalse(controller.window.isVisible)
            XCTAssertFalse(PlayerWindowController.windows.contains { $0 === controller })
            for other in PlayerWindowController.windows { other.window.close() }
        }
        try await waitUntil("контроллер отпущен") { weakController == nil }
        try await waitUntil("модель и AVPlayer — вместе с окном") { weakModel == nil }
    }

    /// S4: видео и `.srt` с другим именем одним перетаскиванием — субтитры прикрепляются к новому видео.
    func testDroppingVideoWithSubtitlesKeepsSubtitles() async throws {
        let folder = try XCTUnwrap(folder)
        let video = try await demo("episode.mp4")
        let srt = try DemoSubtitles.write(DemoSubtitles.srt, .utf8, to: folder.appendingPathComponent("другое имя.srt"))
        let controller = PlayerWindowController(model: PlayerModel(silent: true, positions: PositionStore(file: nil)))
        controller.dropped([srt, video])
        try await waitUntil("субтитры прикреплены") { controller.model.subtitles.selectedExternal?.url == srt }
        try await waitUntil("ready") { controller.model.phase == .ready }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(controller.model.subtitles.external.map(\.url), [srt], "автопоиск рядом с видео их не стёр")
        XCTAssertEqual(controller.model.playlist.count, 1)
        controller.window.close()
    }
}

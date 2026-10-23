import AVFoundation
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot

/// Этап 4 плеера на демо-файлах: субтитры (встроенные и внешние), аудиодорожки, пропуск по главам,
/// следующая серия, снимок кадра (точный кадр и HDR → SDR). Звука нет, позиции — в памяти.
@MainActor
final class PlayerFeatureTests: XCTestCase {
    private var folder: URL?
    private var model: PlayerModel?
    private let touched = [Pref.playerSubtitleLanguage, Pref.playerAudioLanguage, Pref.playerSkipAuto, Pref.playerNextEpisode,
                           Pref.playerSubtitlesNearby]

    override func setUp() async throws {
        Pref.register()
        folder = try DemoVideo.makeFolder()
        for key in touched { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() async throws {
        model?.shutdown()
        model = nil
        DemoVideo.cleanup(folder)
        for key in touched { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func makeModel() -> PlayerModel {
        let model = PlayerModel(silent: true, positions: PositionStore(file: nil))
        self.model = model
        return model
    }

    private func demo(_ name: String, duration: Double = 10, chapters: [DemoVideo.Chapter] = []) async throws -> URL {
        var options = DemoVideo.Options()
        options.duration = duration
        options.width = 160
        options.height = 90
        options.chapters = chapters
        return try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: name)
    }

    private func waitUntil(_ what: String, timeout: Double = 30, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("не дождались: \(what)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Субтитры

    func testEmbeddedSubtitlesAreReadAndShown() async throws {
        let model = makeModel()
        model.open([try await demo("embedded.mp4")])
        try await waitUntil("встроенные субтитры") { model.subtitles.embedded.count == 2 }
        let subtitles = model.subtitles
        XCTAssertEqual(Set(subtitles.embedded.map(\.title)), ["Русский", "English"])
        let russian = try XCTUnwrap(subtitles.embedded.first { $0.language == "ru" })
        subtitles.select(.embedded(russian.id))
        XCTAssertEqual(subtitles.cues(at: 1).map(\.text), ["Первая реплика"])
        XCTAssertEqual(subtitles.cues(at: 1.8).map(\.text), [], "между репликами — пусто")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Pref.playerSubtitleLanguage), "ru", "язык запомнен")
        subtitles.shiftDelay(0.5)
        XCTAssertEqual(subtitles.cues(at: 1.8).map(\.text), ["Первая реплика"], "сдвиг +0,5 с — позже")
        XCTAssertEqual(subtitles.delayTitle, "Сдвиг субтитров +0,5 с")
        subtitles.select(.off)
        XCTAssertTrue(subtitles.cues(at: 1).isEmpty)
    }

    func testDefaultSubtitleSelection() async throws {
        let model = makeModel()
        model.open([try await demo("pick.mp4")])
        try await waitUntil("встроенные субтитры") { model.subtitles.embedded.count == 2 }
        let subtitles = model.subtitles
        guard case .embedded(let id) = subtitles.defaultSelection(preferred: ["ru-RU"]) else { return XCTFail("язык системы") }
        XCTAssertEqual(subtitles.embedded.first { $0.id == id }?.language, "ru")
        UserDefaults.standard.set("en", forKey: Pref.playerSubtitleLanguage)
        guard case .embedded(let remembered) = subtitles.defaultSelection(preferred: ["ru-RU"]) else { return XCTFail("запомненный") }
        XCTAssertEqual(subtitles.embedded.first { $0.id == remembered }?.language, "en", "последний выбор — первым")
        UserDefaults.standard.set("off", forKey: Pref.playerSubtitleLanguage)
        XCTAssertEqual(subtitles.defaultSelection(preferred: ["ru-RU"]), .off, "выключили — выключены")
        UserDefaults.standard.removeObject(forKey: Pref.playerSubtitleLanguage)
        XCTAssertEqual(subtitles.defaultSelection(preferred: ["de-DE"]), .off, "нет языка системы — выключены")
    }

    func testNearbyCP1251SubtitlesLoadThemselvesAndReencode() async throws {
        let folder = try XCTUnwrap(folder)
        let video = try await demo("Ночной город.mp4")
        try DemoSubtitles.write(DemoSubtitles.srt, .windows1251, crlf: true, to: folder.appendingPathComponent("Ночной город.ru.srt"))
        let model = makeModel()
        model.open([video])
        try await waitUntil("файл рядом") { !model.subtitles.external.isEmpty }
        let file = try XCTUnwrap(model.subtitles.external.first)
        XCTAssertTrue(file.nearby)
        XCTAssertEqual(file.language, "ru")
        XCTAssertEqual(file.encoding, .windows1251)
        model.subtitles.select(.external(file.id))
        XCTAssertEqual(model.subtitles.cues(at: 1).first?.text, "Привет, это первая реплика")
        await model.subtitles.reencode(.koi8R).value
        XCTAssertEqual(model.subtitles.selectedExternal?.encoding, .koi8R)
        XCTAssertNotEqual(model.subtitles.cues(at: 1).first?.text, "Привет, это первая реплика", "ручная кодировка перечитывает байты")
        await model.subtitles.reencode(.windows1251).value
        XCTAssertEqual(model.subtitles.cues(at: 1).first?.text, "Привет, это первая реплика")
    }

    func testDroppedSubtitleFileAttachesToCurrentVideo() async throws {
        let folder = try XCTUnwrap(folder)
        let model = makeModel()
        model.open([try await demo("plain.mp4")])
        try await waitUntil("ready") { model.phase == .ready }
        let ass = try DemoSubtitles.write(DemoSubtitles.ass, .utf8BOM, to: folder.appendingPathComponent("другое имя.ass"))
        await model.subtitles.addExternal(ass).value
        XCTAssertEqual(model.subtitles.selectedExternal?.url, ass, "добавленный файл сразу включён")
        XCTAssertFalse(model.subtitles.selectedExternal?.nearby ?? true)
        XCTAssertEqual(model.playlist.count, 1, "субтитры — не в плейлист")
        let broken = folder.appendingPathComponent("пусто.srt")
        try Data("мусор".utf8).write(to: broken)
        await model.subtitles.addExternal(broken).value
        XCTAssertNotNil(model.subtitles.lastError, "понятная ошибка, а не падение")
        XCTAssertEqual(model.subtitles.selectedExternal?.url, ass, "прежний выбор остался")
    }

    // MARK: - Дорожки

    func testAudioTracksSwitchAndRemember() async throws {
        let model = makeModel()
        model.open([try await demo("audio.mp4")])
        try await waitUntil("дорожки") { model.audioOptions.count == 2 }
        XCTAssertEqual(model.audioOptions.map(\.title), ["Русский", "English"])
        XCTAssertTrue(model.audioOptions[0].detail.hasPrefix("AAC"), model.audioOptions[0].detail)
        XCTAssertEqual(model.selectedAudio, 0)
        model.selectAudio(1)
        let item = try XCTUnwrap(model.player.currentItem)
        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loadedGroup)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag, "en")
        XCTAssertEqual(UserDefaults.standard.string(forKey: Pref.playerAudioLanguage), "en")
        // Следующий файл открывается с запомненным языком.
        model.open([try await demo("audio2.mp4")])
        try await waitUntil("второй файл") { model.audioOptions.count == 2 && model.info.title == "audio2.mp4" }
        XCTAssertEqual(model.selectedAudio, 1)
    }

    // MARK: - Пропуск и следующая серия

    func testAutoSkipIntroOnceAndUndo() async throws {
        UserDefaults.standard.set(true, forKey: Pref.playerSkipAuto)
        let model = makeModel()
        model.open([try await demo("e01.mp4", chapters: [.init(title: "Story", start: 0), .init(title: "Intro", start: 1),
                                                          .init(title: "Episode", start: 3)])])
        try await waitUntil("отрезки") { model.skip.segments.count == 1 }
        model.seek(to: 0.5, exact: true)
        model.play()
        try await waitUntil("авто-пропуск") { model.skip.skippedToast != nil }
        try await waitUntil("за концом интро") { model.currentTime >= 2.5 }
        XCTAssertEqual(model.skip.skippedToast?.label, "Intro")
        model.skip.undo()
        try await waitUntil("вернулись к началу отрезка") { abs(model.currentTime - 1) < 0.3 }
        XCTAssertNil(model.skip.skippedToast)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertLessThan(model.currentTime, 2.5, "второго пропуска нет")
    }

    func testSkipKeyInsideSegmentNeverOvershoots() async throws {
        let model = makeModel()
        model.open([try await demo("e02.mp4", chapters: [.init(title: "Recap", start: 0), .init(title: "Episode", start: 2)])])
        try await waitUntil("отрезки") { model.skip.segments.count == 1 }
        model.pause()
        model.seek(to: 0.5, exact: true)
        try await waitUntil("0,5 с") { abs(model.currentTime - 0.5) < 0.05 }
        model.skip.skipCurrent()
        try await waitUntil("пропуск") { model.currentTime > 1.4 }
        XCTAssertLessThanOrEqual(model.currentTime, 2.0001, "никогда не позже конца отрезка")
        let before = model.currentTime
        model.skip.skipCurrent()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.currentTime, before, accuracy: 0.01, "вне отрезка — ничего")
    }

    func testNextEpisodeCountdownPlaysNextFile() async throws {
        let model = makeModel()
        let chapters: [DemoVideo.Chapter] = [.init(title: "Episode", start: 0), .init(title: "Ending", start: 8.6)]
        let first = try await demo("s01e01.mp4", chapters: chapters)
        let second = try await demo("s01e02.mp4", chapters: chapters)
        model.open([first, second])
        try await waitUntil("отрезки") { model.skip.segments.count == 1 }
        model.seek(to: 8.3, exact: true)
        model.play()
        try await waitUntil("отсчёт") { if case .countdown = model.skip.decision { return true } else { return false } }
        // Пауза отменяет отсчёт, остаётся кнопка «Следующая серия».
        model.pause()
        try await waitUntil("кнопка") {
            if case .button(_, "Следующая серия", _) = model.skip.decision { return true } else { return false }
        }
        model.skip.playNext()
        try await waitUntil("вторая серия") { model.playlist.current?.url.lastPathComponent == "s01e02.mp4" && model.phase == .ready }
    }

    // MARK: - Снимок кадра

    func testSnapshotIsExactlyTheShownFrame() async throws {
        let model = makeModel()
        model.open([try await demo("shot.mp4")])
        try await waitUntil("ready") { model.phase == .ready }
        model.pause()
        model.seek(to: 5, exact: true)
        try await waitUntil("5 с") { abs(model.currentTime - 5) < 0.01 }
        model.stepFrame(forward: true)
        try await waitUntil("кадр 121") { model.frameNumber == 121 }
        try await Task.sleep(nanoseconds: 100_000_000)
        let frame = await PlayerSnapshot.frame(of: model)
        let image = try XCTUnwrap(frame)
        XCTAssertEqual(DemoVideo.frameNumber(in: image), 121, "номер на снимке = номер показанного кадра")
        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(PlayerSnapshot.fileName(video: "night_city_demo.mp4", time: 1390), "night_city_demo — кадр 23.10.png")
    }

    func testHDRSnapshotIsToneMappedNotClipped() async throws {
        guard let url = try await DemoVideo.makeHLG(in: try XCTUnwrap(folder)) else {
            throw XCTSkip("Кодер HEVC 10 бит недоступен")
        }
        let model = makeModel()
        model.open([url])
        try await waitUntil("ready") { model.phase == .ready }
        XCTAssertTrue(model.info.isHDR)
        XCTAssertTrue(model.info.codecs.contains("HDR"), model.info.codecs)
        model.pause()
        model.seek(to: 0.5, exact: true)
        try await waitUntil("0,5 с") { abs(model.currentTime - 0.5) < 0.05 }
        try await Task.sleep(nanoseconds: 200_000_000)
        let frame = await PlayerSnapshot.frame(of: model)
        let image = try XCTUnwrap(frame)
        let peak = luma(image, x: image.width / 4, y: image.height / 2)
        let reference = luma(image, x: image.width * 3 / 4, y: image.height / 2)
        XCTAssertGreaterThan(peak, reference + 8, "пик и опорный белый различимы — тональная компрессия, а не обрезка (\(peak) / \(reference))")
        XCTAssertLessThan(reference, 250, "опорный белый HLG не пересвечен")
    }

    private func luma(_ image: CGImage, x: Int, y: Int) -> Int {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
    }
}

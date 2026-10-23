import AVFoundation
import XCTest
@testable import MUDesign

/// Этап 1 плеера: демо-медиа создаётся во временной папке, в нём то, что нужно тестам плеера.
final class DemoVideoTests: XCTestCase {
    private var folder: URL?

    override func setUpWithError() throws { folder = try DemoVideo.makeFolder() }
    override func tearDown() { DemoVideo.cleanup(folder) }

    func testMP4HasVideoTwoAudioLanguagesAndSubtitles() async throws {
        let url = try await DemoVideo.make(in: try XCTUnwrap(folder), name: "demo.mp4")
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.1)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 2)

        let audibleGroup = try await asset.loadMediaSelectionGroup(for: .audible)
        let audible = try XCTUnwrap(audibleGroup)
        XCTAssertEqual(Set(audible.options.compactMap { $0.extendedLanguageTag }), ["ru", "en"])
        let legibleGroup = try await asset.loadMediaSelectionGroup(for: .legible)
        let legible = try XCTUnwrap(legibleGroup, "tx3g — в группе субтитров")
        // Обе дорожки tx3g — в группе субтитров. macOS может добавить в группу свои варианты на языках пользователя
        // (видели «uk-UA», «ru-RU»), поэтому проверяем, что наши есть, а не что других нет. Плеер берёт дорожки файла.
        XCTAssertTrue(Set(legible.options.compactMap { $0.extendedLanguageTag }).isSuperset(of: ["ru", "en"]))
        let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
        XCTAssertEqual(subtitleTracks.count, 2)
    }

    func testEveryFrameCarriesItsNumber() async throws {
        let url = try await DemoVideo.make(in: try XCTUnwrap(folder), name: "frames.mov")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for frame in [0, 1, 23, 24, 57, 95] {
            let image = try await generator.image(at: CMTime(value: CMTimeValue(frame), timescale: 24)).image
            XCTAssertEqual(DemoVideo.frameNumber(in: image), frame, "кадр \(frame)")
        }
    }

    func testQuickTimeChaptersAreReadable() async throws {
        var options = DemoVideo.Options()
        options.duration = 6
        options.chapters = [.init(title: "Intro", start: 0), .init(title: "Part 1", start: 2), .init(title: "Ending", start: 5)]
        let url = try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: "chapters.mp4")
        let asset = AVURLAsset(url: url)
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["en", "und"])
        XCTAssertEqual(groups.count, 3)
        var titles: [String] = []
        for group in groups {
            let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            titles.append(try await item?.load(.stringValue) ?? "")
        }
        XCTAssertEqual(titles, ["Intro", "Part 1", "Ending"])
        XCTAssertEqual(groups[1].timeRange.start.seconds, 2, accuracy: 0.05)
    }

    func testNeroChaptersAtomIsWritten() async throws {
        var options = DemoVideo.Options()
        options.neroChapters = [.init(title: "Opening", start: 0), .init(title: "Story", start: 1.5)]
        let url = try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: "nero.mp4")
        let data = try Data(contentsOf: url)
        XCTAssertNotNil(data.firstRange(of: Data("chpl".utf8)))
        // Файл после дописывания по-прежнему открывается и играет.
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        XCTAssertTrue(playable)
        XCTAssertEqual(duration, 4, accuracy: 0.1)
    }

    func testAudioOnlyFile() async throws {
        var options = DemoVideo.Options()
        options.audioOnly = true
        options.audioLanguages = ["ru"]
        options.fileType = .m4a
        let url = try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: "voice.m4a")
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 0)
        XCTAssertEqual(audioTracks.count, 1)
    }

    func testSubtitleFilesInBothEncodings() throws {
        let dir = try XCTUnwrap(folder)
        let utf = try DemoSubtitles.write(DemoSubtitles.srt, .utf8, to: dir.appendingPathComponent("a.srt"))
        let cp = try DemoSubtitles.write(DemoSubtitles.srt, .windows1251, crlf: true, to: dir.appendingPathComponent("b.srt"))
        XCTAssertNotNil(String(data: try Data(contentsOf: utf), encoding: .utf8))
        XCTAssertNil(String(data: try Data(contentsOf: cp), encoding: .utf8), "cp1251 — не UTF-8")
        XCTAssertTrue(try Data(contentsOf: cp).contains(0x0D))
    }

    func testFilesStayInTemporaryFolder() throws {
        let dir = try XCTUnwrap(folder)
        XCTAssertTrue(dir.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}

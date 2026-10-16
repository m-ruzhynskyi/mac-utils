@preconcurrency import AVFoundation
import XCTest
@testable import MacUtils

/// Склейка кусков записи и восстановление после сбоя — на настоящих короткых M4A (без разрешений и сети).
final class MeetingMergeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("meet-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// Кусок M4A заданной длительности (синус); AVAudioFile закрывается при выходе из функции.
    private func writeTone(to url: URL, seconds: Double, rate: Double = 44_100) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.3 }
        try file.write(from: buffer)
    }

    private func duration(_ url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    func testMergeConcatenatesPartsInOrder() async throws {
        let parts = (1...3).map { MeetingFiles.partURL(folder: folder, track: "Я", index: $0) }
        for part in parts { try writeTone(to: part, seconds: 1) }
        let target = folder.appendingPathComponent("Я.m4a")
        let used = try await MeetingMerge.merge(parts: parts, to: target)
        XCTAssertEqual(used, 3)
        let total = try await duration(target)
        XCTAssertEqual(total, 3, accuracy: 0.3)
    }

    func testSinglePartIsJustMoved() async throws {
        let part = MeetingFiles.partURL(folder: folder, track: "Я", index: 1)
        try writeTone(to: part, seconds: 1)
        let target = folder.appendingPathComponent("Я.m4a")
        let used = try await MeetingMerge.merge(parts: [part], to: target)
        XCTAssertEqual(used, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
        let seconds = try await duration(target)
        XCTAssertEqual(seconds, 1, accuracy: 0.2)
    }

    /// Сбой: последний кусок не закрыт (нечитаем) — теряется он, остальное склеивается.
    func testUnreadableLastPartIsSkipped() async throws {
        let good = (1...2).map { MeetingFiles.partURL(folder: folder, track: "Я", index: $0) }
        for part in good { try writeTone(to: part, seconds: 1) }
        let broken = MeetingFiles.partURL(folder: folder, track: "Я", index: 3)
        try Data(repeating: 0x41, count: 5_000).write(to: broken)
        let target = folder.appendingPathComponent("Я.m4a")
        let used = try await MeetingMerge.merge(parts: good + [broken], to: target)
        XCTAssertEqual(used, 2)
        let total = try await duration(target)
        XCTAssertEqual(total, 2, accuracy: 0.3)
    }

    func testNothingReadableThrows() async throws {
        let broken = MeetingFiles.partURL(folder: folder, track: "Я", index: 1)
        try Data(repeating: 0x41, count: 100).write(to: broken)
        do {
            _ = try await MeetingMerge.merge(parts: [broken], to: folder.appendingPathComponent("Я.m4a"))
            XCTFail("пустая запись не должна склеиваться")
        } catch {}
        do {
            _ = try await MeetingMerge.merge(parts: [], to: folder.appendingPathComponent("Я.m4a"))
            XCTFail()
        } catch {}
    }

    /// Восстановление: куски обеих дорожек и метка «запись идёт» → обычные файлы, куски и метка убраны.
    func testFinalizeRecoversInterruptedRecording() async throws {
        MeetingFiles.writeMarker(in: folder, startedAt: Date(), microphone: true)
        for index in 1...2 {
            try writeTone(to: MeetingFiles.partURL(folder: folder, track: MeetingFiles.systemTrack, index: index), seconds: 1)
        }
        try writeTone(to: MeetingFiles.partURL(folder: folder, track: MeetingFiles.micTrack, index: 1), seconds: 1)
        try Data(repeating: 0x41, count: 3_000).write(to: MeetingFiles.partURL(folder: folder, track: MeetingFiles.micTrack, index: 2))

        let ready = await MeetingMerge.finalize(folder: folder)
        XCTAssertEqual(Set(ready), [MeetingFiles.systemTrack, MeetingFiles.micTrack])
        let system = try await duration(folder.appendingPathComponent("Собеседники.m4a"))
        XCTAssertEqual(system, 2, accuracy: 0.3)
        let mic = try await duration(folder.appendingPathComponent("Я.m4a"))
        XCTAssertEqual(mic, 1, accuracy: 0.3, "оборванный кусок потерян, закрытый — сохранён")
        XCTAssertTrue(MeetingFiles.parts(in: folder, track: MeetingFiles.systemTrack).isEmpty)
        XCTAssertTrue(MeetingFiles.parts(in: folder, track: MeetingFiles.micTrack).isEmpty)
        XCTAssertFalse(MeetingFiles.hasMarker(in: folder))

        // Повторный вызов безвреден.
        let again = await MeetingMerge.finalize(folder: folder)
        XCTAssertEqual(Set(again), [MeetingFiles.systemTrack, MeetingFiles.micTrack])
    }

    func testFinalizeWithOnlyGarbageClearsPartsAndMarker() async throws {
        MeetingFiles.writeMarker(in: folder, startedAt: Date(), microphone: false)
        try Data(repeating: 0x41, count: 100).write(to: MeetingFiles.partURL(folder: folder, track: MeetingFiles.systemTrack, index: 1))
        let ready = await MeetingMerge.finalize(folder: folder)
        XCTAssertTrue(ready.isEmpty)
        XCTAssertTrue(MeetingFiles.parts(in: folder, track: MeetingFiles.systemTrack).isEmpty, "мусор не копится и не повторяется при каждом запуске")
        XCTAssertFalse(MeetingFiles.hasMarker(in: folder))
    }

    /// Обычная (уже собранная) встреча не страдает от finalize.
    func testFinalizeLeavesFinishedMeetingAlone() async throws {
        try writeTone(to: folder.appendingPathComponent("Собеседники.m4a"), seconds: 1)
        let ready = await MeetingMerge.finalize(folder: folder)
        XCTAssertEqual(ready, [MeetingFiles.systemTrack])
        let seconds = try await duration(folder.appendingPathComponent("Собеседники.m4a"))
        XCTAssertEqual(seconds, 1, accuracy: 0.2)
    }

    // MARK: - MAJOR-2: одна склейка на папку, атомарная замена

    /// Две склейки одной папки одновременно (восстановление и «Расшифровать»): один файл, звук на месте, куски удалены.
    func testParallelFinalizeOfOneFolderKeepsTheRecording() async throws {
        for index in 1...3 { try writeTone(to: MeetingFiles.partURL(folder: folder, track: MeetingFiles.systemTrack, index: index), seconds: 1) }
        MeetingFiles.writeMarker(in: folder, startedAt: Date(), microphone: false)
        let folder = self.folder!
        async let first = MeetingMerge.finalize(folder: folder)
        async let second = MeetingMerge.finalize(folder: folder)
        let results = await [first, second]
        XCTAssertEqual(results, [[MeetingFiles.systemTrack], [MeetingFiles.systemTrack]], "второй вызов получил результат первого")
        let target = folder.appendingPathComponent("\(MeetingFiles.systemTrack).m4a")
        let total = try await duration(target)
        XCTAssertEqual(total, 3, accuracy: 0.3)
        XCTAssertEqual(MeetingFiles.parts(in: folder, track: MeetingFiles.systemTrack), [])
        XCTAssertFalse(MeetingFiles.hasMarker(in: folder))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains(".merging") }
        XCTAssertEqual(leftovers, [], "временный файл не остаётся")
    }

    /// Готовый файл не удаляется, если склеивать нечего (нечитаемые куски): раньше `target` удалялся до проверки.
    func testExistingTrackSurvivesFailedMerge() async throws {
        let target = folder.appendingPathComponent("Я.m4a")
        try writeTone(to: target, seconds: 2)
        let broken = MeetingFiles.partURL(folder: folder, track: "Я", index: 1)
        try Data(repeating: 0x41, count: 5_000).write(to: broken)
        do {
            _ = try await MeetingMerge.merge(parts: [broken], to: target)
            XCTFail("нечитаемый кусок не склеивается")
        } catch {}
        let seconds = try await duration(target)
        XCTAssertEqual(seconds, 2, accuracy: 0.3, "прежняя дорожка на месте")
    }

    /// Склейка поверх прежнего файла заменяет его целиком (переименованием), без временных файлов рядом.
    func testMergeReplacesExistingTargetAtomically() async throws {
        let target = folder.appendingPathComponent("Я.m4a")
        try writeTone(to: target, seconds: 5)
        let parts = (1...2).map { MeetingFiles.partURL(folder: folder, track: "Я", index: $0) }
        for part in parts { try writeTone(to: part, seconds: 1) }
        let used = try await MeetingMerge.merge(parts: parts, to: target)
        XCTAssertEqual(used, 2)
        let total = try await duration(target)
        XCTAssertEqual(total, 2, accuracy: 0.3)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(names.contains { $0.contains(".merging") })
    }

    func testFinalizeOfDifferentFoldersRunsIndependently() async throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("meet-merge-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try writeTone(to: MeetingFiles.partURL(folder: folder, track: "Я", index: 1), seconds: 1)
        try writeTone(to: MeetingFiles.partURL(folder: other, track: "Я", index: 1), seconds: 1)
        let folder = self.folder!
        async let a = MeetingMerge.finalize(folder: folder)
        async let b = MeetingMerge.finalize(folder: other)
        let results = await [a, b]
        XCTAssertEqual(results, [["Я"], ["Я"]])
    }
}

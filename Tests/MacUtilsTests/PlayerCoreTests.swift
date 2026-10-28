import AVFoundation
import XCTest
@testable import MacUtils
@testable import MUAudio
@testable import MUVideoPlayer

/// Детерминированный генератор для перемешивания в тестах.
struct PlayerTestRandom: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Этап 2 плеера: очередь и позиции — чистые модели.
final class PlaylistTests: XCTestCase {
    private func urls(_ names: String...) -> [URL] { names.map { URL(fileURLWithPath: "/demo/\($0).mp4") } }
    private func names(_ playlist: Playlist) -> [String] { playlist.items.map { $0.url.deletingPathExtension().lastPathComponent } }

    func testNewFilesGoAfterCurrentAndDuplicatesAreNotAdded() {
        var playlist = Playlist()
        let first = playlist.insertAfterCurrent(urls("a", "b", "c"))
        XCTAssertEqual(names(playlist), ["a", "b", "c"])
        playlist.select(try! XCTUnwrap(first).id)
        let added = playlist.insertAfterCurrent(urls("x", "y"))
        XCTAssertEqual(names(playlist), ["a", "x", "y", "b", "c"], "после текущего, по порядку")
        XCTAssertEqual(added?.url.lastPathComponent, "x.mp4")
        let again = playlist.insertAfterCurrent(urls("c"))
        XCTAssertEqual(playlist.count, 5, "уже открытый файл не дублируется")
        XCTAssertEqual(again?.url.lastPathComponent, "c.mp4", "к нему переходим")
    }

    func testRepeatModes() {
        var playlist = Playlist()
        playlist.append(urls("a", "b"))
        playlist.select(playlist.items[1].id)
        XCTAssertNil(playlist.next(automatic: true), "без повтора — после последнего ничего")
        XCTAssertFalse(playlist.hasNext)
        playlist.repeatMode = .all
        XCTAssertEqual(playlist.next(automatic: true)?.url.lastPathComponent, "a.mp4", "весь список — по кругу")
        playlist.repeatMode = .one
        XCTAssertEqual(playlist.next(automatic: true)?.id, playlist.current?.id, "один файл — он же снова")
        XCTAssertEqual(playlist.next(automatic: false)?.url.lastPathComponent, "a.mp4", "кнопка «Дальше» при повторе одного идёт дальше")
        XCTAssertEqual(Playlist.Repeat.off.next, .all)
        XCTAssertEqual(Playlist.Repeat.all.next, .one)
        XCTAssertEqual(Playlist.Repeat.one.next, .off)
    }

    func testShuffleKeepsCurrentFirstAndVisitsEveryone() {
        var playlist = Playlist()
        playlist.append(urls("a", "b", "c", "d", "e"))
        playlist.select(playlist.items[2].id)
        var random = PlayerTestRandom(1)
        playlist.shuffle(using: &random)
        XCTAssertTrue(playlist.isShuffled)
        var seen = [playlist.current!.url.lastPathComponent]
        while let next = playlist.next(automatic: true) {
            seen.append(next.url.lastPathComponent)
            playlist.select(next.id)
        }
        XCTAssertEqual(seen.first, "c.mp4")
        XCTAssertEqual(Set(seen).count, 5, "все по одному разу")
        playlist.unshuffle()
        XCTAssertFalse(playlist.isShuffled)
    }

    func testRemoveCurrentSelectsNeighbour() {
        var playlist = Playlist()
        playlist.append(urls("a", "b", "c"))
        playlist.select(playlist.items[1].id)
        playlist.remove(playlist.items[1].id)
        XCTAssertEqual(playlist.current?.url.lastPathComponent, "c.mp4")
        playlist.remove(playlist.items[1].id)
        XCTAssertEqual(playlist.current?.url.lastPathComponent, "a.mp4", "удалили последний — предыдущий")
        playlist.remove(playlist.items[0].id)
        XCTAssertNil(playlist.current)
        XCTAssertTrue(playlist.isEmpty)
    }

    func testMoveLikeListOnMove() {
        var playlist = Playlist()
        playlist.append(urls("a", "b", "c", "d"))
        playlist.move(fromOffsets: [0], toOffset: 3)
        XCTAssertEqual(names(playlist), ["b", "c", "a", "d"])
        playlist.move(fromOffsets: [3], toOffset: 0)
        XCTAssertEqual(names(playlist), ["d", "b", "c", "a"])
        playlist.move(fromOffsets: [1, 2], toOffset: 4)
        XCTAssertEqual(names(playlist), ["d", "a", "b", "c"])
    }

    func testPositionTitle() {
        var playlist = Playlist()
        playlist.append(urls("a"))
        playlist.select(playlist.items[0].id)
        XCTAssertNil(playlist.positionTitle, "один файл — без «1 из 1»")
        playlist.append(urls("b", "c"))
        XCTAssertEqual(playlist.positionTitle, "1 из 3")
    }

    func testPreviousWrapsOnlyWithRepeat() {
        var playlist = Playlist()
        playlist.append(urls("a", "b"))
        playlist.select(playlist.items[0].id)
        XCTAssertNil(playlist.previous())
        playlist.repeatMode = .all
        XCTAssertEqual(playlist.previous()?.url.lastPathComponent, "b.mp4")
    }
}

final class PositionStoreTests: XCTestCase {
    func testRulesThirtySecondsAndNinetyFivePercent() {
        XCTAssertFalse(PositionStore.shouldRemember(position: 29, duration: 3600), "меньше 30 с — сначала")
        XCTAssertTrue(PositionStore.shouldRemember(position: 30, duration: 3600))
        XCTAssertTrue(PositionStore.shouldRemember(position: 3420, duration: 3600), "ровно 95 %")
        XCTAssertFalse(PositionStore.shouldRemember(position: 3421, duration: 3600), "досмотрели")
        XCTAssertFalse(PositionStore.shouldRemember(position: .nan, duration: 3600))
        XCTAssertFalse(PositionStore.shouldRemember(position: 40, duration: 0))
        XCTAssertTrue(PositionStore.isFinished(position: 3500, duration: 3600))
    }

    func testRecordResumeAndForget() {
        let store = PositionStore(file: nil)
        store.record(key: "k", path: "/a.mp4", position: 754, duration: 2890)
        XCTAssertEqual(store.resumePosition(for: "k"), 754)
        store.record(key: "k", path: "/a.mp4", position: 10, duration: 2890)
        XCTAssertNil(store.resumePosition(for: "k"), "отмотали в начало — запись убрана")
        XCTAssertTrue(store.entries.isEmpty, "меньше 30 с — не пишем")
        store.record(key: "k", path: "/a.mp4", position: 2880, duration: 2890)
        XCTAssertTrue(store.entries.isEmpty, "больше 95 % — не пишем")
    }

    func testOverwrittenFileStartsOver() {
        let store = PositionStore(file: nil)
        let old = PositionStore.key(path: "/a.mp4", size: 100, modified: Date(timeIntervalSince1970: 1000))
        let new = PositionStore.key(path: "/a.mp4", size: 100, modified: Date(timeIntervalSince1970: 2000))
        store.record(key: old, path: "/a.mp4", position: 120, duration: 600)
        XCTAssertNil(store.resumePosition(for: new), "другое время изменения — другой файл")
        store.record(key: new, path: "/a.mp4", position: 200, duration: 600)
        XCTAssertEqual(store.entries.count, 1, "старая запись того же пути заменена")
    }

    func testLRUKeepsFiveHundredNewest() {
        let store = PositionStore(file: nil)
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<510 {
            store.record(key: "k\(index)", path: "/\(index).mp4", position: 60, duration: 600, now: start.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(store.entries.count, PositionStore.limit)
        XCTAssertNil(store.resumePosition(for: "k0"), "старые — первыми")
        XCTAssertEqual(store.resumePosition(for: "k509"), 60)
    }

    func testPersistsToFile() throws {
        let folder = try DemoVideo.makeFolder()
        defer { DemoVideo.cleanup(folder) }
        let file = folder.appendingPathComponent("Player/positions.json")
        PositionStore(file: file).record(key: "k", path: "/a.mp4", position: 90, duration: 600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(PositionStore(file: file).resumePosition(for: "k"), 90)
        // Без записи — файла нет.
        let other = folder.appendingPathComponent("Other/positions.json")
        PositionStore(file: other).record(key: "k", path: "/a.mp4", position: 5, duration: 600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    func testKeyFollowsFileOnDisk() throws {
        let folder = try DemoVideo.makeFolder()
        defer { DemoVideo.cleanup(folder) }
        let url = folder.appendingPathComponent("a.mp4")
        try Data([1, 2, 3]).write(to: url)
        let first = try XCTUnwrap(PositionStore.key(for: url))
        XCTAssertTrue(first.contains("|3|"), "размер в ключе")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: url.path)
        XCTAssertNotEqual(PositionStore.key(for: url), first)
        XCTAssertNil(PositionStore.key(for: folder.appendingPathComponent("нет.mp4")))
    }

    func testDefaultLocation() {
        XCTAssertTrue(PositionStore.defaultFile.path.hasSuffix("Application Support/Mac Utils/Player/positions.json"))
    }
}

final class PlayerFormatTests: XCTestCase {
    func testRates() {
        XCTAssertEqual(PlaybackRate.clamp(0.1), 0.25)
        XCTAssertEqual(PlaybackRate.clamp(9), 4)
        XCTAssertEqual(PlaybackRate.clamp(1.1), 1)
        XCTAssertEqual(PlaybackRate.stepped(1, by: 1), 1.25)
        XCTAssertEqual(PlaybackRate.stepped(0.25, by: -1), 0.25)
        XCTAssertEqual(PlaybackRate.stepped(4, by: 1), 4)
        XCTAssertEqual(PlaybackRate.title(1), "1×")
        XCTAssertEqual(PlaybackRate.title(1.25), "1,25×")
        XCTAssertEqual(PlaybackRate.title(0.5), "0,5×")
    }

    func testTime() {
        XCTAssertEqual(PlayerFormat.time(0), "0:00")
        XCTAssertEqual(PlayerFormat.time(1390.7), "23:10")
        XCTAssertEqual(PlayerFormat.time(3723), "1:02:03")
        XCTAssertEqual(PlayerFormat.remaining(1390, of: 2890), "−25:00")
        XCTAssertEqual(PlayerFormat.timecode(1390.21, fps: 24), "00:23:10:05")
        XCTAssertEqual(PlayerFormat.time(.nan), "0:00")
    }

    func testMediaKinds() {
        XCTAssertTrue(PlayerMedia.isUnsupported(URL(fileURLWithPath: "/a.MKV")))
        XCTAssertTrue(PlayerMedia.isMedia(URL(fileURLWithPath: "/a.mp4")))
        XCTAssertTrue(PlayerMedia.isMedia(URL(fileURLWithPath: "/a.m4a")))
        XCTAssertTrue(PlayerMedia.isMedia(URL(fileURLWithPath: "/a.webm")), "MKV/WebM — в плейлист, с пометкой")
        XCTAssertFalse(PlayerMedia.isMedia(URL(fileURLWithPath: "/a.srt")))
        XCTAssertFalse(PlayerMedia.isMedia(URL(fileURLWithPath: "/a.txt")))
        XCTAssertEqual(PlayerMedia.formatName(URL(fileURLWithPath: "/a.webm")), "WebM")
        XCTAssertFalse(PlayerMedia.openWithExtensions.contains("mkv"), "MKV — со второй версии")
    }

    func testFolderExpandsInNaturalOrder() throws {
        let folder = try DemoVideo.makeFolder()
        defer { DemoVideo.cleanup(folder) }
        for name in ["Серия 10.mp4", "Серия 2.mp4", "Серия 1.mov", "notes.txt", ".hidden.mp4"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        let expanded = PlayerMedia.expand([folder]).map(\.lastPathComponent)
        XCTAssertEqual(expanded, ["Серия 1.mov", "Серия 2.mp4", "Серия 10.mp4"])
    }

    func testCodecNames() {
        XCTAssertEqual(CodecDescription.video(kCMVideoCodecType_H264), "H.264")
        XCTAssertEqual(CodecDescription.video(kCMVideoCodecType_HEVC), "HEVC")
        XCTAssertEqual(CodecDescription.audio(kAudioFormatMPEG4AAC), "AAC")
        XCTAssertEqual(CodecDescription.channels(6), "5.1")
        XCTAssertEqual(CodecDescription.frameRate(24), "24 к/с")
        XCTAssertEqual(CodecDescription.frameRate(29.97), "29,97 к/с")
    }
}

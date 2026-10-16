import XCTest
@testable import MacUtils

final class NowPlayingSupportTests: XCTestCase {
    private func strings(_ lines: [Data]) -> [String] { lines.map { String(decoding: $0, as: UTF8.self) } }

    func testLineSplitInTheMiddleAcrossChunks() {
        var buffer = LineBuffer()
        XCTAssertEqual(strings(buffer.feed(Data(#"{"title":"A"#.utf8))), [])
        XCTAssertEqual(strings(buffer.feed(Data("B\"}\n{\"t".utf8))), [#"{"title":"AB"}"#])
        XCTAssertEqual(strings(buffer.feed(Data("\"}\n".utf8))), [#"{"t"}"#])
        XCTAssertEqual(buffer.pendingCount, 0)
    }

    func testMultilineChunkCRLFAndEmptyLines() {
        var buffer = LineBuffer()
        XCTAssertEqual(strings(buffer.feed(Data("one\r\n\n\ntwo\nthree".utf8))), ["one", "two"])
        XCTAssertEqual(strings(buffer.feed(Data("\n".utf8))), ["three"])
    }

    func testUTF8CharacterSplitAcrossChunks() {
        var buffer = LineBuffer()
        let bytes = Array("привет\n".utf8)
        XCTAssertEqual(strings(buffer.feed(Data(bytes[0..<3]))), [])
        XCTAssertEqual(strings(buffer.feed(Data(bytes[3...]))), ["привет"])
    }

    func testOverlongLineWithoutNewlineIsDroppedAndParsingRecovers() {
        var buffer = LineBuffer(maxLength: 16)
        XCTAssertEqual(strings(buffer.feed(Data(String(repeating: "x", count: 40).utf8))), [])
        XCTAssertEqual(buffer.pendingCount, 0, "мусор не копится")
        XCTAssertEqual(strings(buffer.feed(Data("yyy\nok\n".utf8))), ["ok"], "хвост мусорной строки отброшен, следующая принята")
        XCTAssertEqual(strings(buffer.feed(Data("good\n".utf8))), ["good"])
    }

    func testLongLineJustUnderLimitIsKept() {
        var buffer = LineBuffer(maxLength: 16)
        XCTAssertEqual(strings(buffer.feed(Data((String(repeating: "x", count: 16) + "\n").utf8))), [String(repeating: "x", count: 16)])
        XCTAssertEqual(strings(buffer.feed(Data((String(repeating: "x", count: 17) + "\n").utf8))), [], "длиннее лимита — отброшена")
    }

    func testResetDropsPartialLine() {
        var buffer = LineBuffer()
        _ = buffer.feed(Data("half".utf8))
        buffer.reset()
        XCTAssertEqual(strings(buffer.feed(Data("new\n".utf8))), ["new"])
    }

    func testArtworkHashIsStableAndContentBased() {
        let a = Data([1, 2, 3]), b = Data([1, 2, 3]), c = Data([1, 2, 4])
        XCTAssertEqual(ArtworkFingerprint.hash(a), ArtworkFingerprint.hash(b))
        XCTAssertNotEqual(ArtworkFingerprint.hash(a), ArtworkFingerprint.hash(c))
        XCTAssertEqual(ArtworkFingerprint.hash(a).count, 64)
    }

    func testArtworkIsStoredOnlyWhenContentChanges() {
        let h1 = ArtworkFingerprint.hash(Data([1])), h2 = ArtworkFingerprint.hash(Data([2]))
        XCTAssertTrue(ArtworkFingerprint.shouldStore(newHash: h1, lastStoredHash: nil))
        XCTAssertFalse(ArtworkFingerprint.shouldStore(newHash: h1, lastStoredHash: h1), "то же содержимое с каждым событием — не пишем")
        XCTAssertTrue(ArtworkFingerprint.shouldStore(newHash: h2, lastStoredHash: h1))
    }

    // MARK: ревью пакета 1: PermissionWatch (AppVolume)

    func testSilenceAloneNeedsTenSecondsToTrip() {
        var watch = PermissionWatch()
        for _ in 0..<(PermissionWatch.silentTicksToTrip - 1) { XCTAssertFalse(watch.record(anyPlaying: true, anySound: false)) }
        XCTAssertTrue(watch.record(anyPlaying: true, anySound: false))
        XCTAssertEqual(watch.silentTicks, 0, "после срабатывания счёт заново")
    }

    func testProvenPermissionNeverTripsOnLaterSilence() {
        var watch = PermissionWatch()
        XCTAssertFalse(watch.record(anyPlaying: true, anySound: true))
        XCTAssertTrue(watch.proven)
        for _ in 0..<100 { XCTAssertFalse(watch.record(anyPlaying: true, anySound: false), "пауза в разговоре — не отказ в разрешении") }
    }

    func testSilenceCounterRestartsWhenNothingPlaysOrSoundArrives() {
        var watch = PermissionWatch()
        for _ in 0..<5 { _ = watch.record(anyPlaying: true, anySound: false) }
        _ = watch.record(anyPlaying: false, anySound: false)
        XCTAssertEqual(watch.silentTicks, 0)
        for _ in 0..<5 { _ = watch.record(anyPlaying: true, anySound: false) }
        watch.reset()
        XCTAssertEqual(watch.silentTicks, 0)
        XCTAssertFalse(watch.proven)
    }
}

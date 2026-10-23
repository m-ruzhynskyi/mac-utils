import XCTest
@testable import MacUtils
@testable import MUMeetings

final class MeetingFilesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("meet-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testUniqueNameAddsSuffixOnlyWhenTaken() {
        XCTAssertEqual(MeetingFiles.uniqueName("2026-10-16 10.30", taken: { _ in false }), "2026-10-16 10.30")
        var taken: Set<String> = ["a", "a (2)", "a (3)"]
        XCTAssertEqual(MeetingFiles.uniqueName("a", taken: { taken.contains($0) }), "a (4)")
        taken = ["a"]
        XCTAssertEqual(MeetingFiles.uniqueName("a", taken: { taken.contains($0) }), "a (2)")
    }

    /// M4: вторая запись в ту же минуту не перезаписывает дорожки первой.
    func testUniqueFolderNeverReusesExistingMeeting() throws {
        let first = MeetingFiles.uniqueFolder(in: root, name: "2026-10-16 10.30")
        XCTAssertEqual(first.lastPathComponent, "2026-10-16 10.30")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = MeetingFiles.uniqueFolder(in: root, name: "2026-10-16 10.30")
        XCTAssertEqual(second.lastPathComponent, "2026-10-16 10.30 (2)")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        XCTAssertEqual(MeetingFiles.uniqueFolder(in: root, name: "2026-10-16 10.30").lastPathComponent, "2026-10-16 10.30 (3)")
    }

    func testPartNamingAndParsing() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        XCTAssertEqual(MeetingFiles.partURL(folder: folder, track: "Собеседники", index: 7).lastPathComponent, "Собеседники.part-007.m4a")
        XCTAssertEqual(MeetingFiles.partIndex(of: "Собеседники.part-007.m4a", track: "Собеседники"), 7)
        XCTAssertEqual(MeetingFiles.partIndex(of: "Я.part-1234.m4a", track: "Я"), 1234)
        XCTAssertNil(MeetingFiles.partIndex(of: "Собеседники.m4a", track: "Собеседники"))
        XCTAssertNil(MeetingFiles.partIndex(of: "Я.part-001.m4a", track: "Собеседники"), "кусок другой дорожки")
        XCTAssertNil(MeetingFiles.partIndex(of: "Я.part-.m4a", track: "Я"))
        XCTAssertNil(MeetingFiles.partIndex(of: "Я.part-1x.m4a", track: "Я"))
    }

    func testPartsAreSortedNumericallyAndNextIndexContinues() throws {
        for index in [10, 2, 1, 9] {
            try Data("x".utf8).write(to: MeetingFiles.partURL(folder: root, track: "Я", index: index))
        }
        try Data("x".utf8).write(to: MeetingFiles.partURL(folder: root, track: "Собеседники", index: 3))
        XCTAssertEqual(MeetingFiles.parts(in: root, track: "Я").map(\.lastPathComponent),
                       ["Я.part-001.m4a", "Я.part-002.m4a", "Я.part-009.m4a", "Я.part-010.m4a"])
        XCTAssertEqual(MeetingFiles.nextPartIndex(in: root, track: "Я"), 11)
        XCTAssertEqual(MeetingFiles.nextPartIndex(in: root, track: "Собеседники"), 4)
        XCTAssertEqual(MeetingFiles.nextPartIndex(in: root.appendingPathComponent("нет"), track: "Я"), 1, "после обрыва запись продолжает нумерацию")
    }

    func testMarkerLifecycleAndUnfinishedScan() throws {
        let done = root.appendingPathComponent("done"), broken = root.appendingPathComponent("broken")
        for folder in [done, broken] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        MeetingFiles.writeMarker(in: broken, startedAt: Date(), microphone: true)
        XCTAssertTrue(MeetingFiles.hasMarker(in: broken))
        XCTAssertFalse(MeetingFiles.hasMarker(in: done))
        XCTAssertEqual(MeetingFiles.unfinished(in: root).map(\.lastPathComponent), ["broken"])
        MeetingFiles.removeMarker(in: broken)
        XCTAssertTrue(MeetingFiles.unfinished(in: root).isEmpty)
        MeetingFiles.removeMarker(in: broken) // повторное снятие безвредно
    }

    func testChunkRotation() {
        XCTAssertFalse(MeetingChunking.shouldRotate(frames: 48_000 * 299, sampleRate: 48_000))
        XCTAssertTrue(MeetingChunking.shouldRotate(frames: 48_000 * 300, sampleRate: 48_000))
        XCTAssertTrue(MeetingChunking.shouldRotate(frames: 100, sampleRate: 10, seconds: 5))
        XCTAssertFalse(MeetingChunking.shouldRotate(frames: 1_000_000, sampleRate: 0), "нулевая частота не вращает")
        XCTAssertEqual(MeetingChunking.seconds, 300)
    }

    func testStallThreshold() {
        XCTAssertFalse(MeetingStall.isStalled(secondsSinceAudio: 0))
        XCTAssertFalse(MeetingStall.isStalled(secondsSinceAudio: 10))
        XCTAssertTrue(MeetingStall.isStalled(secondsSinceAudio: 10.5))
    }
}

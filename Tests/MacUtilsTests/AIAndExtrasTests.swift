@testable import MacUtils
import XCTest

final class AIAndExtrasTests: XCTestCase {
    func testJSONInsideChatter() {
        let json = AIParsing.jsonObject(in: "Вот ответ:\n```json\n{\"folder\": \"Lab\"}\n```")
        XCTAssertEqual(json?["folder"] as? String, "Lab")
        XCTAssertNil(AIParsing.jsonObject(in: "нет json"))
    }

    func testFileNameCleanup() {
        XCTAssertEqual(AIParsing.fileName(from: "«Счёт за интернет.»\nПояснение"), "Счёт за интернет")
        XCTAssertEqual(AIParsing.fileName(from: "a/b: c"), "a b c")
        XCTAssertNil(AIParsing.fileName(from: "\"\""))
    }

    func testCleanedTextAndEdges() {
        XCTAssertEqual(AIParsing.cleanedText("Исправленный текст: \"Привет\""), "Привет")
        XCTAssertEqual(AIParsing.keepingEdges(of: "  превет \n", "Привет"), "  Привет \n")
    }

    func testBreakSchedule() {
        var schedule = BreakSchedule()
        XCTAssertFalse(schedule.tick(dt: 600, idle: 0, interval: 1200))
        XCTAssertTrue(schedule.tick(dt: 600, idle: 2, interval: 1200))
        // Отошёл на 5 минут — перерыв засчитан.
        XCTAssertFalse(schedule.tick(dt: 15, idle: 400, interval: 1200))
        XCTAssertEqual(schedule.worked, 0)
        schedule.reset(postpone: 300)
        XCTAssertEqual(schedule.worked, -300)
    }

    func testWarmScheduleOverMidnight() {
        XCTAssertEqual(WarmSchedule.level(hour: 12, from: 21, to: 7), 0)
        XCTAssertEqual(WarmSchedule.level(hour: 23, from: 21, to: 7), 1)
        XCTAssertEqual(WarmSchedule.level(hour: 21.5, from: 21, to: 7), 0.5, accuracy: 0.001)
        XCTAssertEqual(WarmSchedule.level(hour: 6.75, from: 21, to: 7), 0.25, accuracy: 0.001)
        let gains = WarmSchedule.gains(strength: 1)
        XCTAssertEqual(gains.red, 1)
        XCTAssertLessThan(gains.blue, gains.green)
    }

    func testWindowKeysAndSignature() {
        XCTAssertEqual(WindowLayoutRules.keys(bundleID: "a", titles: ["x", "x", "y"]), ["a|x", "a|x#1", "a|y"])
        XCTAssertEqual(WindowLayoutRules.signature(["b", "a"]), WindowLayoutRules.signature(["a", "b"]))
    }

    func testMeetingMergeAndChunks() {
        let lines = [
            TranscriptLine(start: 5, speaker: "Я", text: "привет"),
            TranscriptLine(start: 1, speaker: "Собеседники", text: "добрый день"),
            TranscriptLine(start: 7, speaker: "Я", text: "начнём"),
        ]
        let merged = MeetingText.merge(lines)
        XCTAssertEqual(merged.map(\.speaker), ["Собеседники", "Я"])
        XCTAssertEqual(merged[1].text, "привет начнём")
        XCTAssertEqual(MeetingText.format(merged).split(separator: "\n").first, "[00:01] Собеседники: добрый день")
        XCTAssertEqual(MeetingText.timestamp(3725), "1:02:05")
        XCTAssertEqual(MeetingText.chunks("aaaa\nbbbb\ncccc", limit: 9), ["aaaa\nbbbb", "cccc"])
    }

    func testShotRename() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Снимок экрана 2026-10-07 в 20.15.03.png")
        try Data([1]).write(to: file)
        let renamed = ShotNamer.renamed(file, to: "Счёт за интернет")
        XCTAssertEqual(renamed?.lastPathComponent, "Счёт за интернет 20.15.03.png")
    }
}

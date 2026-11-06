@testable import MacUtils
import XCTest
@testable import MUCore
@testable import MUWellbeing
@testable import MUMeetings
@testable import MUUpdate
@testable import MUWindowSnap
@testable import MUScreenShare
@testable import MUScreenshot
@testable import MUTextEditor

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

final class WhisperOutputTests: XCTestCase {
    func testParsesSegmentsAndDropsNoise() {
        let json = """
        {"result": {"language": "uk"}, "transcription": [
          {"offsets": {"from": 1500, "to": 3000}, "text": " Розноситься прибуткова накладна."},
          {"offsets": {"from": 4000, "to": 5000}, "text": " [Музыка]"},
          {"offsets": {"from": 6000, "to": 7000}, "text": " ..."}
        ]}
        """
        let lines = WhisperOutput.lines(fromJSON: Data(json.utf8), speaker: "Собеседники")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].start, 1.5)
        XCTAssertEqual(lines[0].text, "Розноситься прибуткова накладна.")
    }

    func testProgressAndLanguage() {
        XCTAssertEqual(WhisperOutput.progress(in: "whisper_print_progress_callback: progress =  37%"), 37)
        XCTAssertNil(WhisperOutput.progress(in: "no progress here"))
        XCTAssertEqual(WhisperOutput.language("uk_UA"), "uk")
        XCTAssertEqual(WhisperOutput.language("auto"), "auto")
    }
}

final class ChangelogTests: XCTestCase {
    /// Info.plist — единственный источник MAJOR.MINOR (docs/VERSIONING.md): PATCH в файле всегда 0,
    /// а для линии есть запись в Changelog (иначе «Что нового» не покажется).
    private func infoPlist() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testInfoPlistVersionIsMajorMinorZero() throws {
        let short = try XCTUnwrap(infoPlist()["CFBundleShortVersionString"] as? String)
        let parts = short.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 3, "ожидается MAJOR.MINOR.PATCH, а в файле \(short)")
        XCTAssertTrue(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }, "только цифры: \(short)")
        XCTAssertEqual(parts.last.map(String.init), "0", "PATCH в Info.plist всегда 0, его считает сборка: \(short)")
        if parts.count == 3, let minor = Int(parts[1]) { XCTAssertLessThanOrEqual(minor, 999) }
    }

    @MainActor func testChangelogHasEntryForInfoPlistLine() throws {
        let short = try XCTUnwrap(infoPlist()["CFBundleShortVersionString"] as? String)
        let line = Changelog.family(short)
        XCTAssertTrue(Changelog.releases.contains { $0.version == line },
                      "нет записи Release(version: \"\(line)\") в Changelog.releases — «Что нового» не откроется")
    }

    @MainActor func testChangelogVersionsAreMajorMinorAndUnique() {
        let versions = Changelog.releases.map(\.version)
        XCTAssertEqual(Set(versions).count, versions.count)
        for version in versions {
            XCTAssertEqual(version.split(separator: ".").count, 2, "запись Changelog — только MAJOR.MINOR: \(version)")
        }
    }

    @MainActor func testChangelogIsNewestFirst() {
        let numbers = Changelog.releases.map { $0.version.split(separator: ".").compactMap { Int($0) } }
        for (newer, older) in zip(numbers, numbers.dropFirst()) {
            XCTAssertTrue(older.lexicographicallyPrecedes(newer), "\(newer) должна идти раньше \(older)")
        }
    }

    @MainActor func testFamilyAndOrder() throws {
        XCTAssertEqual(Changelog.family("1.3.4"), "1.3")
        XCTAssertEqual(Changelog.family("1.3"), "1.3")
        let short = try XCTUnwrap(infoPlist()["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(Changelog.releases.first?.version, Changelog.family(short))
        XCTAssertTrue(Updater.isVersion("1.3.0", newerThan: "1.2.118"))
    }
}

final class ShareCodeTests: XCTestCase {
    func testCodeAndURL() {
        XCTAssertNil(ShareCode.normalized("123 456"), "6-значные ID строгий relay не принимает")
        XCTAssertNil(ShareCode.normalized("12345"))
        XCTAssertEqual(ShareCode.display("123456"), "123 456")
        XCTAssertEqual(ShareCode.url(server: "https://relay.example.dev/", code: "123456", role: "host")?.absoluteString,
                       "wss://relay.example.dev/room/123456?role=host")
        let viewer = ShareCode.url(server: "http://127.0.0.1:8787", code: "1234567890", role: "viewer")?.absoluteString ?? ""
        XCTAssertTrue(viewer.hasPrefix("ws://127.0.0.1:8787/room/1234567890?role=viewer&viewer="))
        XCTAssertEqual(ShareCode.display("1234567890"), "123 456 7890")
        XCTAssertEqual(ShareCode.normalized("123 456 7890"), "1234567890")
        XCTAssertEqual(ShareCode.statusURL(server: "https://relay.dev/", ids: ["1", "2"])?.absoluteString, "https://relay.dev/status?ids=1,2")
    }
}

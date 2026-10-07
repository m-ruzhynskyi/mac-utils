import XCTest
@testable import MacUtils

final class ScreenshotLibraryTests: XCTestCase {
    func testFolderByDayAndApp() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 7; components.hour = 12
        let date = Calendar.current.date(from: components)!
        let folder = ShotLibraryRules.folder(root: URL(fileURLWithPath: "/Users/x/Desktop"), date: date, app: "Safari")
        XCTAssertEqual(folder.path, "/Users/x/Desktop/Снимки экрана/2026-10-07/Safari")
        XCTAssertEqual(ShotLibraryRules.sanitized(""), "Другое")
        XCTAssertEqual(ShotLibraryRules.sanitized("A/B: C"), "A-B- C")
    }

    func testSearch() {
        let record = ShotRecord(path: "/s/Снимок экрана.png", date: Date(), app: "Telegram", text: "Привет, это счёт за октябрь")
        XCTAssertTrue(ShotLibraryRules.matches(record, query: ""))
        XCTAssertTrue(ShotLibraryRules.matches(record, query: "счёт"))
        XCTAssertTrue(ShotLibraryRules.matches(record, query: "telegram ОКТЯБРЬ"))
        XCTAssertFalse(ShotLibraryRules.matches(record, query: "счёт ноябрь"))
    }

    func testSystemScreenshotNames() {
        XCTAssertTrue(ShotLibraryRules.isSystemScreenshot("Screenshot 2026-10-07 at 12.00.00.png"))
        XCTAssertTrue(ShotLibraryRules.isSystemScreenshot("Снимок экрана 2026-10-07 в 12.00.00.png"))
        XCTAssertFalse(ShotLibraryRules.isSystemScreenshot("Screenshot notes.txt"))
        XCTAssertFalse(ShotLibraryRules.isSystemScreenshot("photo.png"))
    }

    func testVideosRecognized() {
        XCTAssertTrue(ShotLibraryRules.isVideo(URL(fileURLWithPath: "/s/Запись экрана.mp4")))
        XCTAssertTrue(ShotLibraryRules.isVideo(URL(fileURLWithPath: "/s/clip.GIF")))
        XCTAssertFalse(ShotLibraryRules.isVideo(URL(fileURLWithPath: "/s/shot.png")))
    }
}

final class CaptureNameTests: XCTestCase {
    func testCaptureNames() {
        XCTAssertTrue(ShotLibraryRules.isCapture("Recording 2026-09-30 at 13-36-32.mp4"))
        XCTAssertTrue(ShotLibraryRules.isCapture("Запись экрана 2026-10-07 в 14.31.55.mp4"))
        XCTAssertTrue(ShotLibraryRules.isCapture("Screenshot 2026-10-02 at 15-45-08.png"))
        XCTAssertFalse(ShotLibraryRules.isCapture("holiday.png"))
        XCTAssertFalse(ShotLibraryRules.isCapture("Screenshot notes.txt"))
    }
}

final class ShotExpiryTests: XCTestCase {
    func testExpiry() {
        let now = Date()
        let old = ShotRecord(path: "/s/a.png", date: now.addingTimeInterval(-10 * 86_400), app: "A", text: "")
        let fresh = ShotRecord(path: "/s/b.png", date: now.addingTimeInterval(-2 * 86_400), app: "A", text: "")
        XCTAssertTrue(ShotLibraryRules.isExpired(old, days: 7, now: now))
        XCTAssertFalse(ShotLibraryRules.isExpired(fresh, days: 7, now: now))
        XCTAssertFalse(ShotLibraryRules.isExpired(old, days: 0, now: now), "0 — никогда")
    }
}

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
}

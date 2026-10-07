import XCTest
@testable import MacUtils

@MainActor
final class UpdaterTests: XCTestCase {
    func testNewerVersions() {
        XCTAssertTrue(Updater.isVersion("1.2.31", newerThan: "1.2.30"))
        XCTAssertTrue(Updater.isVersion("1.3.0", newerThan: "1.2.99"))
        XCTAssertTrue(Updater.isVersion("1.2.10", newerThan: "1.2.9"))
        XCTAssertTrue(Updater.isVersion("1.2.1", newerThan: "1.2"))
    }

    func testNotNewer() {
        XCTAssertFalse(Updater.isVersion("1.2.30", newerThan: "1.2.30"))
        XCTAssertFalse(Updater.isVersion("1.2.9", newerThan: "1.2.10"))
        XCTAssertFalse(Updater.isVersion("1.2", newerThan: "1.2.0"))
    }
}

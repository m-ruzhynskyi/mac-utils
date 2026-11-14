import ApplicationServices
@testable import MUHiddenScreen
import XCTest

/// Разбор AXValue (значения создаются локально, без запросов к программам) и признак блокировки экрана.
final class AXGeometryTests: XCTestCase {
    func testPointAndSizeAreTypeChecked() throws {
        var point = CGPoint(x: 208, y: 147)
        var size = CGSize(width: 1217, height: 724)
        let pointValue = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        let sizeValue = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        XCTAssertEqual(AXGeometry.point(pointValue), CGPoint(x: 208, y: 147))
        XCTAssertEqual(AXGeometry.size(sizeValue), CGSize(width: 1217, height: 724))
        XCTAssertNil(AXGeometry.point(sizeValue), "размер вместо позиции — не путаем")
        XCTAssertNil(AXGeometry.size(pointValue))
        XCTAssertNil(AXGeometry.point("208,147" as CFString), "не AXValue — nil, а не падение на as!")
        XCTAssertNil(AXGeometry.point(nil))
    }

    func testScreenLockKeys() {
        XCTAssertTrue(ScreenLock.isLocked(["CGSSessionScreenIsLocked": true, kCGSessionOnConsoleKey as String: true]))
        XCTAssertTrue(ScreenLock.isLocked([kCGSessionOnConsoleKey as String: false]), "сессия не у консоли")
        XCTAssertFalse(ScreenLock.isLocked([kCGSessionOnConsoleKey as String: true]))
        XCTAssertFalse(ScreenLock.isLocked([:]))
    }
}

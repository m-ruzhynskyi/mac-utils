import XCTest
@testable import MacUtils

final class ShakeDetectorTests: XCTestCase {
    /// Точки «маха» влево-вправо с шагом 10 pt.
    private func strokes(_ count: Int, amplitude: CGFloat, start time: TimeInterval = 0, dt: TimeInterval = 0.01) -> [(CGFloat, TimeInterval)] {
        var points: [(CGFloat, TimeInterval)] = []
        var x: CGFloat = 500, t = time, direction: CGFloat = 1
        for _ in 0..<count {
            var travelled: CGFloat = 0
            while travelled < amplitude {
                x += 10 * direction
                travelled += 10
                t += dt
                points.append((x, t))
            }
            direction = -direction
        }
        return points
    }

    func testFastShakeDetected() {
        var detector = ShakeDetector()
        let detected = strokes(6, amplitude: 60).contains { detector.add(x: $0.0, time: $0.1) }
        XCTAssertTrue(detected)
    }

    func testSlowOrSmallMovesIgnored() {
        var small = ShakeDetector()
        XCTAssertFalse(strokes(8, amplitude: 10).contains { small.add(x: $0.0, time: $0.1) }, "мелкое дрожание")
        var slow = ShakeDetector()
        XCTAssertFalse(strokes(6, amplitude: 60, dt: 0.1).contains { slow.add(x: $0.0, time: $0.1) }, "медленно")
        var straight = ShakeDetector()
        XCTAssertFalse((0..<100).contains { straight.add(x: CGFloat($0) * 10, time: Double($0) * 0.01) }, "по прямой")
    }
}

final class ShortcutFormatTests: XCTestCase {
    func testModifiers() {
        XCTAssertEqual(ShortcutFormat.modifiers(0), "⌘")
        XCTAssertEqual(ShortcutFormat.modifiers(1), "⇧⌘")
        XCTAssertEqual(ShortcutFormat.modifiers(2 | 4), "⌃⌥⌘")
        XCTAssertEqual(ShortcutFormat.modifiers(8 | 4), "⌃", "без ⌘")
    }

    func testKeys() {
        XCTAssertEqual(ShortcutFormat.key(char: "n", glyph: nil), "N")
        XCTAssertEqual(ShortcutFormat.key(char: " ", glyph: nil), "Пробел")
        XCTAssertEqual(ShortcutFormat.key(char: nil, glyph: 0x64), "←")
        XCTAssertEqual(ShortcutFormat.key(char: "", glyph: 0x17), "⌫")
        XCTAssertNil(ShortcutFormat.key(char: nil, glyph: nil))
    }
}

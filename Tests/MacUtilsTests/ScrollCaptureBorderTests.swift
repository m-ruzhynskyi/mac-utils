import AppKit
import XCTest
@testable import MacUtils

/// Рамка длинного снимка (1.6.6: красная пунктирная рамка в нижнем куске снимка). Панель — далеко за экраном;
/// рисуется только её собственный вид, экран не снимается.
@MainActor
final class ScrollCaptureBorderTests: XCTestCase {
    /// Линия рамки — только в полях панели, снаружи области съёмки; панель без анимации появления: анимацию рисует
    /// система (фильтр захвата исключает лишь окна приложения), и рамка в ней меньше настоящей — внутри области.
    func testBorderNeverDrawsInsideTheCapturedArea() throws {
        let area = NSRect(x: -20_000, y: -20_000, width: 400, height: 240)
        let panel = ScrollCapture.makeBorderPanel(around: area)
        defer { panel.orderOut(nil) }
        XCTAssertEqual(panel.animationBehavior, .none)
        let margin = ScrollCapture.borderMargin
        XCTAssertEqual(panel.frame, area.insetBy(dx: -margin, dy: -margin))
        // Первый кадр — не в момент показа панелей.
        XCTAssertGreaterThanOrEqual(ScrollCapture.firstFrameDelay, 0.25)

        let view = try XCTUnwrap(panel.contentView)
        panel.orderBack(nil)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let cache = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: cache)
        let scale = CGFloat(cache.pixelsWide) / view.bounds.width
        let edge = Int((margin * scale).rounded())
        var inside = 0, ring = 0
        for y in 0..<cache.pixelsHigh {
            for x in 0..<cache.pixelsWide where (cache.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                let within = x >= edge && x < cache.pixelsWide - edge && y >= edge && y < cache.pixelsHigh - edge
                if within { inside += 1 } else { ring += 1 }
            }
        }
        XCTAssertEqual(inside, 0, "точки рамки внутри области съёмки")
        XCTAssertGreaterThan(ring, 0, "рамка не нарисована")
    }
}

import CoreGraphics
import XCTest
@testable import MacUtils

@MainActor
final class CollageLayoutTests: XCTestCase {
    private func images(_ count: Int, width: Int = 800, height: Int = 500) -> [CGImage] {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        return Array(repeating: image, count: count)
    }

    func testAutoColumns() {
        XCTAssertEqual(ShotComposer.columnCount(for: images(1), layout: .auto), 1)
        XCTAssertEqual(ShotComposer.columnCount(for: images(2), layout: .auto), 2)
        XCTAssertEqual(ShotComposer.columnCount(for: images(3), layout: .auto), 2)
        XCTAssertEqual(ShotComposer.columnCount(for: images(4), layout: .auto), 2)
        // 5+ — 2 или 3 колонки, что ближе к квадрату.
        XCTAssertEqual(ShotComposer.columnCount(for: images(6), layout: .auto), 2)
        XCTAssertEqual(ShotComposer.columnCount(for: images(9, width: 500, height: 500), layout: .auto), 3)
        XCTAssertEqual(ShotComposer.columnCount(for: images(6, width: 400, height: 800), layout: .auto), 3)
    }

    func testManualLayouts() {
        XCTAssertEqual(ShotComposer.columnCount(for: images(5), layout: .vertical), 1)
        XCTAssertEqual(ShotComposer.columnCount(for: images(5), layout: .horizontal), 5)
        XCTAssertEqual(ShotComposer.columnCount(for: images(9), layout: .grid), 3)
        XCTAssertEqual(ShotComposer.columnCount(for: images(5), layout: .grid), 3)
    }

    func testFourStepsMakeSquareishCanvas() {
        var options = ShotComposer.Options()
        options.layout = .auto
        options.unit = 1
        let collage = ShotComposer.compose(images(4), options: options)
        XCTAssertNotNil(collage)
        let ratio = Double(collage!.width) / Double(collage!.height)
        XCTAssertGreaterThan(ratio, 1.2)
        XCTAssertLessThan(ratio, 1.8)
    }
}

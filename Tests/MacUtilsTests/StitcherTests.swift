import CoreGraphics
import XCTest
@testable import MacUtils

final class StitcherTests: XCTestCase {
    /// Страница с «строками текста»: тёмные блоки разной длины на белом фоне.
    private func makePage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SeededGenerator(seed: 42)
        var y = 20
        while y < height - 40 {
            var x = 30
            while x < width - 60 {
                let w = Int.random(in: 8...60, using: &generator)
                context.setFillColor(CGColor(gray: 0.1, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: w, height: 14))
                x += w + 10
            }
            y += Int.random(in: 24...36, using: &generator)
        }
        return context.makeImage()!
    }

    func testStitchesScrolledFrames() {
        let page = makePage(width: 600, height: 3000)
        let frameHeight = 700
        var stitcher = Stitcher()
        var offset = 0
        var last = 0
        while offset + frameHeight <= page.height {
            let frame = page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: frameHeight))!
            let result = stitcher.add(frame)
            if offset == 0 {
                XCTAssertEqual(result, .first)
            } else {
                XCTAssertEqual(result, .appended, "offset \(offset)")
            }
            last = offset
            offset += 150
        }
        XCTAssertEqual(stitcher.height, last + frameHeight)
        XCTAssertEqual(stitcher.makeImage()?.height, last + frameHeight)
    }

    func testUnchangedFrameAddsNothing() {
        let page = makePage(width: 400, height: 1200)
        let frame = page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 500))!
        var stitcher = Stitcher()
        XCTAssertEqual(stitcher.add(frame), .first)
        XCTAssertEqual(stitcher.add(frame), .unchanged)
        XCTAssertEqual(stitcher.height, 500)
    }
}

/// Детерминированный генератор, чтобы тест не зависел от случайности.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

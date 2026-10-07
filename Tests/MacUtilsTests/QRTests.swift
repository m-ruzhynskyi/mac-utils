import XCTest
@testable import MacUtils

final class QRTests: XCTestCase {
    func testRoundTrip() throws {
        for text in ["https://github.com/m-ruzhynskyi/mac-utils", "Привет, QR! 12345"] {
            let image = try XCTUnwrap(QRTools.make(text))
            XCTAssertEqual(QRTools.detect(in: image), [text])
        }
    }

    func testNoCodeInBlankImage() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(QRTools.detect(in: try XCTUnwrap(context.makeImage())), [])
    }
}

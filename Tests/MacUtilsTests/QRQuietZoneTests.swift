import XCTest
@testable import MacUtils
@testable import MUDesign

/// QR: тихая зона, целый масштаб, граничные тексты.
final class QRQuietZoneTests: XCTestCase {
    /// Пиксели картинки в градациях серого (0…255), строка 0 — верх.
    private func gray(_ image: CGImage) throws -> [[UInt8]] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<height).map { row in Array(data[(row * width)..<((row + 1) * width)]) }
    }

    func testQuietZoneOfFourModulesIsWhite() throws {
        let scale = 5
        let image = try XCTUnwrap(QRTools.make("https://github.com/m-ruzhynskyi/mac-utils", scale: scale))
        let side = try XCTUnwrap(QRTools.side("https://github.com/m-ruzhynskyi/mac-utils"))
        XCTAssertEqual(image.width, side * scale, "картинка — целое число модулей с полем")
        XCTAssertEqual(image.height, image.width)
        let pixels = try gray(image)
        let border = QRTools.quietZone * scale
        for row in 0..<image.height {
            for column in 0..<image.width where row < border || column < border
                || row >= image.height - border || column >= image.width - border {
                XCTAssertGreaterThan(pixels[row][column], 250, "поле должно быть белым: \(row),\(column)")
            }
        }
        // Сразу за полем — угловой «глаз» QR (тёмный модуль).
        XCTAssertLessThan(pixels[border + 1][border + 1], 50)
    }

    func testRoundTripWithQuietZone() throws {
        for text in ["Привет, мир", "emoji 🚀✨", "WIFI:T:WPA;S:Дом;P:пароль;;", String(repeating: "a", count: 1000)] {
            let image = try XCTUnwrap(QRTools.make(text, scale: 4), text.prefix(20).description)
            XCTAssertEqual(QRTools.detect(in: image), [text])
        }
    }

    func testTooLongTextHasNoCode() {
        XCTAssertNil(QRTools.make(String(repeating: "x", count: 3_000)), "больше вместимости QR (уровень M)")
        XCTAssertNil(QRTools.side(String(repeating: "x", count: 3_000)))
    }

    func testIntegerPointsPerModule() {
        XCTAssertEqual(QRTools.pointsPerModule(side: 29, maxPoints: 240), 8)
        XCTAssertEqual(QRTools.pointsPerModule(side: 30, maxPoints: 240), 8)
        XCTAssertEqual(QRTools.pointsPerModule(side: 31, maxPoints: 240), 7)
        XCTAssertEqual(QRTools.pointsPerModule(side: 185, maxPoints: 240), 1, "плотный код — по точке на модуль")
        XCTAssertEqual(QRTools.pointsPerModule(side: 400, maxPoints: 240), 1, "не меньше 1")
        XCTAssertEqual(QRTools.pointsPerModule(side: 0, maxPoints: 240), 1)
    }

    func testCopyFallbackSkipsFinder() {
        XCTAssertFalse(QRTools.copyFallbackAllowed(frontmost: "com.apple.finder"))
        XCTAssertTrue(QRTools.copyFallbackAllowed(frontmost: "com.google.Chrome"))
        XCTAssertTrue(QRTools.copyFallbackAllowed(frontmost: nil))
    }
}

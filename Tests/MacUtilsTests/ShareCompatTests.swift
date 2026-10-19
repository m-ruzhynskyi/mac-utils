import AVFoundation
import XCTest
@testable import MacUtils

/// Совместимость сторон трансляции по общим фикстурам `relay/tests/fixtures` (их же читает relay/tests/compat.test.cjs):
/// видео страницы relay (браузер, клиент для Windows) показывает зритель Mac, метки Mac и страницы — один формат,
/// точка зрителя — доля кадра. Правка формата на одной стороне ломает тест на другой.
final class ShareCompatTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("relay/tests/fixtures")

    /// Пакеты `[3][ключевой][Annex B]`, каждый с 4 байтами длины впереди.
    private func packets(_ name: String) throws -> [Data] {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        var list: [Data] = []
        var at = data.startIndex
        while at + 4 <= data.endIndex {
            let length = data[at..<at + 4].reduce(0) { (sum: Int, byte: UInt8) -> Int in sum << 8 | Int(byte) }
            list.append(Data(data[at + 4..<at + 4 + length]))
            at += 4 + length
        }
        return list
    }

    /// Ведущий — страница relay в Chromium (аппаратный кодер и программный OpenH264, как у Windows без аппаратного H.264):
    /// ключевой кадр несёт SPS и PPS, зритель Mac показывает 320×180 без ошибки декодера.
    func testPageVideoPlaysInMacViewer() throws {
        for name in ["page-chromium-hardware.h264", "page-chromium-openh264.h264", "mac-videotoolbox.h264"] {
            let list = try packets(name)
            XCTAssertEqual(list.map { $0[$0.startIndex + 1] }, [1, 0, 0], name)
            let types = H264Packet.units(list[0].dropFirst(2)).map { (unit: Data) -> UInt8 in unit[unit.startIndex] & 0x1F }
            XCTAssertTrue(types.contains(7) && types.contains(8), "\(name): SPS и PPS в ключевом кадре, есть \(types)")

            let player = H264Player()
            let socket = NSObject()
            player.attach(socket)
            for packet in list {
                XCTAssertEqual(packet.first, H264Packet.type)
                player.play(packet.dropFirst(), from: socket)
            }
            let deadline = Date().addingTimeInterval(5)
            while player.size == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertEqual(player.size, CGSize(width: 320, height: 180), name)
            XCTAssertNotEqual(player.layer.status, .failed, "\(name): \(String(describing: player.layer.error))")
        }
    }

    /// Метки: Mac шлёт ровно то, что записано в фикстуре (её проверяет relay), и понимает формат страницы.
    func testMarksFormatMatchesPageAndRelay() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtures.appendingPathComponent("marks.json"))) as? [String: Any])
        let mac = try XCTUnwrap(json["mac"] as? [String: String]), page = try XCTUnwrap(json["page"] as? [String: String])
        XCTAssertEqual(ShareMark.message(ping: CGPoint(x: 0.25, y: 0.75), color: "blue"), mac["ping"])
        XCTAssertEqual(ShareMark.message(stroke: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.125), CGPoint(x: 1, y: 1)], color: "green"), mac["stroke"])

        let ping = try XCTUnwrap(ShareMark.parse(try XCTUnwrap(page["ping"])))
        XCTAssertEqual(ping.kind, .ping)
        XCTAssertEqual(ping.points, [CGPoint(x: 0.3, y: 0.6)])
        let stroke = try XCTUnwrap(ShareMark.parse(try XCTUnwrap(page["stroke"])))
        XCTAssertEqual(stroke.kind, .stroke)
        XCTAssertEqual(stroke.points, [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.9, y: 0.8)])
    }

    /// Точка зрителя Mac — доля кадра от левого верхнего угла, картинка вписана с полями (как `resizeAspect`):
    /// поля не входят в кадр, точка в поле — не метка. Так же считают страница и окно меток Windows.
    func testViewerPointIsAShareOfTheFrameNotOfTheWindow() throws {
        // Широкое окно, кадр 16:9 — поля слева и справа.
        let wide = ShareMarkGeometry.imageRect(frame: CGSize(width: 1920, height: 1080), in: CGSize(width: 1400, height: 500))
        XCTAssertEqual(wide.height, 500, accuracy: 0.001)
        XCTAssertEqual(wide.width, 500 * 16 / 9, accuracy: 0.001)
        XCTAssertEqual(wide.minX, (1400 - 500 * 16 / 9) / 2, accuracy: 0.001)
        XCTAssertEqual(wide.minY, 0)
        // Высокое окно — поля сверху и снизу.
        let tall = ShareMarkGeometry.imageRect(frame: CGSize(width: 1920, height: 1080), in: CGSize(width: 600, height: 900))
        XCTAssertEqual(tall.width, 600)
        XCTAssertEqual(tall.minY, (900 - 337.5) / 2, accuracy: 0.001)

        let p = try XCTUnwrap(ShareMarkGeometry.normalized(CGPoint(x: wide.minX + wide.width * 0.3, y: wide.minY + wide.height * 0.25), in: wide))
        XCTAssertEqual(p.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(p.y, 0.25, accuracy: 1e-9, "ось y вниз, от верхнего края кадра")
        XCTAssertNil(ShareMarkGeometry.normalized(CGPoint(x: wide.minX - 1, y: 10), in: wide), "клик в поле — не метка")
        XCTAssertNil(ShareMarkGeometry.normalized(CGPoint(x: 10, y: tall.minY - 1), in: tall))
        let back = ShareMarkGeometry.point(p, in: wide)
        XCTAssertEqual(back.x, wide.minX + wide.width * 0.3, accuracy: 1e-9)
        XCTAssertEqual(back.y, wide.minY + wide.height * 0.25, accuracy: 1e-9)
        // Кадра ещё нет — весь вид.
        XCTAssertEqual(ShareMarkGeometry.imageRect(frame: nil, in: CGSize(width: 300, height: 200)), CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    /// Ведущий Mac: транслируемое окно изменило размер — поток под новый размер (иначе кадр и метки расходятся),
    /// мелкое округление — без перенастройки.
    func testSharedWindowResizeChangesStreamSize() {
        XCTAssertNil(ShareVideo.resizedStreamSize(current: (1600, 1000), window: CGSize(width: 800, height: 500), scale: 2))
        XCTAssertNil(ShareVideo.resizedStreamSize(current: (1600, 1000), window: CGSize(width: 800.5, height: 500.5), scale: 2))
        let grown = ShareVideo.resizedStreamSize(current: (1600, 1000), window: CGSize(width: 1200, height: 500), scale: 2)
        XCTAssertEqual(grown?.width, 1920)
        XCTAssertEqual(grown?.height, 800)
        XCTAssertNil(ShareVideo.resizedStreamSize(current: (1600, 1000), window: .zero, scale: 2))
    }
}

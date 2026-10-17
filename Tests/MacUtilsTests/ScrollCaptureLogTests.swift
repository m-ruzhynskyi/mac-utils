import CoreGraphics
import XCTest
@testable import MacUtils

/// Журнал длинного снимка: только числа и имена, последние 10 файлов, кадры — лишь по скрытой настройке.
/// Все файлы — во временной папке теста, не в ~/Library/Logs.
final class ScrollCaptureLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-log-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func logs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".log") }.sorted()
    }

    func testKeepsTheTenNewestLogs() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for k in 0..<13 {
            let log = try XCTUnwrap(ScrollCaptureLog(directory: directory, date: start.addingTimeInterval(Double(k) * 60), saveFrames: false))
            log.write("frame \(k)")
            log.flush()
        }
        let names = try logs()
        XCTAssertEqual(names.count, ScrollCaptureLog.keptLogs)
        XCTAssertEqual(names.first, "scroll-\(ScrollCaptureLog.stamp(start.addingTimeInterval(3 * 60))).log", "удалены три самых старых")
    }

    func testSameSecondGetsItsOwnFile() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try XCTUnwrap(ScrollCaptureLog(directory: directory, date: date, saveFrames: false))
        let b = try XCTUnwrap(ScrollCaptureLog(directory: directory, date: date, saveFrames: false))
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertEqual(try logs().count, 2)
    }

    func testWritesLinesInOrder() throws {
        let log = try XCTUnwrap(ScrollCaptureLog(directory: directory, saveFrames: false))
        for k in 0..<100 { log.write("line \(k)") }
        log.close()
        log.flush()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").map(String.init), (0..<100).map { "line \($0)" })
    }

    func testFramesAreSavedOnlyWhenEnabled() throws {
        let frame = try XCTUnwrap(Self.image())
        let off = try XCTUnwrap(ScrollCaptureLog(directory: directory, saveFrames: false))
        XCTAssertNil(off.framesDirectory)
        off.saveFrame(frame, index: 0)
        off.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("scroll-frames").path))

        let on = try XCTUnwrap(ScrollCaptureLog(directory: directory, saveFrames: true))
        let frames = try XCTUnwrap(on.framesDirectory)
        on.saveFrame(frame, index: 7)
        on.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: frames.appendingPathComponent("0007.png").path))
    }

    func testKeepsFramesOfTheLastThreeCaptures() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var last: URL?
        for k in 0..<5 {
            let log = try XCTUnwrap(ScrollCaptureLog(directory: directory, date: start.addingTimeInterval(Double(k) * 60), saveFrames: true))
            last = log.framesDirectory
        }
        let root = directory.appendingPathComponent("scroll-frames")
        let sessions = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(sessions.count, ScrollCaptureLog.keptFrameSessions)
        XCTAssertEqual(sessions.last, last?.lastPathComponent)
    }

    func testFrameLineHasOnlyNumbersAndModeNames() {
        let trace = Stitcher.Trace(up: true, shift: 240, header: 120, footer: 100, source: .layer, expected: 230, reason: nil)
        let line = ScrollCaptureLog.frameLine(index: 3, time: 1.25, grabMs: 31.4, addMs: 12.06, result: .appended, added: 240,
                                              height: 2400, trace: trace, motion: Stitcher.Motion(lines: -3))
        XCTAssertEqual(line, "frame 3 1.250 31.4 12.1 appended +240 2400 up 240 120 100 layer 230 - lines=-3.00")
        XCTAssertEqual(line.split(separator: " ").count, ScrollCaptureLog.frameColumns.split(separator: " ").count)
        let lost = ScrollCaptureLog.frameLine(index: 4, time: 1.4, grabMs: 30, addMs: 9, result: .lost, added: 0, height: 2400,
                                              trace: Stitcher.Trace(reason: .noMatch), motion: nil)
        XCTAssertEqual(lost, "frame 4 1.400 30.0 9.0 lost +0 2400 down - 0 0 - - noMatch none")
    }

    func testMotionDescription() {
        XCTAssertEqual(ScrollCaptureLog.describe(nil), "none")
        XCTAssertEqual(ScrollCaptureLog.describe(Stitcher.Motion()), "0")
        XCTAssertEqual(ScrollCaptureLog.describe(Stitcher.Motion(pixels: 12.34, pages: 1, unknown: 2)), "px=12.3,pages=1,unknown=2")
    }

    func testErrorIsLoggedByCodeOnly() {
        let error = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3811,
                            userInfo: [NSLocalizedDescriptionKey: "Окно «Секретный документ» недоступно"])
        XCTAssertEqual(ScrollCaptureLog.code(error), "com.apple.ScreenCaptureKit.SCStreamErrorDomain#-3811")
    }

    private static func image() -> CGImage? {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context?.makeImage()
    }
}

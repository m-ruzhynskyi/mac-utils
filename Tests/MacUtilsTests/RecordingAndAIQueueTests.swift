import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUScreenshot
@testable import MUTextEditor

final class RecordingAndAIQueueTests: XCTestCase {
    // R2: предупреждение и предел длительности GIF
    func testGIFPolicyWarnsOnceThenStops() {
        XCTAssertEqual(GIFPolicy.check(elapsed: 5, warned: false), .none)
        XCTAssertEqual(GIFPolicy.check(elapsed: GIFPolicy.warnAfter, warned: false), .warn)
        XCTAssertEqual(GIFPolicy.check(elapsed: GIFPolicy.warnAfter + 10, warned: true), .none)
        XCTAssertEqual(GIFPolicy.check(elapsed: GIFPolicy.maxDuration, warned: true), .stop)
        XCTAssertEqual(GIFPolicy.check(elapsed: GIFPolicy.maxDuration + 1, warned: false), .stop)
        XCTAssertLessThan(GIFPolicy.warnAfter, GIFPolicy.maxDuration)
    }

    func testGIFPercent() {
        XCTAssertEqual(GIFPolicy.percent(done: 0, total: 10), 0)
        XCTAssertEqual(GIFPolicy.percent(done: 5, total: 10), 50)
        XCTAssertEqual(GIFPolicy.percent(done: 10, total: 10), 100)
        XCTAssertEqual(GIFPolicy.percent(done: 12, total: 10), 100)
        XCTAssertEqual(GIFPolicy.percent(done: 1, total: 0), 100)
    }

    // R3: неудачный старт — временный .mp4 удаляется
    func testDiscardRemovesTemporaryFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacUtils-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(url: url, width: 640, height: 480, audio: false, microphone: false)
        writer.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        writer.discard() // повторный вызов безопасен
    }

    // AI3: keep_alive на время очереди
    func testKeepAliveOnlyWhileMoreQueued() {
        XCTAssertEqual(BackgroundAIQueue.keepAlive(outstanding: 0), "0")
        XCTAssertEqual(BackgroundAIQueue.keepAlive(outstanding: 1), "0")
        XCTAssertEqual(BackgroundAIQueue.keepAlive(outstanding: 2), "30s")
        XCTAssertEqual(BackgroundAIQueue.keepAlive(outstanding: 300), "30s")
    }

    func testQueueCounterDrainsToZeroKeepAlive() {
        let queue = BackgroundAIQueue()
        for _ in 0..<3 { queue.enter() }
        XCTAssertEqual(queue.keepAlive, "30s")
        queue.leave(); queue.leave()
        XCTAssertEqual(queue.keepAlive, "0") // последний элемент
        queue.leave(); queue.leave() // лишний leave не уходит в минус
        XCTAssertEqual(queue.count, 0)
        queue.enter()
        XCTAssertEqual(queue.keepAlive, "0")
    }
}

@MainActor
final class ToastTokenTests: XCTestCase {
    override func tearDown() async throws { Toast.dismiss() }

    func testUpdateTextOnlyAffectsOwnToast() {
        let a = Toast.show("a", sticky: true)
        let b = Toast.show("b", sticky: true)
        Toast.updateText("x", token: a)
        XCTAssertNil(Toast.text(of: a))
        XCTAssertEqual(Toast.text(of: b), "b")
        Toast.updateText("y", token: b)
        XCTAssertEqual(Toast.text(of: b), "y")
    }

    func testDismissWithTokenKeepsForeignToast() {
        let a = Toast.show("a", sticky: true)
        let b = Toast.show("b", sticky: true)
        Toast.dismiss(token: a)
        XCTAssertEqual(Toast.text(of: b), "b")
        Toast.dismiss(token: b)
        XCTAssertNil(Toast.text(of: b))
        Toast.dismiss(token: b) // повтор безопасен
    }

    func testDismissWithoutTokenRemovesCurrent() {
        let a = Toast.show("a", sticky: true)
        Toast.dismiss()
        XCTAssertNil(Toast.text(of: a))
    }

    func testPanelFitsNewTextOnNextPass() async throws {
        let t = Toast.show("Создаю GIF… 9 %", sticky: true)
        let narrow = try XCTUnwrap(Toast.panelWidth(of: t))
        Toast.updateText("Создаю GIF… 100 % и очень длинный хвост уведомления", token: t)
        try await Task.sleep(nanoseconds: 200_000_000)
        let wide = try XCTUnwrap(Toast.panelWidth(of: t))
        XCTAssertGreaterThan(wide, narrow)
        XCTAssertEqual(wide, try XCTUnwrap(Toast.fittingWidth(of: t)), accuracy: 1)
    }
}

final class GIFFallbackTests: XCTestCase {
    func testFallbackMovesTempToDestination() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let temp = dir.appendingPathComponent("t.mp4"), target = dir.appendingPathComponent("out.mp4")
        try Data([1, 2, 3]).write(to: temp)
        XCTAssertTrue(ScreenRecorder.saveFallback(temp, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertEqual(try Data(contentsOf: target), Data([1, 2, 3]))
    }

    func testFallbackRemovesTempWhenMoveFails() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).mp4")
        try Data([1]).write(to: temp)
        let bad = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/out.mp4")
        XCTAssertFalse(ScreenRecorder.saveFallback(temp, to: bad))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }
}

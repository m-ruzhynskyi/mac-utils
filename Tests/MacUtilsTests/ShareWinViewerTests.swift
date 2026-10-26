import XCTest
@testable import MUScreenShare

/// SHARE-WIN-VIEWER: зритель не успевает декодировать — просит ключевой кадр и снижение частоты; ведущий Mac отвечает
/// 30 кадрами/с и пишет статистику видео в журнал раз в минуту. Без экрана, звука и сети.
final class ShareWinViewerTests: XCTestCase {
    func testViewersSlowFlag() {
        let slow = ShareViewersSignal(json: ["type": "viewers", "count": 1, "key": true, "slow": true])
        XCTAssertTrue(slow.slow)
        XCTAssertTrue(slow.resendsLast(viewers: 1), "с slow всегда приходит key — ключевой кадр")
        XCTAssertFalse(slow.announcesDisplays, "состав не менялся — мониторы заново не шлём")
        XCTAssertFalse(ShareViewersSignal(json: ["type": "viewers", "count": 1]).slow)
        XCTAssertFalse(ShareViewersSignal(json: ["type": "viewers", "count": 1, "slow": "yes"]).slow, "не Bool — как отсутствие")
    }

    /// Сигнал зрителя — та же перегрузка, что своя: 60 → 30, обратно только после спокойного окна.
    func testViewerSlowLowersRateLikeCongestion() {
        var governor = ShareRateGovernor()
        governor.warmUp(now: 0)
        for t in stride(from: 0.0, through: 10, by: 0.1) { governor.bitrateSample(8_000_000, now: t) }
        XCTAssertEqual(governor.fps, 60)
        XCTAssertTrue(governor.congested(now: 10))
        XCTAssertEqual(governor.fps, 30)
        XCTAssertFalse(governor.calm(now: 12), "спокойное окно 8 с ещё не прошло")
        XCTAssertFalse(governor.congested(now: 14), "повторный сигнал — частота уже 30")
        XCTAssertFalse(governor.calm(now: 20), "повторный сигнал продлил окно")
        for t in stride(from: 10.0, through: 23, by: 0.1) { governor.bitrateSample(8_000_000, now: t) }
        XCTAssertTrue(governor.calm(now: 23))
        XCTAssertEqual(governor.fps, 60)
    }

    func testVideoStatsLineOncePerMinuteNumbersOnly() {
        var stats = ShareVideoStats(now: 100)
        for i in 0..<1800 { stats.sent(bytes: 20_000, key: i % 240 == 0) }
        stats.keyRequests = 3; stats.congestion = 2; stats.viewerSlow = 1; stats.skipped = 5
        XCTAssertNil(stats.line(now: 159, fps: 30, bitrate: 6_000_000, mode: "hw"))
        let line = try? XCTUnwrap(stats.line(now: 160, fps: 30, bitrate: 6_000_000, mode: "hw"))
        XCTAssertEqual(line, "Трансляция: видео за 60 с — кадров 1800 (30 в с), передано 4800 кбит/с, кодер 6000 кбит/с, режим 30 кадров/с hw, ключевых 8, по просьбе 3, перегрузок 2, зритель не успевает 1, пропущено 5")
        XCTAssertEqual(stats.frames, 0, "после строки — новый отсчёт")
        XCTAssertNil(stats.line(now: 200, fps: 60, bitrate: 6_000_000, mode: nil))
    }

    func testKeyRequestMessage() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ShareVideoAck.keyRequest.utf8)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "video-trouble")
        XCTAssertEqual(json["key"] as? Bool, true)
        XCTAssertEqual(json["slow"] as? Bool, false)
    }

    /// Проигрыватель Mac-зрителя отстал (очередь полна) — ждёт ключевой и просит его, не чаще раза в секунду.
    func testPlayerAsksForKeyWhenDropping() {
        let player = H264Player(limit: 0)
        let asked = expectation(description: "просьба ключевого")
        asked.assertForOverFulfill = true
        let lock = NSLock()
        var count = 0
        player.onNeedKey = { lock.lock(); count += 1; lock.unlock(); asked.fulfill() }
        let socket = NSObject()
        player.attach(socket)
        for _ in 0..<30 { player.play(Data([0, 0, 0, 0, 1, 0x41, 0x9a]), from: socket) }
        wait(for: [asked], timeout: 2)
        let drained = expectation(description: "очередь проигрывателя")
        player.received { _ in drained.fulfill() }
        wait(for: [drained], timeout: 2)
        lock.lock(); XCTAssertEqual(count, 1, "30 выброшенных пакетов за миг — одна просьба"); lock.unlock()
        XCTAssertEqual(player.dropped, 30)
    }
}

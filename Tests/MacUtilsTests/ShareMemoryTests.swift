import AVFoundation
import XCTest
@testable import MacUtils
@testable import MUAudio

/// Очереди трансляции ограничены (долгая трансляция не съедает память): политика звука ведущего и зрителя.
final class ShareMemoryTests: XCTestCase {
    func testAudioSenderDropsWhenSocketIsBehindAndResumesAfterCompletion() {
        var completions: [() -> Void] = []
        var sent = 0
        let sender = ShareAudioSender(limit: 10_000) { _, done in sent += 1; completions.append(done) }
        let packet = Data(count: 4_801)
        sender.send(packet)
        sender.send(packet)
        sender.send(packet)
        XCTAssertEqual(sent, 2, "третий пакет не помещается в предел")
        XCTAssertEqual(sender.dropped, 1)
        XCTAssertEqual(sender.pending, 9_602)
        completions.removeFirst()()
        sender.send(packet)
        XCTAssertEqual(sent, 3, "сокет отдал пакет — место освободилось")
        completions.forEach { $0() }
        XCTAssertEqual(sender.pending, 0)
    }

    func testAudioSenderDefaultIsAboutTwoSeconds() {
        XCTAssertEqual(Double(ShareAudioSender.defaultLimit) / (ShareProtocol.sampleRate * 2), 2, accuracy: 0.01)
    }

    func testPlayerQueueIsCappedAtOneSecond() {
        let player = SharePlayer(silent: true, catchUp: .max)
        defer { player.stop() }
        let payload = Data(ShareProtocol.audioPacket([Float](repeating: 0.1, count: 2_400)).dropFirst())
        for _ in 0..<100 { player.play(payload) }
        XCTAssertLessThanOrEqual(player.queuedSeconds, 1.0001)
        XCTAssertEqual(player.dropped, 90, "10 кусков по 0,1 с — секунда, остальные отброшены")
    }
}

final class SharePlayerOutputChangeTests: XCTestCase {
    private let payload = Data(ShareProtocol.audioPacket([Float](repeating: 0.1, count: 2_400)).dropFirst())

    func testConfigurationChangeNotificationRestartsPlayer() {
        let center = NotificationCenter()
        let player = SharePlayer(silent: true, center: center)
        defer { player.stop() }
        for _ in 0..<5 { player.play(payload) }
        center.post(name: .AVAudioEngineConfigurationChange, object: AVAudioEngine())
        player.waitForRestart()
        XCTAssertEqual(player.restarts, 0, "уведомление чужого движка игнорируется")
        center.post(name: .AVAudioEngineConfigurationChange, object: player.engine)
        player.waitForRestart()
        XCTAssertEqual(player.restarts, 1)
        XCTAssertEqual(player.queuedSeconds, 0, accuracy: 0.0001)
    }

    func testOutputChangeResetsQueueAndKeepsPlaying() {
        let player = SharePlayer(silent: true)
        defer { player.stop() }
        for _ in 0..<5 { player.play(payload) }
        XCTAssertGreaterThan(player.queuedSeconds, 0.4)
        player.outputChanged()
        XCTAssertEqual(player.restarts, 1)
        XCTAssertEqual(player.queuedSeconds, 0, accuracy: 0.0001, "старая очередь сброшена")
        player.play(payload)
        XCTAssertEqual(player.queuedSeconds, 0.1, accuracy: 0.0001, "после смены выхода принимаются свежие пакеты")
    }

    func testOutputChangeBeforeFirstPacketDoesNothing() {
        let player = SharePlayer(silent: true)
        player.outputChanged()
        XCTAssertEqual(player.restarts, 0)
    }
}

final class ShareVideoAckTests: XCTestCase {
    func testAckEveryTenPacketsAndResetsOnNewSocket() {
        let ack = ShareVideoAck()
        let a = NSObject(), b = NSObject()
        var sent: [Int] = []
        for _ in 0..<25 { if let n = ack.received(on: a) { sent.append(n) } }
        XCTAssertEqual(sent, [10, 20])
        XCTAssertNil(ack.received(on: b), "новый сокет — счёт заново")
        XCTAssertEqual(ShareVideoAck.message(10), #"{"type":"ack","n":10}"#)
    }
}

final class SharePlayerCatchUpTests: XCTestCase {
    func testLongQueueIsResetSoAudioCatchesUp() {
        let player = SharePlayer(silent: true)
        defer { player.stop() }
        let payload = Data(ShareProtocol.audioPacket([Float](repeating: 0.1, count: 2_400)).dropFirst())
        for _ in 0..<30 { player.play(payload) }
        XCTAssertGreaterThanOrEqual(player.catchUps, 1, "очередь дошла до 0,5 с и была сброшена")
        XCTAssertEqual(player.dropped, 0, "пока сброс срабатывает раньше предела, ничего не отбрасывается")
        XCTAssertLessThanOrEqual(player.queuedSeconds, 0.6)
    }
}

final class SharePlayerOwnerTests: XCTestCase {
    func testPacketsOfAClosedSocketStartNothing() {
        let player = SharePlayer(silent: true)
        defer { player.stop() }
        let payload = Data(ShareProtocol.audioPacket([Float](repeating: 0.1, count: 2_400)).dropFirst())
        let old = NSObject(), fresh = NSObject()
        player.attach(old)
        player.play(payload, from: old)
        XCTAssertGreaterThan(player.queuedSeconds, 0)
        player.stop()
        player.play(payload, from: old)
        XCTAssertEqual(player.queuedSeconds, 0, "после выхода звук старого сокета не запускает движок")
        player.attach(fresh)
        player.play(payload, from: old)
        XCTAssertEqual(player.queuedSeconds, 0, "старый сокет после переподключения молчит")
        player.play(payload, from: fresh)
        XCTAssertGreaterThan(player.queuedSeconds, 0)
    }
}

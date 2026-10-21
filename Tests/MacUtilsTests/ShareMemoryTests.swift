import XCTest
@testable import MacUtils

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
        let player = SharePlayer(silent: true)
        defer { player.stop() }
        let payload = Data(ShareProtocol.audioPacket([Float](repeating: 0.1, count: 2_400)).dropFirst())
        for _ in 0..<100 { player.play(payload) }
        XCTAssertLessThanOrEqual(player.queuedSeconds, 1.0001)
        XCTAssertEqual(player.dropped, 90, "10 кусков по 0,1 с — секунда, остальные отброшены")
    }
}

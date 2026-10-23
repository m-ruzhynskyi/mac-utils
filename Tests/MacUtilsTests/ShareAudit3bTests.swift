import XCTest
@testable import MacUtils

@MainActor
final class ShareAudit3bTests: XCTestCase {
    /// B5: при откате подписи (раньше подписывал, теперь нет) текст тот же, что на странице relay; при неверной подписи — общий.
    func testSignatureFailureTexts() {
        XCTAssertEqual(ShareViewer.signatureFailureText(downgrade: true), "Ведущий раньше подписывал принятие, а теперь нет: подключение отменено")
        XCTAssertEqual(ShareViewer.signatureFailureText(downgrade: false), "Подпись ведущего не сошлась: подключение отменено")
    }

    // MARK: B6

    func testViewersSignalTickAndKey() {
        let cases: [(json: [String: Any], displays: Bool, resend: Bool)] = [
            (["type": "viewers", "count": 2], true, true),                         // новый состав
            (["type": "viewers", "count": 2, "tick": true], false, false),          // напоминание раз в 30 с
            (["type": "viewers", "count": 2, "key": true], false, true),             // медленный зритель просит ключевой
            (["type": "viewers", "count": 2, "tick": true, "key": true], false, true),
            (["type": "viewers", "count": 2, "tick": false, "key": false], true, true),
            (["type": "viewers", "count": 2, "tick": "yes", "key": 1], true, true),  // не Bool — как отсутствие
        ]
        for item in cases {
            let signal = ShareViewersSignal(json: item.json)
            XCTAssertEqual(signal.announcesDisplays, item.displays, "\(item.json)")
            XCTAssertEqual(signal.resendsLast(viewers: 2), item.resend, "\(item.json)")
        }
        XCTAssertFalse(ShareViewersSignal(json: ["key": true]).resendsLast(viewers: 0), "никто не смотрит — кадр не шлём")
    }

    /// Ключевой кадр просит сам `resendLast`; отдельный `requestKeyFrame()` в обработчике `viewers` не возвращается.
    func testViewersHandlerDoesNotRequestKeyFrameSeparately() throws {
        let source = try String(contentsOfFile: #filePath.replacingOccurrences(of: "Tests/MacUtilsTests/ShareAudit3bTests.swift",
                                                                              with: "Sources/MacUtils/Features/ScreenShare/ScreenShare.swift"))
        let start = try XCTUnwrap(source.range(of: "ShareViewersSignal(json: json).resendsLast"))
        let before = String(source[source.index(start.lowerBound, offsetBy: -600)..<start.lowerBound])
        XCTAssertFalse(before.contains("requestKeyFrame()"), "лишний requestKeyFrame перед resendLast")
        let resend = try XCTUnwrap(source.range(of: "func resendLast()"))
        XCTAssertTrue(source[resend.upperBound...].prefix(200).contains("encoder.requestKeyFrame()"), "resendLast сам просит ключевой кадр")
    }

    // MARK: B1

    func testFallbackAudioNotStartedTwiceAfterSleep() {
        // Сон: видео остановилось первым, recoverCapture ждёт остановки звука; пришёл captureStopped звука → идёт перезапуск.
        var gate = ShareFallbackAudioGate(restarting: false, hasStream: true, hasTap: false)
        XCTAssertTrue(gate.mayRestart)
        gate.restarting = true; gate.hasStream = false                              // restartFallbackAudio: audioStream = nil
        XCTAssertFalse(gate.recoverMayStartAudio, "пересборка захвата не стартует звук, пока идёт перезапуск")
        XCTAssertFalse(gate.mayRestart, "второй параллельный перезапуск не нужен")
        XCTAssertTrue(gate.mayStartAfterDelay, "перезапуск стартует один раз")

        // Наоборот: звук уже пересоздала пересборка захвата — отложенный перезапуск не стартует второй.
        let rebuilt = ShareFallbackAudioGate(restarting: true, hasStream: true, hasTap: false)
        XCTAssertFalse(rebuilt.mayStartAfterDelay)
        XCTAssertFalse(ShareFallbackAudioGate(restarting: true, hasStream: false, hasTap: true).mayStartAfterDelay, "перехват уже работает")
    }

    func testFallbackAudioStreamDiscardedWhenBroadcastChangedOrAlreadyRunning() {
        let idle = ShareFallbackAudioGate()
        XCTAssertTrue(idle.mayAttach(sameBroadcast: true))
        XCTAssertFalse(idle.mayAttach(sameBroadcast: false), "эфир остановили, пока поток создавался")
        XCTAssertFalse(ShareFallbackAudioGate(hasStream: true).mayAttach(sameBroadcast: true), "другая ветка уже подняла звук")
        XCTAssertFalse(ShareFallbackAudioGate(hasTap: true).mayAttach(sameBroadcast: true))
    }
}

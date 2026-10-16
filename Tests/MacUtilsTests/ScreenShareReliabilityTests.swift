import CoreMedia
import XCTest
@testable import MacUtils

/// Трансляция: отмена и таймаут подключения (SH3), пауза кодера без зрителей (SH4), переподключение зрителя (SH5).
final class ScreenShareReliabilityTests: XCTestCase {
    // MARK: - SH3: попытки подключения

    func testCancelledOrTimedOutAttemptIsStale() {
        var attempts = ShareAttempts()
        let first = attempts.begin()
        XCTAssertTrue(attempts.isCurrent(first))
        attempts.cancel() // «Отмена», «Стоп» или таймаут
        XCTAssertFalse(attempts.isCurrent(first), "запоздавшее рукопожатие не делает трансляцию живой")
        let second = attempts.begin()
        XCTAssertTrue(attempts.isCurrent(second))
        XCTAssertFalse(attempts.isCurrent(first))
        XCTAssertNotEqual(first, second)
    }

    /// MINOR-1: «Отмена» закрывает сокет, который ещё проходит рукопожатие, — он не дойдёт до `auth` позже новой попытки.
    func testCancelClosesSocketStillInHandshake() {
        var attempts = ShareAttempts()
        _ = attempts.begin()
        let socket = NSObject()
        var closed = 0
        attempts.track(socket) { closed += 1 }
        attempts.cancel()
        XCTAssertEqual(closed, 1)
        attempts.cancel()
        XCTAssertEqual(closed, 1, "закрывается один раз")
    }

    func testFinishedHandshakeSocketIsNotClosedByCancel() {
        var attempts = ShareAttempts()
        _ = attempts.begin()
        let socket = NSObject()
        var closed = false
        attempts.track(socket) { closed = true }
        attempts.untrack(socket) // рукопожатие закончилось: сокет — уже эфир, его закрывает «Стоп»
        attempts.cancel()
        XCTAssertFalse(closed)
    }

    /// Повтор после 403/426 открывает второй сокет внутри первой попытки: отмена закрывает именно его,
    /// а выход из внешнего вызова не снимает слежение за внутренним.
    func testRetrySocketReplacesTrackedOne() {
        var attempts = ShareAttempts()
        _ = attempts.begin()
        let first = NSObject(), retry = NSObject()
        var closed: [String] = []
        attempts.track(first) { closed.append("first") }
        attempts.track(retry) { closed.append("retry") }
        attempts.untrack(first)
        attempts.cancel()
        XCTAssertEqual(closed, ["retry"])
    }

    func testConnectTimeoutIsShorterThanSystemDefaultAndExplained() {
        XCTAssertLessThan(ShareTimeouts.hostConnect, 60, "системный таймаут URLRequest — 60 с")
        XCTAssertGreaterThanOrEqual(ShareTimeouts.hostConnect, 10, "проверка ключа сама ждёт до 12 с")
        XCTAssertTrue(ShareTimeouts.hostConnectMessage.contains("\(Int(ShareTimeouts.hostConnect)) секунд"))
    }

    // MARK: - SH4: пауза кодера

    func testEncoderPausesOnlyWhenServerSaysNobodyWatches() {
        XCTAssertFalse(ShareEncoderGate.shouldPause(viewers: nil), "число зрителей ещё не пришло — не останавливаемся")
        XCTAssertTrue(ShareEncoderGate.shouldPause(viewers: 0))
        XCTAssertFalse(ShareEncoderGate.shouldPause(viewers: 1))
        XCTAssertFalse(ShareEncoderGate.shouldPause(viewers: 7))
    }

    func testFrameSenderPausesAndResumesByViewerCount() throws {
        let url = try XCTUnwrap(URL(string: "wss://relay.example/room/1234567890?role=host"))
        let socket = URLSession.shared.webSocketTask(with: url) // не запускается: в сеть ничего не уходит
        let sender = FrameSender(socket: socket)
        XCTAssertFalse(sender.isPaused, "до первого числа зрителей кодер работает")
        sender.setViewers(0)
        XCTAssertTrue(sender.isPaused)
        sender.setViewers(2)
        XCTAssertFalse(sender.isPaused)
        sender.setViewers(0)
        XCTAssertTrue(sender.isPaused)
        sender.resendLast() // без кадров и на паузе — ничего не делает и не падает
        socket.cancel()
    }

    // MARK: - SH5: переподключение зрителя

    func testFirstConnectFailureIsNotARetry() {
        XCTAssertNil(ShareViewerReconnect.onDrop(wasWatching: false, attemptsMade: 0, status: 404),
                     "не удалось подключиться с первого раза — обычное сообщение, без повторов")
    }

    func testDropWhileWatchingRetriesWithGrowingPauses() {
        var attempts = 0
        var pauses: [UInt64] = []
        var watching = true
        while case .reconnect(let attempt, let delay)? = ShareViewerReconnect.onDrop(wasWatching: watching, attemptsMade: attempts,
                                                                                       status: nil) {
            XCTAssertEqual(attempt, attempts + 1)
            pauses.append(delay)
            attempts = attempt
            watching = false // во время переподключения картинки нет
        }
        XCTAssertEqual(pauses, ShareViewerReconnect.delays)
        XCTAssertEqual(pauses.count, 7)
        XCTAssertEqual(pauses, pauses.sorted(), "паузы не убывают")
        XCTAssertLessThanOrEqual(pauses.reduce(0, +), 90, "долго не висим")
    }

    /// MINOR-2: пока ведущий в grace, relay отвечает зрителю 404 — зритель не должен сдаться раньше.
    func testRetriesOutlastHostGrace() {
        let total = TimeInterval(ShareViewerReconnect.delays.reduce(0, +))
        XCTAssertEqual(ShareViewerReconnect.hostGrace, 45, "relay ждёт ведущего 45 с")
        XCTAssertGreaterThanOrEqual(total, ShareViewerReconnect.hostGrace)
        // Ведущий сам переподключается с паузами 1, 2, 3, 5, 8, 10, 15 — последняя его попытка около 44 с.
        XCTAssertGreaterThan(total, TimeInterval([1, 2, 3, 5, 8, 10, 15].reduce(0, +)))
    }

    func testRetriesEndWithHonestMessage() {
        let limit = ShareViewerReconnect.delays.count
        XCTAssertEqual(ShareViewerReconnect.onDrop(wasWatching: false, attemptsMade: limit, status: 404), .end("Трансляция завершена"))
        XCTAssertEqual(ShareViewerReconnect.onDrop(wasWatching: false, attemptsMade: limit, status: nil),
                       .end("Связь с ведущим потеряна — переподключиться не удалось"))
        XCTAssertEqual(ShareViewerReconnect.onDrop(wasWatching: false, attemptsMade: limit, status: 429),
                       .end("Связь с ведущим потеряна — переподключиться не удалось"))
    }

    /// Снова пошла картинка — счётчик обнулён (в коде), и следующий обрыв опять начинается с первой попытки.
    func testNewDropAfterRecoveryStartsOver() {
        XCTAssertEqual(ShareViewerReconnect.onDrop(wasWatching: true, attemptsMade: 0, status: nil), .reconnect(attempt: 1, delay: 1))
    }

    func testStatusText() {
        XCTAssertEqual(ShareViewerReconnect.status(attempt: 2), "Связь потеряна, переподключаюсь… (попытка 2 из 7)")
    }

    func testSilentConnectionDetection() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ShareViewerReconnect.isSilent(lastMessage: start, now: start.addingTimeInterval(45)), "grace ведущего (45 с) — ещё не обрыв")
        XCTAssertFalse(ShareViewerReconnect.isSilent(lastMessage: start, now: start.addingTimeInterval(ShareViewerReconnect.silenceLimit)))
        XCTAssertTrue(ShareViewerReconnect.isSilent(lastMessage: start, now: start.addingTimeInterval(ShareViewerReconnect.silenceLimit + 1)))
        XCTAssertGreaterThan(ShareViewerReconnect.silenceLimit, 2 * 30, "дольше двух пропущенных heartbeat")
    }

    // MARK: - MINOR-3: тайм-аут одной попытки

    func testReconnectAttemptHasItsOwnTimeout() {
        let timeout = ShareViewerReconnect.attemptTimeout
        XCTAssertLessThan(timeout, 60, "системный тайм-аут — 60 с")
        XCTAssertGreaterThanOrEqual(timeout, 10, "медленному серверу нужно время на рукопожатие")
        XCTAssertLessThan(timeout, ShareViewerReconnect.silenceLimit)
        let delays = ShareViewerReconnect.delays
        let worst = TimeInterval(delays.reduce(0, +)) + Double(delays.count) * timeout
        XCTAssertLessThanOrEqual(worst, 180, "все попытки в худшем случае — не дольше 3 минут, а не 8")
    }

    func testOnlyUnansweredAttemptIsAborted() {
        XCTAssertTrue(ShareViewerReconnect.shouldAbortAttempt(state: .reconnecting(attempt: 3)))
        XCTAssertFalse(ShareViewerReconnect.shouldAbortAttempt(state: .waiting), "ведущий решает — не торопим")
        XCTAssertFalse(ShareViewerReconnect.shouldAbortAttempt(state: .watching))
        XCTAssertFalse(ShareViewerReconnect.shouldAbortAttempt(state: .connecting))
        XCTAssertFalse(ShareViewerReconnect.shouldAbortAttempt(state: .ended("Отключено")))
        XCTAssertFalse(ShareViewerReconnect.shouldAbortAttempt(state: .idle))
    }

    // MARK: - MINOR-4: метки времени кодера

    func testFrameClockPassesIncreasingTimesThrough() {
        var clock = ShareFrameClock()
        let a = CMTime(seconds: 10, preferredTimescale: 600)
        let b = CMTime(seconds: 10.5, preferredTimescale: 600)
        XCTAssertEqual(clock.next(a), a)
        XCTAssertEqual(clock.next(b), b)
    }

    /// Повтор последнего кадра взял «сейчас», а кадр захвата, снятый раньше, пришёл после него.
    func testFrameClockNeverGoesBack() {
        var clock = ShareFrameClock()
        let resend = CMTime(value: 20_000_000_000, timescale: 1_000_000_000) // часы хоста, 20 с
        let captured = CMTime(value: 11_990, timescale: 600) // ScreenCaptureKit, 19,98 с
        XCTAssertEqual(clock.next(resend), resend)
        let late = clock.next(captured)
        XCTAssertGreaterThan(late, resend)
        XCTAssertEqual(late, CMTimeAdd(resend, ShareFrameClock.step))
        let same = clock.next(late)
        XCTAssertGreaterThan(same, late, "одинаковая метка тоже сдвигается")
    }

    func testFrameClockHandlesInvalidTime() {
        var clock = ShareFrameClock()
        XCTAssertFalse(clock.next(.invalid).isValid, "до первой настоящей метки подставить нечего")
        let a = CMTime(seconds: 5, preferredTimescale: 600)
        XCTAssertEqual(clock.next(a), a)
        XCTAssertEqual(clock.next(.invalid), CMTimeAdd(a, ShareFrameClock.step))
    }
}

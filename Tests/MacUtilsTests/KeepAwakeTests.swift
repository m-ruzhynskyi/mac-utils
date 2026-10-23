import XCTest
@testable import MacUtils
@testable import MUCore

private final class FakeAssertions: SleepAssertionProviding {
    var created: [String] = []
    var released: [UInt32] = []
    var refuse = false
    private var next: UInt32 = 100

    func create(reason: String) -> UInt32? {
        guard !refuse else { return nil }
        created.append(reason)
        next += 1
        return next
    }

    func release(_ id: UInt32) { released.append(id) }
}

@MainActor
final class KeepAwakeTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func make(_ fake: FakeAssertions) -> KeepAwake {
        KeepAwake(provider: fake, now: { [unowned self] in self.clock })
    }

    func testStartsOffAndStartCreatesOneAssertionWithReason() {
        let fake = FakeAssertions()
        let keepAwake = make(fake)
        XCTAssertFalse(keepAwake.isActive)
        keepAwake.start(.indefinite)
        XCTAssertTrue(keepAwake.isActive)
        XCTAssertTrue(keepAwake.isIndefinite)
        XCTAssertNil(keepAwake.remaining())
        XCTAssertEqual(fake.created, ["Mac Utils: не засыпать"])
        keepAwake.stop()
    }

    func testStopReleasesAssertion() {
        let fake = FakeAssertions()
        let keepAwake = make(fake)
        keepAwake.start(.hour1)
        keepAwake.stop()
        XCTAssertFalse(keepAwake.isActive)
        XCTAssertNil(keepAwake.endsAt)
        XCTAssertEqual(fake.released, [101])
        keepAwake.stop()
        XCTAssertEqual(fake.released, [101], "повторное выключение ничего не освобождает")
    }

    func testChangingDurationKeepsTheSameAssertion() {
        let fake = FakeAssertions()
        let keepAwake = make(fake)
        keepAwake.start(.hour1)
        keepAwake.start(.hours8)
        XCTAssertEqual(fake.created.count, 1)
        XCTAssertTrue(fake.released.isEmpty)
        XCTAssertEqual(keepAwake.remaining(), 8 * 3_600)
        XCTAssertEqual(keepAwake.currentDuration, .hours8)
        keepAwake.stop()
    }

    func testExpiresAfterDurationAndRemainingCountsDown() {
        let fake = FakeAssertions()
        let keepAwake = make(fake)
        keepAwake.start(.hour1)
        clock.addTimeInterval(1_800)
        keepAwake.expireIfNeeded()
        XCTAssertTrue(keepAwake.isActive)
        XCTAssertEqual(keepAwake.remaining(), 1_800)
        clock.addTimeInterval(1_800)
        keepAwake.expireIfNeeded()
        XCTAssertFalse(keepAwake.isActive, "срок вышел — assertion снят")
        XCTAssertEqual(fake.released, [101])
    }

    func testWakeRearmsTimerOnEndsAt() {
        let fake = FakeAssertions()
        let keepAwake = make(fake)
        keepAwake.start(.hour1)
        let endsAt = keepAwake.endsAt
        XCTAssertEqual(keepAwake.timerFireDate, endsAt)
        // Имитация: за время сна таймер «уехал» (здесь — потерян).
        keepAwake.simulateLostTimerForTests()
        XCTAssertNil(keepAwake.timerFireDate)
        clock.addTimeInterval(600)
        keepAwake.handleWake()
        XCTAssertTrue(keepAwake.isActive)
        XCTAssertEqual(keepAwake.timerFireDate, endsAt, "после сна таймер снова стоит на endsAt")
        keepAwake.stop()
    }

    func testWakeAfterDeadlineExpiresImmediately() {
        let fake = FakeAssertions()
        let keepAwake = make(fake)
        keepAwake.start(.hour1)
        clock.addTimeInterval(3 * 3_600)
        keepAwake.handleWake()
        XCTAssertFalse(keepAwake.isActive)
        XCTAssertNil(keepAwake.timerFireDate)
        XCTAssertEqual(fake.released, [101])
    }

    func testObserveWakeIsIdempotentAndShutdownRemovesIt() {
        let keepAwake = make(FakeAssertions())
        keepAwake.observeWake()
        keepAwake.observeWake()
        keepAwake.shutdown()
        keepAwake.observeWake()
        keepAwake.shutdown()
    }

    func testIndefiniteNeverExpires() {
        let fake = FakeAssertions()
        let keepAwake = make(fake)
        keepAwake.start(.indefinite)
        clock.addTimeInterval(86_400 * 30)
        keepAwake.expireIfNeeded()
        XCTAssertTrue(keepAwake.isActive)
        keepAwake.stop()
    }

    func testRefusedAssertionLeavesItOffAndFlagsFailure() {
        let fake = FakeAssertions()
        fake.refuse = true
        let keepAwake = make(fake)
        keepAwake.start(.hour1)
        XCTAssertFalse(keepAwake.isActive)
        XCTAssertTrue(keepAwake.failed)
        XCTAssertNil(keepAwake.endsAt)
        fake.refuse = false
        keepAwake.start(.hour1)
        XCTAssertTrue(keepAwake.isActive)
        XCTAssertFalse(keepAwake.failed)
        keepAwake.stop()
    }

    func testToggleUsesSavedDuration() {
        let fake = FakeAssertions()
        let keepAwake = make(fake)
        UserDefaults.standard.set(KeepAwakeDuration.hours3.rawValue, forKey: Pref.keepAwakeDuration)
        defer { UserDefaults.standard.removeObject(forKey: Pref.keepAwakeDuration) }
        keepAwake.toggle()
        XCTAssertEqual(keepAwake.remaining(), 3 * 3_600)
        keepAwake.toggle()
        XCTAssertFalse(keepAwake.isActive)
    }

    func testRemainingText() {
        XCTAssertEqual(KeepAwake.remainingText(0), "Осталось меньше минуты")
        XCTAssertEqual(KeepAwake.remainingText(30), "Осталось 1 мин")
        XCTAssertEqual(KeepAwake.remainingText(12 * 60), "Осталось 12 мин")
        XCTAssertEqual(KeepAwake.remainingText(3_600), "Осталось 1 ч")
        XCTAssertEqual(KeepAwake.remainingText(2 * 3_600 + 15 * 60), "Осталось 2 ч 15 мин")
    }

    func testDurations() {
        XCTAssertEqual(KeepAwakeDuration.allCases.map(\.seconds), [nil, 3_600, 10_800, 28_800])
        XCTAssertEqual(KeepAwakeDuration.allCases.map(\.title), ["Пока не выключу", "1 час", "3 часа", "8 часов"])
    }

    /// Настоящий assertion: создаётся и снимается (проверка системного вызова, сон не запрещаем надолго).
    func testIOKitAssertionRoundTrip() {
        let provider = IOKitSleepAssertion()
        let id = provider.create(reason: "Mac Utils: тест")
        XCTAssertNotNil(id)
        if let id { provider.release(id) }
    }
}

import XCTest
@testable import MacUtils
@testable import MUCore

/// Перерыв не перекрывает запись, показ экрана и звонок.
final class BreakGuardTests: XCTestCase {
    func testBlockingActivitiesDeferTheBreak() {
        XCTAssertNil(BreakGuard.deferReason(busy: [], microphoneInUse: false))
        for reason in [BusyRegistry.Reason.screenRecording, .meetingRecording, .broadcast, .viewing, .scrollCapture] {
            XCTAssertEqual(BreakGuard.deferReason(busy: [reason], microphoneInUse: false), "идёт \(reason.title)", reason.rawValue)
        }
    }

    func testCallOnMicrophoneDefersTheBreak() {
        XCTAssertEqual(BreakGuard.deferReason(busy: [], microphoneInUse: true), "микрофон занят (звонок)")
    }

    /// Фоновая работа, которой оверлей не мешает, перерыв не откладывает.
    func testBackgroundWorkDoesNotDefer() {
        XCTAssertNil(BreakGuard.deferReason(busy: [.meetingProcessing, .uninstalling, .screenshotSaving], microphoneInUse: false))
    }

    /// Пока перерыв отложен, счёт не сбрасывается: сразу после звонка он снова «пора».
    func testScheduleStaysDueWhileDeferred() {
        var schedule = BreakSchedule()
        XCTAssertFalse(schedule.tick(dt: 60, idle: 0, interval: 120))
        XCTAssertTrue(schedule.tick(dt: 60, idle: 0, interval: 120))
        XCTAssertTrue(schedule.tick(dt: 15, idle: 30, interval: 120), "отложили — на следующем тике снова пора")
    }
}

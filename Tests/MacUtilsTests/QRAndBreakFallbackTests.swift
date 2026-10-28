import XCTest
@testable import MacUtils
@testable import MUWellbeing
@testable import MUQR

/// ⌃⌥Q: ⌘C — только запасной путь; перерыв: занятый микрофон откладывает не дольше 30 минут.
final class QRAndBreakFallbackTests: XCTestCase {
    // MARK: - QR

    /// Выделение точно пустое (AX ответил 0) — ⌘C скопировал бы строку или ячейку: не пробуем.
    func testCopyIsSkippedWhenSelectionIsKnownEmpty() {
        XCTAssertFalse(QRTools.shouldTryCopy(frontmost: "com.microsoft.VSCode", selectionLength: 0))
    }

    /// AX не отдал выделение (Chrome, Electron, Терминал) или оно есть — ⌘C пробуем.
    func testCopyIsTriedWhenSelectionIsUnknownOrPresent() {
        XCTAssertTrue(QRTools.shouldTryCopy(frontmost: "com.google.Chrome", selectionLength: nil))
        XCTAssertTrue(QRTools.shouldTryCopy(frontmost: "com.apple.Terminal", selectionLength: 12))
    }

    /// В Finder ⌘C копирует файлы — никогда.
    func testCopyIsNeverTriedInFinder() {
        XCTAssertFalse(QRTools.shouldTryCopy(frontmost: "com.apple.finder", selectionLength: nil))
        XCTAssertFalse(QRTools.shouldTryCopy(frontmost: "com.apple.finder", selectionLength: 5))
    }

    // MARK: - Перерыв

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testMicrophoneDefersUpToThirtyMinutesThenReminds() {
        var since: Date?
        XCTAssertEqual(BreakGuard.action(busy: [], microphoneInUse: true, microphoneSince: &since, now: start),
                       .postpone("микрофон занят (звонок)"))
        XCTAssertEqual(since, start)
        let almost = start.addingTimeInterval(BreakGuard.microphoneLimit - 15)
        XCTAssertEqual(BreakGuard.action(busy: [], microphoneInUse: true, microphoneSince: &since, now: almost),
                       .postpone("микрофон занят (звонок)"))
        XCTAssertEqual(since, start, "начало отсрочки не сдвигается")
        let limit = start.addingTimeInterval(BreakGuard.microphoneLimit)
        XCTAssertEqual(BreakGuard.action(busy: [], microphoneInUse: true, microphoneSince: &since, now: limit), .remind)
        XCTAssertNil(since, "после напоминания отсчёт начинается заново")
    }

    /// Звонок закончился до предела — обычный экран перерыва, отсчёт сброшен.
    func testFreeMicrophoneShowsBreakAndResetsCounter() {
        var since: Date? = start
        XCTAssertEqual(BreakGuard.action(busy: [], microphoneInUse: false, microphoneSince: &since,
                                         now: start.addingTimeInterval(600)), .show)
        XCTAssertNil(since)
        // Новый звонок — снова полные 30 минут.
        let later = start.addingTimeInterval(700)
        XCTAssertEqual(BreakGuard.action(busy: [], microphoneInUse: true, microphoneSince: &since, now: later),
                       .postpone("микрофон занят (звонок)"))
        XCTAssertEqual(since, later)
    }

    /// Запись и показ экрана Mac Utils откладывают без предела и не тратят «микрофонные» 30 минут.
    func testOwnRecordingDefersWithoutLimit() {
        var since: Date?
        let far = start.addingTimeInterval(10 * BreakGuard.microphoneLimit)
        for reason in BreakGuard.blockingReasons {
            XCTAssertEqual(BreakGuard.action(busy: [reason], microphoneInUse: true, microphoneSince: &since, now: far),
                           .postpone("идёт \(reason.title)"), reason.rawValue)
        }
        XCTAssertNil(since)
    }

    /// Фоновая работа не мешает перерыву.
    func testBackgroundWorkShowsBreak() {
        var since: Date?
        XCTAssertEqual(BreakGuard.action(busy: [.meetingProcessing, .uninstalling], microphoneInUse: false,
                                         microphoneSince: &since, now: start), .show)
    }
}

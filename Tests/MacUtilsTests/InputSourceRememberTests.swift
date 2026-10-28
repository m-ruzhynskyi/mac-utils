import XCTest
@testable import MacUtils
@testable import MUAppInputSource

/// «Раскладка по программам»: что запоминается как выбор пользователя.
final class InputSourceRememberTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func remember(secure: Bool = false, ownUntil: Date = .distantPast, activatedAt: Date? = nil,
                          front: String? = "ru.keepcoder.Telegram") -> Bool {
        InputSourceRules.shouldRemember(now: now, ownUntil: ownUntil, activatedAt: activatedAt, secure: secure,
                                        front: front, ownBundleID: "com.mruzhynskyi.macutils")
    }

    func testUserChoiceIsRemembered() {
        XCTAssertTrue(remember())
        XCTAssertTrue(remember(activatedAt: now.addingTimeInterval(-5)))
    }

    /// Поле пароля: система сама включает латиницу — это не выбор пользователя.
    func testSecureInputIsNotRemembered() {
        XCTAssertFalse(remember(secure: true))
    }

    func testOwnSwitchIsNotRemembered() {
        XCTAssertFalse(remember(ownUntil: now.addingTimeInterval(0.3)))
        XCTAssertTrue(remember(ownUntil: now.addingTimeInterval(-0.1)))
    }

    /// Уведомление пришло сразу после смены программы: оно может относиться к прошлой — не записываем за новую.
    func testRightAfterActivationIsNotRemembered() {
        XCTAssertFalse(remember(activatedAt: now.addingTimeInterval(-0.2)))
        XCTAssertTrue(remember(activatedAt: now.addingTimeInterval(-InputSourceRules.settleAfterActivation - 0.01)))
    }

    func testOwnAppAndUnknownAppAreSkipped() {
        XCTAssertFalse(remember(front: "com.mruzhynskyi.macutils"))
        XCTAssertFalse(remember(front: nil))
        XCTAssertFalse(remember(front: ""))
    }

    func testRulesWinOverRemembered() {
        XCTAssertEqual(InputSourceRules.target(for: "a", rules: [:], remembered: [:], remember: true), nil)
        XCTAssertEqual(InputSourceRules.target(for: "a", rules: [:], remembered: ["a": "ru"], remember: false), nil)
        XCTAssertEqual(InputSourceRules.target(for: "a", rules: ["a": "en"], remembered: ["a": "ru"], remember: true), "en")
    }
}

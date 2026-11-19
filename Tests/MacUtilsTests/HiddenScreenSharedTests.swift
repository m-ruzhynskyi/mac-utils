import XCTest
@testable import MUCore

/// HSCR-47: пока скрытый экран включён, переключатель ⌥Tab не показывает Claude и ChatGPT.
@MainActor
final class HiddenScreenSharedTests: XCTestCase {
    override func tearDown() { HiddenScreenShared.update(active: false, bundleIDs: []) }

    func testHidesOnlyWhileActive() {
        let set: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.chat"]
        XCTAssertTrue(HiddenScreenShared.hides("com.openai.chat", in: set))
        XCTAssertTrue(HiddenScreenShared.hides("COM.OPENAI.CHAT", in: set), "регистр не важен")
        XCTAssertFalse(HiddenScreenShared.hides("com.apple.finder", in: set))
        XCTAssertFalse(HiddenScreenShared.hides(nil, in: set))
        HiddenScreenShared.update(active: true, bundleIDs: ["com.anthropic.claudefordesktop"])
        XCTAssertTrue(HiddenScreenShared.isActive)
        XCTAssertTrue(HiddenScreenShared.hides("com.anthropic.claudefordesktop"))
        HiddenScreenShared.update(active: false, bundleIDs: ["com.anthropic.claudefordesktop"])
        XCTAssertFalse(HiddenScreenShared.isActive)
        XCTAssertFalse(HiddenScreenShared.hides("com.anthropic.claudefordesktop"), "выключено — в переключателе снова видны")
    }
}

import XCTest
@testable import MacUtils

final class InputSourceRulesTests: XCTestCase {
    func testRuleBeatsRemembered() {
        let rules = ["ru.keepcoder.Telegram": "com.apple.keylayout.Russian"]
        let remembered = ["ru.keepcoder.Telegram": "com.apple.keylayout.ABC",
                          "com.apple.Terminal": "com.apple.keylayout.ABC"]
        XCTAssertEqual(InputSourceRules.target(for: "ru.keepcoder.Telegram", rules: rules, remembered: remembered, remember: true),
                       "com.apple.keylayout.Russian")
        XCTAssertEqual(InputSourceRules.target(for: "com.apple.Terminal", rules: rules, remembered: remembered, remember: true),
                       "com.apple.keylayout.ABC")
        XCTAssertNil(InputSourceRules.target(for: "com.apple.Terminal", rules: rules, remembered: remembered, remember: false))
        XCTAssertNil(InputSourceRules.target(for: "com.apple.Safari", rules: rules, remembered: remembered, remember: true))
    }
}

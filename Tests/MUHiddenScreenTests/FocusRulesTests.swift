import CoreGraphics
@testable import MUHiddenScreen
import XCTest

/// Экран для зеркала и возврат фокуса (14.11: зеркало открылось на скрытом дисплее, активным остался ChatGPT).
final class FocusRulesTests: XCTestCase {
    // Как на Mac пользователя: основной 1710×1112 (AppKit: начало слева снизу), скрытый — справа, ниже.
    let main = FocusRules.Screen(id: 1, frame: CGRect(x: 0, y: 0, width: 1710, height: 1112),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1075))
    let hidden = FocusRules.Screen(id: 18, frame: CGRect(x: 1710, y: -860, width: 1440, height: 900),
                                   visibleFrame: CGRect(x: 1710, y: -860, width: 1440, height: 900))
    let external = FocusRules.Screen(id: 3, frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                                     visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1050))

    func testMirrorNeverGoesToHiddenDisplay() {
        // Курсор на скрытом дисплее (или NSScreen.main указывает туда) — всё равно основной.
        XCTAssertEqual(FocusRules.mirrorScreen([hidden, main], hidden: 18, mouse: CGPoint(x: 2000, y: -500))?.id, 1)
        XCTAssertEqual(FocusRules.mirrorScreen([main, hidden, external], hidden: 18, mouse: CGPoint(x: -100, y: 500))?.id, 3,
                       "экран с курсором")
        XCTAssertEqual(FocusRules.mirrorScreen([main, hidden], hidden: 18, mouse: CGPoint(x: 400, y: 300))?.id, 1)
        XCTAssertNil(FocusRules.mirrorScreen([hidden], hidden: 18, mouse: .zero))
    }

    func testCenteredFitsVisibleFrame() {
        XCTAssertEqual(FocusRules.centered(CGSize(width: 900, height: 700), in: main.visibleFrame),
                       CGRect(x: 405, y: 188, width: 900, height: 700))
        XCTAssertEqual(FocusRules.centered(CGSize(width: 3000, height: 2000), in: main.visibleFrame), main.visibleFrame)
    }

    func testRescueWhenMirrorTouchesHidden() {
        XCTAssertTrue(FocusRules.needsRescue(mirror: CGRect(x: 1980, y: -700, width: 900, height: 700), hiddenCocoa: hidden.frame))
        XCTAssertFalse(FocusRules.needsRescue(mirror: CGRect(x: 405, y: 188, width: 900, height: 700), hiddenCocoa: hidden.frame))
        XCTAssertFalse(FocusRules.needsRescue(mirror: .zero, hiddenCocoa: .null))
    }

    func testReclaimOnlyWhenNotOurOwnStep() {
        XCTAssertTrue(FocusRules.shouldReclaim(activatedIsTarget: true, mirrorShown: true, handoff: nil, stepsRunning: false))
        XCTAssertFalse(FocusRules.shouldReclaim(activatedIsTarget: true, mirrorShown: true, handoff: nil, stepsRunning: true),
                       "наш щелчок сам активирует ИИ на миллисекунды")
        XCTAssertFalse(FocusRules.shouldReclaim(activatedIsTarget: true, mirrorShown: true, handoff: .drag, stepsRunning: false),
                       "курсор у программы — протягивание или меню")
        XCTAssertFalse(FocusRules.shouldReclaim(activatedIsTarget: false, mirrorShown: true, handoff: nil, stepsRunning: false))
        XCTAssertFalse(FocusRules.shouldReclaim(activatedIsTarget: true, mirrorShown: false, handoff: nil, stepsRunning: false))
    }

    func testActivationModeArgument() {
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-activate=skylight"], storedBundleIDs: nil)?.activationMode, .skylight)
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug"], storedBundleIDs: nil)?.activationMode, .auto)
    }
}

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

    // 768c91b (14.11): Claude активировал себя сам через 0,1–1 с после щелчка, уведомление гасилось как эхо нашей активации.
    func testAISelfActivationIsReclaimedEvenRightAfterOurClick() {
        XCTAssertEqual(FocusRules.reaction(isTarget: true, isSelf: false, isEcho: false, stepsRunning: false, mirrorShown: true, handoff: nil),
                       .reclaim)
        XCTAssertEqual(FocusRules.reaction(isTarget: true, isSelf: false, isEcho: true, stepsRunning: false, mirrorShown: true, handoff: nil),
                       .reclaim, "эхо для ИИ не в счёт")
        XCTAssertEqual(FocusRules.reaction(isTarget: true, isSelf: false, isEcho: false, stepsRunning: true, mirrorShown: true, handoff: nil),
                       .ignore, "наш щелчок ещё идёт")
        XCTAssertEqual(FocusRules.reaction(isTarget: true, isSelf: false, isEcho: false, stepsRunning: false, mirrorShown: true, handoff: .menu),
                       .ignore, "меню открыто")
    }

    func testUserSwitchVersusOurReturn() {
        XCTAssertEqual(FocusRules.reaction(isTarget: false, isSelf: false, isEcho: false, stepsRunning: false, mirrorShown: true, handoff: nil),
                       .userSwitched)
        XCTAssertEqual(FocusRules.reaction(isTarget: false, isSelf: false, isEcho: true, stepsRunning: false, mirrorShown: true, handoff: nil),
                       .ignore, "наш возврат в Finder — фокус зеркала не снимать")
        XCTAssertEqual(FocusRules.reaction(isTarget: false, isSelf: true, isEcho: false, stepsRunning: false, mirrorShown: true, handoff: nil),
                       .ignore)
        XCTAssertEqual(FocusRules.reaction(isTarget: false, isSelf: false, isEcho: false, stepsRunning: true, mirrorShown: true, handoff: nil),
                       .ignore)
    }

    func testRechecksCoverLateSelfActivation() {
        XCTAssertLessThanOrEqual(FocusRules.recheckDelays.first ?? 1, 0.15, "первая проверка — раньше, чем пользователь начнёт печатать")
        XCTAssertGreaterThanOrEqual(FocusRules.recheckDelays.last ?? 0, 1.0, "14.11 Claude активировался до 1 с спустя")
    }

    func testReclaimLimiterBacksOff() {
        var limiter = ReclaimLimiter()
        for index in 0..<ReclaimLimiter.maximum { XCTAssertTrue(limiter.allow(at: Double(index) * 0.1)) }
        XCTAssertFalse(limiter.allow(at: 0.7), "не бороться бесконечно")
        XCTAssertTrue(limiter.allow(at: 3.05), "окно прошло")
    }

    func testHoverArgument() {
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug"], storedBundleIDs: nil)?.hover, true)
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-hover=off"], storedBundleIDs: nil)?.hover, false)
    }

    func testActivationModeArgument() {
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug", "--hs-activate=skylight"], storedBundleIDs: nil)?.activationMode, .skylight)
        XCTAssertEqual(HiddenScreenOptions.debug(arguments: ["--hidden-screen-debug"], storedBundleIDs: nil)?.activationMode, .auto)
    }
}

/// Строка меню не должна показывать ИИ (14.11): активность — программе пользователя, клавиши — через перехват.
final class KeyboardFocusTests: XCTestCase {
    func testKeysGoToMirrorOnlyWhenFocused() {
        XCTAssertEqual(FocusRules.keyDecision(code: 0, flags: [], mirrorFocused: false, handoff: nil), .pass)
        XCTAssertEqual(FocusRules.keyDecision(code: 0, flags: [], mirrorFocused: true, handoff: nil), .forward)
        XCTAssertEqual(FocusRules.keyDecision(code: MirrorKeys.v, flags: .maskCommand, mirrorFocused: true, handoff: nil), .forward)
        XCTAssertEqual(FocusRules.keyDecision(code: 0, flags: [], mirrorFocused: true, handoff: .menu), .pass,
                       "меню открыто — программа активна, стрелки и Return идут ей напрямую")
    }

    func testReservedShortcutsNeverReachZoomOrAI() {
        for code in [MirrorKeys.q, MirrorKeys.w, MirrorKeys.h, MirrorKeys.m, MirrorKeys.comma] {
            XCTAssertEqual(FocusRules.keyDecision(code: code, flags: .maskCommand, mirrorFocused: true, handoff: nil), .drop, "код \(code)")
        }
        XCTAssertEqual(FocusRules.keyDecision(code: MirrorKeys.tab, flags: .maskCommand, mirrorFocused: true, handoff: nil), .pass, "⌘Tab — системе")
    }

    func testWinKeysRewrite() {
        let v = MirrorKeys.winKeysRewrite(code: MirrorKeys.v, flags: .maskControl, enabled: true, disabled: [])
        XCTAssertEqual(v.code, MirrorKeys.v)
        XCTAssertEqual(v.flags, .maskCommand)
        let y = MirrorKeys.winKeysRewrite(code: 16, flags: .maskControl, enabled: true, disabled: [])   // kVK_ANSI_Y → ⇧⌘Z
        XCTAssertEqual(y.code, 6)
        XCTAssertEqual(y.flags, [.maskCommand, .maskShift])
        XCTAssertEqual(MirrorKeys.winKeysRewrite(code: MirrorKeys.v, flags: .maskControl, enabled: false, disabled: []).flags, .maskControl)
        XCTAssertEqual(MirrorKeys.winKeysRewrite(code: MirrorKeys.v, flags: .maskControl, enabled: true, disabled: ["v"]).flags, .maskControl)
        XCTAssertEqual(MirrorKeys.winKeysRewrite(code: 5, flags: .maskControl, enabled: true, disabled: []).flags, .maskControl, "Ctrl+G не трогаем")
    }

    func testUserAppIsNeitherAINorSelfNorLoginWindow() {
        XCTAssertTrue(FocusRules.isUserApp(isRegular: true, isTarget: false, isSelf: false, bundleID: "us.zoom.xos"))
        XCTAssertFalse(FocusRules.isUserApp(isRegular: true, isTarget: true, isSelf: false, bundleID: "com.openai.codex"))
        XCTAssertFalse(FocusRules.isUserApp(isRegular: false, isTarget: false, isSelf: true, bundleID: "com.mruzhynskyi.macutils"))
        XCTAssertFalse(FocusRules.isUserApp(isRegular: true, isTarget: false, isSelf: false, bundleID: "com.apple.loginwindow"))
    }

    func testOwnActivationEchoIsIgnoredOnce() {
        var echo = ActivationEcho()
        echo.note(500, at: 10)
        XCTAssertTrue(echo.consume(500, at: 10.3), "наш возврат в Zoom — не переключение пользователя")
        XCTAssertFalse(echo.consume(500, at: 10.4), "второй раз — уже пользователь")
        echo.note(600, at: 20)
        XCTAssertFalse(echo.consume(600, at: 21.5), "через секунду — не эхо")
        XCTAssertFalse(echo.consume(700, at: 20))
    }
}

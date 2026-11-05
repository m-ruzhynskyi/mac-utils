import XCTest
import CoreGraphics
@testable import MUWinKeys
@testable import MUCutPaste
@testable import MUCore

final class WinKeysTests: XCTestCase {
    private func decide(_ flags: CGEventFlags, key: Int64 = WinKeysRules.keyC, type: CGEventType = .keyDown,
                        app: String? = "com.apple.TextEdit", excluded: Bool = false, synthetic: Bool = false) -> WinKeysRules.Decision {
        WinKeysRules.decision(type: type, flags: flags, keyCode: key, bundleID: app, isExcluded: excluded, isSynthetic: synthetic)
    }

    func testOnlyControlIsRewritten() {
        for key in [WinKeysRules.keyC, WinKeysRules.keyV, WinKeysRules.keyX] {
            XCTAssertEqual(decide(.maskControl, key: key), .rewrite)
        }
    }

    func testControlWithOtherModifiersPassesThrough() {
        for extra: CGEventFlags in [.maskShift, .maskAlternate, .maskCommand] {
            XCTAssertEqual(decide([.maskControl, extra]), .passThrough)
        }
        XCTAssertEqual(decide([.maskControl, .maskShift, .maskAlternate, .maskCommand]), .passThrough)
    }

    func testNoControlPassesThrough() {
        XCTAssertEqual(decide([]), .passThrough)
        XCTAssertEqual(decide(.maskCommand), .passThrough)
        XCTAssertEqual(decide(.maskShift), .passThrough)
    }

    func testNeutralFlagsDoNotBlock() {
        XCTAssertEqual(decide([.maskControl, .maskAlphaShift]), .rewrite)
        XCTAssertEqual(decide([.maskControl, .maskNonCoalesced]), .rewrite)
    }

    func testOtherKeysPassThrough() {
        for key: Int64 in [0, 1, 6, 10, 11, 12, 13, 36, 53] {
            XCTAssertEqual(decide(.maskControl, key: key), .passThrough, "keycode \(key)")
        }
    }

    func testKeyUpIsRewrittenToo() {
        XCTAssertEqual(decide(.maskControl, type: .keyUp), .rewrite)
    }

    func testOtherEventTypesPassThrough() {
        XCTAssertEqual(decide(.maskControl, type: .flagsChanged), .passThrough)
        XCTAssertEqual(decide(.maskControl, type: .leftMouseDown), .passThrough)
    }

    func testTerminalsPassThrough() {
        let terminals = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                         "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper", "org.tabby"]
        for id in terminals {
            XCTAssertTrue(WinKeysRules.isTerminal(id), id)
            XCTAssertEqual(decide(.maskControl, app: id), .passThrough, id)
            XCTAssertEqual(decide(.maskControl, type: .keyUp, app: id), .passThrough, id)
        }
        XCTAssertFalse(WinKeysRules.isTerminal("com.apple.finder"))
        XCTAssertFalse(WinKeysRules.isTerminal(nil))
    }

    func testExcludedAppPassesThrough() {
        XCTAssertEqual(decide(.maskControl, excluded: true), .passThrough)
        XCTAssertEqual(decide(.maskControl, type: .keyUp, excluded: true), .passThrough)
    }

    func testSyntheticEventPassesThrough() {
        XCTAssertEqual(decide(.maskControl, synthetic: true), .passThrough)
    }

    func testUnknownFrontAppIsRewritten() {
        XCTAssertEqual(decide(.maskControl, app: nil), .rewrite)
    }

    func testRewrittenFlags() {
        XCTAssertEqual(WinKeysRules.rewritten(.maskControl), .maskCommand)
        let withCaps = WinKeysRules.rewritten([.maskControl, .maskAlphaShift])
        XCTAssertTrue(withCaps.contains(.maskCommand))
        XCTAssertTrue(withCaps.contains(.maskAlphaShift))
        XCTAssertFalse(withCaps.contains(.maskControl))
    }

    func testRewrittenKeepsSide() {
        XCTAssertEqual(WinKeysRules.rewritten(CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x1)).rawValue,
                       CGEventFlags.maskCommand.rawValue | 0x8)
        XCTAssertEqual(WinKeysRules.rewritten(CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)).rawValue,
                       CGEventFlags.maskCommand.rawValue | 0x10)
    }

    func testRewriteOnRealEventObject() throws {
        // Событие создаётся только в памяти и никуда не отправляется.
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true))
        event.flags = .maskControl
        event.flags = WinKeysRules.rewritten(event.flags)
        XCTAssertTrue(event.flags.contains(.maskCommand))
        XCTAssertFalse(event.flags.contains(.maskControl))
        XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 8)
    }

    func testDefaultIsOff() {
        let key = "winKeysEnabled"
        XCTAssertEqual(Pref.winKeys, key)
        XCTAssertFalse(UserDefaults(suiteName: "winkeys-test-\(UUID().uuidString)")!.bool(forKey: Pref.winKeys))
    }

    // MARK: - Finder

    func testFinderCutPasteChord() {
        XCTAssertTrue(CutRules.isCutPasteChord(flags: .maskCommand, winKeys: false))
        XCTAssertTrue(CutRules.isCutPasteChord(flags: .maskCommand, winKeys: true))
        XCTAssertFalse(CutRules.isCutPasteChord(flags: .maskControl, winKeys: false))
        XCTAssertTrue(CutRules.isCutPasteChord(flags: .maskControl, winKeys: true))
        XCTAssertFalse(CutRules.isCutPasteChord(flags: [.maskControl, .maskShift], winKeys: true))
        XCTAssertFalse(CutRules.isCutPasteChord(flags: [.maskControl, .maskCommand], winKeys: true))
        XCTAssertFalse(CutRules.isCutPasteChord(flags: [.maskCommand, .maskAlternate], winKeys: true))
        XCTAssertFalse(CutRules.isCutPasteChord(flags: [], winKeys: true))
    }
}

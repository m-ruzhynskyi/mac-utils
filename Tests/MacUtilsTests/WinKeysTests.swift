import XCTest
import Carbon.HIToolbox
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

    // MARK: - Свой список исключений

    private func decide(custom: [String], app: String?, key: Int64 = WinKeysRules.keyC) -> WinKeysRules.Decision {
        WinKeysRules.decision(type: .keyDown, flags: .maskControl, keyCode: key, bundleID: app,
                              isExcluded: false, isSynthetic: false, customExcluded: custom)
    }

    func testDefaultCustomListHasEditors() {
        let list = WinKeysRules.defaultExcluded
        XCTAssertTrue(list.contains("com.microsoft.VSCode"))
        XCTAssertTrue(list.contains("com.jetbrains."))
        XCTAssertTrue(list.contains("org.gnu.Emacs"))
        XCTAssertTrue(list.contains("org.vim.MacVim"))
        XCTAssertEqual(list.count, 5)
        // Терминалы остаются встроенным списком, а не частью своего.
        XCTAssertTrue(Set(list).isDisjoint(with: WinKeysRules.terminalBundleIDs))
    }

    func testCustomExactEntryPassesThrough() {
        XCTAssertEqual(decide(custom: WinKeysRules.defaultExcluded, app: "com.microsoft.VSCode"), .passThrough)
        XCTAssertEqual(decide(custom: ["com.example.Editor"], app: "com.example.editor"), .passThrough, "регистр не важен")
        for key in [WinKeysRules.keyC, WinKeysRules.keyV, WinKeysRules.keyX] {
            XCTAssertEqual(decide(custom: ["com.example.Editor"], app: "com.example.Editor", key: key), .passThrough)
        }
    }

    func testCustomExactEntryDoesNotMatchLongerId() {
        XCTAssertEqual(decide(custom: ["com.microsoft.VSCode"], app: "com.microsoft.VSCodeInsiders"), .rewrite)
        XCTAssertEqual(decide(custom: ["com.microsoft.VSCode"], app: "com.microsoft"), .rewrite)
    }

    func testCustomPrefixWithTrailingDot() {
        let list = WinKeysRules.defaultExcluded
        XCTAssertEqual(decide(custom: list, app: "com.jetbrains.intellij"), .passThrough)
        XCTAssertEqual(decide(custom: list, app: "com.jetbrains.AppCode-EAP"), .passThrough)
        XCTAssertEqual(decide(custom: list, app: "com.jetbrains."), .passThrough)
        XCTAssertEqual(decide(custom: list, app: "com.jetbrainsx.app"), .rewrite, "префикс требует точку")
        XCTAssertEqual(decide(custom: list, app: "com.jetbrains"), .rewrite)
    }

    func testProgramOutsideCustomListIsRewritten() {
        XCTAssertEqual(decide(custom: WinKeysRules.defaultExcluded, app: "com.apple.TextEdit"), .rewrite)
        XCTAssertEqual(decide(custom: [], app: "com.microsoft.VSCode"), .rewrite, "пустой список — ничего не исключено")
        XCTAssertEqual(decide(custom: WinKeysRules.defaultExcluded, app: nil), .rewrite)
        XCTAssertEqual(decide(custom: ["", " "], app: "com.apple.TextEdit"), .rewrite)
    }

    func testCustomListDoesNotChangeOtherRules() {
        let list = WinKeysRules.defaultExcluded
        // Терминал и общий список по-прежнему пропускают, свой список их не отменяет.
        XCTAssertEqual(decide(custom: list, app: "com.apple.Terminal"), .passThrough)
        XCTAssertEqual(WinKeysRules.decision(type: .keyDown, flags: .maskControl, keyCode: 8, bundleID: "com.apple.TextEdit",
                                             isExcluded: true, isSynthetic: false, customExcluded: []), .passThrough)
        XCTAssertEqual(WinKeysRules.decision(type: .keyDown, flags: [.maskControl, .maskShift], keyCode: 8, bundleID: "x",
                                             isExcluded: false, isSynthetic: false, customExcluded: []), .passThrough)
    }

    @MainActor
    func testCustomListIsSeparateFromGeneralExclusions() {
        XCTAssertEqual(Pref.winKeysExcluded, "winKeysExcludedApps")
        XCTAssertNotEqual(Pref.winKeysExcluded, AppExclusions.defaultsKey)
        // Список по умолчанию не пересекается с общим: редакторы не попали в «Исключённые программы».
        XCTAssertFalse(WinKeysRules.defaultExcluded.contains { AppExclusions.matches($0, in: AppExclusions.defaultList) })
    }

    @MainActor
    func testCustomListLoadAndDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "winkeys-excl-\(UUID().uuidString)"))
        XCTAssertEqual(WinKeysExclusions.load(defaults: defaults), WinKeysRules.defaultExcluded)
        defaults.set(["org.example.A"], forKey: Pref.winKeysExcluded)
        XCTAssertEqual(WinKeysExclusions.load(defaults: defaults), ["org.example.A"])
        defaults.set([String](), forKey: Pref.winKeysExcluded)
        XCTAssertEqual(WinKeysExclusions.load(defaults: defaults), [], "пустой сохранённый список — не значения по умолчанию")
    }

    @MainActor
    func testCustomListAddingTrimsAndDeduplicates() {
        var list = AppExclusions.adding("  org.example.Editor ", to: WinKeysRules.defaultExcluded)
        XCTAssertEqual(list.last, "org.example.Editor")
        list = AppExclusions.adding("ORG.EXAMPLE.EDITOR", to: list)
        XCTAssertEqual(list.filter { $0.lowercased() == "org.example.editor" }.count, 1)
        XCTAssertEqual(AppExclusions.adding("   ", to: list), list)
    }

    // MARK: - Предупреждение в записи сочетаний

    private func chord(_ keyCode: Int, _ modifiers: Int) -> LayoutHotKey { LayoutHotKey(keyCode: keyCode, modifiers: modifiers) }

    func testRecorderWarnsForExactlyControlCVX() {
        for code in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X] {
            XCTAssertEqual(WinKeysConflict.warning(for: chord(code, controlKey), winKeysEnabled: true),
                           "Это сочетание занято „Клавишами Windows“")
        }
    }

    func testRecorderDoesNotWarnWhenWinKeysAreOff() {
        for code in [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X] {
            XCTAssertNil(WinKeysConflict.warning(for: chord(code, controlKey), winKeysEnabled: false))
        }
    }

    func testRecorderDoesNotWarnForOtherChords() {
        // С другими модификаторами «Клавиши Windows» событие не трогают.
        XCTAssertNil(WinKeysConflict.warning(for: chord(kVK_ANSI_C, controlKey | shiftKey), winKeysEnabled: true))
        XCTAssertNil(WinKeysConflict.warning(for: chord(kVK_ANSI_C, controlKey | optionKey), winKeysEnabled: true))
        XCTAssertNil(WinKeysConflict.warning(for: chord(kVK_ANSI_C, controlKey | cmdKey), winKeysEnabled: true))
        XCTAssertNil(WinKeysConflict.warning(for: chord(kVK_ANSI_C, cmdKey), winKeysEnabled: true))
        XCTAssertNil(WinKeysConflict.warning(for: chord(kVK_ANSI_C, optionKey), winKeysEnabled: true))
        // Другие клавиши с ⌃.
        for code in [kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_B, kVK_Space, kVK_Return, kVK_ANSI_RightBracket] {
            XCTAssertNil(WinKeysConflict.warning(for: chord(code, controlKey), winKeysEnabled: true), "keycode \(code)")
        }
    }

    func testRecorderWarningAgreesWithTheRewriteRule() {
        // Предупреждение появляется ровно там, где правило перехвата заменяет Control (по коду клавиши, не по символу).
        for code in 0..<60 {
            let warned = WinKeysConflict.warning(for: chord(code, controlKey), winKeysEnabled: true) != nil
            let rewritten = WinKeysRules.decision(type: .keyDown, flags: .maskControl, keyCode: Int64(code), bundleID: nil,
                                                  isExcluded: false, isSynthetic: false) == .rewrite
            XCTAssertEqual(warned, rewritten, "keycode \(code)")
        }
    }
}

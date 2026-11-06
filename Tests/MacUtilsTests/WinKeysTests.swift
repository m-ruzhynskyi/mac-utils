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
        for key: Int64 in [2, 4, 5, 10, 11, 12, 13, 36, 53] {
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
        for code in [kVK_ANSI_B, kVK_ANSI_D, kVK_ANSI_E, kVK_Space, kVK_Return, kVK_ANSI_RightBracket] {
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

    func testRecordingShortcutPassesControlThrough() {
        // Во время записи сочетания в настройках ⌃C/⌃V/⌃X не заменяются: иначе рекордер получил бы ⌘C и не предупредил.
        for key in [WinKeysRules.keyC, WinKeysRules.keyV, WinKeysRules.keyX] {
            for type in [CGEventType.keyDown, .keyUp] {
                XCTAssertEqual(WinKeysRules.decision(type: type, flags: .maskControl, keyCode: key, bundleID: "com.apple.TextEdit",
                                                     isExcluded: false, isSynthetic: false, isRecordingShortcut: true), .passThrough)
            }
        }
        XCTAssertEqual(decide(.maskControl), .rewrite, "без записи — как раньше")
    }

    @MainActor
    func testShortcutRecordingIsBalanced() {
        XCTAssertFalse(ShortcutRecording.isActive)
        ShortcutRecording.begin()
        ShortcutRecording.begin()
        ShortcutRecording.end()
        XCTAssertTrue(ShortcutRecording.isActive, "второй рекордер ещё пишет")
        ShortcutRecording.end()
        XCTAssertFalse(ShortcutRecording.isActive)
        ShortcutRecording.end()
        XCTAssertEqual(ShortcutRecording.active, 0, "лишний end не уводит в минус")
    }

    // MARK: - Сочетания Ctrl+A / Z / Y / S / F

    private let allIDs = ["c", "v", "x", "a", "z", "y", "s", "f"]

    func testTableHasEightShortcutsWithExpectedCodes() {
        XCTAssertEqual(WinKeysShortcut.all.map(\.id), allIDs)
        let codes = Dictionary(uniqueKeysWithValues: WinKeysShortcut.all.map { ($0.id, ($0.keyCode, $0.targetKeyCode, $0.addsShift)) })
        XCTAssertTrue(codes["a"]! == (0, 0, false))
        XCTAssertTrue(codes["z"]! == (6, 6, false))
        XCTAssertTrue(codes["y"]! == (16, 6, true), "Ctrl+Y → ⇧⌘Z: код меняется 16 → 6, добавляется ⇧")
        XCTAssertTrue(codes["s"]! == (1, 1, false))
        XCTAssertTrue(codes["f"]! == (3, 3, false))
        XCTAssertTrue(codes["c"]! == (8, 8, false))
        XCTAssertTrue(codes["v"]! == (9, 9, false))
        XCTAssertTrue(codes["x"]! == (7, 7, false))
        XCTAssertEqual(WinKeysShortcut.all.first { $0.id == "y" }?.mac, "⇧⌘Z")
        XCTAssertEqual(WinKeysShortcut.all.first { $0.id == "a" }?.summary, "Выделить всё — как ⌘A")
    }

    func testEachShortcutIsRewrittenAndPlainKeysAreNot() {
        for shortcut in WinKeysShortcut.all {
            let code = Int64(shortcut.keyCode)
            XCTAssertEqual(decide(.maskControl, key: code), .rewrite, shortcut.windows)
            XCTAssertEqual(decide(.maskControl, key: code, type: .keyUp), .rewrite, shortcut.windows)
            for extra: CGEventFlags in [.maskShift, .maskAlternate, .maskCommand] {
                XCTAssertEqual(decide([.maskControl, extra], key: code), .passThrough, "\(shortcut.windows) + extra")
            }
            XCTAssertEqual(decide([], key: code), .passThrough)
            XCTAssertEqual(decide(.maskCommand, key: code), .passThrough)
        }
        for key: Int64 in [2, 4, 5, 10, 11, 12, 13, 14, 15, 17, 36, 49, 53] {
            XCTAssertEqual(decide(.maskControl, key: key), .passThrough, "keycode \(key)")
        }
    }

    func testSingleRewriteKeepsKeyAndSwapsControlForCommand() {
        for id in ["a", "z", "s", "f", "c", "v", "x"] {
            let shortcut = WinKeysShortcut.all.first { $0.id == id }!
            XCTAssertEqual(WinKeysRules.rewritten(.maskControl, for: shortcut), .maskCommand, id)
            XCTAssertEqual(shortcut.keyCode, shortcut.targetKeyCode)
        }
    }

    func testCtrlYBecomesShiftCommandZ() {
        let y = WinKeysRules.shortcut(forKeyCode: WinKeysRules.keyY)!
        let flags = WinKeysRules.rewritten([.maskControl, .maskAlphaShift], for: y)
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertFalse(flags.contains(.maskControl))
        XCTAssertTrue(flags.contains(.maskAlphaShift), "CapsLock не трогаем")
        XCTAssertEqual(y.targetKeyCode, Int(WinKeysRules.keyZ))
        // Левый Ctrl → левый Command и левый Shift.
        let left = WinKeysRules.rewritten(CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x1), for: y)
        XCTAssertEqual(left.rawValue, CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue | 0x8 | 0x2)
    }

    func testRewrittenWithoutControlLeavesFlagsAlone() {
        let y = WinKeysRules.shortcut(forKeyCode: WinKeysRules.keyY)!
        XCTAssertEqual(WinKeysRules.rewritten([], for: y), [])
        XCTAssertEqual(WinKeysRules.rewritten(.maskAlphaShift, for: y), .maskAlphaShift)
    }

    func testCtrlYRealEventObject() throws {
        // Событие создаётся только в памяти и никуда не отправляется.
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 16, keyDown: true))
        event.flags = .maskControl
        var pairing = WinKeysRules.Pairing()
        let out = try XCTUnwrap(translate(&pairing, .keyDown, event.flags, 16))
        event.flags = out.flags
        event.setIntegerValueField(.keyboardEventKeycode, value: out.keyCode)
        XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 6)
        XCTAssertTrue(event.flags.contains(.maskCommand))
        XCTAssertTrue(event.flags.contains(.maskShift))
        XCTAssertFalse(event.flags.contains(.maskControl))
    }

    func testDisabledShortcutPassesThroughOthersStayOn() {
        for shortcut in WinKeysShortcut.all {
            let code = Int64(shortcut.keyCode)
            let off = WinKeysRules.decision(type: .keyDown, flags: .maskControl, keyCode: code, bundleID: nil,
                                            isExcluded: false, isSynthetic: false, disabled: [shortcut.id])
            XCTAssertEqual(off, .passThrough, shortcut.windows)
            let other = Set(allIDs).subtracting([shortcut.id])
            let on = WinKeysRules.decision(type: .keyDown, flags: .maskControl, keyCode: code, bundleID: nil,
                                           isExcluded: false, isSynthetic: false, disabled: other)
            XCTAssertEqual(on, .rewrite, "\(shortcut.windows): выключены только остальные")
        }
    }

    func testExceptionsStillApplyToNewShortcuts() {
        for shortcut in WinKeysShortcut.all {
            let code = Int64(shortcut.keyCode)
            XCTAssertEqual(decide(.maskControl, key: code, app: "com.apple.Terminal"), .passThrough)
            XCTAssertEqual(decide(.maskControl, key: code, excluded: true), .passThrough)
            XCTAssertEqual(decide(.maskControl, key: code, synthetic: true), .passThrough)
            XCTAssertEqual(decide(custom: ["com.microsoft.VSCode"], app: "com.microsoft.VSCode", key: code), .passThrough)
            XCTAssertEqual(decide(custom: ["com.jetbrains."], app: "com.jetbrains.intellij", key: code), .passThrough)
            XCTAssertEqual(WinKeysRules.decision(type: .keyDown, flags: .maskControl, keyCode: code, bundleID: "com.apple.TextEdit",
                                                 isExcluded: false, isSynthetic: false, isRecordingShortcut: true), .passThrough)
        }
    }

    // MARK: - Нажатие и отпускание вместе

    private func translate(_ pairing: inout WinKeysRules.Pairing, _ type: CGEventType, _ flags: CGEventFlags, _ key: Int64,
                           app: String? = "com.apple.TextEdit", excluded: Bool = false, disabled: Set<String> = [],
                           custom: [String] = [], recording: Bool = false) -> WinKeysRules.Pairing.Output? {
        pairing.translate(type: type, flags: flags, keyCode: key, isSynthetic: false, isRecordingShortcut: recording,
                          customExcluded: custom, disabled: disabled, app: { (app, excluded) })
    }

    func testCtrlYKeyUpCarriesTheSameNewCode() throws {
        var pairing = WinKeysRules.Pairing()
        let down = try XCTUnwrap(translate(&pairing, .keyDown, .maskControl, 16))
        let up = try XCTUnwrap(translate(&pairing, .keyUp, .maskControl, 16))
        XCTAssertEqual(down.keyCode, 6)
        XCTAssertEqual(up.keyCode, 6, "keyUp приходит с тем же новым кодом, что и keyDown")
        XCTAssertEqual(down.flags, up.flags)
        XCTAssertTrue(up.flags.contains(.maskShift) && up.flags.contains(.maskCommand))
    }

    func testKeyUpAfterAppChangedFollowsKeyDown() throws {
        var pairing = WinKeysRules.Pairing()
        // keyDown ушёл в обычную программу, keyUp пришёл уже в исключённую (терминал, VS Code, общий список).
        _ = translate(&pairing, .keyDown, .maskControl, 16)
        for (app, excluded) in [("com.apple.Terminal", false), ("com.microsoft.VSCode", false), ("com.apple.TextEdit", true)] {
            var p = pairing
            let up = try XCTUnwrap(translate(&p, .keyUp, .maskControl, 16, app: app, excluded: excluded, custom: ["com.microsoft.VSCode"]),
                                   "\(app) excluded=\(excluded)")
            XCTAssertEqual(up.keyCode, 6)
            XCTAssertTrue(up.flags.contains(.maskCommand))
        }
    }

    func testKeyUpAfterPassThroughStaysUntouched() {
        var pairing = WinKeysRules.Pairing()
        // keyDown в исключённой программе прошёл как есть; keyUp в обычной не должен превратиться в ⌘Z.
        XCTAssertNil(translate(&pairing, .keyDown, .maskControl, 16, app: "com.apple.Terminal"))
        XCTAssertNil(translate(&pairing, .keyUp, .maskControl, 16, app: "com.apple.TextEdit"))
        // Следующее нажатие снова переписывается.
        XCTAssertNotNil(translate(&pairing, .keyDown, .maskControl, 16))
    }

    func testKeyUpAfterControlReleasedFirstStillSwapsCode() throws {
        var pairing = WinKeysRules.Pairing()
        _ = translate(&pairing, .keyDown, .maskControl, 16)
        // Ctrl отпущен раньше буквы: у keyUp уже нет Control, но Y не должна остаться «нажатой» без пары.
        let up = try XCTUnwrap(translate(&pairing, .keyUp, [], 16))
        XCTAssertEqual(up.keyCode, 6)
        XCTAssertEqual(up.flags, [])
    }

    func testKeyUpAfterShortcutWasDisabledStillPairs() throws {
        var pairing = WinKeysRules.Pairing()
        _ = translate(&pairing, .keyDown, .maskControl, 6)
        let up = try XCTUnwrap(translate(&pairing, .keyUp, .maskControl, 6, disabled: ["z"]))
        XCTAssertEqual(up.keyCode, 6)
        XCTAssertTrue(up.flags.contains(.maskCommand))
    }

    func testAutorepeatKeyDownsAreRewrittenEachTime() throws {
        var pairing = WinKeysRules.Pairing()
        for _ in 0..<3 {
            XCTAssertEqual(try XCTUnwrap(translate(&pairing, .keyDown, .maskControl, 16)).keyCode, 6)
        }
        XCTAssertEqual(try XCTUnwrap(translate(&pairing, .keyUp, .maskControl, 16)).keyCode, 6)
        XCTAssertNil(translate(&pairing, .keyUp, [], 16, disabled: ["y"]), "после пары запись очищена")
    }

    func testDisabledShortcutThroughPairing() {
        var pairing = WinKeysRules.Pairing()
        XCTAssertNil(translate(&pairing, .keyDown, .maskControl, 0, disabled: ["a"]))
        XCTAssertNil(translate(&pairing, .keyUp, .maskControl, 0, disabled: ["a"]))
        XCTAssertNotNil(translate(&pairing, .keyDown, .maskControl, 0))
    }

    func testPairingIgnoresOtherKeysAndEvents() {
        var pairing = WinKeysRules.Pairing()
        XCTAssertNil(translate(&pairing, .keyDown, .maskControl, 12))
        XCTAssertNil(translate(&pairing, .flagsChanged, .maskControl, 16))
        XCTAssertNil(translate(&pairing, .keyDown, [], 16))
        XCTAssertNil(translate(&pairing, .keyDown, [.maskControl, .maskShift], 16))
    }

    func testPairingDoesNotAskForFrontAppWhenNotNeeded() {
        var pairing = WinKeysRules.Pairing()
        var asked = 0
        _ = pairing.translate(type: .keyDown, flags: [], keyCode: 16, isSynthetic: false, isRecordingShortcut: false,
                              customExcluded: [], disabled: [], app: { asked += 1; return (nil, false) })
        _ = pairing.translate(type: .keyDown, flags: .maskControl, keyCode: 16, isSynthetic: false, isRecordingShortcut: false,
                              customExcluded: [], disabled: ["y"], app: { asked += 1; return (nil, false) })
        XCTAssertEqual(asked, 0)
        _ = pairing.translate(type: .keyDown, flags: .maskControl, keyCode: 16, isSynthetic: false, isRecordingShortcut: false,
                              customExcluded: [], disabled: [], app: { asked += 1; return (nil, false) })
        XCTAssertEqual(asked, 1)
    }

    // MARK: - Настройка «выключенные»

    func testDisabledSetDefaultsAndRoundTrip() throws {
        XCTAssertEqual(Pref.winKeysDisabled, "winKeysDisabledShortcuts")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "winkeys-off-\(UUID().uuidString)"))
        XCTAssertEqual(WinKeysShortcut.loadDisabled(defaults: defaults), [], "по умолчанию включены все")
        WinKeysShortcut.saveDisabled(["f", "a"], defaults: defaults)
        XCTAssertEqual(defaults.array(forKey: Pref.winKeysDisabled) as? [String], ["a", "f"])
        XCTAssertEqual(WinKeysShortcut.loadDisabled(defaults: defaults), ["a", "f"])
        WinKeysShortcut.saveDisabled([], defaults: defaults)
        XCTAssertNil(defaults.object(forKey: Pref.winKeysDisabled))
    }

    // MARK: - Предупреждение для всех сочетаний

    func testRecorderWarnsForEveryEnabledShortcut() {
        for shortcut in WinKeysShortcut.all {
            XCTAssertEqual(WinKeysConflict.warning(for: chord(shortcut.keyCode, controlKey), winKeysEnabled: true),
                           "Это сочетание занято „Клавишами Windows“", shortcut.windows)
        }
    }

    func testRecorderDoesNotWarnForDisabledShortcutOrWinKeysOff() {
        for shortcut in WinKeysShortcut.all {
            XCTAssertNil(WinKeysConflict.warning(for: chord(shortcut.keyCode, controlKey), winKeysEnabled: true, disabled: [shortcut.id]))
            XCTAssertNil(WinKeysConflict.warning(for: chord(shortcut.keyCode, controlKey), winKeysEnabled: false))
            XCTAssertNil(WinKeysConflict.warning(for: chord(shortcut.keyCode, controlKey | shiftKey), winKeysEnabled: true))
            XCTAssertNil(WinKeysConflict.warning(for: chord(shortcut.keyCode, controlKey | optionKey), winKeysEnabled: true))
        }
        // Выключено только одно: соседнее по-прежнему предупреждает.
        XCTAssertNotNil(WinKeysConflict.warning(for: chord(kVK_ANSI_Z, controlKey), winKeysEnabled: true, disabled: ["a"]))
    }
}

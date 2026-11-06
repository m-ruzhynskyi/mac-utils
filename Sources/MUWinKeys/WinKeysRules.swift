import CoreGraphics
import Foundation
import MUCore

/// Правила «Клавиш Windows» без системных вызовов (для тестов): когда Ctrl+C / V / X / A / Z / Y / S / F заменяются на
/// сочетания Mac (⌘C … ⌘F; Ctrl+Y → ⇧⌘Z). Таблица сочетаний — `WinKeysShortcut.all`.
package enum WinKeysRules {
    package static let keyX: Int64 = 7
    package static let keyC: Int64 = 8
    package static let keyV: Int64 = 9
    package static let keyA: Int64 = 0
    package static let keyZ: Int64 = 6
    package static let keyY: Int64 = 16
    package static let keyS: Int64 = 1
    package static let keyF: Int64 = 3

    package static func shortcut(forKeyCode code: Int64) -> WinKeysShortcut? { WinKeysShortcut.forKeyCode(Int(code)) }

    /// Терминалы: Ctrl+C там прерывает команду, Ctrl+V и Ctrl+X тоже имеют свой смысл.
    package static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "dev.warp.Warp", "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty",
        "co.zeit.hyper", "org.tabby",
    ]

    /// Свой список по умолчанию: редакторы и среды разработки, где Ctrl+C/V/X имеют свой смысл или уже настроены.
    /// Запись с точкой на конце — префикс bundle id (все программы JetBrains), иначе точное совпадение.
    package static let defaultExcluded: [String] = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.jetbrains.", "org.gnu.Emacs", "org.vim.MacVim",
    ]

    package static func isTerminal(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return terminalBundleIDs.contains(bundleID)
    }

    package enum Decision: Equatable {
        case passThrough
        /// Заменить Control на Command в событии и пропустить его дальше.
        case rewrite
    }

    /// Решение по событию. Только нажатия и отпускания (`keyDown`/`keyUp`); сопоставление по коду клавиши, а не по символу,
    /// поэтому работает и в русской раскладке. Ровно Control: с ⌘, ⌥ или ⇧ событие не трогаем. `customExcluded` — свой список
    /// «Клавиш Windows» (точное совпадение или префикс с точкой на конце, как в `AppExclusions`). `isRecordingShortcut` —
    /// идёт запись сочетания в настройках Mac Utils: ⌃C должен попасть в запись как ⌃C, а не как ⌘C. `disabled` — идентификаторы
    /// выключенных сочетаний (`WinKeysShortcut.id`): они проходят как есть.
    package static func decision(type: CGEventType, flags: CGEventFlags, keyCode: Int64, bundleID: String?,
                                 isExcluded: Bool, isSynthetic: Bool, customExcluded: [String] = [],
                                 isRecordingShortcut: Bool = false, disabled: Set<String> = []) -> Decision {
        guard type == .keyDown || type == .keyUp else { return .passThrough }
        guard let shortcut = shortcut(forKeyCode: keyCode), !disabled.contains(shortcut.id) else { return .passThrough }
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        guard flags.intersection(modifiers) == .maskControl else { return .passThrough }
        if isSynthetic || isRecordingShortcut || isExcluded || isTerminal(bundleID) || AppExclusions.matches(bundleID, in: customExcluded) { return .passThrough }
        return .rewrite
    }

    // Биты конкретной (левой/правой) клавиши в флагах события (NX_DEVICE*KEYMASK): часть программ смотрит и на них.
    private static let leftControl: UInt64 = 0x0001
    private static let rightControl: UInt64 = 0x2000
    private static let leftCommand: UInt64 = 0x0008
    private static let rightCommand: UInt64 = 0x0010

    /// Флаги после замены: Control → Command (вместе с битами левой/правой клавиши), остальные флаги как были.
    package static func rewritten(_ flags: CGEventFlags) -> CGEventFlags {
        var raw = flags.rawValue
        raw &= ~CGEventFlags.maskControl.rawValue
        raw |= CGEventFlags.maskCommand.rawValue
        if raw & leftControl != 0 { raw = (raw & ~leftControl) | leftCommand }
        if raw & rightControl != 0 { raw = (raw & ~rightControl) | rightCommand }
        return CGEventFlags(rawValue: raw)
    }

    private static let leftShift: UInt64 = 0x0002

    /// Флаги после замены для сочетания: Control → Command, у Ctrl+Y ещё и Shift. Если Control уже отпущен (keyUp после
    /// отпускания Ctrl), флаги не трогаем: менять в них нечего.
    package static func rewritten(_ flags: CGEventFlags, for shortcut: WinKeysShortcut) -> CGEventFlags {
        guard flags.contains(.maskControl) else { return flags }
        var result = rewritten(flags)
        if shortcut.addsShift { result = CGEventFlags(rawValue: result.rawValue | CGEventFlags.maskShift.rawValue | leftShift) }
        return result
    }

    /// Подмены, сделанные при нажатии, помнятся по исходному коду клавиши до её отпускания. Отпускание получает ту же
    /// подмену (тот же новый код и флаги), даже если программа сменилась, Ctrl уже отпущен или сочетание выключили:
    /// иначе у Ctrl+Y нажатие ушло бы как Z, а отпускание как Y, и «Z» осталась бы нажатой.
    package struct Pairing {
        private enum Entry { case rewritten(WinKeysShortcut), passed }
        private var held: [Int64: Entry] = [:]

        package init() {}

        package struct Output: Equatable {
            package let keyCode: Int64
            package let flags: CGEventFlags
        }

        /// Что сделать с событием: `nil` — пропустить как есть. `app` вызывается только для подходящего сочетания
        /// (узнавать активную программу на каждое нажатие незачем).
        package mutating func translate(type: CGEventType, flags: CGEventFlags, keyCode: Int64, isSynthetic: Bool,
                                        isRecordingShortcut: Bool, customExcluded: [String], disabled: Set<String>,
                                        app: () -> (bundleID: String?, isExcluded: Bool)) -> Output? {
            guard type == .keyDown || type == .keyUp, let shortcut = WinKeysRules.shortcut(forKeyCode: keyCode) else { return nil }
            if type == .keyUp, let entry = held.removeValue(forKey: keyCode) {
                guard case .rewritten(let done) = entry else { return nil }
                return Output(keyCode: Int64(done.targetKeyCode), flags: WinKeysRules.rewritten(flags, for: done))
            }
            var output: Output?
            let cheap = WinKeysRules.decision(type: type, flags: flags, keyCode: keyCode, bundleID: nil, isExcluded: false,
                                              isSynthetic: isSynthetic, isRecordingShortcut: isRecordingShortcut, disabled: disabled)
            if cheap == .rewrite {
                let front = app()
                let full = WinKeysRules.decision(type: type, flags: flags, keyCode: keyCode, bundleID: front.bundleID,
                                                 isExcluded: front.isExcluded, isSynthetic: isSynthetic, customExcluded: customExcluded,
                                                 isRecordingShortcut: isRecordingShortcut, disabled: disabled)
                if full == .rewrite {
                    output = Output(keyCode: Int64(shortcut.targetKeyCode), flags: WinKeysRules.rewritten(flags, for: shortcut))
                }
            }
            if type == .keyDown { held[keyCode] = output == nil ? .passed : .rewritten(shortcut) }
            return output
        }
    }
}

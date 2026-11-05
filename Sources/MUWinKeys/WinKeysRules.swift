import CoreGraphics
import Foundation

/// Правила «Клавиш Windows» без системных вызовов (для тестов): когда Ctrl+C / Ctrl+V / Ctrl+X заменяются на ⌘C / ⌘V / ⌘X.
package enum WinKeysRules {
    package static let keyX: Int64 = 7
    package static let keyC: Int64 = 8
    package static let keyV: Int64 = 9

    /// Терминалы: Ctrl+C там прерывает команду, Ctrl+V и Ctrl+X тоже имеют свой смысл.
    package static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "dev.warp.Warp", "com.github.wez.wezterm", "org.alacritty", "net.kovidgoyal.kitty",
        "co.zeit.hyper", "org.tabby",
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
    /// поэтому работает и в русской раскладке. Ровно Control: с ⌘, ⌥ или ⇧ событие не трогаем.
    package static func decision(type: CGEventType, flags: CGEventFlags, keyCode: Int64, bundleID: String?,
                                 isExcluded: Bool, isSynthetic: Bool) -> Decision {
        guard type == .keyDown || type == .keyUp else { return .passThrough }
        guard [keyX, keyC, keyV].contains(keyCode) else { return .passThrough }
        let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        guard flags.intersection(modifiers) == .maskControl else { return .passThrough }
        if isSynthetic || isExcluded || isTerminal(bundleID) { return .passThrough }
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
}

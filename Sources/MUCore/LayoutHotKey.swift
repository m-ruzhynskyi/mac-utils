import Carbon.HIToolbox
import AppKit

/// Горячая клавиша «Раскладки»: код клавиши (не символ — работает в любой
/// раскладке: ⌘] = ⌘Ъ, ⌘P = ⌘З) и модификаторы Carbon.
package struct LayoutHotKey: Equatable {
    package var keyCode: Int
    package var modifiers: Int

    package static let commandBracket = LayoutHotKey(keyCode: kVK_ANSI_RightBracket, modifiers: cmdKey)
    package static let controlOptionV = LayoutHotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey)

    /// Сочетание из настроек по паре ключей (код клавиши и модификаторы).
    package static func load(codeKey: String, modifiersKey: String, default value: LayoutHotKey) -> LayoutHotKey {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: codeKey) != nil else { return value }
        return LayoutHotKey(keyCode: defaults.integer(forKey: codeKey), modifiers: defaults.integer(forKey: modifiersKey))
    }

    package func save(codeKey: String, modifiersKey: String) {
        UserDefaults.standard.set(keyCode, forKey: codeKey)
        UserDefaults.standard.set(modifiers, forKey: modifiersKey)
    }
    package static let commandP = LayoutHotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey)
    package static let presets: [LayoutHotKey] = [
        .commandBracket,
        .commandP,
        LayoutHotKey(keyCode: kVK_Space, modifiers: optionKey | shiftKey),
        LayoutHotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey),
    ]

    package static var current: LayoutHotKey {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Pref.layoutFixKeyCode) != nil else { return .commandBracket }
        return LayoutHotKey(keyCode: defaults.integer(forKey: Pref.layoutFixKeyCode),
                            modifiers: defaults.integer(forKey: Pref.layoutFixModifiers))
    }

    package func save() {
        UserDefaults.standard.set(keyCode, forKey: Pref.layoutFixKeyCode)
        UserDefaults.standard.set(modifiers, forKey: Pref.layoutFixModifiers)
    }

    /// Из нажатия в окне настроек; нужен хотя бы один из ⌘ ⌥ ⌃.
    package init?(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        guard modifiers != 0 else { return nil }
        if flags.contains(.shift) { modifiers |= shiftKey }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers)
    }

    package init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    package var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & cmdKey != 0 { flags.insert(.maskCommand) }
        if modifiers & optionKey != 0 { flags.insert(.maskAlternate) }
        if modifiers & controlKey != 0 { flags.insert(.maskControl) }
        if modifiers & shiftKey != 0 { flags.insert(.maskShift) }
        return flags
    }

    /// Символы для показа: ⌃⌥⇧⌘ + клавиша.
    package var keys: [String] {
        var result: [String] = []
        if modifiers & controlKey != 0 { result.append("⌃") }
        if modifiers & optionKey != 0 { result.append("⌥") }
        if modifiers & shiftKey != 0 { result.append("⇧") }
        if modifiers & cmdKey != 0 { result.append("⌘") }
        result.append(Self.keyName(keyCode))
        return result
    }

    package var title: String { keys.joined() }

    /// Чьё стандартное сочетание перекрывается.
    package var conflictNote: String? {
        switch self {
        case .commandBracket: return "⌘] (⌘Ъ) — это «Вперёд» в Safari и Finder и «сдвинуть вправо» в редакторах кода: пока исправление включено, они работать не будут."
        case .commandP: return "⌘P (⌘З) заменяет «Печать» во всех приложениях, пока исправление раскладки включено."
        default: return nil
        }
    }

    private static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [
            kVK_Space: "Пробел", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "Esc", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[code] { return name }
        // Буквы и цифры — по английской раскладке (QWERTY).
        let ansi: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P (З)", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
            kVK_ANSI_9: "9", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "] (Ъ)", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        return ansi[code] ?? "#\(code)"
    }
}

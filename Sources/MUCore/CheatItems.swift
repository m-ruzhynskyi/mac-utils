import Foundation

/// Сочетание пункта меню в виде «⌃⌥⇧⌘K» (без UI — для тестов).
package enum ShortcutFormat {
    /// kAXMenuItemCmdModifiers: 1 — ⇧, 2 — ⌥, 4 — ⌃, 8 — без ⌘.
    package static func modifiers(_ mask: Int) -> String {
        var result = ""
        if mask & 4 != 0 { result += "⌃" }
        if mask & 2 != 0 { result += "⌥" }
        if mask & 1 != 0 { result += "⇧" }
        if mask & 8 == 0 { result += "⌘" }
        return result
    }

    /// Клавиша: символ из меню или значок для служебных (kAXMenuItemCmdGlyph).
    package static func key(char: String?, glyph: Int?) -> String? {
        if let char, !char.isEmpty, char != "\u{0}" {
            switch char {
            case " ": return "Пробел"
            case "\u{1B}": return "Esc"
            case "\r": return "↩"
            case "\t": return "⇥"
            case "\u{7F}", "\u{8}": return "⌫"
            default: return char.uppercased()
            }
        }
        guard let glyph else { return nil }
        let glyphs: [Int: String] = [
            0x02: "⇥", 0x04: "⌅", 0x0B: "↩", 0x17: "⌫", 0x1B: "Esc", 0x09: "Пробел",
            0x64: "←", 0x65: "→", 0x68: "↑", 0x6A: "↓", 0x0A: "⌦",
            0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6",
            0x75: "F7", 0x76: "F8", 0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12",
            0x62: "⇞", 0x6B: "⇟", 0x66: "↖", 0x67: "↘",
        ]
        return glyphs[glyph]
    }
}

package struct CheatItem: Identifiable, Hashable {
    package let id = UUID()
    package let title: String
    package let shortcut: String

    package init(title: String, shortcut: String) { self.title = title; self.shortcut = shortcut }
}

package struct CheatGroup: Identifiable {
    package let id = UUID()
    package let title: String
    package let items: [CheatItem]

    package init(title: String, items: [CheatItem]) { self.title = title; self.items = items }
}

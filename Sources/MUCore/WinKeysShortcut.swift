import Carbon.HIToolbox
import Foundation

/// Сочетание Windows, которое «Клавиши Windows» переписывают в сочетание Mac: Ctrl+<клавиша> → ⌘<клавиша> (Ctrl+Y → ⇧⌘Z).
/// Клавиша — по коду, а не по символу: работает в любой раскладке. Каждое сочетание включается отдельно.
package struct WinKeysShortcut: Equatable, Identifiable {
    /// Стабильный идентификатор для настройки (`Pref.winKeysDisabled`).
    package let id: String
    package let letter: String
    package let keyCode: Int
    /// Код клавиши в событии после замены: у Ctrl+Y он меняется (Y → Z), у остальных тот же.
    package let targetKeyCode: Int
    /// К Command добавляется Shift (Ctrl+Y → ⇧⌘Z).
    package let addsShift: Bool
    package let title: String
    package let note: String?

    package var windows: String { "Ctrl+\(letter)" }
    package var mac: String { (addsShift ? "⇧⌘" : "⌘") + (addsShift ? "Z" : letter) }
    /// Подпись для страницы: «Выделить всё — как ⌘A».
    package var summary: String { "\(title) — как \(mac)" + (note.map { ". " + $0 } ?? "") }

    private init(_ letter: String, _ keyCode: Int, to target: Int? = nil, shift: Bool = false, _ title: String, note: String? = nil) {
        self.id = letter.lowercased()
        self.letter = letter
        self.keyCode = keyCode
        self.targetKeyCode = target ?? keyCode
        self.addsShift = shift
        self.title = title
        self.note = note
    }

    /// Все сочетания, в порядке показа на странице.
    package static let all: [WinKeysShortcut] = [
        WinKeysShortcut("C", kVK_ANSI_C, "Копировать"),
        WinKeysShortcut("V", kVK_ANSI_V, "Вставить"),
        WinKeysShortcut("X", kVK_ANSI_X, "Вырезать", note: "В Finder перемещает файлы, если включено «Вырезать и вставить»."),
        WinKeysShortcut("A", kVK_ANSI_A, "Выделить всё"),
        WinKeysShortcut("Z", kVK_ANSI_Z, "Отменить"),
        WinKeysShortcut("Y", kVK_ANSI_Y, to: kVK_ANSI_Z, shift: true, "Повторить"),
        WinKeysShortcut("S", kVK_ANSI_S, "Сохранить"),
        WinKeysShortcut("F", kVK_ANSI_F, "Найти"),
    ]

    package static func forKeyCode(_ code: Int) -> WinKeysShortcut? { all.first { $0.keyCode == code } }

    // MARK: - Какие сочетания выключены

    package static func loadDisabled(defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.array(forKey: Pref.winKeysDisabled) as? [String]) ?? [])
    }

    package static func saveDisabled(_ ids: Set<String>, defaults: UserDefaults = .standard) {
        if ids.isEmpty { defaults.removeObject(forKey: Pref.winKeysDisabled) } else { defaults.set(ids.sorted(), forKey: Pref.winKeysDisabled) }
    }
}

import Carbon.HIToolbox

/// Сочетания, которые «Клавиши Windows» перехватывают сами: ровно ⌃C, ⌃V, ⌃X (по коду клавиши, в любой раскладке).
package enum WinKeysConflict {
    package static let message = "Это сочетание занято „Клавишами Windows“"

    /// Предупреждение для записанного сочетания; `nil` — конфликта нет. Запись сочетания не блокируется.
    package static func warning(for key: LayoutHotKey, winKeysEnabled: Bool) -> String? {
        guard winKeysEnabled else { return nil }
        let mask = cmdKey | optionKey | controlKey | shiftKey
        guard key.modifiers & mask == controlKey else { return nil }
        return [kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V].contains(key.keyCode) ? message : nil
    }

    /// То же при текущем значении настройки «Клавиши Windows».
    package static func warning(for key: LayoutHotKey) -> String? {
        warning(for: key, winKeysEnabled: UserDefaults.standard.bool(forKey: Pref.winKeys))
    }
}

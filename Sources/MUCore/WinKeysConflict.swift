import Carbon.HIToolbox

/// Сочетания, которые «Клавиши Windows» перехватывают сами: ровно ⌃ и одна из клавиш включённых сочетаний
/// (C, V, X, A, Z, Y, S, F; по коду клавиши, в любой раскладке).
package enum WinKeysConflict {
    package static let message = "Это сочетание занято „Клавишами Windows“"

    /// Предупреждение для записанного сочетания; `nil` — конфликта нет. Запись сочетания не блокируется.
    /// `disabled` — идентификаторы выключенных сочетаний: их клавиши свободны.
    package static func warning(for key: LayoutHotKey, winKeysEnabled: Bool, disabled: Set<String> = []) -> String? {
        guard winKeysEnabled else { return nil }
        let mask = cmdKey | optionKey | controlKey | shiftKey
        guard key.modifiers & mask == controlKey else { return nil }
        guard let shortcut = WinKeysShortcut.forKeyCode(key.keyCode), !disabled.contains(shortcut.id) else { return nil }
        return message
    }

    /// То же при текущих значениях настроек «Клавиши Windows».
    package static func warning(for key: LayoutHotKey) -> String? {
        warning(for: key, winKeysEnabled: UserDefaults.standard.bool(forKey: Pref.winKeys),
                disabled: WinKeysShortcut.loadDisabled())
    }
}

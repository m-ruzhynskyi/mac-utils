import Carbon.HIToolbox

/// Последнее набранное слово и пробелы после него — как они были набраны (чистая логика, без событий системы).
/// Нужно, чтобы горячая клавиша знала, сколько символов стереть и что перевести.
struct WordTracker: Equatable {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let control = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    static let maxWordLength = 64

    private(set) var word = ""
    private(set) var trailing = ""

    /// Клавиши, после которых курсор мог уйти или текст изменился не так, как набрано.
    private static let resettingKeys: Set<Int> = [
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_ForwardDelete,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
    ]

    mutating func reset() {
        word = ""
        trailing = ""
    }

    /// После замены слово хранится в новом виде — повторное нажатие вернёт как было.
    mutating func replace(word: String, trailing: String) {
        self.word = word
        self.trailing = trailing
    }

    /// Нажатие клавиши (не наше синтетическое). `characters` — что она напечатала в текущей раскладке.
    mutating func feed(keyCode: Int, modifiers: Modifiers, characters: String?) {
        // ⌘ и ⌃ — команды, текст мог измениться как угодно.
        if modifiers.contains(.command) || modifiers.contains(.control) {
            reset()
            return
        }
        if keyCode == kVK_Delete {
            // ⌥⌫ стирает слово целиком: наше «слово» уже не в тексте.
            if modifiers.contains(.option) {
                reset()
            } else if !trailing.isEmpty {
                trailing.removeLast()
            } else if !word.isEmpty {
                word.removeLast()
            }
            return
        }
        // Навигация и удаление вперёд сбрасывают слово при любых модификаторах (⌥← прыгает по словам, ⇧← выделяет).
        if Self.resettingKeys.contains(keyCode) {
            reset()
            return
        }
        // ⌥ + буква (польская, украинская раскладки: «ą», «ґ») печатает символ, которого трекер не учтёт: безопаснее сбросить.
        // Прочие ⌥-сочетания без текста слово не меняют.
        if modifiers.contains(.option) {
            if let first = characters?.first, first.isLetter { reset() }
            return
        }
        guard let characters, !characters.isEmpty else { return }
        for character in characters {
            if character == " " {
                if !word.isEmpty { trailing.append(character) }
            } else if character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol {
                if !trailing.isEmpty {
                    word = ""
                    trailing = ""
                }
                word.append(character)
                if word.count > Self.maxWordLength { word.removeFirst(word.count - Self.maxWordLength) }
            } else {
                reset()
            }
        }
    }
}

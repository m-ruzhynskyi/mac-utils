import Foundation

/// Перевод текста, набранного не в той раскладке: QWERTY ↔ ЙЦУКЕН
/// по положению клавиш (ghbdtn ↔ привет), с регистром и знаками препинания.
enum LayoutMap {
    enum Direction { case toRussian, toEnglish }

    /// Пары «клавиша в английской раскладке → символ в русской».
    private static let pairs: [(Character, Character)] = {
        let en = "qwertyuiop[]asdfghjkl;'zxcvbnm,./`QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?~@#$^&"
        let ru = "йцукенгшщзхъфывапролджэячсмитьбю.ёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,Ё\"№;:?"
        return Array(zip(en, ru))
    }()

    private static let toRussianMap = Dictionary(pairs.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
    private static let toEnglishMap = Dictionary(pairs.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })

    /// Направление по тому, каких букв больше.
    static func direction(of text: String) -> Direction {
        var latin = 0, cyrillic = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x0400...0x04FF: cyrillic += 1
            default: break
            }
        }
        return cyrillic > latin ? .toEnglish : .toRussian
    }

    static func convert(_ text: String, _ direction: Direction) -> String {
        let map = direction == .toRussian ? toRussianMap : toEnglishMap
        return String(text.map { map[$0] ?? $0 })
    }
}

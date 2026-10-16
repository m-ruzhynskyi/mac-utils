import Foundation

/// Перевод текста, набранного не в той раскладке: QWERTY ↔ ЙЦУКЕН (русская и украинская)
/// по положению клавиш (ghbdtn ↔ привет, ghbdsn ↔ привіт), с регистром и знаками препинания.
enum LayoutMap {
    enum Direction { case toRussian, toUkrainian, toEnglish }

    /// Какую кириллическую раскладку подставлять при переводе с английской.
    enum CyrillicLayout: String, CaseIterable {
        case russian, ukrainian
    }

    /// Пары «клавиша в английской раскладке → символ в русской».
    private static let russianPairs: [(Character, Character)] = {
        let en = "qwertyuiop[]asdfghjkl;'zxcvbnm,./`QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?~@#$^&"
        let ru = "йцукенгшщзхъфывапролджэячсмитьбю.ёЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,Ё\"№;:?"
        return Array(zip(en, ru))
    }()

    /// Украинская раскладка: на тех же клавишах «і» (вместо «ы»), «ї» («ъ»), «є» («э»), «ґ» на \ и апостроф `ʼ` на `.
    /// Цифры и знаки Shift-ряда те же, что в русской.
    private static let ukrainianPairs: [(Character, Character)] = {
        let en = "qwertyuiop[]asdfghjkl;'zxcvbnm,./`\\QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?|@#$^&"
        let uk = "йцукенгшщзхїфівапролджєячсмитьбю.ʼґЙЦУКЕНГШЩЗХЇФІВАПРОЛДЖЄЯЧСМИТЬБЮ,Ґ\"№;:?"
        return Array(zip(en, uk))
    }()

    private static let toRussianMap = Dictionary(russianPairs.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
    private static let toUkrainianMap = Dictionary(ukrainianPairs.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
    /// С любой кириллицы на английскую: буквы русской и украинской раскладок различаются (ы/і, ъ/ї, э/є), конфликтов нет.
    private static let toEnglishMap: [Character: Character] = {
        var map = Dictionary(russianPairs.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })
        for (en, uk) in ukrainianPairs where map[uk] == nil { map[uk] = en }
        // Апостроф на клавише ` у разных украинских раскладок: ʼ (U+02BC, есть выше), ' (ПК) и ’ (U+2019). В кириллическом
        // тексте с русской раскладки эти знаки не встречаются (там эта клавиша — «э»).
        map["'"] = "`"
        map["\u{2019}"] = "`"
        return map
    }()

    /// Направление по тому, каких букв больше. С английской переводим в `cyrillic` (по умолчанию русскую).
    /// Кириллица, в которой есть буквы только украинской раскладки, и так идёт в английскую; выбор нужен только для латиницы.
    static func direction(of text: String, cyrillic: CyrillicLayout = .russian) -> Direction {
        var latin = 0, cyrillicCount = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            case 0x0400...0x04FF: cyrillicCount += 1
            default: break
            }
        }
        if cyrillicCount > latin { return .toEnglish }
        return cyrillic == .ukrainian ? .toUkrainian : .toRussian
    }

    static func convert(_ text: String, _ direction: Direction) -> String {
        let map: [Character: Character]
        switch direction {
        case .toRussian: map = toRussianMap
        case .toUkrainian: map = toUkrainianMap
        case .toEnglish: map = toEnglishMap
        }
        return String(text.map { map[$0] ?? $0 })
    }

    /// Язык системной раскладки, на которую переключаемся после перевода.
    static func inputLanguage(for direction: Direction) -> String {
        switch direction {
        case .toRussian: return "ru"
        case .toUkrainian: return "uk"
        case .toEnglish: return "en"
        }
    }

    /// Кириллическая раскладка для перевода с английской: выбор пользователя, а в режиме «авто» — по включённым в системе
    /// раскладкам (`enabledLanguages`, коды «ru», «uk», «en»…): только украинская → украинская, иначе русская.
    static func cyrillicLayout(setting: String?, enabledLanguages: [String]) -> CyrillicLayout {
        switch setting {
        case "russian": return .russian
        case "ukrainian": return .ukrainian
        default:
            return enabledLanguages.contains("uk") && !enabledLanguages.contains("ru") ? .ukrainian : .russian
        }
    }
}

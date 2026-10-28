import Foundation

/// Текст, набранный не в той раскладке: QWERTY ↔ ЙЦУКЕН (русская и украинская), по положению клавиш.
/// Те же пары, что у «Исправить раскладку» в приложении; модуль от приложения не зависит, поэтому своя копия.
enum KeyboardLayouts {
    enum Target: CaseIterable { case russian, ukrainian, english }

    private static let russianPairs = Array(zip(
        "qwertyuiop[]asdfghjkl;'zxcvbnm,.`",
        "йцукенгшщзхъфывапролджэячсмитьбюё"))
    private static let ukrainianPairs = Array(zip(
        "qwertyuiop[]asdfghjkl;'zxcvbnm,.`\\",
        "йцукенгшщзхїфівапролджєячсмитьбюʼґ"))

    private static let toRussian = Dictionary(russianPairs.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    private static let toUkrainian = Dictionary(ukrainianPairs.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    private static let toEnglish: [Character: Character] = {
        var map = Dictionary(russianPairs.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })
        for (en, uk) in ukrainianPairs where map[uk] == nil { map[uk] = en }
        map["'"] = "`"
        map["\u{2019}"] = "`"
        return map
    }()

    /// Варианты запроса в других раскладках (в нижнем регистре); только те, что отличаются от исходного.
    static func alternatives(_ text: String) -> [String] {
        let lower = text.lowercased()
        var latin = 0, cyrillic = 0
        for u in lower.unicodeScalars {
            switch u.value {
            case 0x61...0x7A: latin += 1
            case 0x0400...0x04FF: cyrillic += 1
            default: break
            }
        }
        let targets: [Target] = cyrillic > latin ? [.english] : (latin > 0 ? [.russian, .ukrainian] : [])
        var out: [String] = []
        for t in targets {
            let converted = convert(lower, to: t)
            if converted != lower, !out.contains(converted) { out.append(converted) }
        }
        return out
    }

    static func convert(_ text: String, to target: Target) -> String {
        let map: [Character: Character]
        switch target {
        case .russian: map = toRussian
        case .ukrainian: map = toUkrainian
        case .english: map = toEnglish
        }
        return String(text.map { map[$0] ?? $0 })
    }
}

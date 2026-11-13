import Foundation

/// Язык текста у курсора для строки состояния: код `\langN` (идентификатор Windows) в исходнике, действующий в этом месте.
/// Читается точечно — от начала абзаца до курсора, с областью видимости групп `{ }` и сбросом `\plain`, — модель символов не трогаем.
package enum DocLanguage {
    /// Язык по умолчанию документа: `\deflangN` из заголовка, иначе английский (США).
    package static func documentDefault(in source: NSString) -> Int {
        let head = source.substring(to: min(source.length, 6000)) as NSString
        for token in RTFLexer.tokens(head, in: NSRange(location: 0, length: head.length)) where token.kind == .word && token.name == "deflang" {
            return token.number ?? 1033
        }
        return 1033
    }

    /// Идентификатор языка в месте исходника `location`; `start` — откуда читать (начало абзаца).
    package static func lcid(atSource location: Int, from start: Int, in source: NSString) -> Int {
        let fallback = documentDefault(in: source)
        let begin = max(0, min(start, source.length)), end = max(begin, min(location, source.length))
        var current = fallback
        var stack: [Int] = []
        for token in RTFLexer.tokens(source, in: NSRange(location: begin, length: end - begin)) {
            switch token.kind {
            case .open: stack.append(current)
            case .close: current = stack.popLast() ?? current
            case .word:
                if token.name == "lang", let number = token.number, number != 1024 { current = number }
                if token.name == "plain" { current = fallback }
            default: break
            }
        }
        return current
    }

    private static let shortCountries = ["US": "США", "GB": "Великобритания", "CA": "Канада", "AU": "Австралия", "RU": "Россия", "UA": "Украина"]

    /// «русский», «украинский», «английский (США)»; неизвестный — nil.
    package static func name(lcid: Int, locale: Locale = Locale(identifier: "ru_RU")) -> String? {
        guard let identifier = Locale.identifier(fromWindowsLocaleCode: lcid) else { return nil }
        let language = Locale(identifier: identifier)
        guard let code = language.language.languageCode?.identifier, let title = locale.localizedString(forLanguageCode: code) else { return nil }
        // Вариант страны — только для языков, у которых он различается в списках Word (английский, немецкий, португальский…).
        if let region = language.region?.identifier, ["en", "de", "pt", "es", "fr", "zh"].contains(code),
           let country = shortCountries[region] ?? locale.localizedString(forRegionCode: region) {
            return title + " (\(country))"
        }
        return title
    }
}

extension DocLanguage {
    /// Места смены языка внутри `[start, end)`: первый элемент — язык в `start`, дальше — каждое `\langN` (с учётом групп и `\plain`).
    /// Для орфографии: абзац режется на куски, каждый проверяется своим словарём.
    package static func changes(from start: Int, to end: Int, in source: NSString) -> [(location: Int, lcid: Int)] {
        let fallback = documentDefault(in: source)
        let begin = max(0, min(start, source.length)), stop = max(begin, min(end, source.length))
        var current = fallback
        var stack: [Int] = []
        var result: [(location: Int, lcid: Int)] = []
        var pending = true  // язык в начале ещё не записан
        for token in RTFLexer.tokens(source, in: NSRange(location: begin, length: stop - begin)) {
            let before = current
            switch token.kind {
            case .open: stack.append(current)
            case .close: current = stack.popLast() ?? current
            case .word:
                if token.name == "lang", let number = token.number, number != 1024 { current = number }
                if token.name == "plain" { current = fallback }
            default: break
            }
            if current != before {
                if pending, token.range.location >= begin { result.append((begin, before)); pending = false }
                result.append((token.range.location, current))
            }
        }
        if pending { result.append((begin, current)) }
        return result
    }

    /// Код словаря `NSSpellChecker` по идентификатору языка Windows: русский, украинский, английский — остальное не проверяем.
    package static func spellingCode(lcid: Int) -> String? {
        switch lcid & 0x3FF {
        case 0x19: return "ru"
        case 0x22: return "uk"
        case 0x09: return lcid == 2057 ? "en_GB" : "en_US"
        default: return nil
        }
    }
}

import Foundation

/// Опции поиска (кнопки `Aa`, `ab`, `.*`, `[ ]` на панели поиска).
struct SearchOptions: Equatable, Codable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    var inSelection = false
}

/// Поиск и замена — чистые функции над `NSString` (смещения UTF-16, как у `NSTextView`).
enum TextSearch {
    /// Больше — счётчик пишет «20 000+», подсветка показывает первые.
    static let limit = 20_000

    struct Result: Equatable {
        var ranges: [NSRange]
        /// Совпадений больше `limit`.
        var truncated: Bool
    }

    enum Failure: LocalizedError, Equatable {
        case badPattern(String)

        var errorDescription: String? {
            switch self {
            case .badPattern(let reason): return reason
            }
        }
    }

    /// Регулярное выражение для запроса: обычный текст экранируется, «слово целиком» — без букв, цифр и `_` по краям.
    static func expression(_ query: String, options: SearchOptions) throws -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "(?<![\\p{L}\\p{N}_])(?:\(pattern))(?![\\p{L}\\p{N}_])" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: pattern, options: flags)
        } catch {
            throw Failure.badPattern("Ошибка в выражении")
        }
    }

    /// Все совпадения в `scope` по порядку (не больше `limit`, если он задан). Пустые совпадения (`^`, `\b`)
    /// тоже считаются, поиск после них идёт дальше, а не по кругу.
    static func find(_ query: String, in text: NSString, options: SearchOptions, scope: NSRange? = nil,
                     limit: Int? = TextSearch.limit) throws -> Result {
        let scope = scope ?? NSRange(location: 0, length: text.length)
        guard !query.isEmpty, scope.length > 0 || options.regex else { return Result(ranges: [], truncated: false) }
        // Обычный текст без «слова целиком» — быстрый поиск `NSString` (10 МБ — десятки миллисекунд).
        if !options.regex && !options.wholeWord {
            var ranges: [NSRange] = []
            var from = scope.location
            let end = NSMaxRange(scope)
            let compare: NSString.CompareOptions = options.caseSensitive ? [.literal] : [.caseInsensitive]
            while from < end {
                let found = text.range(of: query, options: compare, range: NSRange(location: from, length: end - from))
                guard found.location != NSNotFound, found.length > 0 else { break }
                if let limit, ranges.count == limit { return Result(ranges: ranges, truncated: true) }
                ranges.append(found)
                from = NSMaxRange(found)
            }
            return Result(ranges: ranges, truncated: false)
        }
        let regex = try expression(query, options: options)
        var ranges: [NSRange] = []
        var truncated = false
        // Изменяемый текст редактора при переходе в `String` копируется — один раз, а не на каждое совпадение.
        let string = text as String
        regex.enumerateMatches(in: string, options: [.withTransparentBounds], range: scope) { match, _, stop in
            guard let match else { return }
            if let limit, ranges.count == limit {
                truncated = true
                stop.pointee = true
                return
            }
            ranges.append(match.range)
        }
        return Result(ranges: ranges, truncated: truncated)
    }

    /// Строки замены для совпадений: в режиме regex `$1`, `$2` — группы, иначе текст как есть.
    static func replacements(_ query: String, template: String, in text: NSString, options: SearchOptions,
                             scope: NSRange? = nil) throws -> (ranges: [NSRange], strings: [String]) {
        guard options.regex else {
            let ranges = try find(query, in: text, options: options, scope: scope, limit: nil).ranges
            return (ranges, Array(repeating: template, count: ranges.count))
        }
        let regex = try expression(query, options: options)
        let scope = scope ?? NSRange(location: 0, length: text.length)
        let string = text as String
        let matches = regex.matches(in: string, options: [.withTransparentBounds], range: scope)
        return (matches.map(\.range),
                matches.map { regex.replacementString(for: $0, in: string, offset: 0, template: template) })
    }

    /// Замена одного совпадения `range` (оно должно совпадать с запросом целиком).
    static func replacement(for range: NSRange, _ query: String, template: String, in text: NSString,
                            options: SearchOptions) throws -> String? {
        guard options.regex else { return template }
        let regex = try expression(query, options: options)
        let string = text as String
        guard let match = regex.firstMatch(in: string, options: [.withTransparentBounds, .anchored], range: range),
              match.range == range else { return nil }
        return regex.replacementString(for: match, in: string, offset: 0, template: template)
    }

    /// Совпадение для «Далее» / «Назад» от выделения `selection`, по кругу; `wrapped` — перешли через край.
    static func next(in ranges: [NSRange], after selection: NSRange, backwards: Bool) -> (index: Int, wrapped: Bool)? {
        guard !ranges.isEmpty else { return nil }
        if backwards {
            if let index = ranges.lastIndex(where: { $0.location < selection.location }) { return (index, false) }
            return (ranges.count - 1, true)
        }
        // Не само выделение: иначе пустое совпадение (`^`) находилось бы снова и снова.
        if let index = ranges.firstIndex(where: { $0.location >= NSMaxRange(selection) && $0 != selection }) { return (index, false) }
        return (0, true)
    }

    /// «строка» или «строка:столбец» для «Перейти к строке»; `nil` — не число.
    static func parseLocation(_ input: String) -> (line: Int, column: Int)? {
        let parts = input.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let line = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let column = parts.count == 2 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : 1
        guard let column else { return nil }
        return (line, column)
    }
}

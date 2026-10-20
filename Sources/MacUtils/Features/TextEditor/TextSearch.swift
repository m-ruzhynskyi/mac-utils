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
        /// Поиск прерван: запрос или текст сменились, либо выражение ищет слишком долго.
        case cancelled

        var errorDescription: String? {
            switch self {
            case .badPattern(let reason): return reason
            case .cancelled: return "Поиск прерван"
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
    /// `isCancelled` — проверяется и между совпадениями, и во время долгого перебора внутри одного (regex
    /// с катастрофическим откатом вроде `(a+)+$`): поиск в фоне можно прервать.
    static func find(_ query: String, in text: NSString, options: SearchOptions, scope: NSRange? = nil,
                     limit: Int? = TextSearch.limit, isCancelled: (() -> Bool)? = nil) throws -> Result {
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
        var cancelled = false
        let flags: NSRegularExpression.MatchingOptions = isCancelled == nil ? [.withTransparentBounds] : [.withTransparentBounds, .reportProgress]
        regex.enumerateMatches(in: string, options: flags, range: scope) { match, _, stop in
            if let isCancelled, isCancelled() {
                cancelled = true
                stop.pointee = true
                return
            }
            guard let match else { return }
            if let limit, ranges.count == limit {
                truncated = true
                stop.pointee = true
                return
            }
            ranges.append(match.range)
        }
        if cancelled { throw Failure.cancelled }
        return Result(ranges: ranges, truncated: truncated)
    }

    /// Строки замены для совпадений: в режиме regex `$1`, `$2` — группы, иначе текст как есть.
    static func replacements(_ query: String, template: String, in text: NSString, options: SearchOptions,
                             scope: NSRange? = nil, isCancelled: (() -> Bool)? = nil) throws -> (ranges: [NSRange], strings: [String]) {
        guard options.regex else {
            let ranges = try find(query, in: text, options: options, scope: scope, limit: nil).ranges
            return (ranges, Array(repeating: template, count: ranges.count))
        }
        let regex = try expression(query, options: options)
        let scope = scope ?? NSRange(location: 0, length: text.length)
        let string = text as String
        var ranges: [NSRange] = [], strings: [String] = []
        var cancelled = false
        let flags: NSRegularExpression.MatchingOptions = isCancelled == nil ? [.withTransparentBounds] : [.withTransparentBounds, .reportProgress]
        regex.enumerateMatches(in: string, options: flags, range: scope) { match, _, stop in
            if let isCancelled, isCancelled() {
                cancelled = true
                stop.pointee = true
                return
            }
            guard let match else { return }
            ranges.append(match.range)
            strings.append(regex.replacementString(for: match, in: string, offset: 0, template: template))
        }
        if cancelled { throw Failure.cancelled }
        return (ranges, strings)
    }

    /// Флаг отмены для фонового поиска (и предел по времени).
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        private let deadline: TimeInterval

        init(timeout: TimeInterval = 15) { deadline = ProcessInfo.processInfo.systemUptime + timeout }

        func cancel() { lock.lock(); flag = true; lock.unlock() }

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return flag || ProcessInfo.processInfo.systemUptime > deadline
        }

        var timedOut: Bool { ProcessInfo.processInfo.systemUptime > deadline }
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

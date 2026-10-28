import Foundation

/// Подсветка синтаксиса: чистые функции над диапазоном текста. Запускаются только для видимой части,
/// поэтому каждая начинает с начала строки и не держит состояния между вызовами.
package enum SyntaxToken: Equatable {
    /// RTF: `\слово`, `\'hh`, `{ }`.
    case control, escape, brace
    /// JSON и XML.
    case key, string, number, keyword, punctuation, tag, attribute, comment
}

package enum SyntaxHighlighter {
    /// Видимая часть дальше этого от начала строки раскрашивается с себя, а не с начала строки (контекст может сбиться,
    /// зато длинная строка не раскрашивается целиком на каждое нажатие).
    package static let context = 2_000

    package static func tokens(_ language: EditorLanguage, in text: NSString, range: NSRange) -> [(NSRange, SyntaxToken)] {
        switch language {
        case .rtf: return rtf(text, range: range)
        case .json: return json(text, range: range)
        case .xml: return xml(text, range: range)
        case .plain: return []
        }
    }

    private static func isLetter(_ unit: UInt16) -> Bool { (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit) }
    private static func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }
    private static func isHex(_ unit: UInt16) -> Bool { isDigit(unit) || (0x61...0x66).contains(unit) || (0x41...0x46).contains(unit) }

    // MARK: - RTF / .frm

    /// `\слово[-]число`, `\'hh`, `\*`, `\{` и т. п., скобки групп.
    package static func rtf(_ text: NSString, range: NSRange) -> [(NSRange, SyntaxToken)] {
        var result: [(NSRange, SyntaxToken)] = []
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            let unit = text.character(at: i)
            if unit == 0x7B || unit == 0x7D {
                result.append((NSRange(location: i, length: 1), .brace))
                i += 1
            } else if unit == 0x5C, i + 1 < text.length {
                let next = text.character(at: i + 1)
                if next == 0x27 {
                    var stop = i + 2
                    while stop < min(i + 4, text.length), isHex(text.character(at: stop)) { stop += 1 }
                    result.append((NSRange(location: i, length: stop - i), .escape))
                    i = stop
                } else if isLetter(next) {
                    var stop = i + 1
                    while stop < text.length, isLetter(text.character(at: stop)) { stop += 1 }
                    if stop < text.length, text.character(at: stop) == 0x2D { stop += 1 }
                    while stop < text.length, isDigit(text.character(at: stop)) { stop += 1 }
                    result.append((NSRange(location: i, length: stop - i), .control))
                    i = stop
                } else {
                    result.append((NSRange(location: i, length: 2), .control))
                    i += 2
                }
            } else {
                i += 1
            }
        }
        return result
    }

    // MARK: - JSON

    /// Строки (ключ — если за ней `:`), числа, `true/false/null`, скобки и разделители.
    package static func json(_ text: NSString, range: NSRange) -> [(NSRange, SyntaxToken)] {
        var result: [(NSRange, SyntaxToken)] = []
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            let unit = text.character(at: i)
            switch unit {
            case 0x22:
                var stop = i + 1
                while stop < text.length {
                    let c = text.character(at: stop)
                    if c == 0x5C { stop += 2; continue }
                    if c == 0x22 || c == 0x0A || c == 0x0D { break }
                    stop += 1
                }
                stop = min(stop + 1, text.length)
                var after = stop
                while after < text.length, [0x20, 0x09].contains(text.character(at: after)) { after += 1 }
                let isKey = after < text.length && text.character(at: after) == 0x3A
                result.append((NSRange(location: i, length: stop - i), isKey ? .key : .string))
                i = stop
            case 0x2D, 0x30...0x39:
                var stop = i + 1
                while stop < text.length {
                    let c = text.character(at: stop)
                    guard isDigit(c) || c == 0x2E || c == 0x65 || c == 0x45 || c == 0x2B || c == 0x2D else { break }
                    stop += 1
                }
                result.append((NSRange(location: i, length: stop - i), .number))
                i = stop
            case 0x74, 0x66, 0x6E:
                var stop = i
                while stop < text.length, isLetter(text.character(at: stop)) { stop += 1 }
                let word = text.substring(with: NSRange(location: i, length: stop - i))
                if ["true", "false", "null"].contains(word) { result.append((NSRange(location: i, length: stop - i), .keyword)) }
                i = max(stop, i + 1)
            case 0x7B, 0x7D, 0x5B, 0x5D, 0x3A, 0x2C:
                result.append((NSRange(location: i, length: 1), .punctuation))
                i += 1
            default:
                i += 1
            }
        }
        return result
    }

    // MARK: - XML / HTML

    /// Теги `<имя …>` с атрибутами и значениями, комментарии `<!-- -->`.
    package static func xml(_ text: NSString, range: NSRange) -> [(NSRange, SyntaxToken)] {
        var result: [(NSRange, SyntaxToken)] = []
        let end = NSMaxRange(range)
        var i = range.location
        while i < end {
            guard text.character(at: i) == 0x3C else { i += 1; continue }
            if text.length - i >= 4, text.substring(with: NSRange(location: i, length: 4)) == "<!--" {
                let close = text.range(of: "-->", options: .literal, range: NSRange(location: i + 4, length: text.length - i - 4))
                let stop = close.location == NSNotFound ? end : NSMaxRange(close)
                result.append((NSRange(location: i, length: stop - i), .comment))
                i = stop
                continue
            }
            // Имя тега вместе с `<`, `</`, `<?`, `<!`.
            var stop = i + 1
            while stop < text.length, [0x2F, 0x3F, 0x21].contains(text.character(at: stop)) { stop += 1 }
            while stop < text.length, isNameChar(text.character(at: stop)) { stop += 1 }
            result.append((NSRange(location: i, length: stop - i), .tag))
            i = stop
            // Атрибуты до `>`.
            while i < text.length {
                let c = text.character(at: i)
                if c == 0x3E || c == 0x3C { break }
                if c == 0x22 || c == 0x27 {
                    var close = i + 1
                    while close < text.length, text.character(at: close) != c, text.character(at: close) != 0x0A { close += 1 }
                    close = min(close + 1, text.length)
                    result.append((NSRange(location: i, length: close - i), .string))
                    i = close
                } else if isNameChar(c) {
                    var close = i
                    while close < text.length, isNameChar(text.character(at: close)) { close += 1 }
                    result.append((NSRange(location: i, length: close - i), .attribute))
                    i = close
                } else {
                    i += 1
                }
                if i >= end + 2_000 { break }
            }
            if i < text.length, text.character(at: i) == 0x3E {
                var start = i
                if start > 0, text.character(at: start - 1) == 0x2F || text.character(at: start - 1) == 0x3F { start -= 1 }
                result.append((NSRange(location: start, length: i + 1 - start), .tag))
                i += 1
            }
        }
        return result
    }

    private static func isNameChar(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit) || unit == 0x2D || unit == 0x5F || unit == 0x3A || unit == 0x2E || unit > 0x7F
    }
}

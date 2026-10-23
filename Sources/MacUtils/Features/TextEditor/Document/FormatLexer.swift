import Foundation
import MUDesign

/// Лексема исходника RTF для точечных правок: группа, управляющее слово или символ, `\'hh`, текст, перевод строки.
struct RTFToken: Equatable {
    enum Kind: Equatable { case open, close, word, symbol, hex, text, newline, binary }

    var kind: Kind
    /// Весь кусок исходника (у слова — с пробелом-разделителем).
    var range: NSRange
    /// Имя слова (буквы) или символ после `\`.
    var name = ""
    var number: Int?
    /// Конец слова без разделителя: сюда можно писать замену, не трогая пробел.
    var wordEnd = 0

    var wordRange: NSRange { NSRange(location: range.location, length: wordEnd - range.location) }
    var hasDelimiter: Bool { wordEnd < NSMaxRange(range) }
}

/// Разбор куска исходника на лексемы — те же правила, что у `RTFReader`: слово — буквы, затем необязательное число
/// со знаком, затем один пробел-разделитель; `\bin N` — N единиц как есть.
enum RTFLexer {
    static func tokens(_ text: NSString, in range: NSRange) -> [RTFToken] {
        var tokens: [RTFToken] = []
        let end = min(NSMaxRange(range), text.length)
        var i = max(0, range.location)
        while i < end {
            let unit = text.character(at: i)
            switch unit {
            case 0x7B:
                tokens.append(RTFToken(kind: .open, range: NSRange(location: i, length: 1), wordEnd: i + 1))
                i += 1
            case 0x7D:
                tokens.append(RTFToken(kind: .close, range: NSRange(location: i, length: 1), wordEnd: i + 1))
                i += 1
            case 0x0D, 0x0A:
                tokens.append(RTFToken(kind: .newline, range: NSRange(location: i, length: 1), wordEnd: i + 1))
                i += 1
            case 0x5C:
                let token = controlToken(text, at: i, limit: end)
                tokens.append(token)
                i = NSMaxRange(token.range)
                // `\bin N` — дальше N единиц двоичных данных.
                if token.kind == .word, token.name == "bin", let count = token.number, count > 0 {
                    let stop = min(end, i + count)
                    tokens.append(RTFToken(kind: .binary, range: NSRange(location: i, length: stop - i), wordEnd: stop))
                    i = stop
                }
            default:
                tokens.append(RTFToken(kind: .text, range: NSRange(location: i, length: 1), wordEnd: i + 1))
                i += 1
            }
        }
        return tokens
    }

    /// Управляющее слово или символ, начинающийся с `\` в `start`.
    static func controlToken(_ text: NSString, at start: Int, limit: Int? = nil) -> RTFToken {
        let end = min(limit ?? text.length, text.length)
        guard start + 1 < end else {
            return RTFToken(kind: .symbol, range: NSRange(location: start, length: max(1, end - start)), wordEnd: end)
        }
        let next = text.character(at: start + 1)
        if isLetter(next) {
            var k = start + 1
            while k < end, isLetter(text.character(at: k)) { k += 1 }
            let name = text.substring(with: NSRange(location: start + 1, length: k - start - 1))
            var number: Int?
            if k < end, text.character(at: k) == 0x2D || isDigit(text.character(at: k)) {
                let negative = text.character(at: k) == 0x2D
                var digits = negative ? k + 1 : k
                let first = digits
                var value = 0
                while digits < end, isDigit(text.character(at: digits)) {
                    value = value &* 10 &+ Int(text.character(at: digits) - 0x30)
                    digits += 1
                }
                if digits > first {
                    number = negative ? -value : value
                    k = digits
                }
            }
            let wordEnd = k
            if k < end, text.character(at: k) == 0x20 { k += 1 }
            return RTFToken(kind: .word, range: NSRange(location: start, length: k - start), name: name, number: number, wordEnd: wordEnd)
        }
        if next == 0x27, start + 3 < end {
            return RTFToken(kind: .hex, range: NSRange(location: start, length: 4), name: "'", wordEnd: start + 4)
        }
        let symbol = String(utf16CodeUnits: [next], count: 1)
        return RTFToken(kind: .symbol, range: NSRange(location: start, length: 2), name: symbol, wordEnd: start + 2)
    }

    static func isLetter(_ unit: UInt16) -> Bool { (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit) }
    static func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }
}

/// Все группы `{…}` исходника: где открываются, где закрываются и кто родитель. Один проход; нужен, чтобы найти
/// самую внутреннюю группу у места исходника за время, пропорциональное глубине вложенности.
struct RTFGroupIndex {
    private(set) var opens: [Int] = []
    private(set) var closes: [Int] = []
    private(set) var parents: [Int] = []

    init(_ text: NSString) {
        let length = text.length
        var units = [UInt16](repeating: 0, count: length)
        if length > 0 { units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) } }
        var stack: [Int] = []
        var i = 0
        while i < length {
            let unit = units[i]
            if unit == 0x5C {
                // `\bin N` — двоичные данные, внутри могут быть скобки.
                if i + 3 < length, units[i + 1] == 0x62, units[i + 2] == 0x69, units[i + 3] == 0x6E {
                    var k = i + 4, value = 0, digits = false
                    while k < length, RTFLexer.isDigit(units[k]) {
                        value = value &* 10 &+ Int(units[k] - 0x30)
                        k += 1
                        digits = true
                    }
                    if digits {
                        if k < length, units[k] == 0x20 { k += 1 }
                        i = min(length, k + value)
                        continue
                    }
                }
                i += 2
                continue
            }
            if unit == 0x7B {
                parents.append(stack.last ?? -1)
                opens.append(i)
                closes.append(length)
                stack.append(opens.count - 1)
            } else if unit == 0x7D, let open = stack.popLast() {
                closes[open] = i
            }
            i += 1
        }
    }

    var count: Int { opens.count }

    /// Самая внутренняя группа, внутри которой (между `{` и `}`) стоит место `location`.
    func innermost(containing location: Int) -> Int? {
        var low = 0, high = opens.count
        while low < high {
            let mid = (low + high) / 2
            if opens[mid] < location { low = mid + 1 } else { high = mid }
        }
        var group = low - 1
        while group >= 0, closes[group] < location { group = parents[group] }
        return group >= 0 ? group : nil
    }

    /// Группа целиком, со скобками.
    func range(of group: Int) -> NSRange { NSRange(location: opens[group], length: closes[group] - opens[group] + 1) }

    /// Содержимое группы без скобок.
    func content(of group: Int) -> NSRange { NSRange(location: opens[group] + 1, length: max(0, closes[group] - opens[group] - 1)) }

    /// Корневая группа документа (`{\rtf1 …}`).
    var root: Int? { opens.isEmpty ? nil : 0 }
}

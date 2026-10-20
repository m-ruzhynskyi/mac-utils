import Foundation

/// Знаки `$` в RTF по видимому тексту документа. Word делит текст на группы с форматированием и rsid:
/// `$}{\rtlch\fcs1 \af0\afs32 \insrsid4548749  }{…\fs0  Иванов` — значение здесь «Иванов», а не пустое.
///
/// Мини-токенизатор по исходнику, текст не меняется:
/// - невидимое (группы, управляющие слова с числом и пробелом-разделителем, прочие управляющие символы, `{\*\…}`
///   и служебные назначения вроде `\info`, `\fonttbl`) значение не прерывает и в него не входит;
/// - видимое — обычные символы, `\'hh`, `\uN` вместе с заменителями (`\ucN`), `\~`, `\_`, `\-`, `\\`, `\{`, `\}`,
///   `\emdash` и подобные;
/// - значение кончается на видимом пробельном символе (пробел не как разделитель кода, NBSP, `\~`), на `\par`, `\line`,
///   `\pard`, `\sect`, `\page`, `\tab`, `\cell`, `\row`, следующем `$` или в конце текста. Переводы строк исходника
///   невидимы и значение не прерывают; `;` и прочие видимые непробельные символы в значение входят.
/// Знаки внутри служебных групп помечаются `hidden`: на странице их не видно, панель их не трогает, значение страницы
/// они не прерывают.
enum RTFDollarScanner {
    /// Группы, текст которых на странице не виден.
    static let hiddenDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "listtable", "listoverridetable", "rsidtbl", "generator", "pict",
        "object", "datastore", "themedata", "colorschememapping", "latentstyles", "xmlnstbl",
    ]
    /// Конец абзаца или поля — конец значения.
    static let terminators: Set<String> = ["par", "line", "tab", "cell", "row", "sect", "page", "pard"]
    /// Управляющие слова, которые сами — видимый символ.
    static let symbols: [String: String] = [
        "emdash": "\u{2014}", "endash": "\u{2013}", "lquote": "\u{2018}", "rquote": "\u{2019}", "ldblquote": "\u{201C}",
        "rdblquote": "\u{201D}", "bullet": "\u{2022}", "emspace": "\u{2003}", "enspace": "\u{2002}", "qmspace": "\u{2005}",
    ]

    /// Имя управляющего слова без строки: первые 20 латинских букв по 6 бит с учётом регистра и длина
    /// (строка на каждое слово на 10 МБ — сотни мс). Все известные имена короче 20 букв, поэтому совпадений нет.
    struct WordKey: Hashable {
        var high: UInt64 = 0
        var low: UInt64 = 0
        var length = 0

        init(_ name: String) {
            for unit in name.utf16 { append(unit) }
        }

        init() {}

        mutating func append(_ unit: UInt16) {
            // a…z → 1…26, A…Z → 27…52.
            let value = UInt64(unit >= 0x61 ? unit - 0x60 : unit - 0x41 + 27)
            if length < 10 { high = high << 6 | value } else if length < 20 { low = low << 6 | value }
            length += 1
        }
    }

    private static let hiddenKeys = Set(hiddenDestinations.map(WordKey.init))
    private static let terminatorKeys = Set(terminators.map(WordKey.init))
    private static let symbolKeys = Dictionary(uniqueKeysWithValues: symbols.map { (WordKey($0.key), $0.value) })
    private static let ucKey = WordKey("uc"), uKey = WordKey("u"), binKey = WordKey("bin")

    private struct Group {
        var hidden: Bool
        var uc: Int
        /// В группе ещё не было ни одного управляющего слова (назначение — первое слово группы).
        var fresh: Bool
    }

    private struct Pending {
        let dollar: Int
        let hidden: Bool
        var parts: [NSRange] = []
        var text = ""
    }

    /// Кодовая страница из `\ansicpgNNNN` в начале текста — для `\'hh`; нет её — `fallback`.
    static func codePage(of text: NSString, fallback: TextEncoding) -> TextEncoding {
        let head = text.substring(to: min(text.length, 4_096))
        guard let marker = head.range(of: "\\ansicpg") else { return fallback }
        let digits = head[marker.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard let page = Int(digits), let encoding = TextEncoding(codePage: page), encoding.group != .unicode else { return fallback }
        return encoding
    }

    /// `skipsLeadingSpace` — видимые пробелы сразу после `$` (до первого символа значения) пропускать, а не считать концом.
    static func scan(_ text: NSString, encoding: TextEncoding = .windows1252, skipsLeadingSpace: Bool = false) -> [DollarMark] {
        let length = text.length
        guard length > 0 else { return [] }
        let byteEncoding = codePage(of: text, fallback: encoding.group == .unicode ? .windows1252 : encoding)
        let table = SingleByteTable.table(for: byteEncoding)?.decodeTable
        var units = [UInt16](repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) }
        return units.withUnsafeBufferPointer { scan($0, byteTable: table, skipsLeadingSpace: skipsLeadingSpace) }
    }

    private static func isLetter(_ unit: UInt16) -> Bool { (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit) }
    private static func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }
    private static func hexValue(_ unit: UInt16) -> Int? {
        switch unit {
        case 0x30...0x39: return Int(unit - 0x30)
        case 0x61...0x66: return Int(unit - 0x61 + 10)
        case 0x41...0x46: return Int(unit - 0x41 + 10)
        default: return nil
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func scan(_ u: UnsafeBufferPointer<UInt16>, byteTable: [UInt16]?, skipsLeadingSpace: Bool) -> [DollarMark] {
        let count = u.count
        var stack = [Group(hidden: false, uc: 1, fresh: false)]
        var marks: [DollarMark] = []
        // Знак страницы и знак служебной группы собираются отдельно: `$A{\*\bkmkstart x$y}B` — «AB» и служебный «y».
        var current: Pending?
        var service: Pending?

        func close(_ pending: inout Pending?) {
            guard let done = pending else { return }
            pending = nil
            let end = done.parts.last.map(NSMaxRange) ?? done.dollar + 1
            marks.append(DollarMark(dollar: done.dollar, value: NSRange(location: done.dollar + 1, length: end - done.dollar - 1),
                                    parts: done.parts, visible: done.text, hidden: done.hidden))
        }

        func finish() {
            close(&current)
            close(&service)
        }

        /// Видимый символ (или кусок исходника, который даёт символ). Видимый пробельный символ значение заканчивает.
        func visible(_ range: NSRange, _ string: String) {
            let hiddenNow = stack[stack.count - 1].hidden
            // Служебный знак кончается на видимом тексте страницы; знак страницы текст служебных групп не берёт.
            if !hiddenNow { close(&service) }
            guard var pending = hiddenNow ? service : current else { return }
            if let scalar = string.unicodeScalars.first, string.unicodeScalars.count == 1, scalar.properties.isWhitespace {
                if skipsLeadingSpace, pending.parts.isEmpty { return }
                if hiddenNow { close(&service) } else { close(&current) }
                return
            }
            if let last = pending.parts.last, NSMaxRange(last) == range.location {
                pending.parts[pending.parts.count - 1].length += range.length
            } else {
                pending.parts.append(range)
            }
            pending.text += string
            if hiddenNow { service = pending } else { current = pending }
        }

        func byteChar(_ byte: Int) -> String {
            let unit = byteTable?[byte] ?? UInt16(byte)
            return String(utf16CodeUnits: [unit], count: 1)
        }

        /// Длина `\'hh` в позиции `i` (4) или 0.
        func hexEscape(at i: Int) -> Int {
            guard i + 3 < count, u[i] == 0x5C, u[i + 1] == 0x27, hexValue(u[i + 2]) != nil, hexValue(u[i + 3]) != nil else { return 0 }
            return 4
        }

        var i = 0
        while i < count {
            let unit = u[i]
            switch unit {
            case 0x7B:   // {
                let top = stack[stack.count - 1]
                stack.append(Group(hidden: top.hidden, uc: top.uc, fresh: true))
                i += 1
            case 0x7D:   // }
                if stack.count > 1 { stack.removeLast() }
                i += 1
            case 0x0D, 0x0A:
                // Переводы строк в исходнике RTF не видны и значение не прерывают.
                i += 1
            case 0x09:
                finish()
                i += 1
            case 0x24:   // $
                if stack[stack.count - 1].hidden {
                    // `$` служебной группы значение страницы не прерывает.
                    close(&service)
                    service = Pending(dollar: i, hidden: true)
                } else {
                    finish()
                    current = Pending(dollar: i, hidden: false)
                }
                i += 1
            case 0x5C:   // \
                guard i + 1 < count else { i += 1; continue }
                let next = u[i + 1]
                if next == 0x27 {
                    let length = hexEscape(at: i)
                    if length > 0, let high = hexValue(u[i + 2]), let low = hexValue(u[i + 3]) {
                        stack[stack.count - 1].fresh = false
                        if current != nil || service != nil { visible(NSRange(location: i, length: 4), byteChar(high * 16 + low)) }
                        i += 4
                    } else {
                        i += 2
                    }
                } else if isLetter(next) {
                    var end = i + 1
                    var name = WordKey()
                    while end < count, isLetter(u[end]) {
                        name.append(u[end])
                        end += 1
                    }
                    var number: Int?
                    var stop = end
                    if stop < count, u[stop] == 0x2D || isDigit(u[stop]) {
                        let negative = u[stop] == 0x2D
                        var digits = negative ? stop + 1 : stop
                        var value = 0
                        let first = digits
                        while digits < count, isDigit(u[digits]) {
                            value = value &* 10 &+ Int(u[digits] - 0x30)
                            digits += 1
                        }
                        if digits > first {
                            number = negative ? -value : value
                            stop = digits
                        }
                    }
                    // Один пробел после слова — часть кода, не текст.
                    if stop < count, u[stop] == 0x20 { stop += 1 }
                    let word = NSRange(location: i, length: stop - i)
                    var top = stack[stack.count - 1]
                    if top.fresh, hiddenKeys.contains(name) { top.hidden = true }
                    top.fresh = false
                    stack[stack.count - 1] = top
                    i = stop
                    if terminatorKeys.contains(name) {
                        finish()
                    } else if name == ucKey {
                        stack[stack.count - 1].uc = max(0, number ?? 1)
                    } else if name == uKey, let number {
                        // \uN и N заменителей после него (обычные символы или \'hh) — один видимый символ.
                        let scalar = UInt32(number < 0 ? number + 65_536 : number)
                        var skip = top.uc
                        var end = i
                        while skip > 0, end < count {
                            let escape = hexEscape(at: end)
                            if escape > 0 { end += escape } else if u[end] == 0x7B || u[end] == 0x7D || u[end] == 0x5C { break } else { end += 1 }
                            skip -= 1
                        }
                        if current != nil || service != nil {
                            let character = Unicode.Scalar(scalar).map { String(Character($0)) } ?? "\u{FFFD}"
                            visible(NSRange(location: word.location, length: end - word.location), character)
                        }
                        i = end
                    } else if name == binKey, let number, number > 0 {
                        i = min(count, i + number)
                    } else if current != nil || service != nil, let symbol = symbolKeys[name] {
                        visible(word, symbol)
                    }
                } else {
                    let symbol = NSRange(location: i, length: 2)
                    stack[stack.count - 1].fresh = false
                    i += 2
                    switch next {
                    case 0x2A: stack[stack.count - 1].hidden = true   // \* — назначение, которое можно не понимать
                    case 0x5C, 0x7B, 0x7D: visible(symbol, String(utf16CodeUnits: [next], count: 1))
                    case 0x7E: visible(symbol, "\u{00A0}")             // \~ неразрывный пробел
                    case 0x5F: visible(symbol, "\u{2011}")             // \_ неразрывный дефис
                    case 0x2D: visible(symbol, "")                     // \- мягкий перенос: в значении, но не виден
                    case 0x0D, 0x0A: finish()                          // \ + перевод строки = \par
                    default: break
                    }
                }
            default:
                stack[stack.count - 1].fresh = false
                // Символ целиком (суррогатная пара — один символ). Вне значения строку не собираем.
                var length = 1
                if (0xD800...0xDBFF).contains(unit), i + 1 < count, (0xDC00...0xDFFF).contains(u[i + 1]) { length = 2 }
                if current != nil || service != nil {
                    visible(NSRange(location: i, length: length), String(utf16CodeUnits: Array(u[i..<(i + length)]), count: length))
                }
                i += length
            }
        }
        finish()
        // Служебный знак внутри значения страницы закрывается раньше него.
        marks.sort { $0.dollar < $1.dollar }
        return marks
    }
}

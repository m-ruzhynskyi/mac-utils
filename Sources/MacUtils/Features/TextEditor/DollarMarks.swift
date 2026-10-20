import Foundation

/// Знак `$` и его значение. Смещения — в UTF-16, как у `NSString` и `NSTextView`.
struct DollarMark: Equatable {
    /// Где стоит `$`.
    let dollar: Int
    /// Охват значения: от символа сразу после `$` до конца последнего символа значения; длина 0 — значение пустое.
    let value: NSRange
    /// Куски исходника, из которых состоит значение. В исходнике — один кусок (`value`); в RTF — только видимые символы
    /// (обычные символы, `\'hh`, `\uN` с заменителем…), а коды и группы между ними в значение не входят.
    let parts: [NSRange]
    /// Видимое значение (RTF: `\'e9` → é, `\u1071?` → я); `nil` — это сам текст `value`.
    let visible: String?
    /// Знак внутри служебной группы RTF (`\info`, `{\*\…}`, таблицы шрифтов…): на странице его не видно, не трогаем.
    let hidden: Bool

    init(dollar: Int, value: NSRange, parts: [NSRange]? = nil, visible: String? = nil, hidden: Bool = false) {
        self.dollar = dollar
        self.value = value
        self.parts = parts ?? (value.length > 0 ? [value] : [])
        self.visible = visible
        self.hidden = hidden
    }

    /// `$` вместе со значением.
    var whole: NSRange { NSRange(location: dollar, length: value.length + 1) }

    var isEmpty: Bool { parts.isEmpty }

    /// Значение как его видит читатель документа.
    func text(in source: NSString) -> String { visible ?? source.substring(with: value) }
}

/// Как считать значение знака. Панель «$» — всегда `.source`; `.rtf` (по видимому тексту) — внутренний, для будущего
/// режима «Документ», в интерфейсе его нет.
enum DollarRule: String, Codable, CaseIterable {
    case rtf, source
}

/// Правило «$ и его значение» для панели «Знаки $» текстового редактора.
enum DollarMarks {
    /// Значение — все символы исходника после `$` до конца строки (CR/LF в значение не входит), следующего `$` или
    /// конца текста. Пробелы, `\ { } ; '`, коды RTF — всё входит, RTF не разбирается.
    static func isTerminator(_ unit: UInt16) -> Bool {
        unit == 0x24 || unit == 0x0A || unit == 0x0D
    }

    static func scan(_ text: NSString, rule: DollarRule, encoding: TextEncoding = .windows1252) -> [DollarMark] {
        rule == .rtf ? RTFDollarScanner.scan(text, encoding: encoding) : scan(text)
    }

    /// Все `$` по порядку со значениями.
    static func scan(_ units: UnsafeBufferPointer<UInt16>) -> [DollarMark] {
        var marks: [DollarMark] = []
        var i = 0
        let count = units.count
        while i < count {
            guard units[i] == 0x24 else { i += 1; continue }
            var end = i + 1
            while end < count, !isTerminator(units[end]) { end += 1 }
            marks.append(DollarMark(dollar: i, value: NSRange(location: i + 1, length: end - i - 1)))
            // Следующий `$` (если значение кончилось на нём) — со своим значением.
            i = end
        }
        return marks
    }

    static func scan(_ text: NSString) -> [DollarMark] {
        let length = text.length
        guard length > 0 else { return [] }
        if let pointer = CFStringGetCharactersPtr(text as CFString) {
            return scan(UnsafeBufferPointer(start: pointer, count: length))
        }
        var units = [UInt16](repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) }
        return units.withUnsafeBufferPointer { scan($0) }
    }

    static func scan(_ text: String) -> [DollarMark] { scan(text as NSString) }

    /// «Пропускать первые N»: первые `skipFirst` знаков не трогаются; `nil` — переключатель выключен, обрабатываются все.
    static func split(_ marks: [DollarMark], skipFirst: Int?) -> (skipped: ArraySlice<DollarMark>, active: ArraySlice<DollarMark>) {
        let skip = min(max(skipFirst ?? 0, 0), marks.count)
        return (marks[..<skip], marks[skip...])
    }

    /// Куски значений к удалению, с конца к началу (удаление не сдвигает следующие). Коды RTF между кусками остаются.
    static func valueRanges(_ marks: some Sequence<DollarMark>) -> [NSRange] {
        marks.flatMap(\.parts).filter { $0.length > 0 }.sorted { $0.location > $1.location }
    }

    /// Оттенок знака по самому значению (FNV-1a по UTF-16): одинаковые значения всегда одного цвета, в любом
    /// файле и после перезапуска. Пустое значение — `nil`, нейтральный оттенок.
    static func hue(of value: NSString, hues: Int = 6) -> Int? {
        let length = value.length
        guard length > 0 else { return nil }
        var hash: UInt32 = 2_166_136_261
        for i in 0..<length {
            let unit = value.character(at: i)
            hash = (hash ^ UInt32(unit & 0xFF)) &* 16_777_619
            hash = (hash ^ UInt32(unit >> 8)) &* 16_777_619
        }
        return Int(hash % UInt32(hues))
    }

    /// Непарных `{` и `}` во всём тексте (`\{`, `\}` и `\\` — не скобки). 0 — баланс есть.
    static func unbalancedBraces(in text: NSString) -> Int {
        let length = text.length
        guard length > 0 else { return 0 }
        var units = [UInt16](repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) }
        var depth = 0, unmatched = 0, i = 0
        while i < length {
            switch units[i] {
            case 0x5C: i += 1                     // экранированный знак за `\` пропускаем
            case 0x7B: depth += 1
            case 0x7D: if depth > 0 { depth -= 1 } else { unmatched += 1 }
            default: break
            }
            i += 1
        }
        return unmatched + depth
    }

    /// Текст без значений у `marks`; сами `$` остаются.
    static func removingValues(of marks: some Sequence<DollarMark>, in text: String) -> String {
        let result = NSMutableString(string: text)
        for range in valueRanges(marks) { result.deleteCharacters(in: range) }
        return result as String
    }
}

/// Начала строк текста — номер строки и столбец по смещению UTF-16. Перевод строки — CRLF, LF или CR.
struct LineIndex {
    /// Смещение первого символа каждой строки; первая строка начинается с 0.
    private(set) var starts: [Int] = [0]

    init(_ text: NSString) {
        let length = text.length
        guard length > 0 else { return }
        if let pointer = CFStringGetCharactersPtr(text as CFString) {
            scan(UnsafeBufferPointer(start: pointer, count: length))
            return
        }
        var units = [UInt16](repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) }
        units.withUnsafeBufferPointer { scan($0) }
    }

    private mutating func scan(_ units: UnsafeBufferPointer<UInt16>) {
        let length = units.count
        var i = 0
        while i < length {
            let unit = units[i]
            if unit == 0x0D {
                i += (i + 1 < length && units[i + 1] == 0x0A) ? 2 : 1
                starts.append(i)
            } else if unit == 0x0A {
                i += 1
                starts.append(i)
            } else {
                i += 1
            }
        }
    }

    init(_ text: String) { self.init(text as NSString) }

    var lineCount: Int { starts.count }

    /// После правки `text`: `editedRange` — новый диапазон в тексте, `delta` — на сколько изменилась длина.
    /// Пересчитывается только окрестность правки (с символа перед ней — CRLF может склеиться или разойтись),
    /// остальные начала строк сдвигаются.
    mutating func update(_ text: NSString, editedRange: NSRange, delta: Int) {
        let length = text.length
        // Правка на большую часть текста (замена целиком, отмена её) — построить заново быстрее.
        if editedRange.length > 65_536, editedRange.length * 4 > length {
            self = LineIndex(text)
            return
        }
        let from = max(0, editedRange.location - 1)
        var to = min(editedRange.location + editedRange.length + 1, length)
        // Граница — не сразу после CR: иначе следующий LF решает, где начнётся строка.
        while to < length, to > 0, text.character(at: to - 1) == 0x0D { to += 1 }
        // Окрестность правки одним куском (и ещё знак после неё — для CRLF на границе).
        let windowEnd = min(to + 1, length)
        var units = [UInt16](repeating: 0, count: windowEnd - from)
        units.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { text.getCharacters(base, range: NSRange(location: from, length: windowEnd - from)) }
        }
        var fresh: [Int] = []
        var i = from
        while i < to {
            let unit = units[i - from]
            if unit == 0x0D {
                i += (i + 1 < length && units[i + 1 - from] == 0x0A) ? 2 : 1
                fresh.append(i)
            } else if unit == 0x0A {
                i += 1
                fresh.append(i)
            } else {
                i += 1
            }
        }
        // Прежние начала в (from, to − delta] заменяются новыми, дальше — сдвиг на delta.
        let low = firstIndex(after: from)
        let high = firstIndex(after: to - delta)
        starts.replaceSubrange(low..<high, with: fresh)
        if delta != 0 {
            for index in (low + fresh.count)..<starts.count { starts[index] += delta }
        }
    }

    /// Первый индекс, где начало строки больше `offset`.
    private func firstIndex(after offset: Int) -> Int {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Номер строки (с 1) для смещения.
    func line(at offset: Int) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// Строка и столбец (оба с 1).
    func position(at offset: Int) -> (line: Int, column: Int) {
        let line = line(at: offset)
        return (line, offset - starts[line - 1] + 1)
    }
}

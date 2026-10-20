import Foundation

/// Знак `$` и его значение. Смещения — в UTF-16, как у `NSString` и `NSTextView`.
struct DollarMark: Equatable {
    /// Где стоит `$`.
    let dollar: Int
    /// Значение: начинается сразу после `$`; длина 0 — значение пустое.
    let value: NSRange

    /// `$` вместе со значением.
    var whole: NSRange { NSRange(location: dollar, length: value.length + 1) }
}

/// Правило «$ и его значение» для панели «Знаки $» текстового редактора.
enum DollarMarks {
    /// Значение — символы сразу после `$` до первого пробельного символа, одного из `\ { } $ ;` или конца текста.
    static func isTerminator(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x5C, 0x7B, 0x7D, 0x24, 0x3B: return true // \ { } $ ;
        case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D: return true
        case 0..<0x80: return false
        default:
            // Половинки суррогатной пары пробелом не бывают; остальное — по свойству Юникода (NBSP, U+2028…).
            return Unicode.Scalar(unit)?.properties.isWhitespace ?? false
        }
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

    /// Диапазоны значений к удалению, с конца к началу (удаление не сдвигает следующие). Пустые значения пропускаются.
    static func valueRanges(_ marks: some Sequence<DollarMark>) -> [NSRange] {
        marks.map(\.value).filter { $0.length > 0 }.sorted { $0.location > $1.location }
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
        var units = [UInt16](repeating: 0, count: length)
        units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) }
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

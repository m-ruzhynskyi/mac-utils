import Foundation

// Списки как в Word (E-2): номера считаются по `\listtable`/`\listoverridetable` и `\ls`/`\ilvl` абзацев. Готовый
// номер `{\listtext …}` Word при чтении не берёт — он лишь подсказка для программ без списков; мы тоже не показываем его,
// если список найден, а при правке переписываем, чтобы он не расходился с номером.

/// Свойства символа номера из уровня списка: заданное здесь заменяет свойства знака конца абзаца (как в Word).
struct RTFListCharProps: Hashable {
    var font: Int?
    var halfPoints: Int?
    var bold: Bool?
    var italic: Bool?
    var underline: RTFUnderline?
    var strike: Bool?
    var color: Int?
    var caps: Bool?
    var hidden: Bool?

    func applied(to base: RTFCharProps) -> RTFCharProps {
        var props = base
        if let font { props.font = font }
        if let halfPoints { props.halfPoints = halfPoints }
        if let bold { props.bold = bold }
        if let italic { props.italic = italic }
        if let underline { props.underline = underline }
        if let strike { props.strike = strike }
        if let color { props.color = color }
        if let caps { props.caps = caps }
        if let hidden { props.hidden = hidden }
        // Номер не бывает выделен маркером и не наследует индекс знака абзаца.
        props.highlight = 0
        props.background = 0
        props.vertical = .normal
        return props
    }
}

/// Уровень списка `{\listlevel …}`.
struct RTFListLevel: Hashable {
    /// `\levelnfcN`: 0 — 1, 2, 3; 1/2 — римские; 3/4 — буквы; 22 — 01; 23 — маркер; 255 — без номера.
    var format = 0
    var start = 1
    /// `\leveltext` без байта длины: литералы и места номеров уровней.
    var text: [UInt16] = []
    /// Места номеров в `text` (по `\levelnumbers`): индекс в `text` → уровень, чей номер там стоит.
    var placeholders: [Int: Int] = [:]
    /// `\levelfollowN`: 0 — табуляция, 1 — пробел, 2 — ничего.
    var follow = 0
    /// `\levellegal`: номера старших уровней — арабскими цифрами.
    var legal = false
    /// `\levelnorestart`: не начинать заново после пункта старшего уровня.
    var noRestart = false
    /// Отступы уровня (`\li`, `\fi`) и табуляция после номера (`\jclisttab\txN`), если заданы.
    var left: Int?
    var firstLine: Int?
    var tab: Int?
    var char = RTFListCharProps()
}

/// Список `{\list …}`.
struct RTFList: Hashable {
    var id = 0
    var levels: [RTFListLevel] = []
    /// `\listrestarthdn` — нумерация заново в каждом разделе.
    var restartsEachSection = false
}

/// Замена списка `{\listoverride …}`: номер `\lsN` абзацев → список `\listid` и замены уровней.
struct RTFListOverride: Hashable {
    var listID = 0
    /// `{\lfolevel\listoverridestartat\levelstartatN}` — начать уровень с N.
    var starts: [Int: Int] = [:]
    /// `{\lfolevel\listoverrideformat{\listlevel …}}` — свой вид уровня.
    var formats: [Int: RTFListLevel] = [:]
}

/// Таблицы списков документа.
struct RTFListTable: Hashable {
    var lists: [Int: RTFList] = [:]
    var overrides: [Int: RTFListOverride] = [:]

    var isEmpty: Bool { overrides.isEmpty }

    /// Уровень `level` списка абзаца `\ls` — с заменами из `\listoverride`. `nil` — у абзаца нет списка.
    func level(list ls: Int, level: Int) -> (list: RTFList, override: RTFListOverride, level: RTFListLevel, index: Int)? {
        guard ls > 0, let override = overrides[ls], let list = lists[override.listID], !list.levels.isEmpty else { return nil }
        let index = min(max(level, 0), list.levels.count - 1)
        return (list, override, override.formats[index] ?? list.levels[index], index)
    }
}

// MARK: - Разбор

enum DocListReader {
    /// Разобрать группы таблиц списков (диапазоны — из `RTFReader`). `\'hh` литералов — в кодовой странице документа.
    static func read(_ source: NSString, table: NSRange?, overrides: NSRange?, codePage: TextEncoding) -> RTFListTable {
        var result = RTFListTable()
        let decode = SingleByteTable.table(for: codePage)?.decodeTable ?? []
        if let table { result.lists = lists(source, table, decode: decode) }
        if let overrides { result.overrides = self.overrides(source, overrides, decode: decode) }
        return result
    }

    private enum Place: Equatable { case other, list, level, levelText, levelNumbers, skip }

    private static func lists(_ source: NSString, _ range: NSRange, decode: [UInt16]) -> [Int: RTFList] {
        var result: [Int: RTFList] = [:]
        var stack: [Place] = []
        var list = RTFList()
        var level = RTFListLevel()
        var text: [UInt16] = []
        var numbers: [Int] = []
        var uc = 1
        var skipReplacements = 0
        var tabPending = false
        for token in RTFLexer.tokens(source, in: range) {
            let place = stack.last ?? .other
            if skipReplacements > 0, token.kind == .text || token.kind == .hex {
                skipReplacements -= 1
                continue
            }
            skipReplacements = 0
            switch token.kind {
            case .open:
                stack.append(place == .skip ? .skip : .other)
            case .close:
                let closed = stack.popLast() ?? .other
                switch closed {
                case .list:
                    result[list.id] = list
                case .level:
                    list.levels.append(level)
                case .levelText:
                    // Первый символ — длина.
                    let length = text.first.map(Int.init) ?? 0
                    level.text = Array(text.dropFirst().prefix(length))
                case .levelNumbers:
                    for position in numbers where position >= 1 && position <= level.text.count {
                        level.placeholders[position - 1] = Int(level.text[position - 1])
                    }
                default: break
                }
            case .word:
                if place == .skip { continue }
                let number = token.number
                // Первое слово группы задаёт, что это за группа.
                if place == .other, stack.count > 0 {
                    switch token.name {
                    case "list" where stack.count == 2:
                        stack[stack.count - 1] = .list
                        list = RTFList()
                        continue
                    case "listlevel":
                        stack[stack.count - 1] = .level
                        level = RTFListLevel()
                        tabPending = false
                        continue
                    case "leveltext":
                        stack[stack.count - 1] = .levelText
                        text = []
                        continue
                    case "levelnumbers":
                        stack[stack.count - 1] = .levelNumbers
                        numbers = []
                        continue
                    case "listname", "listpicture", "levelpicture":
                        stack[stack.count - 1] = .skip
                        continue
                    default: break
                    }
                }
                switch token.name {
                case "uc": uc = max(0, number ?? 1)
                case "u" where stack.last == .levelText:
                    if let number { text.append(UInt16(truncatingIfNeeded: number < 0 ? number + 65_536 : number)) }
                    skipReplacements = uc
                case "leveltemplateid": break
                case "listid": list.id = number ?? 0
                case "listrestarthdn": list.restartsEachSection = true
                default:
                    if stack.contains(.level) { levelWord(token.name, number, level: &level, tabPending: &tabPending) }
                }
            case .hex:
                guard place != .skip, let byte = hexByte(source, token) else { continue }
                switch place {
                case .levelText:
                    // Места номеров (`\'00`…`\'08`) и длина — числами, остальное — буквами кодовой страницы.
                    text.append(byte < 0x20 || text.isEmpty ? UInt16(byte) : (byte < decode.count ? decode[byte] : UInt16(byte)))
                case .levelNumbers: numbers.append(byte)
                default: break
                }
            case .text:
                guard place == .levelText else { continue }
                let unit = source.character(at: token.range.location)
                if unit == 0x3B, text.count > Int(text.first ?? 0) { continue }
                text.append(unit)
            case .symbol:
                if place == .levelText, ["\\", "{", "}"].contains(token.name) { text.append(token.name.utf16.first ?? 0) }
            case .newline, .binary:
                break
            }
        }
        return result
    }

    private static func levelWord(_ name: String, _ number: Int?, level: inout RTFListLevel, tabPending: inout Bool) {
        let on = (number ?? 1) != 0
        switch name {
        case "levelnfc", "levelnfcn": level.format = number ?? 0
        case "levelstartat": level.start = number ?? 1
        case "levelfollow": level.follow = number ?? 0
        case "levellegal": level.legal = on
        case "levelnorestart": level.noRestart = on
        case "li", "lin": level.left = number ?? 0
        case "fi": level.firstLine = number ?? 0
        case "jclisttab": tabPending = true
        case "tx":
            if tabPending { level.tab = number }
            tabPending = false
        case "f": level.char.font = number ?? 0
        case "fs": level.char.halfPoints = max(1, number ?? 24)
        case "b": level.char.bold = on
        case "i": level.char.italic = on
        case "ul": level.char.underline = on ? .single : RTFUnderline.none
        case "ulnone": level.char.underline = RTFUnderline.none
        case "strike": level.char.strike = on
        case "cf": level.char.color = max(0, number ?? 0)
        case "caps": level.char.caps = on
        case "v": level.char.hidden = on
        default: break
        }
    }

    private static func overrides(_ source: NSString, _ range: NSRange, decode: [UInt16]) -> [Int: RTFListOverride] {
        var result: [Int: RTFListOverride] = [:]
        var override = RTFListOverride()
        var ls = 0
        var depth = 0
        var overrideDepth: Int?
        var levelIndex = -1
        var levelDepth: Int?
        var startPending = false
        var formatPending = false
        var formatStart: Int?
        for token in RTFLexer.tokens(source, in: range) {
            switch token.kind {
            case .open:
                depth += 1
                if formatStart == nil, formatPending, levelDepth != nil { formatStart = token.range.location }
            case .close:
                if let start = formatStart, levelDepth != nil, depth == (levelDepth ?? 0) + 1 {
                    // `{\listlevel …}` замены уровня — тем же разбором, что в таблице списков.
                    let group = NSRange(location: start, length: NSMaxRange(token.range) - start)
                    let wrapped = "{{\\list" + source.substring(with: group) + "\\listid1}}"
                    if let parsed = lists(wrapped as NSString, NSRange(location: 0, length: (wrapped as NSString).length), decode: decode)[1]?.levels.first {
                        override.formats[levelIndex] = parsed
                    }
                    formatStart = nil
                    formatPending = false
                }
                if depth == levelDepth { levelDepth = nil }
                if depth == overrideDepth {
                    if ls > 0 { result[ls] = override }
                    overrideDepth = nil
                }
                depth -= 1
            case .word:
                if formatStart != nil { continue }
                switch token.name {
                case "listoverride":
                    override = RTFListOverride()
                    ls = 0
                    overrideDepth = depth
                    levelIndex = -1
                case "listid" where levelDepth == nil: override.listID = token.number ?? 0
                case "ls" where levelDepth == nil: ls = token.number ?? 0
                case "lfolevel":
                    levelIndex += 1
                    levelDepth = depth
                    startPending = false
                    formatPending = false
                case "listoverridestartat": startPending = true
                case "listoverrideformat": formatPending = true
                case "levelstartat" where startPending && levelDepth != nil: override.starts[levelIndex] = token.number ?? 1
                default: break
                }
            default:
                break
            }
        }
        return result
    }

    private static func hexByte(_ source: NSString, _ token: RTFToken) -> Int? {
        guard token.range.length == 4 else { return nil }
        let digits = source.substring(with: NSRange(location: token.range.location + 2, length: 2))
        return Int(digits, radix: 16)
    }
}

import Foundation

/// Номер пункта списка, как его показывает Word: текст с символом после номера, свойства символа, уровень.
struct DocListLabel: Equatable {
    /// Номер без символа после него («1.2.», «•»).
    var number: String
    /// `\levelfollow`: 0 — табуляция, 1 — пробел, 2 — ничего.
    var follow: Int
    var props: RTFCharProps
    var level: RTFListLevel
    /// `\ls` и уровень абзаца (после ограничения числом уровней).
    var list: Int
    var levelIndex: Int

    /// Показанный текст номера: сам номер и символ после него.
    var text: String { number + (follow == 0 ? "\t" : follow == 1 ? " " : "") }
}

/// Нумерация списков истории по правилам Word: счётчики — по списку (`\listid`), общие для всех его замен `\ls`, пока
/// замена не начинает уровень заново (`\listoverridestartat`); пункт уровня сбрасывает все младшие (кроме
/// `\levelnorestart`); `\listrestarthdn` — заново в каждом разделе. Текст — по шаблону `\leveltext`.
enum DocListNumbers {
    static let levelCount = 9

    /// Номера абзацев истории: номер абзаца → его номер в списке. Абзацы без списка (или с неизвестным `\ls`) — нет.
    static func labels(_ story: RTFStory, lists: RTFListTable) -> [Int: DocListLabel] {
        guard !lists.isEmpty else { return [:] }
        var result: [Int: DocListLabel] = [:]
        var counters: [Int: [Int?]] = [:]
        var sections: [Int: Int] = [:]
        var startsApplied = Set<[Int]>()
        for (index, paragraph) in story.paragraphs.enumerated() {
            let ls = paragraph.props.list
            guard ls > 0, let found = lists.level(list: ls, level: paragraph.props.listLevel) else { continue }
            let key = found.list.id
            var values = counters[key] ?? Array(repeating: nil, count: levelCount)
            if found.list.restartsEachSection, sections[key] != paragraph.section { values = Array(repeating: nil, count: levelCount) }
            sections[key] = paragraph.section
            let level = found.index
            let levels = (0..<levelCount).map { found.override.formats[$0] ?? found.list.levels[safe: $0] ?? found.level }
            if let start = found.override.starts[level], !startsApplied.contains([ls, level]) {
                startsApplied.insert([ls, level])
                values[level] = start
            } else {
                values[level] = (values[level] ?? (levels[level].start - 1)) + 1
            }
            for deeper in (level + 1)..<levelCount where !levels[deeper].noRestart { values[deeper] = nil }
            counters[key] = values
            let number = text(found.level, level: level, values: values, levels: levels)
            let props = found.level.char.applied(to: paragraph.endProps)
            result[index] = DocListLabel(number: number, follow: found.level.follow, props: props, level: found.level, list: ls,
                                         levelIndex: level)
        }
        return result
    }

    /// Кусок показа номера: его единицы и места исходника — пустые, на месте `{\listtext}` (или в начале области абзаца):
    /// номер не правится как текст и стоит до текста абзаца в порядке исходника.
    static func piece(_ label: DocListLabel, paragraph: RTFParagraph) -> (units: [UInt16], ranges: [NSRange])? {
        let units = Array(label.text.utf16)
        guard !units.isEmpty else { return nil }
        let location = min(paragraph.listTextGroup?.location ?? paragraph.regionStart, paragraph.textStart)
        return (units, Array(repeating: NSRange(location: location, length: 0), count: units.count))
    }

    /// Свойства абзаца для показа: при выступе первой строки — табуляция на отступе (Word ставит табуляцию после номера
    /// туда, если до отступа нет своей). Отступы — абзаца: в RTF они записаны у него самого, отступы уровня Word тут
    /// не подставляет (сверено с PDF Word).
    static func shownProps(_ props: RTFParaProps, label: DocListLabel) -> RTFParaProps {
        var shown = props
        if label.follow == 0, shown.firstLine < 0, !shown.tabs.contains(where: { $0.position == shown.left && $0.kind != .bar }) {
            let index = shown.tabs.firstIndex { $0.position > shown.left } ?? shown.tabs.count
            shown.tabs.insert(RTFTabStop(position: shown.left), at: index)
        }
        return shown
    }

    /// Текст номера по шаблону уровня.
    static func text(_ level: RTFListLevel, level index: Int, values: [Int?], levels: [RTFListLevel]) -> String {
        var units: [UInt16] = []
        for (position, unit) in level.text.enumerated() {
            if let placeholder = level.placeholders[position] {
                guard placeholder >= 0, placeholder < levelCount else { continue }
                let other = levels[placeholder]
                let format = level.legal && placeholder < index ? 0 : other.format
                units += Array(formatted(values[placeholder] ?? other.start, format: format).utf16)
            } else if unit >= 0x20 {
                units.append(symbolBullets[unit] ?? unit)
            }
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Число в виде `\levelnfc`.
    static func formatted(_ value: Int, format: Int) -> String {
        switch format {
        case 1: return roman(value).uppercased()
        case 2: return roman(value)
        case 3: return letters(value).uppercased()
        case 4: return letters(value)
        case 22: return value >= 0 && value < 10 ? "0\(value)" : "\(value)"
        case 23, 255: return ""
        default: return "\(value)"
        }
    }

    private static func roman(_ value: Int) -> String {
        guard value > 0, value < 4_000 else { return "\(value)" }
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
                                      (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var rest = value
        var out = ""
        for (number, letters) in table {
            while rest >= number {
                out += letters
                rest -= number
            }
        }
        return out
    }

    /// a…z, затем aa…zz (как в Word: буква повторяется).
    private static func letters(_ value: Int) -> String {
        guard value > 0 else { return "\(value)" }
        let letter = Character(UnicodeScalar(UInt8(0x61 + (value - 1) % 26)))
        return String(repeating: letter, count: (value - 1) / 26 + 1)
    }

    /// Маркеры из Symbol и Wingdings (личная область `F0xx`) → знаки Юникода: шрифт номера остаётся тем же (по нему —
    /// высота строки, как у Word; в Symbol на Mac знаки — по Юникоду), а знак виден и без шрифта Windows.
    static let symbolBullets: [UInt16: UInt16] = [
        0xF0B7: 0x2022,  // •
        0xF0A7: 0x25AA,  // ▪
        0xF0A8: 0x25C6,  // ◆
        0xF076: 0x2756,  // ❖
        0xF0D8: 0x27A2,  // ➢
        0xF0FC: 0x2713,  // ✓
        0xF06E: 0x25A0,  // ■
        0xF071: 0x2751,  // ❑
        0xF0B2: 0x25CB,  // ○
        0xF02D: 0x2013,  // –
    ]
}

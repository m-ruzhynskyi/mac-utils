import Foundation

/// Карта показанного текста: каждая единица UTF-16 страницы → кусок исходника и её вид. Идёт по порядку исходника
/// (у служебных единиц — пустой диапазон на своём месте), поэтому обратный путь «место исходника → символ» —
/// двоичный поиск. Числа — `Int32`: у 10 МБ исходника миллионы единиц.
package struct DocSourceMap: Equatable {
    package enum Kind: UInt8 {
        /// Обычный символ — правится.
        case text
        /// `\tab`, `\line` — правятся как символы.
        case tab, lineBreak
        /// Конец абзаца `\par` — удаляется (абзацы склеиваются).
        case paragraphEnd
        /// Конец ячейки `\cell`, конец раздела `\sect`, конец истории — не удаляются.
        case cellEnd, sectionEnd, storyEnd
        /// Разрыв страницы `\page` / `\pagebb` — удаляется вместе с кодом.
        case pageBreak
        /// Новая страница раздела (своего кода нет) — не удаляется.
        case sectionBreak
        /// Номер страницы и число страниц — неделимы, удаляются только целым полем.
        case field
        /// Номер списка (`\pntext`) — не правится.
        case listText
        /// Рисунок или заглушка — не правится, переносится байт в байт.
        case object
        /// Скрытый текст при включённых ¶ — правится.
        case hidden

        package var isEditable: Bool {
            switch self {
            case .text, .tab, .lineBreak, .hidden: return true
            default: return false
            }
        }

        /// Удаляется ли единица вместе с выделением (код в исходнике вырезается).
        package var isDeletable: Bool {
            switch self {
            case .text, .tab, .lineBreak, .hidden, .paragraphEnd, .pageBreak: return true
            default: return false
            }
        }
    }

    package private(set) var locations: [Int32] = []
    package private(set) var lengths: [Int32] = []
    package private(set) var kinds: [Kind] = []

    package var count: Int { locations.count }

    package mutating func append(_ range: NSRange, kind: Kind) {
        locations.append(Int32(truncatingIfNeeded: range.location))
        lengths.append(Int32(truncatingIfNeeded: range.length))
        kinds.append(kind)
    }

    package mutating func reserve(_ capacity: Int) {
        locations.reserveCapacity(capacity)
        lengths.reserveCapacity(capacity)
        kinds.reserveCapacity(capacity)
    }

    package func range(at unit: Int) -> NSRange {
        NSRange(location: Int(locations[unit]), length: Int(lengths[unit]))
    }

    package func kind(at unit: Int) -> Kind { kinds[unit] }

    /// Первая единица, чей кусок исходника начинается не раньше `location` (`count`, если таких нет).
    package func firstUnit(atOrAfter location: Int) -> Int {
        var low = 0, high = locations.count
        let target = Int32(truncatingIfNeeded: location)
        while low < high {
            let mid = (low + high) / 2
            if locations[mid] < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Ближайший видимый символ к месту исходника: единица, внутри которой оно лежит, иначе следующая.
    package func unit(forSource location: Int) -> Int {
        let next = firstUnit(atOrAfter: location)
        if next > 0, NSLocationInRange(location, range(at: next - 1)) { return next - 1 }
        return next
    }

    /// Место исходника перед единицей `unit` (у конца текста — после последней).
    package func sourceLocation(beforeUnit unit: Int) -> Int {
        if unit < count { return Int(locations[unit]) }
        guard count > 0 else { return 0 }
        return NSMaxRange(range(at: count - 1))
    }

    /// Кусок исходника, который покрывает показанные единицы `units` (от начала первой до конца последней).
    package func sourceRange(ofUnits units: NSRange) -> NSRange {
        guard units.length > 0, units.location < count else {
            let location = sourceLocation(beforeUnit: units.location)
            return NSRange(location: location, length: 0)
        }
        let first = range(at: units.location)
        let last = range(at: min(count, NSMaxRange(units)) - 1)
        return NSRange(location: first.location, length: max(0, NSMaxRange(last) - first.location))
    }

    /// Показанные единицы, чьи куски исходника целиком лежат внутри `source`, — непрерывными отрезками.
    package func units(inside source: NSRange) -> [NSRange] {
        var result: [NSRange] = []
        var unit = firstUnit(atOrAfter: source.location)
        let end = NSMaxRange(source)
        while unit < count, Int(locations[unit]) < end {
            let piece = range(at: unit)
            if piece.length > 0, NSMaxRange(piece) <= end {
                if let last = result.last, NSMaxRange(last) == unit {
                    result[result.count - 1].length += 1
                } else {
                    result.append(NSRange(location: unit, length: 1))
                }
            }
            unit += 1
        }
        return result
    }
}

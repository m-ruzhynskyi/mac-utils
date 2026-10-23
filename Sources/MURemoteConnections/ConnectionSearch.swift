import Foundation

/// Поиск по названию, ID, группе, тегам и заметке: без регистра и диакритики, по частям слов,
/// ID — с пробелами и без. Если по запросу ничего нет, пробует его в другой раскладке («ctdth» → «север»).
public struct ConnectionSearch: Sendable {
    /// Запрос, набранный не в той раскладке, и во что он превратился — для плашки «ctdth → север».
    public struct LayoutHint: Equatable, Sendable {
        public let typed: String
        public let converted: String
    }

    public struct Result: Equatable, Sendable {
        public var records: [ConnectionRecord]
        public var hint: LayoutHint?
        /// Запрос, по которому найдено (исходный или в другой раскладке), — для подсветки.
        public var effectiveQuery: String
    }

    private struct Entry: Sendable {
        let record: ConnectionRecord
        let name: String
        let id: String
        let rest: String
    }

    private let entries: [Entry]

    public init(_ records: [ConnectionRecord]) {
        entries = records.map { r in
            Entry(record: r, name: Self.fold(r.name), id: r.id,
                  rest: Self.fold(([r.group] + r.tags + [r.note]).joined(separator: "\u{1F}")))
        }
    }

    public var records: [ConnectionRecord] { entries.map(\.record) }

    public func search(_ query: String) -> Result {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Result(records: records, hint: nil, effectiveQuery: "") }
        let found = matches(trimmed)
        if !found.isEmpty { return Result(records: found, hint: nil, effectiveQuery: trimmed) }
        for alt in KeyboardLayouts.alternatives(trimmed) {
            let converted = matches(alt)
            if !converted.isEmpty {
                return Result(records: converted, hint: LayoutHint(typed: trimmed, converted: alt), effectiveQuery: alt)
            }
        }
        return Result(records: [], hint: nil, effectiveQuery: trimmed)
    }

    private func matches(_ query: String) -> [ConnectionRecord] {
        let folded = Self.fold(query)
        let tokens = folded.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // ID набирают с пробелами («123 456») — сравниваем и без них.
        let compact = folded.filter { !$0.isWhitespace }
        var scored: [(score: Int, index: Int)] = []
        for (i, e) in entries.enumerated() {
            let idHit = !compact.isEmpty && e.id.contains(compact)
            let allTokens = tokens.allSatisfy { t in e.name.contains(t) || e.id.contains(t) || e.rest.contains(t) }
            guard idHit || allTokens else { continue }
            scored.append((Self.score(e, folded: folded, first: tokens.first ?? folded, compact: compact), i))
        }
        scored.sort { ($0.score, $0.index) < ($1.score, $1.index) }
        return scored.map { entries[$0.index].record }
    }

    /// Чем меньше, тем выше: начало названия, начало слова в названии, часть названия, начало ID, остальное.
    private static func score(_ e: Entry, folded: String, first: String, compact: String) -> Int {
        if e.name.hasPrefix(folded) { return 0 }
        if e.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(first) }) { return 1 }
        if e.name.contains(first) { return 2 }
        if !compact.isEmpty, e.id.hasPrefix(compact) { return 3 }
        return 4
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
    }

    // MARK: Подсветка

    /// Где в тексте встречаются слова запроса (без регистра и диакритики) — для подсветки в списке.
    public static func highlights(in text: String, query: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for token in query.split(whereSeparator: { $0.isWhitespace }) {
            var from = text.startIndex
            while from < text.endIndex,
                  let r = text.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                ranges.append(r)
                from = r.upperBound
            }
        }
        return merge(ranges)
    }

    /// Подсветка в ID, показанном группами («123 456 789»): запрос сравнивается по цифрам, без пробелов.
    public static func highlightsInID(_ display: String, query: String) -> [Range<String.Index>] {
        let compact = fold(query).filter { !$0.isWhitespace }
        guard !compact.isEmpty else { return [] }
        let chars = Array(display.indices).filter { !display[$0].isWhitespace }
        let plain = String(chars.map { display[$0] }).lowercased()
        guard let hit = plain.range(of: compact) else { return highlights(in: display, query: query) }
        let lo = plain.distance(from: plain.startIndex, to: hit.lowerBound)
        let hi = plain.distance(from: plain.startIndex, to: hit.upperBound)
        return [chars[lo]..<display.index(after: chars[hi - 1])]
    }

    private static func merge(_ ranges: [Range<String.Index>]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}

extension ConnectionRecord {
    /// ID для показа: цифры группами по три с конца («123 456 789», «1 234 567 890»); алиас — как есть.
    public var displayID: String {
        guard !isAlias else { return id }
        var out = ""
        for (i, ch) in id.enumerated() {
            if i > 0, (id.count - i) % 3 == 0 { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}

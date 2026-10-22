import Foundation

/// Гейт «Документа» против эталона Word (`.audit/plan-doc-word-parity.md` § 4): база — по строке чисел на форму
/// (TSV вне репозитория, рядом с эталоном), прогон сравнивается с базой, форма «хуже» — падение.
/// Только числа и fNNN: текста документов здесь нет.
enum WordGate {
    struct Row: Equatable {
        var name: String
        /// Наша раскладка не открылась.
        var failed = false
        var pagesWord = 0
        var pagesOurs = 0
        var breaks: Double = 0
        var shiftMedian: Double = 0
        var shiftP95: Double = 0
        var shiftMax: Double = 0
        var cellWraps = 0
        var otherPage = 0
        var missingWords = 0
        var extraWords = 0
        var suspectPairs = 0
        var suspectMax: Double = 0
        var identical = false

        var pageDifference: Int { abs(pagesOurs - pagesWord) }

        init(name: String, failed: Bool = false) {
            self.name = name
            self.failed = failed
        }

        init(name: String, _ result: WordFidelity.Result) {
            self.name = name
            pagesWord = result.pagesWord
            pagesOurs = result.pagesOurs
            breaks = result.sameBreaks
            shiftMedian = Double(result.shift.median)
            shiftP95 = Double(result.shift.p95)
            shiftMax = Double(result.shift.max)
            cellWraps = result.extraCellWraps
            otherPage = result.otherPage
            missingWords = result.missingWords
            extraWords = result.extraWords
            suspectPairs = result.suspectPairs
            suspectMax = Double(result.suspectMax)
            identical = result.identical
        }

        static let header = ["file", "failed", "pages_word", "pages_ours", "breaks", "shift_median", "shift_p95", "shift_max",
                             "cell_wraps", "other_page", "missing_words", "extra_words", "suspect_pairs", "suspect_max", "identical"]

        var fields: [String] {
            [name, failed ? "1" : "0", "\(pagesWord)", "\(pagesOurs)", String(format: "%.4f", breaks),
             String(format: "%.2f", shiftMedian), String(format: "%.2f", shiftP95), String(format: "%.2f", shiftMax),
             "\(cellWraps)", "\(otherPage)", "\(missingWords)", "\(extraWords)", "\(suspectPairs)",
             String(format: "%.2f", suspectMax), identical ? "1" : "0"]
        }

        init?(fields: [String]) {
            guard fields.count == Self.header.count, fields[0].hasPrefix("f"), fields[0].count > 1,
                  fields[0].dropFirst().allSatisfy(\.isNumber) else { return nil }
            func int(_ i: Int) -> Int { Int(fields[i]) ?? 0 }
            func double(_ i: Int) -> Double { Double(fields[i]) ?? 0 }
            self.init(name: fields[0], failed: fields[1] == "1")
            pagesWord = int(2); pagesOurs = int(3); breaks = double(4)
            shiftMedian = double(5); shiftP95 = double(6); shiftMax = double(7)
            cellWraps = int(8); otherPage = int(9); missingWords = int(10); extraWords = int(11)
            suspectPairs = int(12); suspectMax = double(13); identical = fields[14] == "1"
        }
    }

    static func tsv(_ rows: [Row]) -> String {
        ([Row.header] + rows.sorted { $0.name < $1.name }.map(\.fields)).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    /// Строки TSV (заголовки и мусор пропускаются — можно склеивать файлы шардов как есть).
    static func rows(_ text: String) -> [Row] {
        text.split(whereSeparator: \.isNewline).compactMap { Row(fields: $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)) }
    }

    /// Чем форма стала хуже базы (пусто — не хуже). Допуски: доля разрывов −0,05 п. п., p95 сдвига +0,5 pt.
    static func worse(_ now: Row, than base: Row) -> [String] {
        if now.failed { return base.failed ? [] : ["не открылась"] }
        if base.failed { return [] }
        var found: [String] = []
        if now.pageDifference > base.pageDifference { found.append("страницы \(base.pagesWord)/\(base.pagesOurs) → \(now.pagesWord)/\(now.pagesOurs)") }
        if now.breaks < base.breaks - 0.0005 { found.append("разрывы \(percent(base.breaks)) → \(percent(now.breaks))") }
        if now.shiftP95 > base.shiftP95 + 0.5 { found.append("p95 сдвига \(pt(base.shiftP95)) → \(pt(now.shiftP95)) pt") }
        if now.cellWraps > base.cellWraps { found.append("переносы в ячейках \(base.cellWraps) → \(now.cellWraps)") }
        if now.missingWords > base.missingWords { found.append("нет слов \(base.missingWords) → \(now.missingWords)") }
        if now.extraWords > base.extraWords { found.append("лишние слова \(base.extraWords) → \(now.extraWords)") }
        return found
    }

    /// Чем форма стала лучше базы (те же метрики и допуски).
    static func better(_ now: Row, than base: Row) -> [String] {
        if base.failed { return now.failed ? [] : ["открылась"] }
        if now.failed { return [] }
        var found: [String] = []
        if now.pageDifference < base.pageDifference { found.append("страницы") }
        if now.breaks > base.breaks + 0.0005 { found.append("разрывы") }
        if now.shiftP95 < base.shiftP95 - 0.5 { found.append("p95 сдвига") }
        if now.cellWraps < base.cellWraps { found.append("переносы в ячейках") }
        if now.missingWords < base.missingWords { found.append("нет слов") }
        if now.extraWords < base.extraWords { found.append("лишние слова") }
        return found
    }

    struct Comparison {
        var worse: [(name: String, what: [String])] = []
        var better: [(name: String, what: [String])] = []
        /// Есть в прогоне, нет в базе / есть в базе, нет в прогоне.
        var added: [String] = []
        var missing: [String] = []
        var passed: Bool { worse.isEmpty }
    }

    static func compare(_ now: [Row], base: [Row]) -> Comparison {
        var result = Comparison()
        let baseByName = Dictionary(base.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let nowNames = Set(now.map(\.name))
        for row in now.sorted(by: { $0.name < $1.name }) {
            guard let old = baseByName[row.name] else { result.added.append(row.name); continue }
            let worse = worse(row, than: old), better = better(row, than: old)
            if !worse.isEmpty { result.worse.append((row.name, worse)) } else if !better.isEmpty { result.better.append((row.name, better)) }
        }
        result.missing = base.map(\.name).filter { !nowNames.contains($0) }.sorted()
        return result
    }

    /// Сводка «было/стало» для менеджера.
    static func markdown(now: [Row], base: [Row], seconds: Double? = nil) -> String {
        let comparison = compare(now, base: base)
        let names = Set(now.map(\.name))
        let old = base.filter { names.contains($0.name) }
        var lines = ["# Гейт «Документа»: было / стало", ""]
        lines.append(comparison.passed ? "**Гейт пройден:** ни одна форма не стала хуже базы." : "**Гейт не пройден:** хуже базы — \(comparison.worse.count) форм.")
        lines.append("Форм в прогоне: \(now.count)\(seconds.map { String(format: ", время %.0f с", $0) } ?? "").")
        lines.append("")
        lines.append("| Метрика | Было | Стало |")
        lines.append("|---|---|---|")
        func row(_ title: String, _ value: ([Row]) -> String) { lines.append("| \(title) | \(value(old)) | \(value(now)) |") }
        let ok = { (rows: [Row]) in rows.filter { !$0.failed } }
        row("Идентично Word") { "\(ok($0).filter(\.identical).count) из \($0.count)" }
        row("Число страниц совпадает") { "\(ok($0).filter { $0.pageDifference == 0 }.count)" }
        row("Разрывы строк 100 %") { "\(ok($0).filter { $0.breaks >= 1 }.count)" }
        row("Разрывы строк, медиана по файлам") { percent(median(ok($0).map(\.breaks))) }
        row("Сдвиг, медиана медиан, pt") { pt(median(ok($0).map(\.shiftMedian))) }
        row("Сдвиг p95, медиана по файлам, pt") { pt(median(ok($0).map(\.shiftP95))) }
        row("Сдвиг ≤ 1 pt (max) — файлов") { "\(ok($0).filter { $0.shiftMax <= 1 }.count)" }
        row("Лишние переносы в ячейках") { "\(ok($0).map(\.cellWraps).reduce(0, +))" }
        row("Строк на другой странице") { "\(ok($0).map(\.otherPage).reduce(0, +))" }
        row("Слов нет / лишние") { "\(ok($0).map(\.missingWords).reduce(0, +)) / \(ok($0).map(\.extraWords).reduce(0, +))" }
        row("Ложные пары (исключены), max отклонение") { "\(ok($0).map(\.suspectPairs).reduce(0, +)), \(pt(ok($0).map(\.suspectMax).max() ?? 0)) pt" }
        row("Не открылись") { "\($0.filter(\.failed).count)" }
        lines.append("")
        lines.append("## Хуже базы (\(comparison.worse.count))")
        lines.append("Допуски: доля разрывов −0,05 п. п., p95 сдвига +0,5 pt; страницы, переносы в ячейках и слова — без допуска.")
        lines.append("")
        lines += comparison.worse.isEmpty ? ["—"] : comparison.worse.map { "- \($0.name): \($0.what.joined(separator: "; "))" }
        lines.append("")
        lines.append("## Лучше базы (\(comparison.better.count))")
        lines.append("")
        lines.append(comparison.better.isEmpty ? "—" : comparison.better.map { "\($0.name) (\($0.what.joined(separator: ", ")))" }.joined(separator: "; "))
        if !comparison.better.isEmpty {
            lines.append("")
            lines.append("Если ухудшений нет, обновите базу: `scripts/word-gate.sh --update`.")
        }
        if !comparison.added.isEmpty { lines += ["", "Нет в базе (новые): \(comparison.added.joined(separator: ", "))."] }
        if !comparison.missing.isEmpty {
            let names = comparison.missing.count <= 10 ? " (\(comparison.missing.joined(separator: ", ")))" : ""
            lines += ["", "Есть в базе, нет в прогоне: \(comparison.missing.count)\(names) — для них сравнения не было."]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func percent(_ value: Double) -> String { String(format: "%.1f %%", value * 100).replacingOccurrences(of: ".", with: ",") }
    private static func pt(_ value: Double) -> String { String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",") }
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

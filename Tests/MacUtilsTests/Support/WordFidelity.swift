import AppKit
import PDFKit

/// Инструмент сравнения «Документа» с эталоном Word по PDF (`WordFidelityTests`). Извлечение одинаково для обеих
/// сторон: строки текста — PDFKit (`selectionsByLine`), базовые линии текста, линии таблиц и рамок — разбор
/// содержимого страницы (`CGPDFScanner`). Координаты — пункты от левого верхнего угла страницы.
enum WordFidelity {
    struct Line: Equatable {
        var page: Int
        var text: String
        /// Рамка строки: от левого верхнего угла страницы.
        var rect: CGRect
        /// Базовая линия (y от верха страницы) по операторам текста PDF. Не зависит от метрик шрифта, поэтому
        /// замена шрифта не даёт ложного сдвига по Y, как верх рамки PDFKit.
        var baseline: CGFloat?

        var words: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
        var key: String { words.joined(separator: " ") }
    }

    /// Горизонтальный или вертикальный отрезок (граница ячейки, рамка, линия).
    struct Segment: Equatable {
        var page: Int
        var horizontal: Bool
        /// Для горизонтального: y и [x0, x1]; для вертикального: x и [y0, y1].
        var position: CGFloat
        var from: CGFloat
        var to: CGFloat
    }

    enum Category: String, CaseIterable {
        case body = "тело"
        case table = "таблицы"
        case margins = "колонтитулы"
    }

    // MARK: - Извлечение из PDF

    static func lines(_ document: PDFDocument) -> [Line] {
        var result: [Line] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .mediaBox)
            var origins: [CGPoint] = []
            if let ref = page.pageRef {
                let scanner = PathScanner(page: index, height: box.maxY, originX: box.minX)
                scanner.scan(ref)
                origins = scanner.textOrigins
            }
            for selection in page.selection(for: box)?.selectionsByLine() ?? [] {
                let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let r = selection.bounds(for: page)
                let rect = CGRect(x: r.minX - box.minX, y: box.maxY - r.maxY, width: r.width, height: r.height)
                result.append(Line(page: index, text: text, rect: rect, baseline: baseline(of: rect, among: origins)))
            }
        }
        return result
    }

    /// Базовая линия строки: самая частая y начал текстовых операторов внутри рамки (при равенстве — нижняя).
    static func baseline(of rect: CGRect, among origins: [CGPoint]) -> CGFloat? {
        var counts: [Int: Int] = [:]
        for origin in origins where origin.x >= rect.minX - 1 && origin.x <= rect.maxX + 1
            && origin.y >= rect.minY - 0.5 && origin.y <= rect.maxY + 0.5 {
            counts[Int((origin.y * 10).rounded()), default: 0] += 1
        }
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }.map { CGFloat($0.key) / 10 }
    }

    /// Положение строки по вертикали для сравнения: базовая линия, если она есть у обеих строк, иначе верх рамки.
    static func top(_ line: Line, _ other: Line) -> (CGFloat, CGFloat) {
        if let a = line.baseline, let b = other.baseline { return (a, b) }
        return (line.rect.minY, other.rect.minY)
    }

    static func pageSizes(_ document: PDFDocument) -> [CGSize] {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .mediaBox).size }
    }

    /// Отрезки из путей страницы: линии (`m`/`l` + обводка) и тонкие прямоугольники (`re` + заливка, толщина ≤ 3 pt).
    static func segments(_ document: PDFDocument) -> [Segment] {
        var result: [Segment] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.pageRef else { continue }
            let box = page.getBoxRect(.mediaBox)
            let scanner = PathScanner(page: index, height: box.maxY, originX: box.minX)
            scanner.scan(page)
            result += scanner.segments
        }
        return result
    }

    // MARK: - Сравнение

    struct Stats: Equatable {
        var count = 0
        var median: CGFloat = 0
        var p95: CGFloat = 0
        var max: CGFloat = 0
        /// Медиана со знаком (наш − Word): в какую сторону сдвиг.
        var signedMedian: CGFloat = 0

        init(_ values: [CGFloat] = []) {
            if !values.isEmpty { signedMedian = values.sorted()[values.count / 2] }
            let sorted = values.map(abs).sorted()
            count = sorted.count
            guard !sorted.isEmpty else { return }
            median = sorted[sorted.count / 2]
            p95 = sorted[Swift.min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
            max = sorted.last!
        }
    }

    /// Расхождение строки: что именно (для топа причин) и строка нашей раскладки, где оно.
    struct Discrepancy {
        enum Kind: String, CaseIterable {
            case shiftX = "сдвиг по X > 1 pt"
            case shiftY = "сдвиг по Y > 1 pt"
            case lineBreak = "другой разрыв строки"
            case cellWrap = "лишний перенос в ячейке"
            case otherPage = "строка на другой странице"
        }
        var kind: Kind
        var category: Category
        var ours: Line
    }

    struct Result {
        var pagesWord = 0
        var pagesOurs = 0
        var linesWord = 0
        /// Доля строк Word, у которых есть наша строка с тем же набором слов.
        var sameBreaks: Double = 0
        var dx: [Category: Stats] = [:]
        var dy: [Category: Stats] = [:]
        /// Наши строки в ячейках, разбитые там, где у Word одна строка.
        var extraCellWraps = 0
        /// Строки, которые у нас на другой странице.
        var otherPage = 0
        var missingWords = 0
        var extraWords = 0
        var segmentsWord = 0
        var segmentsMatched = 0
        var segmentOffset = Stats()
        /// Шаг строк: (наш y₂ − y₁) − (Word y₂ − y₁) со знаком для соседних совпавших строк одной страницы.
        var pitch: [Category: [CGFloat]] = [:]
        /// Первая совпавшая строка на той же странице: наш − Word со знаком (смещение до накопления сдвигов).
        var firstOffset: CGPoint?
        /// Размер страниц Word и наш различаются больше чем на 1 pt (выставляет вызывающий по `pageSizes`).
        var sizeMismatch = false
        var discrepancies: [Discrepancy] = []
        /// Сдвиг пары max(|dx|, |dy|) по всем категориям, без ложных пар.
        var shift = Stats()
        /// Ложные пары (повтор текста в другом месте) — исключены из сдвигов; наибольшее их отклонение от соседей.
        var suspectPairs = 0
        var suspectMax: CGFloat = 0

        var maxShift: CGFloat { (dx.values.map(\.max) + dy.values.map(\.max)).max() ?? 0 }
        var identical: Bool { pagesWord == pagesOurs && sameBreaks >= 1 && maxShift <= 1 && missingWords == 0 && extraWords == 0 }
    }

    /// Сопоставить строки Word и наши (`align`), затем метрики. `category` — к какой части нашей раскладки
    /// относится наша строка.
    static func compare(word: [Line], ours: [Line], pagesWord: Int, pagesOurs: Int,
                        category: (Line) -> Category, wordSegments: [Segment] = [], ourSegments: [Segment] = []) -> Result {
        var result = Result()
        result.pagesWord = pagesWord
        result.pagesOurs = pagesOurs
        result.linesWord = word.count
        let pairs = align(word, ours)
        result.sameBreaks = word.isEmpty ? 1 : Double(pairs.count) / Double(word.count)

        // Ложная пара (повтор того же текста в другом месте): сдвиг по Y отличается от соседних пар больше чем на 20 pt.
        let offsets = pairs.map { w, o -> CGFloat? in
            guard word[w].page == ours[o].page else { return nil }
            let (a, b) = top(word[w], ours[o])
            return b - a
        }
        var suspect = Set<Int>()
        for (index, offset) in offsets.enumerated() {
            guard let offset else { continue }
            let near = (max(0, index - 3)...min(offsets.count - 1, index + 3)).filter { $0 != index }.compactMap { offsets[$0] }.sorted()
            guard near.count >= 2 else { continue }
            let deviation = abs(offset - near[near.count / 2])
            if deviation > 20 {
                suspect.insert(index)
                result.suspectMax = max(result.suspectMax, deviation)
            }
        }
        result.suspectPairs = suspect.count

        var dx: [Category: [CGFloat]] = [:], dy: [Category: [CGFloat]] = [:], shifts: [CGFloat] = []
        for (index, (w, o)) in pairs.enumerated() where !suspect.contains(index) {
            let a = word[w], b = ours[o], kind = category(b)
            guard a.page == b.page else {
                result.otherPage += 1
                result.discrepancies.append(Discrepancy(kind: .otherPage, category: kind, ours: b))
                continue
            }
            let (ya, yb) = top(a, b)
            let x = b.rect.minX - a.rect.minX, y = yb - ya
            if result.firstOffset == nil { result.firstOffset = CGPoint(x: x, y: y) }
            dx[kind, default: []].append(x)
            dy[kind, default: []].append(y)
            shifts.append(max(abs(x), abs(y)))
            if abs(x) > 1 { result.discrepancies.append(Discrepancy(kind: .shiftX, category: kind, ours: b)) }
            if abs(y) > 1 { result.discrepancies.append(Discrepancy(kind: .shiftY, category: kind, ours: b)) }
        }
        result.shift = Stats(shifts)
        // Шаг строк: соседние строки Word одной колонки (следующая ниже и перекрывается по X) и их пары у нас.
        var partner: [Int: Int] = [:]
        for (index, (w, o)) in pairs.enumerated() where !suspect.contains(index) { partner[w] = o }
        for w1 in word.indices.dropLast() {
            let w2 = w1 + 1
            guard let o1 = partner[w1], let o2 = partner[w2] else { continue }
            let a1 = word[w1], a2 = word[w2], b1 = ours[o1], b2 = ours[o2]
            guard a1.page == a2.page, b1.page == b2.page, a1.page == b1.page, a2.rect.minY > a1.rect.maxY - 1,
                  min(a1.rect.maxX, a2.rect.maxX) > max(a1.rect.minX, a2.rect.minX) else { continue }
            let kind = category(b2)
            guard kind == category(b1) else { continue }
            let (ya1, yb1) = top(a1, b1), (ya2, yb2) = top(a2, b2)
            result.pitch[kind, default: []].append((yb2 - yb1) - (ya2 - ya1))
        }
        for kind in Category.allCases {
            result.dx[kind] = Stats(dx[kind] ?? [])
            result.dy[kind] = Stats(dy[kind] ?? [])
        }

        // Несовпавшие строки: наш перенос там, где у Word одна строка, — подряд идущие наши строки без пары,
        // вместе ровно слова строки Word.
        let pairedWord = Set(pairs.map(\.0)), pairedOurs = Set(pairs.map(\.1))
        var runs: [[Int]] = []
        for index in ours.indices where !pairedOurs.contains(index) {
            if let last = runs.last?.last, last == index - 1 { runs[runs.count - 1].append(index) } else { runs.append([index]) }
        }
        var used = Set<Int>()
        for (index, line) in word.enumerated() where !pairedWord.contains(index) {
            for run in runs {
                let lines = run.map { ours[$0] }
                guard let split = split(line.words, in: lines, skipping: Set(run.indices.filter { used.contains(run[$0]) })) else { continue }
                used.formUnion(split.map { run[$0] })
                let first = lines[split.lowerBound], kind = category(first)
                if kind == .table { result.extraCellWraps += 1 }
                result.discrepancies.append(Discrepancy(kind: kind == .table ? .cellWrap : .lineBreak, category: kind, ours: first))
                break
            }
        }
        for index in ours.indices where !pairedOurs.contains(index) && !used.contains(index) {
            result.discrepancies.append(Discrepancy(kind: .lineBreak, category: category(ours[index]), ours: ours[index]))
        }

        // Слова: что есть у Word и нет у нас, и наоборот (по количеству).
        var counts: [String: Int] = [:]
        for word in word.flatMap(\.words) { counts[word, default: 0] += 1 }
        for word in ours.flatMap(\.words) { counts[word, default: 0] -= 1 }
        result.missingWords = counts.values.filter { $0 > 0 }.reduce(0, +)
        result.extraWords = -counts.values.filter { $0 < 0 }.reduce(0, +)

        // Линии таблиц и рамок: у каждой линии Word — ближайшая наша той же ориентации и перекрытием.
        result.segmentsWord = wordSegments.count
        var segmentOffsets: [CGFloat] = []
        for segment in wordSegments {
            let candidates = ourSegments.filter {
                $0.page == segment.page && $0.horizontal == segment.horizontal && min($0.to, segment.to) - max($0.from, segment.from) > 2
            }
            guard let nearest = candidates.min(by: { abs($0.position - segment.position) < abs($1.position - segment.position) }),
                  abs(nearest.position - segment.position) <= 12 else { continue }
            result.segmentsMatched += 1
            segmentOffsets.append(nearest.position - segment.position)
        }
        result.segmentOffset = Stats(segmentOffsets)
        return result
    }

    /// Пары (Word, наш) с одинаковым текстом строки, по возрастанию индекса Word. Порядок строк в PDF у Word и у нас
    /// может различаться (ячейки соседних столбцов), поэтому без общего порядка:
    /// 1) якоря — тексты, которые встречаются ровно один раз и у Word, и у нас;
    /// 2) повторы одного текста — по месту: у каждой строки Word ожидаемое место у нас = её место + смещение
    ///    ближайшего якоря; повторы сопоставляются по порядку с наименьшим расхождением с ожидаемым (DP).
    static func align(_ word: [Line], _ ours: [Line]) -> [(Int, Int)] {
        var wordByKey: [String: [Int]] = [:], oursByKey: [String: [Int]] = [:]
        for (index, line) in word.enumerated() { wordByKey[line.key, default: []].append(index) }
        for (index, line) in ours.enumerated() { oursByKey[line.key, default: []].append(index) }
        let height = max(word.map(\.rect.maxY).max() ?? 0, ours.map(\.rect.maxY).max() ?? 0) + 100
        func place(_ line: Line) -> CGPoint { CGPoint(x: line.rect.minX, y: CGFloat(line.page) * height + line.rect.minY) }

        var pairs: [(Int, Int)] = []
        var anchors: [(w: Int, offset: CGPoint)] = []
        for (key, ws) in wordByKey where ws.count == 1 && oursByKey[key]?.count == 1 {
            let o = oursByKey[key]![0]
            pairs.append((ws[0], o))
            let a = place(word[ws[0]]), b = place(ours[o])
            anchors.append((ws[0], CGPoint(x: b.x - a.x, y: b.y - a.y)))
        }
        anchors.sort { $0.w < $1.w }
        func expected(_ w: Int) -> CGPoint {
            let p = place(word[w])
            guard !anchors.isEmpty else { return p }
            var low = 0, high = anchors.count
            while low < high { let mid = (low + high) / 2; if anchors[mid].w < w { low = mid + 1 } else { high = mid } }
            let candidates = [low - 1, low].filter { anchors.indices.contains($0) }
            let nearest = candidates.min { abs(anchors[$0].w - w) < abs(anchors[$1].w - w) }!
            return CGPoint(x: p.x + anchors[nearest].offset.x, y: p.y + anchors[nearest].offset.y)
        }

        let skip: CGFloat = 200
        for (key, ws) in wordByKey {
            guard let os = oursByKey[key], !(ws.count == 1 && os.count == 1) else { continue }
            let predicted = ws.map(expected), actual = os.map { place(ours[$0]) }
            func cost(_ i: Int, _ j: Int) -> CGFloat { abs(predicted[i].y - actual[j].y) + abs(predicted[i].x - actual[j].x) / 4 }
            // best[i][j] — наименьшая цена для первых i строк Word и первых j наших.
            var best = [[CGFloat]](repeating: [CGFloat](repeating: 0, count: os.count + 1), count: ws.count + 1)
            for i in 0...ws.count { best[i][0] = CGFloat(i) * skip }
            for j in 0...os.count { best[0][j] = CGFloat(j) * skip }
            for i in 1...ws.count {
                for j in 1...os.count {
                    let match = cost(i - 1, j - 1) < 2 * skip ? best[i - 1][j - 1] + cost(i - 1, j - 1) : .infinity
                    best[i][j] = min(match, best[i - 1][j] + skip, best[i][j - 1] + skip)
                }
            }
            var i = ws.count, j = os.count
            while i > 0, j > 0 {
                if cost(i - 1, j - 1) < 2 * skip, best[i][j] == best[i - 1][j - 1] + cost(i - 1, j - 1) {
                    pairs.append((ws[i - 1], os[j - 1])); i -= 1; j -= 1
                } else if best[i][j] == best[i - 1][j] + skip { i -= 1 } else { j -= 1 }
            }
        }
        return pairs.sorted { $0.0 < $1.0 }
    }

    /// Две и больше наших подряд строки, которые вместе — ровно слова строки Word.
    private static func split(_ words: [String], in lines: [Line], skipping used: Set<Int>) -> Range<Int>? {
        guard words.count > 1 else { return nil }
        for start in lines.indices where !used.contains(start) {
            var collected: [String] = []
            var end = start
            while end < lines.count, !used.contains(end), collected.count < words.count {
                collected += lines[end].words
                end += 1
            }
            if end - start >= 2, collected == words { return start..<end }
        }
        return nil
    }
}

/// Разбор содержимого страницы PDF: состояние графики (`q`, `Q`, `cm`), линии и прямоугольники → отрезки по осям;
/// матрица текста (`BT`, `Tm`, `Td`, `TD`, `T*`, `TL`) → начала текстовых операторов (`Tj`, `TJ`, `'`, `"`).
private final class PathScanner {
    let page: Int
    let height: CGFloat
    let originX: CGFloat
    private(set) var segments: [WordFidelity.Segment] = []
    /// Начала показа текста — на базовой линии, от левого верхнего угла.
    private(set) var textOrigins: [CGPoint] = []
    private var textMatrix = CGAffineTransform.identity
    private var lineMatrix = CGAffineTransform.identity
    private var leading: CGFloat = 0
    private var ctm = CGAffineTransform.identity
    private var stack: [CGAffineTransform] = []
    private var current: [(CGPoint, CGPoint)] = []
    private var rects: [CGRect] = []
    private var point = CGPoint.zero
    private var operands: [CGFloat] = []

    init(page: Int, height: CGFloat, originX: CGFloat) {
        self.page = page
        self.height = height
        self.originX = originX
    }

    func scan(_ pdfPage: CGPDFPage) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        func register(_ name: String, _ callback: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, name, callback) }
        register("q") { _, info in let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue(); s.stack.append(s.ctm) }
        register("Q") { _, info in let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue(); s.ctm = s.stack.popLast() ?? .identity }
        register("cm") { scannerRef, info in
            let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
            let v = PathScanner.numbers(scannerRef, 6)
            guard v.count == 6 else { return }
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        register("m") { scannerRef, info in
            let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
            let v = PathScanner.numbers(scannerRef, 2)
            if v.count == 2 { s.point = CGPoint(x: v[0], y: v[1]) }
        }
        register("l") { scannerRef, info in
            let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
            let v = PathScanner.numbers(scannerRef, 2)
            guard v.count == 2 else { return }
            let next = CGPoint(x: v[0], y: v[1])
            s.current.append((s.point.applying(s.ctm), next.applying(s.ctm)))
            s.point = next
        }
        register("re") { scannerRef, info in
            let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
            let v = PathScanner.numbers(scannerRef, 4)
            if v.count == 4 { s.rects.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).applying(s.ctm).standardized) }
        }
        for name in ["S", "s"] { register(name) { _, info in Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue().finish(stroke: true) } }
        for name in ["f", "F", "f*", "B", "B*", "b", "b*"] {
            register(name) { _, info in Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue().finish(stroke: false) }
        }
        register("n") { _, info in let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue(); s.current = []; s.rects = [] }
        register("BT") { _, info in
            let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
            s.textMatrix = .identity
            s.lineMatrix = .identity
        }
        register("Tm") { scannerRef, info in
            let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
            let v = PathScanner.numbers(scannerRef, 6)
            guard v.count == 6 else { return }
            s.lineMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            s.textMatrix = s.lineMatrix
        }
        register("Td") { scannerRef, info in
            let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
            let v = PathScanner.numbers(scannerRef, 2)
            if v.count == 2 { s.moveLine(v[0], v[1]) }
        }
        register("TD") { scannerRef, info in
            let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
            let v = PathScanner.numbers(scannerRef, 2)
            guard v.count == 2 else { return }
            s.leading = -v[1]
            s.moveLine(v[0], v[1])
        }
        register("TL") { scannerRef, info in
            let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
            if let v = PathScanner.numbers(scannerRef, 1).first { s.leading = v }
        }
        register("T*") { _, info in let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue(); s.moveLine(0, -s.leading) }
        for name in ["Tj", "TJ"] { register(name) { _, info in Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue().showText() } }
        for name in ["'", "\""] {
            register(name) { _, info in
                let s = Unmanaged<PathScanner>.fromOpaque(info!).takeUnretainedValue()
                s.moveLine(0, -s.leading)
                s.showText()
            }
        }
        let stream = CGPDFContentStreamCreateWithPage(pdfPage)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
    }

    private func moveLine(_ x: CGFloat, _ y: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: x, y: y).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    /// Начало текста; сдвиг после показа (ширины глифов) не считаем: базовая линия от него не меняется.
    private func showText() {
        let origin = CGPoint.zero.applying(textMatrix.concatenating(ctm))
        textOrigins.append(CGPoint(x: origin.x - originX, y: height - origin.y))
    }

    /// Последние `count` чисел со стека операндов (в порядке записи).
    static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat] {
        var values: [CGFloat] = []
        for _ in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return [] }
            values.append(CGFloat(value))
        }
        return values.reversed()
    }

    private func finish(stroke: Bool) {
        for (a, b) in current {
            if abs(a.y - b.y) < 0.5, abs(a.x - b.x) > 2 { add(horizontal: true, position: a.y, a.x, b.x) }
            else if abs(a.x - b.x) < 0.5, abs(a.y - b.y) > 2 { add(horizontal: false, position: a.x, a.y, b.y) }
        }
        for rect in rects {
            if stroke {
                add(horizontal: true, position: rect.minY, rect.minX, rect.maxX)
                add(horizontal: true, position: rect.maxY, rect.minX, rect.maxX)
                add(horizontal: false, position: rect.minX, rect.minY, rect.maxY)
                add(horizontal: false, position: rect.maxX, rect.minY, rect.maxY)
            } else if rect.height <= 3, rect.width > 2 {
                add(horizontal: true, position: rect.midY, rect.minX, rect.maxX)
            } else if rect.width <= 3, rect.height > 2 {
                add(horizontal: false, position: rect.midX, rect.minY, rect.maxY)
            }
        }
        current = []
        rects = []
    }

    /// В координаты «от левого верхнего угла».
    private func add(horizontal: Bool, position: CGFloat, _ from: CGFloat, _ to: CGFloat) {
        if horizontal {
            segments.append(.init(page: page, horizontal: true, position: height - position, from: min(from, to) - originX, to: max(from, to) - originX))
        } else {
            segments.append(.init(page: page, horizontal: false, position: position - originX, from: height - max(from, to), to: height - min(from, to)))
        }
    }
}

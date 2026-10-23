import AppKit
import PDFKit
@testable import MUDesign
@testable import MUAudio

/// Инструмент сравнения «Документа» с эталоном Word по PDF (`WordFidelityTests`). Извлечение одинаково для обеих
/// сторон: строки текста — PDFKit (`selectionsByLine`), линии таблиц и рамок — разбор путей PDF (`CGPDFScanner`).
/// Координаты — пункты от левого верхнего угла страницы.
enum WordFidelity {
    struct Line: Equatable {
        var page: Int
        var text: String
        /// Рамка строки: от левого верхнего угла страницы.
        var rect: CGRect

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
            for selection in page.selection(for: box)?.selectionsByLine() ?? [] {
                let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let r = selection.bounds(for: page)
                result.append(Line(page: index, text: text,
                                   rect: CGRect(x: r.minX - box.minX, y: box.maxY - r.maxY, width: r.width, height: r.height)))
            }
        }
        return result
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
        /// Доля строк Word, у которых есть наша строка с тем же набором слов (в том же порядке строк).
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

        var maxShift: CGFloat { (dx.values.map(\.max) + dy.values.map(\.max)).max() ?? 0 }
        var identical: Bool { pagesWord == pagesOurs && sameBreaks >= 1 && maxShift <= 1 && missingWords == 0 && extraWords == 0 }
    }

    /// Сопоставить строки Word и наши: выравнивание по тексту (LCS по строкам), затем метрики.
    /// `category` — к какой части нашей раскладки относится наша строка.
    static func compare(word: [Line], ours: [Line], pagesWord: Int, pagesOurs: Int,
                        category: (Line) -> Category, wordSegments: [Segment] = [], ourSegments: [Segment] = []) -> Result {
        var result = Result()
        result.pagesWord = pagesWord
        result.pagesOurs = pagesOurs
        result.linesWord = word.count
        let pairs = align(word.map(\.key), ours.map(\.key))
        result.sameBreaks = word.isEmpty ? 1 : Double(pairs.count) / Double(word.count)

        var dx: [Category: [CGFloat]] = [:], dy: [Category: [CGFloat]] = [:]
        for (w, o) in pairs {
            let a = word[w], b = ours[o], kind = category(b)
            guard a.page == b.page else {
                result.otherPage += 1
                result.discrepancies.append(Discrepancy(kind: .otherPage, category: kind, ours: b))
                continue
            }
            let x = b.rect.minX - a.rect.minX, y = b.rect.minY - a.rect.minY
            if result.firstOffset == nil { result.firstOffset = CGPoint(x: x, y: y) }
            dx[kind, default: []].append(x)
            dy[kind, default: []].append(y)
            if abs(x) > 1 { result.discrepancies.append(Discrepancy(kind: .shiftX, category: kind, ours: b)) }
            if abs(y) > 1 { result.discrepancies.append(Discrepancy(kind: .shiftY, category: kind, ours: b)) }
        }
        for ((w1, o1), (w2, o2)) in zip(pairs, pairs.dropFirst()) where w2 == w1 + 1 && o2 == o1 + 1 {
            let a1 = word[w1], a2 = word[w2], b1 = ours[o1], b2 = ours[o2]
            guard a1.page == a2.page, b1.page == b2.page, a1.page == b1.page, a2.rect.minY > a1.rect.maxY - 1 else { continue }
            let kind = category(b2)
            guard kind == category(b1) else { continue }
            result.pitch[kind, default: []].append((b2.rect.minY - b1.rect.minY) - (a2.rect.minY - a1.rect.minY))
        }
        for kind in Category.allCases {
            result.dx[kind] = Stats(dx[kind] ?? [])
            result.dy[kind] = Stats(dy[kind] ?? [])
        }

        // Несовпавшие строки между соседними совпадениями: наш перенос там, где у Word одна строка.
        var previous = (w: -1, o: -1)
        for anchor in pairs + [(word.count, ours.count)] {
            let wordGap = Array(word[(previous.w + 1)..<anchor.0]), ourGap = Array(ours[(previous.o + 1)..<anchor.1])
            var used = Set<Int>()
            for line in wordGap {
                if let split = split(line.words, in: ourGap, skipping: used) {
                    used.formUnion(split)
                    let first = ourGap[split.lowerBound], kind = category(first)
                    if kind == .table { result.extraCellWraps += 1 }
                    result.discrepancies.append(Discrepancy(kind: kind == .table ? .cellWrap : .lineBreak, category: kind, ours: first))
                }
            }
            for (index, line) in ourGap.enumerated() where !used.contains(index) {
                result.discrepancies.append(Discrepancy(kind: .lineBreak, category: category(line), ours: line))
            }
            previous = (anchor.0, anchor.1)
        }

        // Слова: что есть у Word и нет у нас, и наоборот (по количеству).
        var counts: [String: Int] = [:]
        for word in word.flatMap(\.words) { counts[word, default: 0] += 1 }
        for word in ours.flatMap(\.words) { counts[word, default: 0] -= 1 }
        result.missingWords = counts.values.filter { $0 > 0 }.reduce(0, +)
        result.extraWords = -counts.values.filter { $0 < 0 }.reduce(0, +)

        // Линии таблиц и рамок: у каждой линии Word — ближайшая наша той же ориентации и перекрытием.
        result.segmentsWord = wordSegments.count
        var offsets: [CGFloat] = []
        for segment in wordSegments {
            let candidates = ourSegments.filter {
                $0.page == segment.page && $0.horizontal == segment.horizontal && min($0.to, segment.to) - max($0.from, segment.from) > 2
            }
            guard let nearest = candidates.min(by: { abs($0.position - segment.position) < abs($1.position - segment.position) }),
                  abs(nearest.position - segment.position) <= 12 else { continue }
            result.segmentsMatched += 1
            offsets.append(nearest.position - segment.position)
        }
        result.segmentOffset = Stats(offsets)
        return result
    }

    /// Пары индексов (Word, наш) с одинаковым текстом строки — наибольшая общая подпоследовательность.
    static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 } else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
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

/// Разбор путей страницы PDF: состояние графики (`q`, `Q`, `cm`), линии и прямоугольники → отрезки по осям.
private final class PathScanner {
    let page: Int
    let height: CGFloat
    let originX: CGFloat
    private(set) var segments: [WordFidelity.Segment] = []
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
        let stream = CGPDFContentStreamCreateWithPage(pdfPage)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
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

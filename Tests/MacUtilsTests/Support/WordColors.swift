import AppKit
import PDFKit

/// Цвета страницы PDF для сравнения «Документа» с Word (`WordColorTests`): сколько знаков текста показано каждым цветом
/// и какая площадь залита каждым цветом (заливки ячеек и абзацев, маркер). Извлечение одинаково для обеих сторон:
/// знаки и их цвет — PDFKit (байты строк у Word и у нас кодируются по-разному), заливки — разбор операторов PDF
/// (`CGPDFScanner`). Только числа и цвета, без текста.
enum WordColors {
    /// Цвет, округлённый до 8 бит на канал: «rrggbb».
    struct RGB: Hashable, Comparable, CustomStringConvertible {
        var r: Int, g: Int, b: Int

        init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
            self.r = byte(r); self.g = byte(g); self.b = byte(b)
        }

        var description: String { String(format: "%02x%02x%02x", r, g, b) }
        var isBlack: Bool { max(r, g, b) <= 0x20 }
        var isWhite: Bool { min(r, g, b) >= 0xF8 }
        func near(_ other: RGB, tolerance: Int = 8) -> Bool {
            abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
        }
        static func < (a: RGB, b: RGB) -> Bool { (a.r, a.g, a.b) < (b.r, b.g, b.b) }
    }

    struct Page {
        /// Цвет текста → число знаков (без пробелов) этим цветом.
        var text: [RGB: Int] = [:]
        /// Цвет заливки → видимая площадь (pt²): заливки рисуются по порядку на растре 1 pt, поздняя закрывает раннюю
        /// (Word кладёт полосы заливки абзаца поверх заливки ячейки того же цвета). Без белого и без тонких полос ≤ 3 pt
        /// (это линии и границы).
        var fills: [RGB: CGFloat] = [:]
    }

    static func pages(_ document: PDFDocument) -> [Page] {
        (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index), let ref = page.pageRef else { return nil }
            let scanner = ColorScanner()
            scanner.scan(ref)
            var result = Page()
            result.fills = coverage(scanner.paints, in: ref.getBoxRect(.mediaBox))
            if let text = page.attributedString {
                text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                    let count = (text.string as NSString).substring(with: range).filter { !$0.isWhitespace }.count
                    guard count > 0 else { return }
                    let color = (value as? NSColor)?.usingColorSpace(.sRGB)
                    let key = color.map { RGB($0.redComponent, $0.greenComponent, $0.blueComponent) } ?? RGB(0, 0, 0)
                    result.text[key, default: 0] += count
                }
            }
            return result
        }
    }

    /// Видимая площадь каждого цвета: растр по 1 pt, заливки по порядку рисования.
    static func coverage(_ paints: [(RGB, CGRect)], in box: CGRect) -> [RGB: CGFloat] {
        let width = Int(box.width.rounded(.up)), height = Int(box.height.rounded(.up))
        guard width > 0, height > 0, !paints.isEmpty else { return [:] }
        var colors: [RGB] = [RGB(1, 1, 1)]
        var ids: [RGB: Int32] = [colors[0]: 0]
        var raster = [Int32](repeating: 0, count: width * height)
        for (color, rect) in paints {
            let id: Int32
            if let known = ids[color] { id = known } else {
                id = Int32(colors.count)
                ids[color] = id
                colors.append(color)
            }
            let r = rect.offsetBy(dx: -box.minX, dy: -box.minY)
            let x0 = max(0, Int(r.minX.rounded())), x1 = min(width, Int(r.maxX.rounded()))
            let y0 = max(0, Int(r.minY.rounded())), y1 = min(height, Int(r.maxY.rounded()))
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 { for x in x0..<x1 { raster[y * width + x] = id } }
        }
        var counts = [Int](repeating: 0, count: colors.count)
        for id in raster { counts[Int(id)] += 1 }
        var result: [RGB: CGFloat] = [:]
        for (index, count) in counts.enumerated() where count > 0 && !colors[index].isWhite { result[colors[index]] = CGFloat(count) }
        return result
    }

    /// Расхождение цветов одного документа: цвет, у Word и у нас.
    struct Mismatch: CustomStringConvertible {
        enum Kind: String { case text = "текст", fill = "заливка" }
        var kind: Kind
        var color: RGB
        var word: Double
        var ours: Double
        var description: String {
            "\(kind.rawValue) #\(color): Word \(Int(word.rounded())) · наш \(Int(ours.rounded()))"
        }
    }

    /// Сравнение по документу целиком (страницы могут разбиваться по-разному): цвет текста — по числу знаков
    /// (допуск 5 % и 2 знака), заливка — по площади (допуск 10 % и 50 pt²). Чёрный текст не сравнивается (его везде больше
    /// всего, а разбивка по знакам у шрифтов разная), белая заливка — тоже (это бумага).
    static func compare(word: [Page], ours: [Page]) -> [Mismatch] {
        func total<V: Numeric>(_ pages: [Page], _ part: (Page) -> [RGB: V]) -> [RGB: V] {
            var result: [RGB: V] = [:]
            for page in pages { for (color, value) in part(page) { result[color, default: 0] += value } }
            return result
        }
        func merged<V: BinaryFloatingPoint>(_ values: [RGB: V]) -> [RGB: Double] {
            var result: [RGB: Double] = [:]
            for (color, value) in values.sorted(by: { $0.key < $1.key }) {
                let key = result.keys.first { $0.near(color) } ?? color
                result[key, default: 0] += Double(value)
            }
            return result
        }
        var mismatches: [Mismatch] = []
        func check(_ kind: Mismatch.Kind, _ word: [RGB: Double], _ ours: [RGB: Double], relative: Double, absolute: Double) {
            var seen = Set<RGB>()
            for (color, amount) in word.sorted(by: { $0.key < $1.key }) {
                let match = ours.keys.first { $0.near(color) }
                if let match { seen.insert(match) }
                let mine = match.map { ours[$0] ?? 0 } ?? 0
                if abs(mine - amount) > max(absolute, amount * relative) {
                    mismatches.append(Mismatch(kind: kind, color: color, word: amount, ours: mine))
                }
            }
            for (color, amount) in ours.sorted(by: { $0.key < $1.key }) where !seen.contains(color) && amount > absolute {
                mismatches.append(Mismatch(kind: kind, color: color, word: 0, ours: amount))
            }
        }
        let wordText = merged(total(word, \.text).filter { !$0.key.isBlack }.mapValues(Double.init))
        let ourText = merged(total(ours, \.text).filter { !$0.key.isBlack }.mapValues(Double.init))
        check(.text, wordText, ourText, relative: 0.05, absolute: 2)
        check(.fill, merged(total(word, \.fills)), merged(total(ours, \.fills)), relative: 0.10, absolute: 50)
        return mismatches
    }
}

/// Разбор операторов страницы: цвет заливки (`rg`/`g`/`k`/`sc`/`scn`, сохраняется `q`/`Q`) и пути с заливкой.
private final class ColorScanner {
    /// Заливки по порядку рисования (белые тоже — они закрывают то, что под ними).
    private(set) var paints: [(WordColors.RGB, CGRect)] = []
    private var fill = WordColors.RGB(0, 0, 0)
    private var components = 1
    private var ctm = CGAffineTransform.identity
    private var stack: [(CGAffineTransform, WordColors.RGB, Int)] = []
    /// Текущий путь: прямоугольники `re` и рамки подпутей `m`/`l` по отдельности.
    private var rects: [CGRect] = []
    private var path = CGRect.null

    private static func this(_ info: UnsafeMutableRawPointer?) -> ColorScanner { Unmanaged<ColorScanner>.fromOpaque(info!).takeUnretainedValue() }

    func scan(_ page: CGPDFPage) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        func register(_ name: String, _ callback: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, name, callback) }
        register("q") { _, info in let s = ColorScanner.this(info); s.stack.append((s.ctm, s.fill, s.components)) }
        register("Q") { _, info in
            let s = ColorScanner.this(info)
            if let saved = s.stack.popLast() { (s.ctm, s.fill, s.components) = saved }
        }
        register("cm") { scanner, info in
            let s = ColorScanner.this(info)
            let v = ColorScanner.numbers(scanner, 6)
            guard v.count == 6 else { return }
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        register("g") { scanner, info in ColorScanner.this(info).setFill(ColorScanner.numbers(scanner, 1)) }
        register("rg") { scanner, info in ColorScanner.this(info).setFill(ColorScanner.numbers(scanner, 3)) }
        register("k") { scanner, info in ColorScanner.this(info).setFill(ColorScanner.numbers(scanner, 4)) }
        register("cs") { scanner, info in
            let s = ColorScanner.this(info)
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            switch String(cString: name) {
            case "DeviceGray", "CalGray", "G": s.components = 1
            case "DeviceCMYK", "CMYK": s.components = 4
            default: s.components = 3
            }
        }
        for name in ["sc", "scn"] {
            register(name) { scanner, info in
                let s = ColorScanner.this(info)
                s.setFill(ColorScanner.numbers(scanner, s.components))
            }
        }
        register("re") { scanner, info in
            let s = ColorScanner.this(info)
            let v = ColorScanner.numbers(scanner, 4)
            guard v.count == 4 else { return }
            s.rects.append(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).applying(s.ctm).standardized)
        }
        register("m") { scanner, info in
            let s = ColorScanner.this(info)
            let v = ColorScanner.numbers(scanner, 2)
            guard v.count == 2 else { return }
            if !s.path.isNull { s.rects.append(s.path) }
            s.path = CGRect(origin: CGPoint(x: v[0], y: v[1]).applying(s.ctm), size: .zero)
        }
        register("l") { scanner, info in
            let s = ColorScanner.this(info)
            let v = ColorScanner.numbers(scanner, 2)
            guard v.count == 2 else { return }
            let point = CGRect(origin: CGPoint(x: v[0], y: v[1]).applying(s.ctm), size: .zero)
            s.path = s.path.isNull ? point : s.path.union(point)
        }
        for name in ["f", "F", "f*", "B", "B*", "b", "b*"] { register(name) { _, info in ColorScanner.this(info).fillPath() } }
        for name in ["S", "s", "n"] {
            register(name) { _, info in
                let s = ColorScanner.this(info)
                s.path = .null
                s.rects = []
            }
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        CGPDFOperatorTableRelease(table)
    }

    private func setFill(_ v: [CGFloat]) {
        switch v.count {
        case 1: fill = WordColors.RGB(v[0], v[0], v[0])
        case 3: fill = WordColors.RGB(v[0], v[1], v[2])
        case 4: fill = WordColors.RGB((1 - v[0]) * (1 - v[3]), (1 - v[1]) * (1 - v[3]), (1 - v[2]) * (1 - v[3]))
        default: break
        }
    }

    private func fillPath() {
        defer { path = .null; rects = [] }
        for rect in rects + (path.isNull ? [] : [path]) where rect.width > 3 && rect.height > 3 { paints.append((fill, rect)) }
    }

    /// Последние `count` чисел со стека операндов (в порядке записи).
    static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat] {
        var values: [CGFloat] = []
        for _ in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { break }
            values.append(CGFloat(value))
        }
        return values.reversed()
    }
}

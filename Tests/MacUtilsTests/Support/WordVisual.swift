import Accelerate
import CoreGraphics
import PDFKit

/// Визуальное сравнение «Документа» с Word: страницы обоих PDF растрируются в одном масштабе (2×, в памяти,
/// на диск не пишутся — это реальные формы), совмещаются по левому верхнему углу листа и сравниваются попиксельно
/// с допуском ±1 px (пиксель совпадает, если в окрестности 3×3 другой картинки есть такой же по яркости).
/// Цвет — отдельно по областям: текст (рамки строк), линии (отрезки таблиц и рамок), остальное — заливки.
enum WordVisual {
    static let scale: CGFloat = 2
    /// Допуск яркости (0…255) для «тот же пиксель» и порог «закрашено» (светлая заливка — тоже).
    static let tolerance = 48
    static let ink: UInt8 = 245
    /// Цвет отличается у пикселя, закрашенного на обеих картинках: цветность (r − g, b − g) дальше этого;
    /// у линий и заливок — ещё и яркость дальше `tolerance`. Текст — только цветность: края букв сглажены
    /// по-разному, и яркость там говорит о сдвиге, а не о цвете.
    static let chroma = 60

    enum Area: Int, CaseIterable {
        case text, lines, fills
        var title: String { ["текст", "линии", "заливки"][rawValue] }
    }

    struct Page {
        /// Доля отличающихся пикселей листа.
        var difference: Double = 0
    }

    struct Result {
        var pages: [Page] = []
        /// По областям: пиксели с краской на обеих картинках и из них — другого цвета.
        var inked: [Area: Int] = [:]
        var colorMismatch: [Area: Int] = [:]

        var maxDifference: Double { pages.map(\.difference).max() ?? 0 }
        var meanDifference: Double { pages.isEmpty ? 0 : pages.map(\.difference).reduce(0, +) / Double(pages.count) }
        func color(_ area: Area) -> Double {
            let all = inked[area] ?? 0
            return all == 0 ? 0 : Double(colorMismatch[area] ?? 0) / Double(all)
        }
        /// «1 в 1»: на каждой странице отличается ≤ 0,5 % пикселей (лишняя или недостающая страница — против пустой).
        var identical: Bool { !pages.isEmpty && maxDifference <= 0.005 }
    }

    /// RGBA-растр страницы на белом; `nil` — страницы нет (сравнивается с пустым листом).
    struct Raster {
        let width: Int, height: Int
        var rgba: [UInt8]
        var gray: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            rgba = [UInt8](repeating: 255, count: width * height * 4)
            gray = [UInt8](repeating: 255, count: width * height)
        }

        init?(page: PDFPage?, width: Int, height: Int) {
            self.init(width: width, height: height)
            guard let ref = page?.pageRef else { return }
            let box = ref.getBoxRect(.mediaBox)
            let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                // Верх листа — к верху растра: совмещение по левому верхнему углу.
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: WordVisual.scale, y: WordVisual.scale)
                context.translateBy(x: -box.minX, y: -box.maxY)
                context.drawPDFPage(ref)
                return true
            }
            guard drawn else { return nil }
            // Яркость (0,30 R + 0,59 G + 0,11 B) — vImage, без цикла по пикселям.
            rgba.withUnsafeMutableBytes { source in
                gray.withUnsafeMutableBytes { target in
                    var input = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    var output = vImage_Buffer(data: target.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                    let matrix: [Int16] = [77, 150, 29, 0]
                    _ = vImageMatrixMultiply_ARGB8888ToPlanar8(&input, &output, matrix, 256, nil, 0, vImage_Flags(kvImageNoFlags))
                }
            }
        }
    }

    /// Окрестность 3×3: самый тёмный и самый светлый пиксель (vImage min/max).
    static func neighborhood(_ gray: [UInt8], width: Int, height: Int) -> (min: [UInt8], max: [UInt8]) {
        var low = [UInt8](repeating: 0, count: gray.count), high = low
        var source = gray
        source.withUnsafeMutableBytes { src in
            low.withUnsafeMutableBytes { lo in
                high.withUnsafeMutableBytes { hi in
                    var input = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                    var minimum = vImage_Buffer(data: lo.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                    var maximum = vImage_Buffer(data: hi.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                    vImageMin_Planar8(&input, &minimum, nil, 0, 0, 3, 3, vImage_Flags(kvImageEdgeExtend))
                    vImageMax_Planar8(&input, &maximum, nil, 0, 0, 3, 3, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        return (low, high)
    }

    /// Карта областей страницы: линии — полоса ±2 px вдоль отрезков, текст — рамки строк (поверх), остальное — заливки.
    static func areas(width: Int, height: Int, lines: [CGRect], segments: [WordFidelity.Segment]) -> [UInt8] {
        var map = [UInt8](repeating: UInt8(Area.fills.rawValue), count: width * height)
        func paint(_ rect: CGRect, _ area: Area) {
            let x0 = max(0, Int((rect.minX * scale).rounded(.down))), x1 = min(width, Int((rect.maxX * scale).rounded(.up)))
            let y0 = max(0, Int((rect.minY * scale).rounded(.down))), y1 = min(height, Int((rect.maxY * scale).rounded(.up)))
            guard x0 < x1, y0 < y1 else { return }
            for y in y0..<y1 { for x in x0..<x1 { map[y * width + x] = UInt8(area.rawValue) } }
        }
        for segment in segments {
            let rect = segment.horizontal
                ? CGRect(x: segment.from, y: segment.position - 1, width: segment.to - segment.from, height: 2)
                : CGRect(x: segment.position - 1, y: segment.from, width: 2, height: segment.to - segment.from)
            paint(rect, .lines)
        }
        for rect in lines { paint(rect, .text) }
        return map
    }

    /// Сравнить все страницы (по большему числу страниц; недостающая — пустой лист).
    static func compare(word: PDFDocument, ours: PDFDocument, wordLines: [WordFidelity.Line], ourLines: [WordFidelity.Line],
                        wordSegments: [WordFidelity.Segment], ourSegments: [WordFidelity.Segment],
                        progress: ((Int) -> Void)? = nil) -> Result {
        var result = Result()
        for index in 0..<max(word.pageCount, ours.pageCount) {
            let a = word.page(at: index), b = ours.page(at: index)
            let size = [a, b].compactMap { $0?.bounds(for: .mediaBox).size }
                .reduce(CGSize.zero) { CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height)) }
            let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
            guard width > 0, height > 0, let wordRaster = Raster(page: a, width: width, height: height),
                  let ourRaster = Raster(page: b, width: width, height: height) else { continue }
            let map = areas(width: width, height: height,
                            lines: (wordLines + ourLines).filter { $0.page == index }.map(\.rect),
                            segments: (wordSegments + ourSegments).filter { $0.page == index })
            autoreleasepool {
                result.pages.append(comparePage(wordRaster, ourRaster, areas: map, into: &result))
            }
            progress?(index)
        }
        return result
    }

    private static func comparePage(_ a: Raster, _ b: Raster, areas map: [UInt8], into result: inout Result) -> Page {
        let (aMin, aMax) = neighborhood(a.gray, width: a.width, height: a.height)
        let (bMin, bMax) = neighborhood(b.gray, width: b.width, height: b.height)
        let width = a.width, height = a.height
        // Пиксель отличается, если яркость одной картинки вне [min − t, max + t] окрестности 3×3 другой:
        // max(bMin − p, p − bMax, aMin − q, q − aMax) > t. Построчно во float (vDSP) — память не растёт.
        var differing = 0
        var row = [[Float]](repeating: [Float](repeating: 0, count: width), count: 6)
        var worst = [Float](repeating: 0, count: width), part = worst, sign = worst
        let n = vDSP_Length(width)
        for y in 0..<height {
            let offset = y * width
            for (index, plane) in [a.gray, b.gray, aMin, aMax, bMin, bMax].enumerated() {
                plane.withUnsafeBufferPointer { vDSP_vfltu8($0.baseAddress! + offset, 1, &row[index], 1, n) }
            }
            vDSP_vsub(row[0], 1, row[4], 1, &worst, 1, n)          // bMin − p
            vDSP_vsub(row[5], 1, row[0], 1, &part, 1, n)           // p − bMax
            vDSP_vmax(worst, 1, part, 1, &worst, 1, n)
            vDSP_vsub(row[1], 1, row[2], 1, &part, 1, n)           // aMin − q
            vDSP_vmax(worst, 1, part, 1, &worst, 1, n)
            vDSP_vsub(row[3], 1, row[1], 1, &part, 1, n)           // q − aMax
            vDSP_vmax(worst, 1, part, 1, &worst, 1, n)
            // vlim: ≥ порога → +1, иначе −1; сумма = 2·(число отличающихся) − width.
            var threshold = Float(tolerance) + 0.5, one: Float = 1, sum: Float = 0
            vDSP_vlim(worst, 1, &threshold, &one, &sign, 1, n)
            vDSP_sve(sign, 1, &sum, n)
            differing += (Int(sum.rounded()) + width) / 2
        }
        // Цвет — по сетке через пиксель (¼ листа): закрашено на обеих картинках, а цвет другой.
        var inked = [Int](repeating: 0, count: Area.allCases.count), mismatch = inked
        let inkLevel = ink, distance = chroma * chroma, text = Area.text.rawValue, t = tolerance
        a.gray.withUnsafeBufferPointer { ag in b.gray.withUnsafeBufferPointer { bg in
            a.rgba.withUnsafeBufferPointer { ac in b.rgba.withUnsafeBufferPointer { bc in
                map.withUnsafeBufferPointer { areas in
                    for y in stride(from: 0, to: height, by: 2) {
                        for x in stride(from: 0, to: width, by: 2) {
                            let index = y * width + x
                            guard ag[index] < inkLevel, bg[index] < inkLevel else { continue }
                            let area = Int(areas[index])
                            inked[area] += 1
                            let ga = Int(ac[index * 4 + 1]), gb = Int(bc[index * 4 + 1])
                            let dr = (Int(ac[index * 4]) - ga) - (Int(bc[index * 4]) - gb)
                            let db = (Int(ac[index * 4 + 2]) - ga) - (Int(bc[index * 4 + 2]) - gb)
                            let other = dr * dr + db * db > distance || (area != text && abs(Int(ag[index]) - Int(bg[index])) > t)
                            if other { mismatch[area] += 1 }
                        }
                    }
                }
            } }
        } }
        for area in Area.allCases {
            result.inked[area, default: 0] += inked[area.rawValue]
            result.colorMismatch[area, default: 0] += mismatch[area.rawValue]
        }
        return Page(difference: Double(differing) / Double(max(1, a.gray.count)))
    }
}

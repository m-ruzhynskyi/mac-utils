import CoreGraphics
import XCTest
@testable import MacUtils

final class StitcherTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Страница с «строками текста»: тёмные блоки разной длины и яркости на белом фоне.
    /// `gaps` — пустые промежутки (строки страницы сверху, высота), в которых строк нет.
    /// `scale` — масштаб экрана: строки, отступы и промежутки задаются в точках.
    private func makePage(width: Int, height: Int, seed: UInt64 = 42, scale: Int = 1,
                          gaps: [(from: Int, height: Int)] = []) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SeededGenerator(seed: seed)
        var y = 20 * scale
        while y < height - 40 * scale {
            if let gap = gaps.first(where: { y + 14 * scale > $0.from && y < $0.from + $0.height }) {
                y = gap.from + gap.height
                continue
            }
            var x = 30 * scale
            while x < width - 60 * scale {
                let w = Int.random(in: 8...60, using: &generator) * scale
                let gray = CGFloat(Int.random(in: 0...40, using: &generator)) / 100
                context.setFillColor(CGColor(gray: gray, alpha: 1))
                // Строки сверху: в CG ось y снизу.
                context.fill(CGRect(x: x, y: height - y - 14 * scale, width: w, height: 14 * scale))
                x += w + 10 * scale
            }
            y += Int.random(in: 24...36, using: &generator) * scale
        }
        return context.makeImage()!
    }

    /// Полоса-«шапка» или «низ» окна: цветной фон и свои блоки, не похожие на страницу.
    /// `badge` — маленький значок справа, как кнопка или часы, которые меняются между кадрами.
    private func makeBar(width: Int, height: Int, seed: UInt64, badge: Bool = false) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(red: 0.85, green: 0.9, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SeededGenerator(seed: seed)
        var x = 10
        while x < width - 40 {
            let w = Int.random(in: 20...80, using: &generator)
            context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: x, y: height / 4, width: w, height: max(1, height / 2)))
            x += w + 16
        }
        if badge {
            context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: width - 46, y: height / 2 - 12, width: 24, height: 24))
        }
        return context.makeImage()!
    }

    /// Кадр окна: шапка сверху, низ снизу, между ними страница со строки `offset`.
    /// Ниже конца страницы — фон `backdrop` (отскок при прокрутке за конец).
    private func makeFrame(page: CGImage, offset: Int, height: Int, header: CGImage? = nil, footer: CGImage? = nil,
                           widget: Bool = false, backdrop: CGFloat = 0.93) -> CGImage {
        let context = makeContext(width: page.width, height: height)
        context.setFillColor(CGColor(gray: backdrop, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: page.width, height: height))
        let top = header?.height ?? 0
        // Строка страницы `offset` должна оказаться в строке кадра `top` (счёт сверху).
        context.draw(page, in: CGRect(x: 0, y: height - page.height - top + offset, width: page.width, height: page.height))
        if let header {
            context.draw(header, in: CGRect(x: 0, y: height - header.height, width: header.width, height: header.height))
        }
        if let footer {
            context.draw(footer, in: CGRect(x: 0, y: 0, width: footer.width, height: footer.height))
        }
        if widget {
            // Плавающая кнопка в углу, как чат поддержки: не двигается вместе со страницей.
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
            context.fillEllipse(in: CGRect(x: page.width - 70, y: (footer?.height ?? 0) + 20, width: 48, height: 48))
        }
        return context.makeImage()!
    }

    /// Строки `range` страницы, а сверху и снизу — шапка и низ, как должно выглядеть склеенное изображение.
    private func expected(page: CGImage, rows range: Range<Int>, header: CGImage? = nil, footer: CGImage? = nil) -> CGImage {
        let top = header?.height ?? 0, bottom = footer?.height ?? 0
        let height = top + range.count + bottom
        let context = makeContext(width: page.width, height: height)
        context.draw(page.cropping(to: CGRect(x: 0, y: range.lowerBound, width: page.width, height: range.count))!,
                     in: CGRect(x: 0, y: bottom, width: page.width, height: range.count))
        if let header {
            context.draw(header, in: CGRect(x: 0, y: height - top, width: header.width, height: top))
        }
        if let footer {
            context.draw(footer, in: CGRect(x: 0, y: 0, width: footer.width, height: bottom))
        }
        return context.makeImage()!
    }

    /// Пиксели RGBA, строки сверху вниз.
    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: sRGB,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    /// Номер первой несовпадающей строки или nil, если изображения совпали попиксельно.
    private func firstDifferentRow(_ a: CGImage, _ b: CGImage) -> Int? {
        guard a.width == b.width, a.height == b.height else { return -1 }
        let pa = pixels(a), pb = pixels(b), stride = a.width * 4
        for row in 0..<a.height where pa[row * stride..<(row + 1) * stride] != pb[row * stride..<(row + 1) * stride] {
            return row
        }
        return nil
    }

    private func assertSame(_ result: CGImage?, _ reference: CGImage, file: StaticString = #filePath, line: UInt = #line) {
        guard let result else { return XCTFail("нет изображения", file: file, line: line) }
        XCTAssertEqual(result.height, reference.height, "высота", file: file, line: line)
        XCTAssertNil(firstDifferentRow(result, reference), "первая несовпавшая строка", file: file, line: line)
    }

    /// Прогоняет кадры со сдвигами `offsets` через склейку и возвращает результаты по кадрам.
    @discardableResult
    private func feed(_ stitcher: inout Stitcher, _ frames: [CGImage]) -> [Stitcher.Result] {
        frames.map { stitcher.add($0) }
    }

    // MARK: - Базовая прокрутка

    func testStitchesScrolledFrames() {
        let page = makePage(width: 600, height: 3000)
        let frameHeight = 700
        var stitcher = Stitcher()
        var offset = 0
        var last = 0
        while offset + frameHeight <= page.height {
            let frame = page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: frameHeight))!
            let result = stitcher.add(frame)
            if offset == 0 {
                XCTAssertEqual(result, .first)
            } else {
                XCTAssertEqual(result, .appended, "offset \(offset)")
            }
            last = offset
            offset += 150
        }
        XCTAssertEqual(stitcher.height, last + frameHeight)
        assertSame(stitcher.makeImage(), expected(page: page, rows: 0..<(last + frameHeight)))
    }

    func testUnchangedFrameAddsNothing() {
        let page = makePage(width: 400, height: 1200)
        let frame = page.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 500))!
        var stitcher = Stitcher()
        XCTAssertEqual(stitcher.add(frame), .first)
        XCTAssertEqual(stitcher.add(frame), .unchanged)
        XCTAssertEqual(stitcher.height, 500)
    }

    /// Неровные шаги: по одной строке, большие рывки, остановки и прокрутка назад.
    func testIrregularScrollIsPixelExact() {
        let page = makePage(width: 500, height: 4000, seed: 7)
        let h = 600
        let offsets = [0, 1, 2, 40, 40, 300, 250, 260, 700, 1100, 1100, 1050, 1150, 1600, 2050, 2051, 2500, 2950, 3400]
        var stitcher = Stitcher()
        let results = feed(&stitcher, offsets.map { makeFrame(page: page, offset: $0, height: h) })
        XCTAssertFalse(results.contains(.lost), "\(results)")
        assertSame(stitcher.makeImage(), expected(page: page, rows: 0..<(3400 + h)))
    }

    // MARK: - Закреплённые шапка и низ

    /// Закреплённые шапка и низ окна попадают в итог по одному разу: шапка сверху, низ в самом конце.
    /// Строки страницы, которые прячутся под низом, не теряются.
    func testStickyHeaderAndFooterAppearOnce() {
        let page = makePage(width: 600, height: 3200, seed: 3)
        let header = makeBar(width: 600, height: 60, seed: 1)
        let footer = makeBar(width: 600, height: 50, seed: 2)
        let h = 700, visible = h - 60 - 50
        var stitcher = Stitcher()
        var offset = 0, last = 0
        while offset + visible <= page.height {
            XCTAssertNotEqual(stitcher.add(makeFrame(page: page, offset: offset, height: h, header: header, footer: footer)),
                              .lost, "offset \(offset)")
            last = offset
            offset += 170
        }
        assertSame(stitcher.makeImage(),
                   expected(page: page, rows: 0..<(last + visible), header: header, footer: footer))
    }

    /// В шапке и в низу меняются мелочи (кнопки заголовка появились, часы, индикатор), а строка состояния
    /// при этом не двигается. Так было в живом окне: в первом кадре ещё не было кнопок заголовка.
    func testStickyBarsWithChangingDetails() {
        let page = makePage(width: 600, height: 3000, seed: 41)
        let h = 700, visible = h - 60 - 50
        var stitcher = Stitcher()
        var offset = 0, last = 0, step = 0
        var results: [Stitcher.Result] = []
        var lastHeader: CGImage?, lastFooter: CGImage?
        while offset + visible <= page.height {
            let header = makeBar(width: 600, height: 60, seed: 1, badge: step > 0)
            let footer = makeBar(width: 600, height: 50, seed: 2, badge: step % 2 == 1)
            results.append(stitcher.add(makeFrame(page: page, offset: offset, height: h, header: header, footer: footer)))
            lastHeader = step == 0 ? header : lastHeader
            lastFooter = footer
            last = offset
            offset += 170
            step += 1
        }
        XCTAssertFalse(results.contains(.lost), "\(results)")
        // Шапка — из первого кадра, низ — из последнего.
        assertSame(stitcher.makeImage(),
                   expected(page: page, rows: 0..<(last + visible), header: lastHeader, footer: lastFooter))
    }

    /// Высокая шапка (больше трети области) с текстурой: старый поиск брал полосу в ней и видел «нет движения».
    func testTallStickyHeader() {
        let page = makePage(width: 600, height: 2600, seed: 5)
        let header = makeBar(width: 600, height: 260, seed: 9)
        let h = 640, visible = h - 260
        var stitcher = Stitcher()
        var offset = 0, last = 0
        while offset + visible <= page.height {
            stitcher.add(makeFrame(page: page, offset: offset, height: h, header: header))
            last = offset
            offset += 120
        }
        assertSame(stitcher.makeImage(), expected(page: page, rows: 0..<(last + visible), header: header))
    }

    // MARK: - Однотонные участки

    /// Пустые промежутки страницы меньше перекрытия кадров: сдвиг однозначен, итог совпадает попиксельно,
    /// хотя в отдельных полосах кадра нет ни одной строки.
    func testBlankStretchesShorterThanOverlap() {
        let gaps = [(from: 500, height: 320), (from: 1300, height: 380), (from: 2200, height: 300)]
        let page = makePage(width: 600, height: 3200, seed: 11, gaps: gaps)
        let h = 640
        var stitcher = Stitcher()
        var offset = 0, last = 0
        var results: [Stitcher.Result] = []
        while offset + h <= page.height {
            results.append(stitcher.add(makeFrame(page: page, offset: offset, height: h)))
            last = offset
            offset += 160
        }
        XCTAssertFalse(results.contains(.lost), "\(results)")
        assertSame(stitcher.makeImage(), expected(page: page, rows: 0..<(last + h)))
    }

    /// Пустой промежуток длиннее кадра: сдвиг внутри него неоднозначен. Строки текста не должны ни
    /// повториться, ни потеряться; сокращаться может только пустота.
    func testBlankStretchLongerThanFrameKeepsEveryLineOnce() {
        let page = makePage(width: 600, height: 3000, seed: 13, gaps: [(from: 900, height: 900)])
        let h = 500
        var stitcher = Stitcher()
        var offset = 0, last = 0
        while offset + h <= page.height {
            stitcher.add(makeFrame(page: page, offset: offset, height: h))
            last = offset
            offset += 100
        }
        guard let image = stitcher.makeImage() else { return XCTFail("нет изображения") }
        XCTAssertLessThanOrEqual(image.height, last + h)
        XCTAssertGreaterThanOrEqual(image.height, last + h - 900)
        XCTAssertEqual(textRowCounts(image), textRowCounts(expected(page: page, rows: 0..<(last + h))))
    }

    /// Сколько раз встречается каждая строка с текстом (пустые строки не считаются).
    private func textRowCounts(_ image: CGImage) -> [[UInt8]: Int] {
        let data = pixels(image), stride = image.width * 4
        var counts: [[UInt8]: Int] = [:]
        for row in 0..<image.height {
            let line = Array(data[row * stride..<(row + 1) * stride])
            guard line.contains(where: { $0 < 200 }) else { continue }
            counts[line, default: 0] += 1
        }
        return counts
    }

    // MARK: - Конец прокрутки

    /// Отскок за конец страницы: кадры с фоном под страницей, потом возврат. Фон в итог не попадает.
    func testOverscrollBounceAtEndIsTrimmed() {
        let page = makePage(width: 500, height: 2000, seed: 17)
        let h = 600, end = page.height - h
        var stitcher = Stitcher()
        for offset in stride(from: 0, through: end, by: 140) {
            stitcher.add(makeFrame(page: page, offset: offset, height: h))
        }
        stitcher.add(makeFrame(page: page, offset: end, height: h))
        for offset in [end + 30, end + 60, end + 40, end + 15, end, end] {
            stitcher.add(makeFrame(page: page, offset: offset, height: h))
        }
        assertSame(stitcher.makeImage(), expected(page: page, rows: 0..<page.height))
    }

    /// После возврата назад кадр с прежним положением ничего не добавляет: конец не дублируется.
    func testScrollBackAndForthDoesNotDuplicate() {
        let page = makePage(width: 500, height: 2400, seed: 19)
        let h = 600
        var stitcher = Stitcher()
        for offset in [0, 200, 400, 250, 100, 250, 400, 600, 800, 800, 800] {
            stitcher.add(makeFrame(page: page, offset: offset, height: h))
        }
        assertSame(stitcher.makeImage(), expected(page: page, rows: 0..<(800 + h)))
    }

    // MARK: - Масштаб и помехи

    /// Retina 2x: строки и сдвиги в точках, кадры в пикселях.
    func testRetinaScaleTwo() {
        let page = makePage(width: 800, height: 4400, seed: 23, scale: 2)
        let h = 1400
        var stitcher = Stitcher()
        var offset = 0, last = 0
        while offset + h <= page.height {
            XCTAssertNotEqual(stitcher.add(makeFrame(page: page, offset: offset, height: h)), .lost)
            last = offset
            offset += 2 * 173
        }
        assertSame(stitcher.makeImage(), expected(page: page, rows: 0..<(last + h)))
    }

    /// Плавающая кнопка в углу не сбивает поиск сдвига.
    func testFloatingWidgetDoesNotBreakTracking() {
        let page = makePage(width: 600, height: 2600, seed: 29)
        let h = 640
        var stitcher = Stitcher()
        var offset = 0, last = 0
        var results: [Stitcher.Result] = []
        while offset + h <= page.height {
            results.append(stitcher.add(makeFrame(page: page, offset: offset, height: h, widget: true)))
            last = offset
            offset += 150
        }
        XCTAssertFalse(results.contains(.lost), "\(results)")
        XCTAssertEqual(stitcher.height, last + h)
    }

    /// Слишком большой рывок между кадрами: перекрытия нет, кадр не приклеивается вслепую.
    func testJumpWithoutOverlapIsLost() {
        let page = makePage(width: 500, height: 3000, seed: 31)
        let h = 500
        var stitcher = Stitcher()
        stitcher.add(makeFrame(page: page, offset: 0, height: h))
        XCTAssertEqual(stitcher.add(makeFrame(page: page, offset: 1200, height: h)), .lost)
        XCTAssertEqual(stitcher.height, h)
        // Вернулись к перекрытию — склейка продолжается с того же места.
        XCTAssertEqual(stitcher.add(makeFrame(page: page, offset: 300, height: h)), .appended)
        assertSame(stitcher.makeImage(), expected(page: page, rows: 0..<(300 + h)))
    }

    /// Кусочки не держат целые кадры: каждый — своё изображение высотой с кусочек.
    func testPiecesDoNotRetainWholeFrames() {
        let page = makePage(width: 400, height: 2000, seed: 37)
        var stitcher = Stitcher()
        let first = makeFrame(page: page, offset: 0, height: 500)
        let second = makeFrame(page: page, offset: 100, height: 500)
        // Счётчик самого CGImage меняет ARC; буфер кадра держит только тот, кто сослался на его провайдер.
        let references = { [CFGetRetainCount(first.dataProvider!), CFGetRetainCount(second.dataProvider!)] }
        let before = references()
        XCTAssertEqual(stitcher.add(first), .first)
        XCTAssertEqual(stitcher.add(second), .appended)
        XCTAssertEqual(references(), before, "кусочек держит кадр или его буфер")
    }
}

/// Детерминированный генератор, чтобы тест не зависел от случайности.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

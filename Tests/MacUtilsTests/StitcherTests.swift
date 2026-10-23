import AppKit
import CoreGraphics
import XCTest
@testable import MacUtils
@testable import MUAudio

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

/// Страницы из настоящего текста (CoreText, антиалиасинг, Retina 2x: строка 20 pt = 40 px) — сценарии ревью
/// `.audit/review-scroll.md`: похожие и повторяющиеся строки, видео, анимация, широкая область, градиент,
/// инерционная прокрутка. На сплошных блоках (`StitcherTests`) эти ошибки не проявлялись.
final class StitcherRealPageTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private struct Theme { var background: CGFloat; var text: CGFloat }
    private let light = Theme(background: 1, text: 0.1)
    private let dark = Theme(background: 0.118, text: 0.86)

    /// Страница из строк текста, фон — однотонный или `background`.
    private func textPage(width: Int, lines: [String], font: NSFont = .systemFont(ofSize: 13), theme: Theme? = nil,
                          background: ((CGContext, Int, Int) -> Void)? = nil) -> CGImage {
        let theme = theme ?? light
        let scale: CGFloat = 2, height = Int((16 + CGFloat(lines.count) * 20 + 40) * scale)
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(gray: theme.background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        background?(context, width, height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: theme.text, alpha: 1)]
        for (i, line) in lines.enumerated() { (line as NSString).draw(at: NSPoint(x: 24, y: 16 + CGFloat(i) * 20), withAttributes: attributes) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private func prose(seed: UInt64, count: Int) -> [String] {
        let words = "стенд склейка строка кадр прокрутка шапка таблица код снимок экран длинный запрос ответ сервер ключ проверка зритель ведущий окно панель".split(separator: " ")
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { i in
            i % 9 == 8 ? "" : (0..<Int.random(in: 3...14, using: &generator)).map { _ in String(words.randomElement(using: &generator)!) }.joined(separator: " ")
        }
    }

    private var mono: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }

    /// Кадр: строки страницы с `offset`, поверх — `overlay(context, offset, height)` (видео, анимация).
    private func makeFrame(page: CGImage, offset: Int, height: Int, overlay: ((CGContext, Int, Int) -> Void)? = nil) -> CGImage {
        let context = makeContext(width: page.width, height: height)
        context.setFillColor(CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: page.width, height: height))
        context.draw(page, in: CGRect(x: 0, y: height - page.height + offset, width: page.width, height: page.height))
        overlay?(context, offset, height)
        return context.makeImage()!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    /// Итог совпадает со строками `0..<height` страницы, кроме строк `ignoring` (видео, анимация — их вид любой).
    private func assertPage(_ result: CGImage?, _ page: CGImage, height: Int, ignoring: Range<Int>? = nil,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let result else { return XCTFail("нет изображения", file: file, line: line) }
        XCTAssertEqual(result.height, height, "высота", file: file, line: line)
        guard result.height == height else { return }
        let got = pixels(result), want = pixels(page), stride = page.width * 4
        let bad = (0..<height).first { (r: Int) -> Bool in
            if let ignoring, ignoring.contains(r) { return false }
            let row: Range<Int> = r * stride..<(r + 1) * stride
            return got[row] != want[row]
        }
        XCTAssertNil(bad, "первая несовпавшая строка", file: file, line: line)
    }

    /// Прокрутка по `offsets`; `motion` — подсказка событий: доля шага в своём кадре (остальное опаздывает в
    /// следующий) и шум ±`noise` — как у настоящих событий относительно кадров.
    private func scroll(_ page: CGImage, height h: Int, offsets: [Int], motion: (share: Double, noise: Double)? = nil,
                        overlay: ((CGContext, Int, Int) -> Void)? = nil) -> (stitcher: Stitcher, results: [Stitcher.Result]) {
        var stitcher = Stitcher()
        var results: [Stitcher.Result] = []
        var generator = SeededGenerator(seed: 5)
        var carry = 0.0, last = offsets.first ?? 0
        for offset in offsets {
            let frame = makeFrame(page: page, offset: offset, height: h, overlay: overlay)
            if let motion {
                let step = Double(offset - last) * (1 + Double.random(in: -motion.noise...motion.noise, using: &generator))
                last = offset
                let now = step * motion.share + carry
                carry = step * (1 - motion.share)
                results.append(stitcher.add(frame, motion: Stitcher.Motion(pixels: now)))
            } else {
                results.append(stitcher.add(frame))
            }
        }
        return (stitcher, results)
    }

    private func steps(_ page: CGImage, height: Int, by step: Int) -> [Int] { Array(stride(from: 0, through: page.height - height, by: step)) }

    /// Инерционная прокрутка (тик 150 мс): разгон, затухание, остановка, немного назад, снова вниз.
    private func inertial(limit: Int) -> [Int] {
        let pattern = [60, 140, 260, 380, 420, 360, 280, 200, 140, 90, 50, 20, 6, 0, 0, -120, -60, 0, 40, 180, 320, 300, 220, 120, 40, 0]
        var offset = 0, out = [0]
        while true {
            for v in pattern {
                offset = max(0, offset + v)
                if offset > limit { return out }
                out.append(offset)
            }
        }
    }

    // MARK: - BLOCKER: похожие строки — ни одна не пропадает

    func testLogWithChangingTimestampsKeepsEveryLine() {
        let lines = (0..<160).map { i -> String in
            String(format: "2026-10-17 09:%02d:%02d.%03d  INFO  [worker-3] GET /api/v1/items 200 ", 41 + i / 60, i % 60, (i * 137) % 1000) + "\((10 + i * 31 % 90))ms"
        }
        let page = textPage(width: 1400, lines: lines, font: mono)
        let offsets = steps(page, height: 1200, by: 300)
        let run = scroll(page, height: 1200, offsets: offsets)
        XCTAssertFalse(run.results.contains(.lost), "\(run.results)")
        assertPage(run.stitcher.makeImage(), page, height: offsets.last! + 1200)   // 7643e21: 2120 из 12000
    }

    func testRepeatedCodeBlocksAndSwitchCasesKeepEveryLine() {
        var code: [String] = []
        for i in 1...22 {
            code += ["func handler\(String(format: "%02d", i))(_ request: Request) -> Response? {", "    guard request.isValid else {",
                     "        return nil", "    }", "    return Response(status: .ok)", "}", ""]
        }
        let page = textPage(width: 1400, lines: code, font: mono)
        // Шаг 300 и 380 больше периода блока (7 строк = 280 px): меньший ложный сдвиг выглядит почти так же.
        for step in [300, 380] {
            let offsets = steps(page, height: 1200, by: step)
            let run = scroll(page, height: 1200, offsets: offsets)
            assertPage(run.stitcher.makeImage(), page, height: offsets.last! + 1200)   // 7643e21: 1660 из 8100
        }
        let cases = ["switch action {"] + (0..<90).map { "case .action\($0): return handle(action, flag: \($0 % 2 == 0))" }
        let switchPage = textPage(width: 1400, lines: cases, font: mono)
        let offsets = steps(switchPage, height: 1200, by: 300)
        assertPage(scroll(switchPage, height: 1200, offsets: offsets).stitcher.makeImage(), switchPage, height: offsets.last! + 1200)
    }

    /// Блок одинаковых строк длиннее кадра по изображению неразличим: без подсказки — `.lost` (предупреждение),
    /// а не молча потерянные строки; с точной подсказкой событий — весь лог.
    func testIdenticalLinesAreNotGuessed() {
        var lines = prose(seed: 7, count: 30)
        lines += Array(repeating: "2026-10-17 09:41:39.123 INFO  heartbeat ok", count: 45)
        lines += prose(seed: 8, count: 40)
        let page = textPage(width: 1400, lines: lines, font: mono)
        let offsets = steps(page, height: 1200, by: 300)
        let blind = scroll(page, height: 1200, offsets: offsets)
        XCTAssertTrue(blind.results.contains(.lost), "неоднозначность не скрыта")
        XCTAssertLessThanOrEqual(blind.stitcher.height, offsets.last! + 1200)
        if let image = blind.stitcher.makeImage() {
            // Всё, что вклеено, — подряд идущее начало страницы: ничего не выпало из середины.
            assertPage(image, page, height: image.height)
        }
        let hinted = scroll(page, height: 1200, offsets: offsets, motion: (share: 1, noise: 0))
        XCTAssertFalse(hinted.results.contains(.lost), "\(hinted.results)")
        assertPage(hinted.stitcher.makeImage(), page, height: offsets.last! + 1200)
    }

    // MARK: - MAJOR-2: видео в странице

    func testPlayingVideoDoesNotLoseTrack() {
        let page = textPage(width: 1400, lines: prose(seed: 7, count: 160))
        var tick: UInt64 = 0
        // Видео 360×640 pt (720×1280 px) в строках 1800…2520 страницы: каждый кадр — новая картинка.
        let video: (CGContext, Int, Int) -> Void = { context, offset, h in
            tick += 1
            var generator = SeededGenerator(seed: tick &* 2654435761)
            let top = 1800 - offset
            for y in stride(from: 0, to: 720, by: 20) { for x in stride(from: 0, to: 1280, by: 20) {
                context.setFillColor(CGColor(gray: CGFloat(Int.random(in: 0...255, using: &generator)) / 255, alpha: 1))
                context.fill(CGRect(x: 60 + x, y: h - top - y - 20, width: 20, height: 20))
            } }
        }
        let offsets = steps(page, height: 1200, by: 300)
        for motion in [nil, (share: 0.7, noise: 0.1)] as [(share: Double, noise: Double)?] {
            tick = 0
            let run = scroll(page, height: 1200, offsets: offsets, motion: motion, overlay: video)
            XCTAssertFalse(run.results.dropFirst(8).contains(.lost), "\(run.results)")   // 7643e21: .lost до конца
            assertPage(run.stitcher.makeImage(), page, height: offsets.last! + 1200, ignoring: 1800..<2520)
        }
    }

    // MARK: - MAJOR-3: анимация в стоящем окне

    func testAnimationInStillWindowAddsNothing() {
        let page = textPage(width: 1400, lines: prose(seed: 7, count: 160))
        var phase = 0
        // Титры 400×800 px в строках 400…800 страницы: уезжают вверх на 24 px за кадр.
        let credits: (CGContext, Int, Int) -> Void = { context, offset, h in
            phase += 1
            let top = 400 - offset
            context.saveGState()
            context.clip(to: CGRect(x: 300, y: h - top - 400, width: 800, height: 400))
            context.setFillColor(CGColor(gray: 0.05, alpha: 1))
            context.fill(CGRect(x: 300, y: h - top - 400, width: 800, height: 400))
            var generator = SeededGenerator(seed: 99)
            for line in 0..<60 {
                let y = top + line * 40 - phase * 24
                context.setFillColor(CGColor(gray: 0.9, alpha: 1))
                context.fill(CGRect(x: 350, y: h - y - 14, width: Int.random(in: 200...700, using: &generator), height: 14))
            }
            context.restoreGState()
        }
        let offsets = Array(repeating: 0, count: 8) + Array(stride(from: 300, through: 1800, by: 300))
        // По изображению (событий нет вовсе) и с событиями: пока окно стоит, событий прокрутки нет.
        for motion in [nil, (share: 1.0, noise: 0.0)] as [(share: Double, noise: Double)?] {
            phase = 0
            let run = scroll(page, height: 1200, offsets: offsets, motion: motion, overlay: credits)
            XCTAssertFalse(run.results[1..<8].contains(.appended), "\(run.results)")   // 7643e21: appended +48, +120
            assertPage(run.stitcher.makeImage(), page, height: 1800 + 1200, ignoring: 400..<800)
        }
    }

    /// События прокрутки шли, потом прекратились: дальнейшие изменения в кадре — не прокрутка.
    func testNoScrollEventsMeansNoScroll() {
        let page = textPage(width: 1400, lines: prose(seed: 3, count: 120))
        var stitcher = Stitcher()
        XCTAssertEqual(stitcher.add(makeFrame(page: page, offset: 0, height: 1200), motion: Stitcher.Motion()), .first)
        XCTAssertEqual(stitcher.add(makeFrame(page: page, offset: 300, height: 1200), motion: Stitcher.Motion(pixels: 300)), .appended)
        // Содержимое «уехало» без событий (так выглядит анимация) — кадр не клеится.
        XCTAssertEqual(stitcher.add(makeFrame(page: page, offset: 600, height: 1200), motion: Stitcher.Motion()), .unchanged)
        XCTAssertEqual(stitcher.height, 1500)
        // Клавиши прокрутки (величина неизвестна) — снова по изображению.
        XCTAssertEqual(stitcher.add(makeFrame(page: page, offset: 600, height: 1200), motion: Stitcher.Motion(unknown: 1)), .appended)
        XCTAssertEqual(stitcher.height, 1800)
    }

    // MARK: - MAJOR-4: широкая область — чужое содержимое не вклеивается

    func testOtherContentInWideRegionIsNotAppended() {
        let a = textPage(width: 5120, lines: prose(seed: 7, count: 160)), b = textPage(width: 5120, lines: prose(seed: 99, count: 160))
        let blank = textPage(width: 5120, lines: Array(repeating: "", count: 160))
        var stitcher = Stitcher()
        XCTAssertEqual(stitcher.add(makeFrame(page: a, offset: 0, height: 2880)), .first)
        XCTAssertEqual(stitcher.add(makeFrame(page: a, offset: 300, height: 2880)), .appended)
        // Переход по ссылке, пустая страница при загрузке, рывок без перекрытия — не продолжение.
        XCTAssertNotEqual(stitcher.add(makeFrame(page: b, offset: 300, height: 2880)), .appended)        // 7643e21: appended +1880
        XCTAssertNotEqual(stitcher.add(makeFrame(page: blank, offset: 0, height: 2880)), .appended)      // 7643e21: appended
        XCTAssertNotEqual(stitcher.add(makeFrame(page: a, offset: 3300, height: 2880)), .appended)       // 7643e21: appended
        XCTAssertEqual(stitcher.height, 2880 + 300)
        // Вернулись к странице — склейка продолжается.
        XCTAssertEqual(stitcher.add(makeFrame(page: a, offset: 600, height: 2880)), .appended)
        assertPage(stitcher.makeImage(), a, height: 600 + 2880)
    }

    // MARK: - MINOR-5: hero с вертикальным градиентом

    func testGradientHeroKeepsHeadings() {
        let gradient: (CGContext, Int, Int) -> Void = { context, _, h in
            let colors = [CGColor(red: 0.2, green: 0.25, blue: 0.4, alpha: 1), CGColor(red: 0.95, green: 0.95, blue: 0.97, alpha: 1)] as CFArray
            context.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: nil)!,
                                       start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h - 3000), options: [.drawsAfterEndLocation])
        }
        var body = prose(seed: 3, count: 160)
        for i in 0..<60 { body[i] = i % 10 == 0 ? "Hero \(i)" : "" }
        let page = textPage(width: 1400, lines: body, background: gradient)
        let offsets = steps(page, height: 1200, by: 300)
        assertPage(scroll(page, height: 1200, offsets: offsets).stitcher.makeImage(), page, height: offsets.last! + 1200)
    }

    // MARK: - Инерционная прокрутка, темы

    func testInertialScrollWithRealTextLightAndDark() {
        let lines = prose(seed: 11, count: 180)
        // Светлая — только по изображению, тёмная — с подсказкой событий (опаздывают и неточны).
        for (theme, motion) in [(light, nil), (dark, (share: 0.7, noise: 0.1))] as [(Theme, (share: Double, noise: Double)?)] {
            let page = textPage(width: 1400, lines: lines, theme: theme)
            let offsets = inertial(limit: page.height - 1200)
            let run = scroll(page, height: 1200, offsets: offsets, motion: motion)
            XCTAssertFalse(run.results.contains(.lost), "\(run.results)")
            assertPage(run.stitcher.makeImage(), page, height: offsets.max()! + 1200)
        }
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

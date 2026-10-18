import AppKit
import CoreGraphics
import XCTest
@testable import MacUtils

/// Сценарии повторного ревью (`.audit/review-scroll2.md`) на настоящем тексте CoreText: после потери места чужое
/// содержимое не вклеивается, похожие строки на широкой области и при шаге, кратном строке или блоку, не теряются,
/// прокрутка клавишами и анимированная прокрутка снимаются целиком. Главная проверка — «без шва»: итог совпадает
/// со страницей строка в строку с самого начала, ничего не выпало из середины.
final class StitcherScenarioTests: XCTestCase {
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private var mono: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }

    private func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    /// Страница из строк текста (Retina 2x: строка 20 pt = 40 px).
    private func textPage(width: Int, lines: [String], font: NSFont = .systemFont(ofSize: 13)) -> CGImage {
        let scale: CGFloat = 2, height = Int((16 + CGFloat(lines.count) * 20 + 40) * scale)
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.1, alpha: 1)]
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

    /// Лог по секундам: строки одной формы, отличаются цифрами.
    private func log(from start: Int, count: Int) -> [String] {
        (start..<(start + count)).map { i in
            String(format: "2026-10-17 %02d:%02d:%02d.%03d  INFO  [worker-3] GET /api/v1/items 200 %dms",
                   9 + i / 3600, (i / 60) % 60, i % 60, (i * 137) % 1000, 10 + (i * 31) % 90)
        }
    }

    private func json(from start: Int, count: Int) -> [String] {
        (start..<(start + count)).flatMap { ["  {", "    \"id\": \(1000 + $0),", "    \"name\": \"item-\($0)\",", "    \"active\": true", "  },"] }
    }

    private func code(from start: Int, count: Int) -> [String] {
        (start..<(start + count)).flatMap {
            ["func handler\(String(format: "%03d", $0))(_ request: Request) -> Response? {", "    guard request.isValid else {",
             "        return nil", "    }", "    return Response(status: .ok)", "}", ""]
        }
    }

    /// Кадр: строки страницы с `offset`, поверх — `overlay(context, offset, height)` (анимация).
    private func makeFrame(_ page: CGImage, offset: Int, height: Int, overlay: ((CGContext, Int, Int) -> Void)? = nil) -> CGImage {
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

    /// Итог — начало страницы строка в строку (шва нет); `height` — какой высоты должен быть.
    private func assertSeamless(_ stitcher: Stitcher, _ page: CGImage, height: Int? = nil, _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        guard let image = stitcher.makeImage() else { return XCTFail("нет изображения \(message)", file: file, line: line) }
        if let height { XCTAssertEqual(image.height, height, "высота \(message)", file: file, line: line) }
        let got = pixels(image), want = pixels(page), stride = page.width * 4
        let rows = min(image.height, page.height)
        let seam = (0..<rows).first { r in got[r * stride..<(r + 1) * stride] != want[r * stride..<(r + 1) * stride] }
        XCTAssertNil(seam, "шов: первая несовпавшая строка \(message)", file: file, line: line)
    }

    // MARK: - BLOCKER 1: после потери места подсказка не клеит чужое

    /// Рывок, которого монитор не видел (скрипт, якорь), и дальше прокрутка трекпадом: события от дальнего кадра
    /// ничего не значат — чужое не вклеивается. Вернулись назад до перекрытия — склейка продолжается без шва.
    func testJumpThenScrollWithEventsDoesNotStitchForeignContent() {
        let page = textPage(width: 1400, lines: prose(seed: 7, count: 300))
        // Разные шаги: у eb02ac2 шов зависел от того, совпадёт ли случайная «ничья» с подсказкой (12 из 20 прогонов).
        for step in [206, 232, 257, 300, 341] {
            var stitcher = Stitcher(), offset = 0
            for k in 0..<4 { if k > 0 { offset += step }; stitcher.add(makeFrame(page, offset: offset, height: 1200), motion: Stitcher.Motion(pixels: k == 0 ? 0 : Double(step))) }
            offset += 2810
            var results: [Stitcher.Result] = [stitcher.add(makeFrame(page, offset: offset, height: 1200), motion: Stitcher.Motion())]
            for k in 0..<8 {
                offset += step
                let noise = 1 + Double(k % 3 - 1) * 0.08
                results.append(stitcher.add(makeFrame(page, offset: offset, height: 1200), motion: Stitcher.Motion(pixels: Double(step) * noise)))
            }
            XCTAssertFalse(results.contains(.appended), "шаг \(step): \(results)")
            assertSeamless(stitcher, page, height: 3 * step + 1200, "шаг \(step)")
        }
        let step = 300
        var stitcher = Stitcher(), offset = 0
        for k in 0..<4 { if k > 0 { offset += step }; stitcher.add(makeFrame(page, offset: offset, height: 1200), motion: Stitcher.Motion(pixels: k == 0 ? 0 : 300)) }
        offset += 3600
        stitcher.add(makeFrame(page, offset: offset, height: 1200), motion: Stitcher.Motion())
        // Как советует HUD: назад до перекрытия и снова вниз.
        while offset > 1200 {
            offset -= 300
            stitcher.add(makeFrame(page, offset: offset, height: 1200), motion: Stitcher.Motion(pixels: -300))
        }
        for _ in 0..<4 {
            offset += 300
            stitcher.add(makeFrame(page, offset: offset, height: 1200), motion: Stitcher.Motion(pixels: 300))
        }
        assertSeamless(stitcher, page, height: offset + 1200)
    }

    /// Переход на другую страницу и прокрутка дальше с событиями: новая страница не вклеивается к старой.
    func testOtherPageWithEventsIsNotAppended() {
        let a = textPage(width: 1400, lines: prose(seed: 7, count: 200)), b = textPage(width: 1400, lines: prose(seed: 99, count: 200))
        var stitcher = Stitcher()
        stitcher.add(makeFrame(a, offset: 0, height: 1200), motion: Stitcher.Motion())
        stitcher.add(makeFrame(a, offset: 300, height: 1200), motion: Stitcher.Motion(pixels: 300))
        for k in 0..<8 {
            XCTAssertNotEqual(stitcher.add(makeFrame(b, offset: 300 + k * 300, height: 1200), motion: Stitcher.Motion(pixels: k == 0 ? 0.6 : 300)), .appended, "кадр \(k)")
        }
        assertSeamless(stitcher, a, height: 1500)
    }

    /// Рывок по логу, JSON, коду или переход к другому файлу того же вида: строки похожи, но не те — не вклеиваются
    /// (eb02ac2 на 5K вклеивал 3060–3540 px).
    func testSimilarContentAfterJumpIsNotAppended() {
        // Весь экран 5K: колонка подписи — 5 px, строки лога, отличающиеся цифрами, выглядят одинаково.
        let wide = textPage(width: 5120, lines: log(from: 0, count: 400), font: mono)
        var stitcher = Stitcher(), offset = 0
        for k in 0..<3 { if k > 0 { offset += 300 }; stitcher.add(makeFrame(wide, offset: offset, height: 2880)) }
        offset += 3 * 2880
        for _ in 0..<3 {
            offset += 300
            XCTAssertNotEqual(stitcher.add(makeFrame(wide, offset: offset, height: 2880)), .appended, "5K, лог, рывок")
        }
        assertSeamless(stitcher, wide, height: 600 + 2880, "5K, лог, рывок")
        let cases: [(String, [String], [String])] = [("лог", log(from: 0, count: 300), log(from: 5000, count: 300)),
                                                     ("JSON", json(from: 0, count: 60), json(from: 300, count: 60)),
                                                     ("код", code(from: 0, count: 40), code(from: 200, count: 40))]
        for (name, linesA, linesB) in cases {
            let a = textPage(width: 1400, lines: linesA, font: mono), b = textPage(width: 1400, lines: linesB, font: mono)
            for (other, jump) in [(a, 2400), (b, 0)] {
                var stitcher = Stitcher(), offset = 0
                for k in 0..<4 { if k > 0 { offset += 300 }; stitcher.add(makeFrame(a, offset: offset, height: 1200)) }
                offset += jump
                for _ in 0..<6 {
                    offset += 300
                    XCTAssertNotEqual(stitcher.add(makeFrame(other, offset: min(offset, other.height - 1200), height: 1200)), .appended, "\(name), рывок \(jump)")
                }
                assertSeamless(stitcher, a, height: 900 + 1200, "\(name), рывок \(jump)")
            }
        }
    }

    // MARK: - BLOCKER 2: шаг, кратный строке или блоку

    /// Колесо мыши прокручивает строками: шаг кратен высоте строки лога (40 px). На широкой области (окно 1400 pt
    /// на Retina, 5K) eb02ac2 застревал в «без изменений» или клеил со швом.
    func testLineAlignedStepsInWideLog() {
        for (width, height, step, frames) in [(2800, 1200, 240, 12), (2800, 1200, 400, 10), (5120, 2880, 400, 6)] {
            let page = textPage(width: width, lines: log(from: 0, count: 160), font: mono)
            var stitcher = Stitcher()
            var results: [Stitcher.Result] = []
            for k in 0..<frames { results.append(stitcher.add(makeFrame(page, offset: k * step, height: height))) }
            XCTAssertFalse(results.contains(.lost) || results.dropFirst().contains(.unchanged), "\(width), шаг \(step): \(results)")
            assertSeamless(stitcher, page, height: (frames - 1) * step + height, "\(width), шаг \(step)")
        }
    }

    /// Шаг, равный периоду разметки: объект JSON (5 строк = 200 px), функция (7 строк = 280 px). Строки на тех же
    /// местах отличаются одной цифрой; было — «без изменений» до конца.
    func testPeriodAlignedStepsInJsonAndCode() {
        for (name, lines, step) in [("JSON", json(from: 0, count: 50), 200), ("код", code(from: 0, count: 30), 280)] {
            let page = textPage(width: 1400, lines: lines, font: mono)
            var stitcher = Stitcher()
            let frames = 12
            for k in 0..<frames { stitcher.add(makeFrame(page, offset: k * step, height: 1200)) }
            assertSeamless(stitcher, page, height: (frames - 1) * step + 1200, name)
        }
    }

    // MARK: - MAJOR и MINOR: клавиши, анимированная прокрутка, события без прокрутки

    /// PageDown и пробел в браузерах: видимая высота − 40 CSS px, перекрытие 80 px из 1200 (было: `.lost` всегда).
    func testPageDownWithSmallOverlap() {
        let page = textPage(width: 1400, lines: prose(seed: 3, count: 300))
        var stitcher = Stitcher()
        stitcher.add(makeFrame(page, offset: 0, height: 1200), motion: Stitcher.Motion())
        for k in 1...5 {
            XCTAssertEqual(stitcher.add(makeFrame(page, offset: k * 1120, height: 1200), motion: Stitcher.Motion(unknown: 1)), .appended, "нажатие \(k)")
        }
        assertSeamless(stitcher, page, height: 5 * 1120 + 1200)
    }

    func testScrollInputGivesMotionToFrames() {
        var input = ScrollInput()
        XCTAssertNil(input.take(upTo: 1), "событий не было — склейка по изображению")
        input.note(Stitcher.Motion(pixels: 120), at: 1.0)
        input.note(Stitcher.Motion(pixels: 80), at: 1.2)
        XCTAssertEqual(input.take(upTo: 1.1), Stitcher.Motion(pixels: 120))
        XCTAssertEqual(input.take(upTo: 1.3), Stitcher.Motion(pixels: 80))
        XCTAssertEqual(input.take(upTo: 1.5), Stitcher.Motion(), "события кончились — прокрутки нет")
        // Колесо: над областью — величина, мимо — «прокрутка неизвестной величины», а не тишина.
        XCTAssertEqual(ScrollInput.wheel(deltaY: -3, precise: true, scale: 2, overArea: true)?.motion, Stitcher.Motion(pixels: 6))
        XCTAssertEqual(ScrollInput.wheel(deltaY: -1, precise: false, scale: 2, overArea: true)?.animated, true)
        XCTAssertEqual(ScrollInput.wheel(deltaY: -3, precise: true, scale: 2, overArea: false)?.motion, Stitcher.Motion(unknown: 1))
        XCTAssertNil(ScrollInput.wheel(deltaY: 0, precise: true, scale: 2, overArea: true))
    }

    /// Щелчок колеса или клавиша запускают анимацию прокрутки: ещё `animationTail` кадрам достаётся «прокрутка
    /// неизвестной величины», и остаток анимации не считается «прокрутки нет».
    func testAnimationTailAfterKeyOrWheel() {
        var input = ScrollInput()
        input.note(Stitcher.Motion(unknown: 1), at: 2.0, animated: true)
        XCTAssertEqual(input.take(upTo: 2.1), Stitcher.Motion(unknown: 1))
        XCTAssertEqual(input.take(upTo: 2.4), Stitcher.Motion(unknown: 1), "анимация ещё идёт")
        XCTAssertEqual(input.take(upTo: 2.7), Stitcher.Motion(), "анимация кончилась")
    }

    /// Модель захвата по времени (тик 150 мс, как `ScrollCapture`): трекпад, потом PageDown с анимацией 300 мс,
    /// потом щелчки колеса с анимацией 200 мс. Клавиши видны всегда (перехватом или по времени нажатия). Было:
    /// без «Универсального доступа» после трекпада — «без изменений» до конца; конец щелчка колеса терялся.
    func testKeyboardAndAnimatedWheelScrollKeepEveryLine() {
        let page = textPage(width: 1400, lines: prose(seed: 5, count: 420))
        enum Source { case trackpad, key, wheel }
        struct Action { var time: Double; var delta: Double; var duration: Double; var source: Source }
        var actions = (0..<3).map { Action(time: 0.3 + Double($0) * 0.6, delta: 300, duration: 0.3, source: .trackpad) }
        actions += (0..<3).map { Action(time: 2.5 + Double($0), delta: 1120, duration: 0.3, source: .key) }
        actions += (0..<6).map { Action(time: 5.5 + Double($0) * 0.5, delta: 240, duration: 0.2, source: .wheel) }
        func ease(_ x: Double) -> Double { x <= 0 ? 0 : x >= 1 ? 1 : (x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2) }
        func offset(at t: Double) -> Int { Int(actions.filter { t >= $0.time }.reduce(0.0) { $0 + $1.delta * ease((t - $1.time) / $1.duration) }.rounded()) }
        var events: [(Double, Stitcher.Motion, Bool)] = []
        for a in actions {
            switch a.source {
            case .trackpad: for k in 0..<18 { events.append((a.time + Double(k) / 60, Stitcher.Motion(pixels: a.delta / 18), false)) }
            case .key: events.append((a.time, Stitcher.Motion(unknown: 1), true))
            case .wheel: events.append((a.time, Stitcher.Motion(lines: 3), true))
            }
        }
        var input = ScrollInput(), stitcher = Stitcher(), next = 0, maxOffset = 0
        for tick in 0...60 {
            let t = Double(tick) * 0.15, cutoff = t + 0.02 - 0.016
            while next < events.count, events[next].0 <= cutoff { input.note(events[next].1, at: events[next].0, animated: events[next].2); next += 1 }
            let o = offset(at: t + 0.012)
            maxOffset = max(maxOffset, o)
            stitcher.add(makeFrame(page, offset: o, height: 1200), motion: input.take(upTo: cutoff))
        }
        assertSeamless(stitcher, page, height: maxOffset + 1200)
    }

    /// Событие, после которого страница не двигается (пробел ставит видео на паузу, выделение мышью, колесо у конца
    /// страницы), а в окне идёт анимация: ничего не вклеивается (было: +24…30 строк мусора).
    func testAnimationAfterNonScrollEventAddsNothing() {
        let page = textPage(width: 1400, lines: prose(seed: 7, count: 160))
        var phase = 0
        let credits: (CGContext, Int, Int) -> Void = { context, offset, h in
            phase += 1
            let top = 400 - offset
            context.saveGState()
            context.clip(to: CGRect(x: 300, y: h - top - 400, width: 800, height: 400))
            context.setFillColor(CGColor(gray: 0.05, alpha: 1))
            context.fill(CGRect(x: 300, y: h - top - 400, width: 800, height: 400))
            var generator = SeededGenerator(seed: 99)
            for line in 0..<60 {
                context.setFillColor(CGColor(gray: 0.9, alpha: 1))
                context.fill(CGRect(x: 350, y: h - (top + line * 40 - phase * 24) - 14, width: Int.random(in: 200...700, using: &generator), height: 14))
            }
            context.restoreGState()
        }
        let panorama: (CGContext, Int, Int) -> Void = { context, offset, h in
            phase += 1
            let top = 300 - offset
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: h - top - 700, width: 1400, height: 700))
            var generator = SeededGenerator(seed: 5)
            for line in 0..<80 {
                let y = top + line * 30 - phase * 30
                context.setFillColor(CGColor(gray: CGFloat(Int.random(in: 0...255, using: &generator)) / 255, alpha: 1))
                context.fill(CGRect(x: 0, y: h - y - 30, width: 1400, height: 30))
                context.setFillColor(CGColor(gray: CGFloat(Int.random(in: 0...255, using: &generator)) / 255, alpha: 1))
                context.fill(CGRect(x: Int.random(in: 0...1000, using: &generator), y: h - y - 22, width: 300, height: 14))
            }
            context.restoreGState()
        }
        for (name, animation) in [("титры", credits), ("панорама во всю ширину", panorama)] {
            for (event, motion) in [("клавиша", Stitcher.Motion(unknown: 1)), ("колесо у конца страницы", Stitcher.Motion(pixels: 200)), ("событий нет", nil)] {
                phase = 0
                var stitcher = Stitcher()
                stitcher.add(makeFrame(page, offset: 0, height: 1200, overlay: animation), motion: motion == nil ? nil : Stitcher.Motion())
                for k in 0..<8 {
                    let m: Stitcher.Motion? = motion == nil ? nil : (k == 0 ? motion : Stitcher.Motion())
                    stitcher.add(makeFrame(page, offset: 0, height: 1200, overlay: animation), motion: m)
                }
                XCTAssertEqual(stitcher.height, 1200, "\(name), \(event)")
            }
        }
    }

    // MARK: - Ревью 3: редкий текст среди пустоты

    /// Строки итога и эталона с рисунком (не однотонные): лишние — уже снятые строки, вклеенные повторно; пропавшие —
    /// строки страницы, которых нет в итоге.
    private func textRows(_ got: CGImage, _ want: CGImage) -> (extra: Int, lost: Int) {
        // Строки — как `Data` (хеш и сравнение в библиотеке, быстро и в отладочной сборке); однотонная строка — та, что
        // совпадает сама с собой со сдвигом на пиксель.
        func rows(_ image: CGImage) -> [Data] {
            let data = Data(pixels(image)), stride = image.width * 4
            return (0..<image.height).compactMap { r in
                let row = data.subdata(in: r * stride..<(r + 1) * stride)
                let plain = row.withUnsafeBytes { memcmp($0.baseAddress!, $0.baseAddress! + 4, stride - 4) == 0 }
                return plain ? nil : row
            }
        }
        var count: [Data: Int] = [:]
        for row in rows(want) { count[row, default: 0] += 1 }
        var extra = 0
        for row in rows(got) {
            count[row, default: 0] -= 1
            if count[row]! < 0 { extra += 1 }
        }
        return (extra, count.values.filter { $0 > 0 }.reduce(0, +))
    }

    /// Прокрутка шагом `step` в режиме `mode`: строк текста не прибавилось и не пропало — или был честный `.lost`.
    /// nil — всё в порядке, иначе — что не так.
    /// `full` — склеено целиком: ни одной пропавшей строки текста, даже с `.lost`.
    private func textKept(_ page: CGImage, step: Int, mode: String, _ name: String, full: Bool = false) -> String? {
        var stitcher = Stitcher()
        var results: [Stitcher.Result] = []
        let offsets = Array(Swift.stride(from: 0, through: page.height - 1200, by: step))
        for (k, offset) in offsets.enumerated() {
            let motion: Stitcher.Motion? = switch mode {
            case "unknown": k == 0 ? Stitcher.Motion() : Stitcher.Motion(unknown: 1)
            case "lines": k == 0 ? Stitcher.Motion() : Stitcher.Motion(lines: Double(step) / 40)
            case "pixels": k == 0 ? Stitcher.Motion() : Stitcher.Motion(pixels: Double(step))
            case "pages": k == 0 ? Stitcher.Motion() : Stitcher.Motion(pages: 1)
            default: nil
            }
            results.append(stitcher.add(makeFrame(page, offset: offset, height: 1200), motion: motion))
        }
        guard let image = stitcher.makeImage() else { return "нет изображения: \(name)" }
        let reference = makeContext(width: page.width, height: offsets.last! + 1200)
        reference.draw(page, in: CGRect(x: 0, y: offsets.last! + 1200 - page.height, width: page.width, height: page.height))
        let rows = textRows(image, reference.makeImage()!)
        if rows.extra > 0 { return "повторено строк текста \(rows.extra): \(name), шаг \(step), \(mode)" }
        if rows.lost > 0, full || !results.contains(.lost) {
            return "пропало строк текста \(rows.lost)\(results.contains(.lost) ? "" : " без .lost"): \(name), шаг \(step), \(mode)"
        }
        return nil
    }

    /// Прогоны независимы — параллельно (отладочная сборка медленная), проверки — после.
    private func assertTextKept(_ runs: [(page: CGImage, step: Int, mode: String, name: String)], full: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) {
        var problems = [String?](repeating: nil, count: runs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: runs.count) { (i: Int) in
            let run = runs[i]
            let problem = textKept(run.page, step: run.step, mode: run.mode, run.name, full: full)
            lock.lock(); problems[i] = problem; lock.unlock()
        }
        for problem in problems.compactMap({ $0 }) { XCTFail(problem, file: file, line: line) }
    }

    private func sparsePage(gap: Int, count: Int = 6) -> CGImage {
        var lines: [String] = []
        for i in 0..<count {
            lines.append("Раздел \(i + 1). Заголовок с уникальным текстом \(i * 37 % 91)")
            lines += Array(repeating: "", count: gap)
        }
        return textPage(width: 1400, lines: lines)
    }

    /// Заголовки через `gap` пустых строк (лендинг, слайды, письмо): было — заголовки повторялись (до +58% высоты) или
    /// пропадали, кадры `.appended` и `.unchanged` без предупреждения.
    func testSparseHeadingsAmongBlankSpace() {
        var runs: [(page: CGImage, step: Int, mode: String, name: String)] = []
        for gap in [10, 12, 15, 18] {
            let page = sparsePage(gap: gap)
            for step in [120, 150, 200, 300, 450] {
                for mode in ["изображение", "unknown", "lines"] { runs.append((page, step, mode, "редкий текст, промежуток \(gap)")) }
            }
        }
        assertTextKept(runs)
    }

    /// Проза, 80 пустых строк с двумя бледными строками и тонкой линией, снова проза (было: +609 лишних строк).
    func testFaintTextAndRuleInBlankStretch() {
        let prose = (0..<60).map { "Строка прозы номер \($0): быстрая коричневая лиса перепрыгивает ленивую собаку \($0 * 7919 % 1000)" }
        var lines = Array(prose.prefix(30)) + Array(repeating: "", count: 80) + Array(prose.suffix(30))
        lines[50] = "ФАНТОМ: бледная подпись, которую нельзя потерять 1234"
        lines[80] = "ФАНТОМ-2: ещё одна бледная строка 5678"
        let text = textPage(width: 1400, lines: lines)
        var runs: [(page: CGImage, step: Int, mode: String, name: String)] = []
        for rule in [false, true] {
            let context = makeContext(width: text.width, height: text.height)
            context.draw(text, in: CGRect(x: 0, y: 0, width: text.width, height: text.height))
            for i in [50, 80] {
                context.setFillColor(CGColor(gray: 1, alpha: 0.6))
                context.fill(CGRect(x: 0, y: CGFloat(text.height) - (16 + CGFloat(i) * 20) * 2 - 40, width: 1400, height: 44))
            }
            if rule {
                context.setFillColor(CGColor(gray: 0.85, alpha: 1))
                context.fill(CGRect(x: 48, y: CGFloat(text.height) - (16 + 65 * 20) * 2, width: 1400 - 96, height: 2))
            }
            let page = context.makeImage()!
            for step in [150, 300] {
                for mode in ["изображение", "unknown", "lines"] { runs.append((page, step, mode, "бледный текст, линия \(rule)")) }
            }
        }
        assertTextKept(runs)
    }

    /// `.lost` на блоке одинаковых строк помечен — HUD советует вернуться к отличающемуся месту, а не «медленнее».
    func testLossOnIdenticalLinesIsReported() {
        let lines = prose(seed: 7, count: 30) + Array(repeating: "2026-10-17 09:41:39.123 INFO  heartbeat ok", count: 45) + prose(seed: 8, count: 40)
        let page = textPage(width: 1400, lines: lines, font: mono)
        var stitcher = Stitcher()
        var reported = false
        for offset in Swift.stride(from: 0, through: page.height - 1200, by: 300) where stitcher.add(makeFrame(page, offset: offset, height: 1200)) == .lost {
            reported = reported || stitcher.lostOnRepeats
        }
        XCTAssertTrue(reported)
        // Рывок на другую страницу — не «одинаковые строки».
        var jump = Stitcher()
        jump.add(makeFrame(page, offset: 0, height: 1200))
        XCTAssertEqual(jump.add(makeFrame(textPage(width: 1400, lines: prose(seed: 99, count: 80)), offset: 0, height: 1200)), .lost)
        XCTAssertFalse(jump.lostOnRepeats)
    }

    // MARK: - Повторное ревью 3 (R1, R2): пустота не короче кадра

    /// Пустота между заголовками не короче кадра (30 и 60 строк = 1200 и 2400 px при кадре 1200), медленная прокрутка
    /// и PageDown: было — после первого пустого кадра «без изменений» до конца, все следующие заголовки пропадали
    /// молча. Теперь склейка идёт через пустоту (она сжимается), и каждый заголовок — один раз.
    func testBlankAtLeastAFrameTallKeepsEveryHeading() {
        var runs: [(page: CGImage, step: Int, mode: String, name: String)] = []
        for gap in [30, 60] {
            let page = sparsePage(gap: gap, count: 5)
            for step in [120, 300] {
                for mode in ["изображение", "pixels"] { runs.append((page, step, mode, "пустота \(gap) строк")) }
            }
            for step in [700, 1120] {
                for mode in ["unknown", "pages"] { runs.append((page, step, mode, "пустота \(gap) строк, PageDown")) }
            }
        }
        assertTextKept(runs, full: true)
    }

    /// Пустота 25 строк (1000 px) и быстрая прокрутка с подсказкой: было (f520651) — `.lost` с 4–5-го кадра до конца.
    func testBlankShorterThanFrameWithFastHintedScroll() {
        let page = sparsePage(gap: 25, count: 8)
        var runs: [(page: CGImage, step: Int, mode: String, name: String)] = []
        for step in [300, 450] {
            for mode in ["pixels", "lines"] { runs.append((page, step, mode, "пустота 25 строк")) }
        }
        assertTextKept(runs, full: true)
    }

    // MARK: - Чат: прокрутка вверх, обои, колесо

    private struct ChatLayout {
        var wallpaper: Bool
        var sidebar: Bool
        var bars: Bool
    }

    /// Лента сообщений на прозрачном фоне: пузыри слева и справа, время, серии одинаковых «Ок».
    private func chatFeed(count: Int, width: Int, run: Int = 3, seed: UInt64 = 11) -> CGImage {
        var generator = SeededGenerator(seed: seed)
        let words = ["привет", "как дела", "созвонимся", "завтра", "в пятницу", "отправил файл", "посмотри", "отлично", "спасибо"]
        var messages: [(mine: Bool, lines: [String], time: String)] = []
        for i in 0..<count {
            if i % 9 == 4 {
                for _ in 0..<run { messages.append((true, ["Ок"], "12:00")) }
                continue
            }
            let lines: [String] = (0..<Int.random(in: 1...3, using: &generator)).map { (k: Int) -> String in
                let text = (0..<Int.random(in: 2...5, using: &generator)).map { (_: Int) -> String in words.randomElement(using: &generator)! }
                return text.joined(separator: " ") + (k == 0 ? " #\(i)" : "")
            }
            messages.append((Bool.random(using: &generator), lines, String(format: "%02d:%02d", 9 + i / 60, i % 60)))
        }
        let font = NSFont.systemFont(ofSize: 26)
        let heights: [Int] = messages.map { (m: (mine: Bool, lines: [String], time: String)) -> Int in m.lines.count * 40 + 60 }
        let total = heights.reduce(0, +) + 20 * messages.count + 40
        let context = makeContext(width: width, height: total)
        context.clear(CGRect(x: 0, y: 0, width: width, height: total))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var y = 20
        for (message, height) in zip(messages, heights) {
            let textWidth = message.lines.map { (line: String) -> CGFloat in (line as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let bubble = max(200, Int(textWidth) + 120)
            let x = message.mine ? width - bubble - 30 : 90
            context.setFillColor(message.mine ? CGColor(red: 0.86, green: 0.97, blue: 0.8, alpha: 1) : CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: x, y: total - y - height, width: bubble, height: height),
                                   cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.fillPath()
            for (k, line) in message.lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: CGFloat(x + 20), y: CGFloat(total - y - 16 - (k + 1) * 40)),
                                        withAttributes: [.font: font, .foregroundColor: NSColor.black])
            }
            (message.time as NSString).draw(at: NSPoint(x: CGFloat(x + bubble - 90), y: CGFloat(total - y - height + 8)),
                                            withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor(white: 0.35, alpha: 1)])
            y += height + 20
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    /// Неподвижные обои с узором (как в Telegram): светлые завитки, стоят на месте, пока едут пузыри.
    private func wallpaper(width: Int, height: Int) -> CGImage {
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(red: 0.8, green: 0.87, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = SeededGenerator(seed: 99)
        context.setStrokeColor(CGColor(red: 0.7, green: 0.8, blue: 0.66, alpha: 1))
        context.setLineWidth(3)
        for _ in 0..<500 {
            let x = CGFloat(Int.random(in: 0..<width, using: &generator)), y = CGFloat(Int.random(in: 0..<height, using: &generator))
            context.strokeEllipse(in: CGRect(x: x, y: y, width: CGFloat(Int.random(in: 30...60, using: &generator)),
                                             height: CGFloat(Int.random(in: 24...40, using: &generator))))
        }
        return context.makeImage()!
    }

    /// Окно мессенджера 1400×1200: шапка 120 px (имя), поле ввода 100 px, слева список чатов 300 px; лента — строки
    /// `[offset, offset + видимая)`. `wall == nil` — сплошной фон.
    private func chatFrame(_ feed: CGImage, offset: Int, _ layout: ChatLayout, wall: CGImage?, background: Bool = true) -> CGImage {
        let width = 1400, height = 1200, left = layout.sidebar ? 300 : 0
        let top = layout.bars ? 120 : 0, bottom = layout.bars ? 100 : 0
        let context = makeContext(width: width, height: height)
        if let wall, background {
            context.draw(wall, in: CGRect(x: left, y: 0, width: wall.width, height: wall.height))
        } else {
            context.setFillColor(background ? CGColor(red: 0.93, green: 0.9, blue: 0.86, alpha: 1) : CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.saveGState()
        context.clip(to: CGRect(x: left, y: bottom, width: width - left, height: height - top - bottom))
        context.draw(feed, in: CGRect(x: left, y: height - top + offset - feed.height, width: feed.width, height: feed.height))
        context.restoreGState()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if layout.sidebar {
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: left, height: height))
            for i in 0..<14 {
                ("Чат \(i + 1)" as NSString).draw(at: NSPoint(x: 90, y: height - 60 - i * 84),
                                                  withAttributes: [.font: NSFont.boldSystemFont(ofSize: 26), .foregroundColor: NSColor.black])
            }
        }
        if layout.bars {
            context.setFillColor(CGColor(gray: 0.97, alpha: 1))
            context.fill(CGRect(x: 0, y: height - top, width: width, height: top))
            context.fill(CGRect(x: 0, y: 0, width: width, height: bottom))
            ("Анна Петрова" as NSString).draw(at: NSPoint(x: left + 120, y: height - 70),
                                              withAttributes: [.font: NSFont.boldSystemFont(ofSize: 30), .foregroundColor: NSColor.black])
            ("Сообщение" as NSString).draw(at: NSPoint(x: left + 50, y: 35),
                                           withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    /// Строки колонки чата с тёмными пикселями (текст, время): ключ строки — их места и яркость. Обои и пузыри светлые
    /// и не входят — эталон без обоев сравним с итогом поверх обоев.
    private func darkRows(_ image: CGImage, from left: Int) -> [Int: Int] {
        let data = pixels(image), stride = image.width * 4
        var out: [Int: Int] = [:]
        for r in 0..<image.height {
            var key = 5381, dark = false
            for x in left..<image.width {
                let i = r * stride + x * 4
                let value = (Int(data[i]) + 2 * Int(data[i + 1]) + Int(data[i + 2])) / 4
                if value < 110 {
                    dark = true
                    key = (key &* 33) &+ x &* 7 &+ value
                }
            }
            if dark { out[key, default: 0] += 1 }
        }
        return out
    }

    /// Съёмка чата: смещения ленты и события кадров; итог — каждая строка текста ленты, шапки и поля ввода ровно один раз.
    /// `allowLost` — недостача допустима, только если о ней предупредил `.lost` (повторов нет никогда).
    private func chatProblem(_ feed: CGImage, _ layout: ChatLayout, offsets: [Int], motions: [Stitcher.Motion?], _ name: String,
                             allowLost: Bool = false, wall given: CGImage? = nil) -> String? {
        let wall: CGImage? = layout.wallpaper ? given ?? wallpaper(width: layout.sidebar ? 1100 : 1400, height: 1200) : nil
        var stitcher = Stitcher()
        var warned = false
        for (offset, motion) in zip(offsets, motions) {
            if stitcher.add(chatFrame(feed, offset: offset, layout, wall: wall), motion: motion) == .lost { warned = true }
        }
        guard let image = stitcher.makeImage() else { return "нет изображения: \(name)" }
        let span = 1200 - (layout.bars ? 220 : 0)
        let low = offsets.min()!, high = offsets.max()! + span
        // Эталон: шапка, лента [low, high), поле ввода — без обоев и фона.
        let tall = chatTall(feed, rows: low..<high, layout)
        let left = layout.sidebar ? 300 : 0
        var want = darkRows(tall, from: left)
        for (key, count) in darkRows(image, from: left) { want[key, default: 0] -= count }
        let extra = -want.values.filter { $0 < 0 }.reduce(0, +), lost = want.values.filter { $0 > 0 }.reduce(0, +)
        if extra > 0 || lost > 0 && !(allowLost && warned) { return "\(name): лишних строк текста \(extra), пропало \(lost), высота \(image.height)/\(tall.height)" }
        return nil
    }

    private func chatTall(_ feed: CGImage, rows: Range<Int>, _ layout: ChatLayout) -> CGImage {
        let top = layout.bars ? 120 : 0, bottom = layout.bars ? 100 : 0
        let window = chatFrame(feed, offset: rows.lowerBound, layout, wall: nil, background: false)
        let context = makeContext(width: 1400, height: top + rows.count + bottom)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1400, height: context.height))
        let left = layout.sidebar ? 300 : 0
        context.saveGState()
        context.clip(to: CGRect(x: left, y: bottom, width: 1400 - left, height: rows.count))
        context.draw(feed, in: CGRect(x: left, y: context.height - top + rows.lowerBound - feed.height, width: feed.width, height: feed.height))
        context.restoreGState()
        // Шапка и поле ввода — из кадра окна.
        if layout.bars {
            context.draw(window.cropping(to: CGRect(x: 0, y: 0, width: 1400, height: top))!,
                         in: CGRect(x: 0, y: context.height - top, width: 1400, height: top))
            context.draw(window.cropping(to: CGRect(x: 0, y: 1200 - bottom, width: 1400, height: bottom))!,
                         in: CGRect(x: 0, y: 0, width: 1400, height: bottom))
        }
        return context.makeImage()!
    }

    /// Колесо мыши: щелчки по 1–3 строки (40 px) без точных дельт, приложение доезжает анимацией 0,3 с; события —
    /// через `ScrollInput`, как в `ScrollCapture`. Вверх — от конца переписки к началу.
    private func wheelScroll(maxOffset: Int, up: Bool) -> (offsets: [Int], motions: [Stitcher.Motion?]) {
        var input = ScrollInput()
        var generator = SeededGenerator(seed: 5)
        var position = Double(up ? maxOffset : 0), target = position, click = 0.2
        var animation: (start: Double, from: Double, to: Double)?
        var offsets = [Int(position)], motions: [Stitcher.Motion?] = [Stitcher.Motion()]
        let end = up ? 0.0 : Double(maxOffset)
        var time = 0.15
        while offsets.count < 400 {
            while click < time, target != end {
                let lines = Int.random(in: 1...3, using: &generator)
                let next = min(Double(maxOffset), max(0, target + Double(lines * 40) * (up ? -1 : 1)))
                animation = (click, target, next)
                target = next
                input.note(Stitcher.Motion(lines: Double(lines) * (up ? -1 : 1)), at: click, animated: true)
                click += Double.random(in: 0.08...0.3, using: &generator)
            }
            if let animation {
                let progress = min(1, (time - animation.start) / 0.3)
                position = animation.from + (animation.to - animation.from) * (1 - pow(1 - progress, 3))
            }
            offsets.append(Int(position.rounded()))
            motions.append(input.take(upTo: time))
            if position == end, target == end { break }
            time += 0.15
        }
        return (offsets, motions)
    }

    /// Главный сценарий чата: колесо мыши вверх, в историю, — по сплошному фону и по неподвижным обоям, со списком
    /// чатов слева, шапкой и полем ввода. Было (1.6.5): склейка росла только вниз — «ничего не происходит».
    func testChatScrolledUpWithMouseWheel() {
        let feed = chatFeed(count: 24, width: 1100)
        let layouts: [(ChatLayout, String)] = [(ChatLayout(wallpaper: false, sidebar: true, bars: true), "сплошной фон"),
                                               (ChatLayout(wallpaper: true, sidebar: true, bars: true), "обои")]
        var problems = [String?](repeating: nil, count: layouts.count * 2)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: problems.count) { (i: Int) in
            let (layout, name) = layouts[i / 2]
            let up = i % 2 == 0
            let scroll = wheelScroll(maxOffset: feed.height - 980, up: up)
            let problem = chatProblem(feed, layout, offsets: scroll.offsets, motions: scroll.motions, "\(name), колесо \(up ? "вверх" : "вниз")")
            lock.lock(); problems[i] = problem; lock.unlock()
        }
        for problem in problems.compactMap({ $0 }) { XCTFail(problem) }
    }

    /// Только по изображению (монитор событий не работает), шаг 240 px: обои стоят, едут только пузыри — большая
    /// часть кадра неподвижна. Было: «без изменений» и вниз, и вверх. Обои вместе со списком чатов без событий в
    /// начале съёмки бывают нераспознаны (модель обоев ещё пуста) — тогда честный `.lost`, но не повтор и не тишина.
    func testChatOverStaticWallpaperByImageOnly() {
        let feed = chatFeed(count: 24, width: 1100)
        let maxOffset = feed.height - 980
        let layouts: [ChatLayout] = [ChatLayout(wallpaper: true, sidebar: false, bars: true), ChatLayout(wallpaper: true, sidebar: true, bars: true)]
        var problems = [String?](repeating: nil, count: layouts.count * 2)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: problems.count) { (i: Int) in
            let up = i % 2 == 0
            var offsets: [Int] = up ? Array(Swift.stride(from: maxOffset, through: 0, by: -240)) : Array(Swift.stride(from: 0, through: maxOffset, by: 240))
            if offsets.last != (up ? 0 : maxOffset) { offsets.append(up ? 0 : maxOffset) }
            let motions = [Stitcher.Motion?](repeating: nil, count: offsets.count)
            let problem = chatProblem(feed, layouts[i / 2], offsets: offsets, motions: motions,
                                      "обои\(layouts[i / 2].sidebar ? " и список" : ""), \(up ? "вверх" : "вниз")",
                                      allowLost: layouts[i / 2].sidebar)
            lock.lock(); problems[i] = problem; lock.unlock()
        }
        for problem in problems.compactMap({ $0 }) { XCTFail(problem) }
    }

    /// Смена направления (ревью 5): вверх в историю, вниз дальше кадра и за первый кадр, снова вверх — с сериями
    /// одинаковых «Ок», только по изображению и с трекпадом. Было: другая сторона находила ложный «точный» сдвиг
    /// без общих строк с её дальним кадром и вклеивала сотни уже снятых строк. Лишнего текста нет никогда;
    /// честный `.lost` допустим.
    func testChatDirectionChangeNeverDuplicates() {
        let feed = chatFeed(count: 30, width: 1100)
        let maxOffset = feed.height - 980
        let routes: [(String, [Double])] = [("середина↓↑↓", [0.5, 0.8, 0.2, 0.9]), ("конец↑↓↑", [1.0, 0.6, 0.8, 0.0]),
                                            ("разворот у первого", [0.5, 0.3, 0.5, 0.75, 0.45])]
        let layouts: [(ChatLayout, String)] = [(ChatLayout(wallpaper: false, sidebar: true, bars: true), "шапка и список"),
                                               (ChatLayout(wallpaper: false, sidebar: false, bars: false), "без рамок"),
                                               (ChatLayout(wallpaper: true, sidebar: false, bars: true), "обои")]
        var runs: [(name: String, layout: ChatLayout, offsets: [Int], motions: [Stitcher.Motion?])] = []
        for (name, points) in routes {
            for (layout, layoutName) in layouts { for pixels in [false, true] {
                var offsets: [Int] = [Int(points[0] * Double(maxOffset))]
                for point in points.dropFirst() {
                    let target = Int(point * Double(maxOffset))
                    while offsets.last! != target {
                        let last = offsets.last!
                        offsets.append(last < target ? min(target, last + 240) : max(target, last - 240))
                    }
                }
                let motions: [Stitcher.Motion?] = offsets.indices.map { (i: Int) -> Stitcher.Motion? in
                    guard pixels else { return nil }
                    return Stitcher.Motion(pixels: Double(i == 0 ? 0 : offsets[i] - offsets[i - 1]))
                }
                runs.append(("\(name), \(layoutName)\(pixels ? ", трекпад" : "")", layout, offsets, motions))
            } }
        }
        var problems = [String?](repeating: nil, count: runs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: runs.count) { (i: Int) in
            let problem = chatProblem(feed, runs[i].layout, offsets: runs[i].offsets, motions: runs[i].motions, runs[i].name,
                                      allowLost: true)
            lock.lock(); problems[i] = problem; lock.unlock()
        }
        for problem in problems.compactMap({ $0 }) { XCTFail(problem) }
    }

    /// Генератор стенда ревью (`rev5/zz2`): тот же псевдослучайный ряд, что и там, — кадры совпадают с найденным случаем.
    private struct ReviewRandom {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % n
        }
    }

    /// Лента стенда ревью: каждые 5 сообщений — серия из `run` одинаковых «Ок 12:00».
    private func reviewFeed(count: Int, run: Int, seed: UInt64) -> CGImage {
        var random = ReviewRandom(state: seed)
        let words = ["привет", "как дела", "созвонимся", "завтра", "в пятницу", "отправил файл", "посмотри", "отлично"]
        var messages: [(mine: Bool, lines: [String], time: String)] = []
        for i in 0..<count {
            if i % 5 == 2 {
                for _ in 0..<run { messages.append((true, ["Ок"], "12:00")) }
                continue
            }
            let n = 1 + random.next(2)
            let lines: [String] = (0..<n).map { (k: Int) -> String in
                let count = 2 + random.next(3)
                let text: [String] = (0..<count).map { (_: Int) -> String in words[random.next(words.count)] }
                return text.joined(separator: " ") + (k == 0 ? " #\(i)" : "")
            }
            messages.append((random.next(2) == 0, lines, String(format: "%02d:%02d", 9 + i / 60 % 12, i % 60)))
        }
        let width = 1100, font = NSFont.systemFont(ofSize: 26)
        let heights: [Int] = messages.map { (m: (mine: Bool, lines: [String], time: String)) -> Int in m.lines.count * 40 + 60 }
        let total = heights.reduce(0, +) + 20 * messages.count + 40
        let context = makeContext(width: width, height: total)
        context.clear(CGRect(x: 0, y: 0, width: width, height: total))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        var y = 20
        for (message, height) in zip(messages, heights) {
            let textWidth = message.lines.map { (line: String) -> CGFloat in (line as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
            let bubble = max(200, Int(textWidth) + 120)
            let x = message.mine ? width - bubble - 30 : 90
            context.setFillColor(message.mine ? CGColor(red: 0.86, green: 0.97, blue: 0.8, alpha: 1) : CGColor(gray: 1, alpha: 1))
            context.addPath(CGPath(roundedRect: CGRect(x: x, y: total - y - height, width: bubble, height: height),
                                   cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.fillPath()
            for (k, line) in message.lines.enumerated() {
                (line as NSString).draw(at: NSPoint(x: CGFloat(x + 20), y: CGFloat(total - y - 16 - k * 40) - 26 * 1.3),
                                        withAttributes: [.font: font, .foregroundColor: NSColor.black])
            }
            (message.time as NSString).draw(at: NSPoint(x: CGFloat(x + bubble - 90), y: CGFloat(total - y - height + 40) - 20 * 1.3),
                                            withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor(white: 0.35, alpha: 1)])
            y += height + 20
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    /// Обои стенда ревью.
    private func reviewWallpaper() -> CGImage {
        let width = 1100, height = 1200
        let context = makeContext(width: width, height: height)
        context.setFillColor(CGColor(red: 0.8, green: 0.87, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var state: UInt64 = 99
        context.setStrokeColor(CGColor(red: 0.7, green: 0.8, blue: 0.66, alpha: 1))
        context.setLineWidth(3)
        for _ in 0..<500 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let x = CGFloat(state >> 40 & 2047) / 2047 * CGFloat(width), y = CGFloat(state >> 20 & 2047) / 2047 * CGFloat(height)
            context.strokeEllipse(in: CGRect(x: x, y: y, width: 30 + CGFloat(state & 31), height: 24 + CGFloat(state >> 8 & 15)))
        }
        return context.makeImage()!
    }

    /// Повторное ревью 5 (R1): обои, шапка и список чатов, серии по 5 одинаковых «Ок», вниз, вверх за первый кадр и вниз
    /// за дальний, шаг 180, по изображению и с трекпадом; в каждой точке разворота — кадр без движения. Было (320c540):
    /// после потери места слой обоев находил ложное «назад», оно становилось местом, и от него проходило ложное
    /// «вперёд» — +1213 уже снятых строк. Лишнего текста нет; честный `.lost` допустим.
    func testWallpaperWithRepeatedBubblesNeverDuplicatesAfterLoss() {
        let feed = reviewFeed(count: 80, run: 5, seed: 59), wall = reviewWallpaper()
        let maxOffset = feed.height - 980
        // «Качели» (Z9) ловят то же, но вдвое дольше в отладочной сборке; они — на стенде.
        let routes: [(String, [Double])] = [("середина↓↑↓", [0.5, 0.75, 0.25, 0.95])]
        let layout = ChatLayout(wallpaper: true, sidebar: true, bars: true)
        var runs: [(name: String, offsets: [Int], motions: [Stitcher.Motion?])] = []
        for (name, points) in routes {
            for pixels in [false, true] {
                let targets: [Int] = points.map { (point: Double) -> Int in Int(point * Double(maxOffset)) }
                var offsets = [targets[0]], motions: [Stitcher.Motion?] = [pixels ? Stitcher.Motion() : nil]
                for target in targets.dropFirst() {
                    while offsets.last! != target {
                        let last = offsets.last!, next = last < target ? min(target, last + 180) : max(target, last - 180)
                        offsets.append(next)
                        motions.append(pixels ? Stitcher.Motion(pixels: Double(next - last)) : nil)
                    }
                    offsets.append(target)
                    motions.append(pixels ? Stitcher.Motion() : nil)
                }
                runs.append(("\(name)\(pixels ? ", трекпад" : "")", offsets, motions))
            }
        }
        var problems = [String?](repeating: nil, count: runs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: runs.count) { (i: Int) in
            let problem = chatProblem(feed, layout, offsets: runs[i].offsets, motions: runs[i].motions, "обои, «Ок» × 5, " + runs[i].name,
                                      allowLost: true, wall: wall)
            lock.lock(); problems[i] = problem; lock.unlock()
        }
        for problem in problems.compactMap({ $0 }) { XCTFail(problem) }
    }

    // MARK: - Терминал: кадр посреди перерисовки

    /// Кадр, снятый посреди перерисовки: верх `tear` строк — уже на месте `upper`, остальное — ещё на месте `lower`.
    private func tornFrame(_ page: CGImage, lower: Int, upper: Int, tear: Int, height: Int,
                           overlay: @escaping (CGContext, Int, Int) -> Void) -> CGImage {
        let all = CGRect(x: 0, y: 0, width: page.width, height: height)
        let context = makeContext(width: page.width, height: height)
        context.draw(makeFrame(page, offset: lower, height: height, overlay: overlay), in: all)
        context.clip(to: CGRect(x: 0, y: height - tear, width: page.width, height: tear))
        context.draw(makeFrame(page, offset: upper, height: height, overlay: overlay), in: all)
        return context.makeImage()!
    }

    /// Терминал (1.6.6, журнал пользователя): колесом вверх, в историю, внизу неподвижное поле ввода. Один кадр снят
    /// посреди перерисовки: верх экрана уже на новом месте, остальное ещё на старом, и разрыв — внутри его новых строк
    /// (перекрытие целиком в старой части, при склейке не видно). Было: кадр приклеен со сдвигом 264 при 528 по
    /// событиям, его верх — строки с другого места (на шве «перетёртая» строка), дальше чуть прокрутили и остановились —
    /// и `.lost noMatch` до конца съёмки. Теперь та склейка откатывается: каждая строка ровно один раз, место найдено.
    func testTornFrameMidRedrawIsUndone() {
        let page = textPage(width: 1400, lines: prose(seed: 21, count: 80), font: mono)
        let height = 1000, step = 264, torn = 4
        let box: (CGContext, Int, Int) -> Void = { (context: CGContext, _: Int, _: Int) in
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1400, height: 140))
            context.setFillColor(CGColor(gray: 0.9, alpha: 1))
            for i in 0..<20 { context.fill(CGRect(x: 40 + i * 64, y: 40 + i % 3 * 24, width: 36, height: 14)) }
        }
        // Кадр: низ на месте `lower`, верх (200 строк) — на `upper`, настоящем месте. После рваного кадра — ещё строка
        // вверх, и экран стоит.
        let offsets: [Int] = (0...torn + 1).map { page.height - height - $0 * step }
        var frames: [(lower: Int, upper: Int)] = offsets.prefix(torn).map { ($0, $0) }
        frames.append((offsets[torn], offsets[torn + 1]))
        frames.append((offsets[torn + 1], offsets[torn + 1]))
        frames += [(lower: Int, upper: Int)](repeating: (offsets[torn + 1] - 33, offsets[torn + 1] - 33), count: 3)
        let top = frames.last!.upper
        let want = makeFrame(page.cropping(to: CGRect(x: 0, y: top, width: page.width, height: page.height - top))!, offset: 0,
                             height: page.height - top, overlay: box)
        for events in [true, false] {
            var stitcher = Stitcher()
            var undone = 0, last = Stitcher.Result.first
            for (i, shown) in frames.enumerated() {
                let frame = shown.lower == shown.upper ? makeFrame(page, offset: shown.upper, height: height, overlay: box)
                    : tornFrame(page, lower: shown.lower, upper: shown.upper, tear: 200, height: height, overlay: box)
                let moved: Double = i == 0 ? 0 : Double(shown.upper - frames[i - 1].upper)
                last = stitcher.add(frame, motion: events ? Stitcher.Motion(pixels: moved) : nil)
                if stitcher.trace.undone { undone += 1 }
            }
            let name = events ? "с событиями" : "по изображению"
            guard let image = stitcher.makeImage() else { XCTFail("нет изображения: \(name)"); continue }
            let rows = textRows(image, want)
            XCTAssertEqual(rows.extra, 0, "лишние строки: \(name)")
            XCTAssertEqual(rows.lost, 0, "пропавшие строки: \(name)")
            XCTAssertNotEqual(last, .lost, "место потеряно до конца: \(name)")
            if events { XCTAssertEqual(undone, 1, "откат") }
        }
    }

    /// Журнал съёмки: как решён кадр — сторона склейки, сдвиг, источник.
    func testTraceTellsDirectionAndSource() {
        let page = textPage(width: 1400, lines: prose(seed: 3, count: 120))
        var stitcher = Stitcher()
        XCTAssertEqual(stitcher.add(makeFrame(page, offset: 1200, height: 1200)), .first)
        XCTAssertEqual(stitcher.add(makeFrame(page, offset: 1500, height: 1200)), .appended)
        XCTAssertEqual(stitcher.trace.up, false)
        XCTAssertEqual(stitcher.trace.shift, 300)
        XCTAssertEqual(stitcher.trace.source, .exact)
        // Назад, внутрь снятого, — не новое.
        XCTAssertEqual(stitcher.add(makeFrame(page, offset: 1300, height: 1200)), .unchanged)
        XCTAssertEqual(stitcher.trace.reason, .back)
        // Дальше назад, за первый кадр, — склейка вверх.
        XCTAssertEqual(stitcher.add(makeFrame(page, offset: 900, height: 1200)), .appended)
        XCTAssertEqual(stitcher.trace.up, true)
        XCTAssertEqual(stitcher.trace.shift, 300)
        XCTAssertEqual(stitcher.add(makeFrame(page, offset: 900, height: 1200), motion: Stitcher.Motion()), .unchanged)
        XCTAssertEqual(stitcher.trace.reason, .noMotion)
        assertSeamless(stitcher, page.cropping(to: CGRect(x: 0, y: 900, width: 1400, height: 1800))!, height: 1800)
    }
}

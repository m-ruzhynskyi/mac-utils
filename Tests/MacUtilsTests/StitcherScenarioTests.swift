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
    private func textKept(_ page: CGImage, step: Int, mode: String, _ name: String) -> String? {
        var stitcher = Stitcher()
        var results: [Stitcher.Result] = []
        let offsets = Array(Swift.stride(from: 0, through: page.height - 1200, by: step))
        for (k, offset) in offsets.enumerated() {
            let motion: Stitcher.Motion? = switch mode {
            case "unknown": k == 0 ? Stitcher.Motion() : Stitcher.Motion(unknown: 1)
            case "lines": k == 0 ? Stitcher.Motion() : Stitcher.Motion(lines: Double(step) / 40)
            default: nil
            }
            results.append(stitcher.add(makeFrame(page, offset: offset, height: 1200), motion: motion))
        }
        guard let image = stitcher.makeImage() else { return "нет изображения: \(name)" }
        let reference = makeContext(width: page.width, height: offsets.last! + 1200)
        reference.draw(page, in: CGRect(x: 0, y: offsets.last! + 1200 - page.height, width: page.width, height: page.height))
        let rows = textRows(image, reference.makeImage()!)
        if rows.extra > 0 { return "повторено строк текста \(rows.extra): \(name), шаг \(step), \(mode)" }
        if rows.lost > 0, !results.contains(.lost) { return "пропало строк текста \(rows.lost) без .lost: \(name), шаг \(step), \(mode)" }
        return nil
    }

    /// Прогоны независимы — параллельно (отладочная сборка медленная), проверки — после.
    private func assertTextKept(_ runs: [(page: CGImage, step: Int, mode: String, name: String)], file: StaticString = #filePath, line: UInt = #line) {
        var problems = [String?](repeating: nil, count: runs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: runs.count) { i in
            let run = runs[i]
            let problem = textKept(run.page, step: run.step, mode: run.mode, run.name)
            lock.lock(); problems[i] = problem; lock.unlock()
        }
        for problem in problems.compactMap({ $0 }) { XCTFail(problem, file: file, line: line) }
    }

    /// Заголовки через `gap` пустых строк (лендинг, слайды, письмо): было — заголовки повторялись (до +58% высоты) или
    /// пропадали, кадры `.appended` и `.unchanged` без предупреждения.
    func testSparseHeadingsAmongBlankSpace() {
        var runs: [(page: CGImage, step: Int, mode: String, name: String)] = []
        for gap in [10, 12, 15, 18] {
            var lines: [String] = []
            for i in 0..<6 { lines.append("Раздел \(i + 1). Заголовок с уникальным текстом \(i * 37 % 91)"); lines += Array(repeating: "", count: gap) }
            let page = textPage(width: 1400, lines: lines)
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
}

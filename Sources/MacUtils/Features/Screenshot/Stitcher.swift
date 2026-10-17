import CoreGraphics

/// Склеивает кадры одной области по вертикали. Чистая логика без экрана: кадры на входе, изображение на выходе.
///
/// Каждый кадр сжимается до 64 колонок в оттенках серого (строки сохранены). Строки, которые не изменились
/// между кадрами сверху и снизу, — закреплённые шапка и низ окна: сдвиг ищется только в движущейся части
/// между ними, а закреплённый низ попадает в итог один раз, в самом конце. Сдвиг проверяется по всему
/// перекрытию кадров, а не по одной полосе: так однотонные участки и повторяющиеся строки не сбивают склейку.
struct Stitcher {
    enum Result { case first, appended, unchanged, lost }

    /// Сдвиг содержимого между кадрами и закреплённые строки сверху и снизу.
    struct Match: Equatable {
        /// На сколько строк содержимое уехало вверх (> 0 — прокрутка вниз).
        var shift: Int
        var header: Int
        var footer: Int
    }

    static let columns = 64
    /// Предел итога по высоте и площади: склейка и PNG держат его в памяти целиком.
    static let maxHeight = 40_000
    static let maxPixels = 100_000_000
    /// Средняя разница пикселей строки (после отсечки), при которой строка ещё считается совпавшей.
    private static let tolerance = 5
    private static let clip = 64

    /// Высота итога в пикселях: склеенное тело и закреплённый низ.
    var height: Int { bodyHeight + footerRows }
    private(set) var isFull = false

    private var heightLimit: Int { min(Self.maxHeight, Self.maxPixels / max(width, 1)) }
    private var width = 0
    private var rows = 0
    /// Склеенное содержимое без закреплённого низа. Каждый кусочек — своя копия, а не вырезка из кадра:
    /// вырезка держала бы буфер всего кадра.
    private var chunks: [CGImage] = []
    private var bodyHeight = 0
    private var footer: CGImage?
    private var footerRows = 0
    /// Подпись самого дальнего кадра; кадры после прокрутки назад сравниваются с ним.
    private var previous: [UInt8]?
    /// Тело кончается на этой строке дальнего кадра; ниже — его закреплённый низ.
    private var bottom = 0
    /// Насколько содержимое сейчас вернулось назад от дальнего кадра (отскок в конце страницы)
    /// и подпись последнего кадра: по ней виден настоящий закреплённый низ.
    private var retreat: (rows: Int, latest: [UInt8]?) = (0, nil)

    @discardableResult
    mutating func add(_ frame: CGImage) -> Result {
        guard !isFull, let signature = Self.signature(frame) else { return .unchanged }
        guard let previous else {
            guard let copy = Self.copy(frame, rows: 0..<frame.height) else { return .unchanged }
            width = frame.width
            rows = frame.height
            chunks = [copy]
            bodyHeight = rows
            bottom = rows
            self.previous = signature
            return .first
        }
        // Размер кадра задан при старте; кадр другого размера к склейке не подходит.
        guard frame.width == width, frame.height == rows,
              let match = Self.match(previous: previous, current: signature, rows: rows) else { return .lost }
        guard match.shift > 0 else {
            // Без движения или прокрутка вверх: ждём, пока снизу снова пойдут новые строки.
            retreat = (-match.shift, match.shift < 0 ? signature : nil)
            return .unchanged
        }
        let end = rows - match.footer            // конец движущейся части нового кадра
        let start = min(bottom, end)             // строка дальнего кадра, с которой продолжается тело
        var from = start - match.shift           // та же строка в новом кадре
        // Прошлый кадр счёл строки ниже `bottom` закреплённым низом, а теперь они двигаются и успели уехать
        // под шапку: их берём из того низа. Так бывает, только когда низ стал меньше (start == bottom).
        let hidden = max(0, match.header - from)
        guard hidden <= footerRows else { return .lost }
        var patch: CGImage?
        if hidden > 0 {
            guard let footer, let piece = Self.copy(footer, rows: 0..<min(hidden, footer.height)) else { return .lost }
            patch = piece
            from += hidden
        }
        let room = heightLimit - bodyHeight - match.footer - hidden + (bottom - start)
        guard room > 0, from < end else {
            isFull = room <= 0
            return .unchanged
        }
        let count = min(end - from, room)
        guard let piece = Self.copy(frame, rows: from..<(from + count)) else { return .unchanged }
        let tail = match.footer > 0 ? Self.copy(frame, rows: end..<rows) : nil
        trimBody(bottom - start)
        if let patch { append(patch) }
        append(piece)
        footer = tail
        footerRows = tail?.height ?? 0
        bottom = from + count
        retreat = (0, nil)
        isFull = count < end - from || height >= heightLimit
        self.previous = signature
        return .appended
    }

    func makeImage() -> CGImage? {
        guard let first = chunks.first, bodyHeight > 0 else { return nil }
        let height = bodyHeight + footerRows
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = first.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: sRGB, bitmapInfo: info) else { return nil }
        var top = 0
        for chunk in chunks {
            context.draw(chunk, in: CGRect(x: 0, y: height - top - chunk.height, width: chunk.width, height: chunk.height))
            top += chunk.height
        }
        if let footer {
            context.draw(footer, in: CGRect(x: 0, y: 0, width: footer.width, height: footer.height))
        }
        guard let image = context.makeImage() else { return nil }
        // Итог кончается строками дальнего кадра подряд: его строка y — строка height - (rows - y) итога.
        guard let cut = overscroll(), let space = image.colorSpace,
              let trimmed = CGContext(data: nil, width: image.width, height: height - cut.count, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { return image }
        let start = height - (rows - cut.lowerBound)
        if let above = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: start)) {
            trimmed.draw(above, in: CGRect(x: 0, y: height - cut.count - start, width: image.width, height: start))
        }
        let below = height - start - cut.count
        if below > 0, let rest = image.cropping(to: CGRect(x: 0, y: start + cut.count, width: image.width, height: below)) {
            trimmed.draw(rest, in: CGRect(x: 0, y: 0, width: image.width, height: below))
        }
        return trimmed.makeImage() ?? image
    }

    private mutating func append(_ piece: CGImage) {
        chunks.append(piece)
        bodyHeight += piece.height
    }

    /// Убирает `count` нижних строк тела: они оказались закреплённым низом окна.
    private mutating func trimBody(_ count: Int) {
        var left = min(count, bodyHeight)
        while left > 0, let last = chunks.last {
            if last.height <= left {
                chunks.removeLast()
                bodyHeight -= last.height
                left -= last.height
            } else {
                guard let kept = Self.copy(last, rows: 0..<(last.height - left)) else { return }
                chunks[chunks.count - 1] = kept
                bodyHeight -= left
                left = 0
            }
        }
    }

    /// Отскок в конце страницы: содержимое прокрутили за конец, и оно вернулось назад. Строки дальнего кадра
    /// за концом (над его настоящим закреплённым низом) — однотонный фон под страницей, в итог они не идут.
    /// Строки с текстом не трогаются никогда. Возвращает строки дальнего кадра, которые надо вырезать.
    private func overscroll() -> Range<Int>? {
        guard retreat.rows > 0, let previous, let latest = retreat.latest else { return nil }
        let w = Self.columns
        // Закреплённый низ здесь — только строки, совпавшие точно: фон под страницей бывает почти белым.
        var footer = 0
        while footer < rows {
            let r = rows - 1 - footer
            var diff = 0
            for k in (r * w)..<((r + 1) * w) { diff += abs(Int(previous[k]) - Int(latest[k])) }
            guard diff <= w * 2 else { break }
            footer += 1
        }
        let end = rows - footer, cut = (end - retreat.rows)..<end
        guard cut.lowerBound > 0, rows - cut.lowerBound < height else { return nil }
        let reference = Int(previous[(end - 1) * w])
        for r in cut {
            let row = previous[(r * w)..<((r + 1) * w)]
            guard let low = row.min(), let high = row.max(), Int(high) - Int(low) <= 6,
                  abs(Int(low) - reference) <= 6 else { return nil }
        }
        return cut
    }

    /// Копия строк `rows` в собственный буфер, в цветовом пространстве кадра.
    private static func copy(_ image: CGImage, rows: Range<Int>) -> CGImage? {
        guard !rows.isEmpty,
              let cropped = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count))
        else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    /// Кадр, сжатый до 64 колонок (строки сохранены), в оттенках серого.
    /// Первая строка буфера — верх изображения.
    static func signature(_ image: CGImage) -> [UInt8]? {
        let width = columns, height = image.height
        guard height > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: width * height)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    /// Сдвиг содержимого между подписями двух кадров по `h` строк. nil — совпадение не найдено
    /// (слишком быстрая прокрутка, перекрытия нет).
    ///
    /// Закреплённые строки сверху и снизу — те, что не изменились. Между ними перебираются сдвиги от малых
    /// к большим, и каждый проверяется по всему перекрытию. Перекрытие со строками текста важнее пустого:
    /// пустое совпадает при любом сдвиге. Если текста в перекрытии нет ни при каком сдвиге (длинная пустота),
    /// берётся наименьший подходящий сдвиг — сокращается пустота, а не текст.
    static func match(previous p: [UInt8], current c: [UInt8], rows h: Int) -> Match? {
        let w = columns
        guard h > 0, p.count == w * h, c.count == w * h else { return nil }
        return p.withUnsafeBufferPointer { p in
            c.withUnsafeBufferPointer { c in
                // Строка не сдвинулась, если в ней изменились лишь отдельные места: кнопки заголовка окна,
                // подсветка под курсором, часы в строке состояния. Принять строку текста за закреплённую не страшно —
                // она приклеится со следующим кадром, а закреплённый низ, принятый за текст, повторялся бы в итоге.
                func isStatic(_ r: Int) -> Bool {
                    var changed = 0
                    for k in (r * w)..<((r + 1) * w) where abs(Int(p[k]) - Int(c[k])) > 24 {
                        changed += 1
                        if changed > w / 8 { return false }
                    }
                    return true
                }
                var header = 0
                while header < h, isStatic(header) { header += 1 }
                if header == h { return Match(shift: 0, header: h, footer: 0) }
                var footer = 0
                while isStatic(h - 1 - footer) { footer += 1 }
                let lo = header, hi = h - footer, span = hi - lo
                // Изменилась узкая полоса посреди неподвижного кадра (подсветка, анимация) — это не прокрутка.
                guard span >= max(16, h / 10) else { return Match(shift: 0, header: header, footer: footer) }

                // Строки с текстом и неподвижные строки обоих кадров.
                func isTextured(_ data: UnsafeBufferPointer<UInt8>, _ r: Int) -> Bool {
                    var low = UInt8.max, high = UInt8.min
                    for k in (r * w)..<((r + 1) * w) { low = min(low, data[k]); high = max(high, data[k]) }
                    return high - low >= 16
                }
                let texturedNow = (0..<h).map { isTextured(c, $0) }
                let texturedBefore = (0..<h).map { isTextured(p, $0) }
                let still = (0..<h).map(isStatic)

                // Сдвиг оценивается по строкам перекрытия: совпавшая строка с текстом — довод за, несовпавшая — против.
                // Пустые совпавшие строки ничего не говорят. Несовпавшая неподвижная строка — закреплённая деталь
                // посреди окна или шапка, которая не распозналась (в ней что-то поменялось), а не довод против.
                // Оценка — доля несовпавших со сглаживанием: пара случайно совпавших строк не перевесит сотни.
                let minOverlap = min(span, max(16, span / 5))
                let rowTolerance = Self.tolerance * w
                var best: (shift: Int, rate: Double)?
                var fallback: Int?
                var d = 0
                while d <= span - minOverlap {
                    for s in d == 0 ? [0] : [d, -d] {
                        // Строка r нового кадра против строки r + s прошлого, обе в движущейся части.
                        let r0 = max(lo, lo - s), r1 = min(hi, hi - s)
                        let n = r1 - r0
                        guard n >= minOverlap else { continue }
                        // Дальний сдвиг выигрывает, только если заметно лучше ближнего.
                        var allowedBad = Int.max
                        if let best {
                            let limit = 0.9 * best.rate * Double(n + 2) - 1
                            guard limit >= 0 else { continue }
                            allowedBad = Int(limit)
                        }
                        var good = 0, bad = 0
                        for r in r0..<r1 {
                            let a = (r + s) * w, b = r * w
                            var sum = 0, k = 0
                            while k < w, sum <= rowTolerance {
                                sum += min(abs(Int(p[a + k]) - Int(c[b + k])), Self.clip)
                                k += 1
                            }
                            if sum <= rowTolerance {
                                if texturedNow[r] || texturedBefore[r + s] { good += 1 }
                            } else if !still[r] {
                                bad += 1
                                if bad > allowedBad { break }
                            }
                        }
                        guard bad <= allowedBad else { continue }
                        let total = good + bad
                        if total >= 3 {
                            let rate = Double(bad + 1) / Double(total + 2)
                            guard bad * 3 <= total, rate < 0.9 * (best?.rate ?? 1) else { continue }
                            best = (s, rate)
                        } else if fallback == nil, bad == 0 {
                            fallback = s
                        }
                    }
                    d += 1
                }
                guard let pick = best?.shift ?? fallback else { return nil }
                return Match(shift: pick, header: header, footer: footer)
            }
        }
    }
}

import Accelerate
import CoreGraphics

/// Склеивает кадры одной области по вертикали. Чистая логика без экрана: кадры на входе, изображение на выходе.
///
/// Каждый кадр сжимается в две подписи яркости (строки сохранены): грубую в 64 колонки — кандидаты сдвига
/// находятся голосованием строк-«якорей», и точную до 1024 колонок — из кандидатов выбирается тот, при котором
/// строки совпали точно, а не «почти» (строки лога, кода, JSON отличаются парой символов).
///
/// - Закреплённые строки сверху и снизу (не изменились между кадрами) — шапка и низ окна: сдвиг ищется между ними,
///   закреплённый низ попадает в итог один раз, в конце.
/// - Доводами служат только строки с рисунком, которые не повторяются по всему кадру: пустые строки, полосы
///   сайдбара и фон совпадают при любом сдвиге и ничего не доказывают.
/// - Колонки, которые стоят на месте, пока содержимое движется (боковая панель, плавающая кнопка), исключаются.
/// - Строки, которые не совпадают ни при каком сдвиге (видео, анимация), не мешают: сдвиг держится на остальных.
/// - Если два разных сдвига объясняют кадр одинаково хорошо (повторяющиеся строки), кадр не клеится вслепую:
///   решает подсказка по событиям прокрутки, без неё — `.lost`.
/// - События ввода (`Motion`): если их не было, содержимое не прокручивалось — изменения в кадре (видео,
///   анимация) не принимаются за прокрутку.
struct Stitcher {
    enum Result { case first, appended, unchanged, lost }

    /// Прокрутка между кадрами по событиям ввода — подсказка для поиска сдвига.
    struct Motion: Equatable {
        /// Точные события (трекпад, Magic Mouse, плавная прокрутка): на сколько пикселей кадра содержимое
        /// должно было уйти вверх (> 0 — прокрутка вниз). Приложения прокручивают почти 1:1, коэффициент уточняется.
        var pixels: Double = 0
        /// Колесо мыши без точных дельт, в строках (> 0 — вниз). Сколько это пикселей, решает приложение — коэффициент
        /// узнаётся по уверенным склейкам.
        var lines: Double = 0
        /// Клавиши прокрутки (стрелки, пробел, Page Up/Down, Home/End): величина неизвестна.
        var keys = 0

        var isEmpty: Bool { abs(pixels) < 0.5 && lines == 0 && keys == 0 }

        static func + (a: Motion, b: Motion) -> Motion {
            Motion(pixels: a.pixels + b.pixels, lines: a.lines + b.lines, keys: a.keys + b.keys)
        }
    }

    /// Сдвиг содержимого между кадрами и закреплённые строки сверху и снизу.
    struct Match: Equatable {
        /// На сколько строк содержимое уехало вверх (> 0 — прокрутка вниз).
        var shift: Int
        var header: Int
        var footer: Int
    }

    /// Подпись кадра: строки сохранены, колонки сжаты.
    struct Signature {
        let rows: Int
        /// Точная подпись: `fineColumns` колонок на строку (в Float — для vDSP).
        let fineValues: [Float]
        let fineColumns: Int
        /// Грубая подпись: `columns` колонок на строку.
        let coarse: [UInt8]
        /// Строка — довод для сдвига: в ней есть рисунок (не однотонная), и она не фон — почти такая же строка
        /// не встречается в кадре часто (пустые строки, полоса сайдбара).
        let detail: [Bool]
    }

    static let columns = 64
    static let maxFineColumns = 1024
    /// Предел итога по высоте и площади: склейка и PNG держат его в памяти целиком.
    static let maxHeight = 40_000
    static let maxPixels = 100_000_000
    /// Средняя разница грубой подписи в строке (после отсечки), при которой строка ещё считается совпавшей.
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
    private var previous: Signature?
    /// Тело кончается на этой строке дальнего кадра; ниже — его закреплённый низ.
    private var bottom = 0
    /// Насколько содержимое сейчас вернулось назад от дальнего кадра (отскок в конце страницы)
    /// и подпись последнего кадра: по ней виден настоящий закреплённый низ.
    private var retreat: (rows: Int, latest: Signature?) = (0, nil)
    /// События ввода с дальнего кадра (он — точка отсчёта сдвига).
    private var motion = Motion()
    /// Хоть раз приходили сведения о вводе: тогда «событий нет» значит «прокрутки нет».
    private var tracksMotion = false
    /// Пиксели кадра на единицу события, по уверенным склейкам (знак тоже узнаётся).
    private var pixelGain = 1.0
    private var lineGain: Double?
    /// Высота прокручиваемой части по последней уверенной склейке (между шапкой и низом).
    private var scrollSpan: Int?
    /// Обычная относительная ошибка подсказки: насколько ожидаемый сдвиг расходился с найденным по изображению
    /// (доля от ожидаемого; за серию потерянных кадров ошибка копится вместе со сдвигом).
    private var hintError = 0.25

    /// `motion` — события ввода после прошлого кадра (nil — неизвестно: склейка только по изображению).
    @discardableResult
    mutating func add(_ frame: CGImage, motion input: Motion? = nil) -> Result {
        guard !isFull, let signature = Self.signature(frame) else { return .unchanged }
        guard let previous else {
            guard let copy = Self.copy(frame, rows: 0..<frame.height) else { return .unchanged }
            width = frame.width
            rows = frame.height
            chunks = [copy]
            bodyHeight = rows
            bottom = rows
            self.previous = signature
            motion = Motion()
            tracksMotion = input != nil
            return .first
        }
        if let input {
            motion = motion + input
            tracksMotion = true
        }
        // Размер кадра задан при старте; кадр другого размера к склейке не подходит.
        guard frame.width == width, frame.height == rows else { return .lost }
        // Событий прокрутки не было — содержимое на месте: видео, анимация, подсветка не прокрутка.
        if tracksMotion, motion.isEmpty { return .unchanged }
        let expected = expectedShift
        // Без сведений о вводе прокрутку от анимации отличает только размер: движется почти вся область прокрутки
        // (не меньше половины кадра, а после первой склейки — не меньше 60% уже известной прокручиваемой части),
        // а не полоса посреди стоящего окна.
        let minSpan = tracksMotion ? 0 : scrollSpan.map { $0 * 6 / 10 } ?? rows / 2
        guard let found = Self.match(previous: previous, current: signature, expected: expected, hintError: hintError,
                                     minSpan: minSpan) else { return .lost }
        let match = found.match
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
        if found.confident {
            scrollSpan = rows - match.header - match.footer
            if let expected { hintError = hintError * 0.7 + Double(abs(match.shift - expected)) / Double(max(abs(expected), 50)) * 0.3 }
            learnGain(shift: match.shift)
        }
        self.previous = signature
        motion = Motion()
        return .appended
    }

    /// Ожидаемый сдвиг по событиям с дальнего кадра; nil — величина неизвестна (клавиши, колесо без коэффициента).
    private var expectedShift: Int? {
        guard tracksMotion, motion.keys == 0 else { return nil }
        var shift = motion.pixels * pixelGain
        if motion.lines != 0 {
            guard let lineGain else { return nil }
            shift += motion.lines * lineGain
        }
        return Int(shift.rounded())
    }

    /// Коэффициент «события → пиксели» по уверенной склейке (сдвиг однозначен по изображению).
    private mutating func learnGain(shift: Int) {
        guard tracksMotion, motion.keys == 0, shift >= 16 else { return }
        if motion.lines == 0, abs(motion.pixels) >= 8 {
            let ratio = Double(shift) / motion.pixels
            if (0.25...4).contains(abs(ratio)) { pixelGain = pixelGain * 0.5 + ratio * 0.5 }
        } else if abs(motion.pixels) < 0.5, motion.lines != 0 {
            let ratio = Double(shift) / motion.lines
            if (1...400).contains(abs(ratio)) { lineGain = lineGain.map { $0 * 0.5 + ratio * 0.5 } ?? ratio }
        }
    }

    func makeImage() -> CGImage? {
        guard let first = chunks.first, bodyHeight > 0 else { return nil }
        // Отскок в конце: однотонные строки за концом страницы не рисуются (сразу, без второго холста).
        let cut = overscroll()
        let height = bodyHeight + footerRows - (cut?.count ?? 0)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = first.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: sRGB, bitmapInfo: info) else { return nil }
        // Итог кончается строками дальнего кадра подряд: его строка y — строка (bodyHeight + footerRows) - (rows - y).
        let skip = cut.map { (bodyHeight + footerRows - (rows - $0.lowerBound))..<(bodyHeight + footerRows - (rows - $0.upperBound)) }
        var top = 0          // строка итога без вырезки
        var drawn = 0        // строка итога с вырезкой
        func draw(_ image: CGImage) {
            let range = top..<(top + image.height)
            top += image.height
            for part in Self.subtract(skip, from: range) {
                let rows = (part.lowerBound - range.lowerBound)..<(part.upperBound - range.lowerBound)
                guard let piece = rows.count == image.height ? image
                        : image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)) else { continue }
                context.draw(piece, in: CGRect(x: 0, y: height - drawn - piece.height, width: piece.width, height: piece.height))
                drawn += piece.height
            }
        }
        chunks.forEach(draw)
        if let footer { draw(footer) }
        return context.makeImage()
    }

    /// Части `range` вне `skip`.
    private static func subtract(_ skip: Range<Int>?, from range: Range<Int>) -> [Range<Int>] {
        guard let skip, skip.overlaps(range) else { return [range] }
        return [range.lowerBound..<max(range.lowerBound, skip.lowerBound), min(range.upperBound, skip.upperBound)..<range.upperBound]
            .filter { !$0.isEmpty }
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
        guard retreat.rows > 0, let previous = previous?.coarse, let latest = retreat.latest?.coarse else { return nil }
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

    // MARK: - Подпись

    /// Яркость `(R + 2G + B) / 4`, сжатая по ширине до `columns` колонок (vImage); строки сохранены, верх — первая.
    /// false — формат не 8 бит × 4 канала (тогда подпись рисуется через CoreGraphics).
    private static func luminance(_ image: CGImage, into out: inout [UInt8], columns: Int) -> Bool {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.width >= columns,
              let data = image.dataProvider?.data, CFDataGetLength(data) >= image.bytesPerRow * image.height,
              let base = CFDataGetBytePtr(data) else { return false }
        // Где цвет в 4 байтах: альфа (или пропуск) впереди или сзади, порядок байтов прямой или обратный.
        let alpha = image.alphaInfo
        let little = image.byteOrderInfo == .order32Little
        let alphaFirst = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        let alphaLast = alpha == .premultipliedLast || alpha == .last || alpha == .noneSkipLast
        guard alphaFirst || alphaLast || alpha == .none else { return false }
        // Цвет в байтах 0…2 (RGBA, BGRA) или 1…3 (ARGB, ABGR); зелёный всегда посередине.
        let matrix: [Int16] = (alphaFirst && !little) || (alphaLast && little) ? [0, 1, 2, 1] : [1, 2, 1, 0]
        let width = image.width, height = image.height
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: image.bytesPerRow)
        var luma = [UInt8](repeating: 0, count: width * height)
        let converted = luma.withUnsafeMutableBytes { buffer -> Bool in
            var planar = vImage_Buffer(data: buffer.baseAddress, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width)
            return vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &planar, matrix, 4, nil, 0, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard converted else { return false }
        return scale(&luma, width: width, height: height, into: &out, columns: columns)
    }

    /// Сжатие по ширине (строки сохранены).
    private static func scale(_ input: inout [UInt8], width: Int, height: Int, into out: inout [UInt8], columns: Int) -> Bool {
        if columns == width {
            out = input
            return true
        }
        return input.withUnsafeMutableBytes { src in
            out.withUnsafeMutableBytes { dst in
                var from = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var to = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(columns), rowBytes: columns)
                return vImageScale_Planar8(&from, &to, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
    }

    /// Подпись кадра. Первая строка буфера — верх изображения.
    static func signature(_ image: CGImage) -> Signature? {
        let height = image.height
        let fineColumns = max(columns, min(image.width, maxFineColumns))
        guard height > 0 else { return nil }
        var fine = [UInt8](repeating: 0, count: fineColumns * height)
        // Быстрый путь — яркость прямо из пикселей кадра (8 бит на канал, 4 байта на пиксель) через vImage:
        // перерисовка в серое через CoreGraphics пересчитывает цвет и на 5K стоит ~60 мс из 150 мс тика.
        let ok = luminance(image, into: &fine, columns: fineColumns) || fine.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: fineColumns, height: height,
                                          bitsPerComponent: 8, bytesPerRow: fineColumns,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: fineColumns, height: height))
            return true
        }
        guard ok else { return nil }
        let w = columns
        var coarse = [UInt8](repeating: 0, count: w * height)
        var detail = [Bool](repeating: false, count: height)
        // Грубая подпись и промежуточная (до 256 колонок, для «есть ли рисунок») — сжатием точной.
        let mw = min(fineColumns, 256)
        var middle = [UInt8](repeating: 0, count: mw * height)
        guard scale(&fine, width: fineColumns, height: height, into: &coarse, columns: w),
              scale(&fine, width: fineColumns, height: height, into: &middle, columns: mw) else { return nil }
        do {
            // Фон — строки, которые почти без изменений встречаются в кадре часто (пустые строки, полоса сайдбара):
            // они совпадают с любым другим таким местом и ничего не доказывают. Строка текста уникальна или
            // повторяется несколько раз подряд (строки внутри буквы), но не на двадцатой части кадра.
            var counts: [Int: Int] = [:]
            var keys = [Int](repeating: 0, count: height)
            coarse.withUnsafeBufferPointer { cb in
                for r in 0..<height {
                    var hash = 5381
                    for c in 0..<w { hash = (hash &* 33) &+ Int(cb[r * w + c] >> 3) }
                    keys[r] = hash
                    counts[hash, default: 0] += 1
                }
            }
            let common = max(8, height / 20)
            middle.withUnsafeBufferPointer { m in
                for r in 0..<height where counts[keys[r]]! <= common {
                    // Рисунок по горизонтали: строка не однотонная.
                    let a = r * mw
                    var low = m[a], high = m[a]
                    for k in 1..<mw { let v = m[a + k]; if v < low { low = v } else if v > high { high = v } }
                    detail[r] = high - low >= 20
                }
            }
        }
        var fineValues = [Float](repeating: 0, count: fine.count)
        vDSP_vfltu8(fine, 1, &fineValues, 1, vDSP_Length(fine.count))
        return Signature(rows: height, fineValues: fineValues, fineColumns: fineColumns, coarse: coarse, detail: detail)
    }

    // MARK: - Поиск сдвига

    struct Found {
        var match: Match
        /// Сдвиг однозначен по самому изображению (по нему можно уточнять коэффициент событий).
        var confident: Bool
    }

    private struct Candidate {
        var shift: Int
        var coarseCost = 0.0
        var evidence = 0
        var matched = 0
        var strict = 0
        var cost = 0
        /// Строки нового кадра, совпавшие при этом сдвиге: 1 — в допуске, 2 — точно (после полной проверки).
        var rows: [UInt8] = []
        var strictRate: Double { evidence > 0 ? Double(strict) / Double(evidence) : 0 }
        var matchedRate: Double { evidence > 0 ? Double(matched) / Double(evidence) : 0 }
    }

    /// Сдвиг содержимого между подписями двух кадров. nil — совпадение не найдено или неоднозначно
    /// (слишком быстрая прокрутка, другое содержимое, повторяющиеся строки без подсказки).
    /// `expected` — сдвиг по событиям прокрутки: среди равных по изображению кандидатов выбирается ближайший к нему.
    /// `hintError` — обычная относительная ошибка подсказки (по прошлым уверенным склейкам).
    /// `minSpan` — движущаяся часть меньше этого считается не прокруткой.
    static func match(previous p: Signature, current c: Signature, expected: Int? = nil, hintError: Double = 0.25,
                      minSpan: Int = 0) -> Found? {
        // Закреплённые строки сначала ищутся мягко: в шапке меняются часы, значки, подсветка. Но так же «почти не
        // меняются» строки лога или таблицы в одном и том же месте при прокрутке (отличаются цифры) — и мягкое правило
        // принимает их за закреплённый низ. Если так сдвига не нашлось, повтор со строгим правилом: закреплены только
        // строки, точно совпавшие на месте.
        let loose = search(previous: p, current: c, expected: expected, hintError: hintError, minSpan: minSpan, exactStatic: false)
        if let loose, loose.match.shift != 0 { return loose }
        let exact = search(previous: p, current: c, expected: expected, hintError: hintError, minSpan: minSpan, exactStatic: true)
        if let exact, exact.match.shift != 0 { return exact }
        return loose ?? exact
    }

    private static func search(previous p: Signature, current c: Signature, expected: Int?, hintError: Double,
                               minSpan: Int, exactStatic: Bool) -> Found? {
        let w = columns, h = p.rows
        guard h > 0, c.rows == h, p.fineColumns == c.fineColumns else { return nil }
        let pc = p.coarse, cc = c.coarse

        // Строка не сдвинулась, если в ней изменились лишь отдельные места: кнопки заголовка окна,
        // подсветка под курсором, часы в строке состояния. Только для шапки и низа: несовпадения внутри
        // движущейся части этим не прощаются.
        var exactDifference = [Float](repeating: 0, count: p.fineColumns)
        let exactTolerance = Float(8 + p.fineColumns / 64)
        func isStatic(_ r: Int) -> Bool {
            if exactStatic {
                let n = vDSP_Length(p.fineColumns), a = r * p.fineColumns
                var low: Float = 0, high = Float(clip), total: Float = 0
                p.fineValues.withUnsafeBufferPointer { pf in
                    c.fineValues.withUnsafeBufferPointer { cf in
                        exactDifference.withUnsafeMutableBufferPointer { d in
                            vDSP_vsub(cf.baseAddress! + a, 1, pf.baseAddress! + a, 1, d.baseAddress!, 1, n)
                            vDSP_vabs(d.baseAddress!, 1, d.baseAddress!, 1, n)
                            vDSP_vclip(d.baseAddress!, 1, &low, &high, d.baseAddress!, 1, n)
                            vDSP_sve(d.baseAddress!, 1, &total, n)
                        }
                    }
                }
                return total <= exactTolerance
            }
            var changed = 0
            for k in (r * w)..<((r + 1) * w) where abs(Int(pc[k]) - Int(cc[k])) > 10 {
                changed += 1
                if changed > w / 8 { return false }
            }
            return true
        }
        var header = 0
        while header < h, isStatic(header) { header += 1 }
        if header == h { return Found(match: Match(shift: 0, header: h, footer: 0), confident: true) }
        var footer = 0
        while isStatic(h - 1 - footer) { footer += 1 }
        let lo = header, hi = h - footer, span = hi - lo
        // Изменилась узкая полоса посреди неподвижного кадра (подсветка, анимация) — это не прокрутка.
        guard span >= max(16, h / 10, minSpan) else { return Found(match: Match(shift: 0, header: header, footer: footer), confident: true) }

        // Колонки, которые стоят на месте, пока остальное движется: боковая панель, плавающая кнопка, ползунок.
        // Клетка «с рисунком», если отличается от клеток на 3 строки выше и ниже.
        var masked = [Bool](repeating: false, count: w)
        for col in 0..<w {
            var textured = 0, still = 0
            for r in lo..<hi {
                let v = Int(cc[r * w + col])
                let up = r >= 3 ? Int(cc[(r - 3) * w + col]) : v, down = r + 3 < h ? Int(cc[(r + 3) * w + col]) : v
                guard abs(v - up) > 12 || abs(v - down) > 12 else { continue }
                textured += 1
                if abs(Int(pc[r * w + col]) - v) <= 4 { still += 1 }
            }
            masked[col] = textured >= 8 && still * 10 >= textured * 6
        }
        let active = (0..<w).filter { !masked[$0] }
        // Почти всё стоит на месте — это не прокрутка содержимого.
        guard active.count * 4 >= w else { return Found(match: Match(shift: 0, header: header, footer: footer), confident: true) }

        let fw = p.fineColumns
        let fineActive = (0..<fw).filter { !masked[$0 * w / fw] }.count
        let rowTolerance = tolerance * active.count
        let rowCap = rowTolerance * 4
        let minOverlap = min(span, max(16, span / 5))
        let limit = span - minOverlap

        // 1. Кандидаты голосованием: до 64 строк-доводов нового кадра («якоря») ищутся среди строк-доводов прошлого,
        // каждое совпадение голосует за свой сдвиг. Полный перебор всех сдвигов по всем строкам на 5K не укладывается
        // в тик съёмки, а голосование — за единицы миллисекунд.
        func rowCost(_ pb: UnsafeBufferPointer<UInt8>, _ cb: UnsafeBufferPointer<UInt8>, _ q: Int, _ r: Int, cap: Int) -> Int {
            let a = q * w, b = r * w
            var sum = 0
            for k in active {
                sum += min(abs(Int(pb[a + k]) - Int(cb[b + k])), clip)
                if sum >= cap { break }
            }
            return sum
        }
        var votes = [Int](repeating: 0, count: 2 * limit + 1)
        let anchors = (lo..<hi).filter { c.detail[$0] }
        let anchorStep = max(1, anchors.count / 64)
        pc.withUnsafeBufferPointer { pb in
            cc.withUnsafeBufferPointer { cb in
                for index in stride(from: 0, to: anchors.count, by: anchorStep) {
                    let r = anchors[index]
                    let first = max(lo, r - limit), last = min(hi - 1, r + limit)
                    guard first <= last else { continue }
                    for q in first...last where p.detail[q] && rowCost(pb, cb, q, r, cap: rowTolerance + 1) <= rowTolerance {
                        votes[q - r + limit] += 1
                    }
                }
            }
        }
        var proposals = Set<Int>()
        let voted: [Int] = votes.indices.filter { votes[$0] > 0 }.sorted { a, b in
            votes[a] != votes[b] ? votes[a] > votes[b] : abs(a - limit) < abs(b - limit)
        }
        // Лучшие по голосам и соседи лидеров на ±2: строки внутри буквы похожи, и голоса соседних сдвигов почти
        // равны — точный выбирается дальше по разнице.
        for index in voted.prefix(24) { proposals.insert(index - limit) }
        for index in voted.prefix(8) { for d in -2...2 { proposals.insert(index - limit + d) } }
        if let expected {
            let window = max(24, abs(expected) * 2 / 5)
            let near: [Int] = voted.map { $0 - limit }.filter { abs($0 - expected) <= window }.sorted { a, b in
                votes[a + limit] != votes[b + limit] ? votes[a + limit] > votes[b + limit] : abs(a - expected) < abs(b - expected)
            }
            proposals.formUnion(near.prefix(6))
        }
        proposals.insert(0)

        // Грубая оценка кандидата: средняя (с потолком) разница по строкам-доводам перекрытия.
        var scored: [Candidate] = []
        pc.withUnsafeBufferPointer { pb in
            cc.withUnsafeBufferPointer { cb in
                for s in proposals where abs(s) <= limit {
                    var evidence = 0, mismatched = 0, total = 0
                    for r in max(lo, lo - s)..<min(hi, hi - s) where c.detail[r] || p.detail[r + s] {
                        evidence += 1
                        let sum = rowCost(pb, cb, r + s, r, cap: rowCap)
                        total += min(sum, rowCap)
                        if sum > rowTolerance { mismatched += 1 }
                    }
                    guard evidence >= 3 else { continue }
                    scored.append(Candidate(shift: s, coarseCost: Double(total) / Double(evidence), evidence: evidence,
                                            matched: evidence - mismatched))
                }
            }
        }
        // Сдвиги без доводов (однотонный участок): ни одной строки с рисунком в перекрытии — нечему противоречить.
        // Считаются только если ничего лучше нет. По порядку |сдвига|.
        func neutralShifts() -> [Int] {
            var cPrefix = [0], pPrefix = [0]
            for r in 0..<h {
                cPrefix.append(cPrefix[r] + (c.detail[r] ? 1 : 0))
                pPrefix.append(pPrefix[r] + (p.detail[r] ? 1 : 0))
            }
            var result: [Int] = []
            pc.withUnsafeBufferPointer { pb in
                cc.withUnsafeBufferPointer { cb in
                    for d in 0...max(0, limit) {
                        for s in d == 0 ? [0] : [d, -d] {
                            let r0 = max(lo, lo - s), r1 = min(hi, hi - s)
                            let count = cPrefix[r1] - cPrefix[r0] + pPrefix[r1 + s] - pPrefix[r0 + s]
                            guard count <= 2 else { continue }
                            let clean = (r0..<r1).allSatisfy { r in
                                !(c.detail[r] || p.detail[r + s]) || rowCost(pb, cb, r + s, r, cap: rowTolerance + 1) <= rowTolerance
                            }
                            if clean { result.append(s) }
                        }
                    }
                }
            }
            return result
        }

        // 2. Лучшие кандидаты (наименьшая средняя разница доводов) и ближайшие к подсказке — в точную проверку.
        let byCost = { (a: Candidate, b: Candidate) in a.coarseCost < b.coarseCost }
        var picks: [Candidate] = []
        for candidate in scored.sorted(by: byCost) where picks.count < 24 {
            if !picks.contains(where: { abs($0.shift - candidate.shift) <= 2 }) { picks.append(candidate) }
        }
        let window = expected.map { max(24, abs($0) * 2 / 5) }
        if let expected, let window {
            // Равные по цене (повторяющиеся строки) — ближайшие к подсказке.
            let near = scored.filter { abs($0.shift - expected) <= window }.sorted {
                (Int($0.coarseCost) / 8, abs($0.shift - expected)) < (Int($1.coarseCost) / 8, abs($1.shift - expected))
            }
            for candidate in near.prefix(3) where !picks.contains(where: { $0.shift == candidate.shift }) { picks.append(candidate) }
        }

        // 3. Точная проверка: доля строк-доводов, совпавших точно (strict) и в допуске (matched). Сначала по каждой
        // четвёртой строке-доводу у всех кандидатов, потом целиком — у лучших.
        let strictTolerance = 8 + fineActive / 64
        let fineTolerance = max(16, fineActive)
        // Разница строк (с отсечкой, без неподвижных колонок) — через vDSP: векторно и одинаково быстро в любой сборке.
        let fineMask: [Float] = (0..<fw).map { masked[$0 * w / fw] ? 0 : 1 }
        var difference = [Float](repeating: 0, count: fw)
        func check(_ picks: inout [Candidate], every step: Int) {
            p.fineValues.withUnsafeBufferPointer { pf in
            c.fineValues.withUnsafeBufferPointer { cf in
            difference.withUnsafeMutableBufferPointer { diff in
                let n = vDSP_Length(fw)
                var low: Float = 0, high = Float(clip)
                for i in picks.indices {
                    let s = picks[i].shift
                    var evidence = 0, matched = 0, strict = 0, cost = 0, seen = 0
                    var rows = step == 1 ? [UInt8](repeating: 0, count: h) : []
                    for r in max(lo, lo - s)..<min(hi, hi - s) where c.detail[r] || p.detail[r + s] {
                        seen += 1
                        guard seen % step == 0 else { continue }
                        evidence += 1
                        let a = (r + s) * fw, b = r * fw
                        vDSP_vsub(cf.baseAddress! + b, 1, pf.baseAddress! + a, 1, diff.baseAddress!, 1, n)
                        vDSP_vabs(diff.baseAddress!, 1, diff.baseAddress!, 1, n)
                        vDSP_vclip(diff.baseAddress!, 1, &low, &high, diff.baseAddress!, 1, n)
                        vDSP_vmul(diff.baseAddress!, 1, fineMask, 1, diff.baseAddress!, 1, n)
                        var total: Float = 0
                        vDSP_sve(diff.baseAddress!, 1, &total, n)
                        let sum = Int(total)
                        cost += sum
                        if sum <= fineTolerance { matched += 1; if step == 1 { rows[r] = 1 } }
                        if sum <= strictTolerance { strict += 1; if step == 1 { rows[r] = 2 } }
                    }
                    picks[i].rows = rows
                    picks[i].evidence = evidence
                    picks[i].matched = matched
                    picks[i].strict = strict
                    picks[i].cost = cost
                }
            }
            }
            }
        }
        if picks.count > 6 {
            check(&picks, every: 4)
            picks.sort { ($0.strictRate, $0.matchedRate) > ($1.strictRate, $1.matchedRate) }
            // Ближайшие к подсказке остаются в любом случае.
            let keep = expected.flatMap { e in window.map { w in
                picks.filter { abs($0.shift - e) <= w }
                    .sorted { (-$0.strictRate, abs($0.shift - e)) < (-$1.strictRate, abs($1.shift - e)) }.prefix(2)
            } } ?? []
            picks = Array(picks.prefix(6)) + keep.filter { k in !picks.prefix(6).contains { $0.shift == k.shift } }
        }
        check(&picks, every: 1)
        // Сдвиг годится, если совпала хоть заметная доля строк-доводов: остальное может быть видео или анимацией.
        // Совсем другое содержимое (переход по ссылке, рывок) отсеивает дальше однозначность: случайные совпадения
        // есть у многих сдвигов понемногу, и точных среди них почти нет.
        let valid = picks.filter { $0.evidence >= 3 && $0.matched >= max(min(8, $0.evidence), $0.evidence / 20) }
        let match = { (shift: Int) in Match(shift: shift, header: header, footer: footer) }
        guard !valid.isEmpty else {
            // Доводов нет ни при каком сдвиге (однотонный участок длиннее кадра): сокращается пустота, а не текст.
            // С подсказкой — ближайший к ней сдвиг, без неё — наименьший.
            let neutral = neutralShifts()
            if let expected, let pick = neutral.min(by: { abs($0 - expected) < abs($1 - expected) }) {
                return Found(match: match(pick), confident: false)
            }
            return neutral.first.map { Found(match: match($0), confident: false) }
        }
        let useStrict = (valid.map(\.strictRate).max() ?? 0) >= 0.15
        func rate(_ x: Candidate) -> Double { useStrict ? x.strictRate : x.matchedRate }
        let ranked = valid.sorted {
            rate($0) != rate($1) ? rate($0) > rate($1)
                : Double($0.cost) / Double($0.evidence) < Double($1.cost) / Double($1.evidence)
        }
        let best = ranked[0]
        // Однозначен ли кандидат. Сильный (объясняет больше половины доводов) — если никакой далёкий сдвиг не объясняет
        // почти так же. Слабый (остальное — видео, анимация) — см. ниже. Сравнение — со всеми проверенными кандидатами,
        // а не только с годными: слабый сдвиг, едва прошедший порог, рядом с такими же «почти годными» — это шум.
        //
        // И у него должны быть собственные доводы: строки, которые совпали при нём и ни при каком другом далёком
        // сдвиге. Иначе он держится только на повторяющихся строках (блок одинаковых строк лога), а новое содержимое
        // просто не совпало ни с чем — и вклеилось бы со сдвигом, взятым наугад.
        let level: UInt8 = useStrict ? 2 : 1
        func unique(_ x: Candidate) -> Bool {
            let others = picks.filter { abs($0.shift - x.shift) > 2 && $0.evidence >= 8 }
            let second = others.map(rate).max() ?? 0
            if rate(x) >= 0.5 {
                guard second < rate(x) - 0.04 else { return false }
            } else {
                // Слабый (меньше половины строк, остальное — видео): держится на строках, совпавших точно, и их доля
                // вдвое больше, чем у любого другого сдвига — у случайных совпадений точных почти нет. При шумном
                // захвате, когда точных нет ни у кого, — по совпавшим в допуске, хотя бы на строке текста.
                let secondStrict = others.map(\.strictRate).max() ?? 0
                let byStrict = x.strict >= 16 && x.strictRate >= 2 * secondStrict + 0.01
                let noisy = !picks.contains { $0.strict >= 16 }
                guard byStrict || (noisy && x.matched >= 24 && rate(x) >= 2 * second + 0.02) else { return false }
            }
            // Соперники — далёкие сдвиги (дальше высоты строки текста): ближние совпадают по тем же строкам из-за
            // самоподобия внутри строки и собственных доводов не отнимают.
            let rivals = picks.filter { abs($0.shift - x.shift) > 16 && !$0.rows.isEmpty }
            var own = 0, matched = 0
            for r in x.rows.indices where x.rows[r] >= level {
                matched += 1
                if !rivals.contains(where: { $0.rows[r] >= level }) { own += 1 }
            }
            return own >= min(8, matched)
        }
        guard let expected, let window else {
            return unique(best) ? Found(match: match(best.shift), confident: true) : nil
        }
        if unique(best) {
            // Однозначный сдвиг. Если он спорит с подсказкой — верим изображению, только когда сдвиг сильный
            // (коэффициент событий ещё не узнан, приложение прокручивает не 1:1).
            guard abs(best.shift - expected) <= window || rate(best) >= 0.5 else { return nil }
            return Found(match: match(best.shift), confident: true)
        }
        // Несколько сдвигов объясняют кадр одинаково (повторяющиеся строки). Подсказка выбирает ближайший, только если
        // она точнее, чем расстояние между ними: иначе это угадывание, и строки молча пропали бы или повторились.
        let accuracy = max(4, Int(2 * hintError * Double(max(abs(expected), 50))))
        let tied = ranked.filter { $0.evidence >= 8 && rate($0) >= rate(best) - 0.04 }
            .sorted { abs($0.shift - expected) < abs($1.shift - expected) }
        guard let first = tied.first, abs(first.shift - expected) <= accuracy else { return nil }
        if tied.count >= 2, abs(tied[1].shift - expected) < abs(first.shift - expected) + max(8, accuracy) { return nil }
        return Found(match: match(first.shift), confident: false)
    }
}

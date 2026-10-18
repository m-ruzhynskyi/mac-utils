import Accelerate
import CoreGraphics

/// Склеивает кадры одной области по вертикали. Чистая логика без экрана: кадры на входе, изображение на выходе.
///
/// Каждая строка кадра делится на 64 полосы, и у каждой полосы — точный отпечаток пикселей в полном разрешении.
/// Захват экрана точен: при прокрутке на целое число пикселей строки совпадают побитово. Поэтому сдвиг ищется по
/// точным совпадениям полос, а не по похожести: строки лога, кода, JSON, отличающиеся одной цифрой, не совпадают.
///
/// - Закреплённые строки сверху и снизу (не изменились между кадрами) — шапка и низ окна: сдвиг ищется между ними,
///   закреплённый низ попадает в итог один раз, в конце.
/// - Доводами служат полосы с рисунком, которые не повторяются по всему кадру: пустые места, полосы сайдбара и фон
///   совпадают при любом сдвиге и ничего не доказывают.
/// - Колонки, которые стоят на месте, пока содержимое движется (боковая панель, плавающая кнопка), исключаются.
/// - Строки, которые не совпадают ни при каком сдвиге (видео, анимация), не мешают: сдвиг держится на остальных.
/// - Сдвиг принимается, только если у него есть собственные доводы против каждого другого сдвига. Если два сдвига
///   объясняют кадр одинаково (повторяющиеся строки), решает подсказка событий прокрутки, без неё — `.lost`:
///   строки не пропадают молча.
/// - События ввода (`Motion`): если их не было, содержимое не прокручивалось — изменения в кадре (видео,
///   анимация) не принимаются за прокрутку.
/// - Если захват неточный (шум, масштабирование) и точных совпадений нет вовсе, сдвиг ищется по похожести, как
///   запасной вариант — но только пока в съёмке не было ни одной точной склейки.
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
        /// PageDown и пробел (+1), PageUp и Shift+пробел (−1): на сколько пикселей прокручивает страница, решает
        /// приложение (в браузере — видимая высота без 40 CSS px) — коэффициент узнаётся по уверенным склейкам.
        var pages: Double = 0
        /// Прокрутка неизвестной величины: клавиши, перетаскивание, щелчок по ползунку, колесо мимо области,
        /// продолжение анимированной прокрутки. Решает изображение.
        var unknown = 0

        var isEmpty: Bool { abs(pixels) < 0.5 && lines == 0 && pages == 0 && unknown == 0 }

        static func + (a: Motion, b: Motion) -> Motion {
            Motion(pixels: a.pixels + b.pixels, lines: a.lines + b.lines, pages: a.pages + b.pages, unknown: a.unknown + b.unknown)
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
        /// Строка — довод для сдвига по похожести: в ней есть рисунок (не однотонная), и она не фон — почти такая
        /// же строка не встречается в кадре часто (пустые строки, полоса сайдбара).
        let detail: [Bool]
        /// Строка однотонная целиком (разброс яркости не больше 2): пустота, а не бледный край букв.
        let flat: [Bool]
        /// Отпечатки полос: `columns` на строку, по пикселям полного разрешения.
        let hashes: [UInt64]
        /// Полосы с рисунком: бит `j` — полоса `j`.
        let textured: [UInt64]
        /// Полосы-доводы: с рисунком и не повторяются в своей колонке часто.
        let distinct: [UInt64]
        /// Полосы, единственные в своей колонке кадра (цифры в логе, номер функции): если сдвиг объясняет такую
        /// полосу, другой сдвиг, считающий эту строку новым содержимым, невозможен.
        let unique: [UInt64]
        /// Строка с рисунком, единственная в кадре целиком (одинаковые строки подряд — одна): строка лога, кода,
        /// текста. Сдвиг, при котором такие строки не совпадают целиком, объясняет кадр лишь повторяющимися местами.
        let uniqueRow: [Bool]
        /// Отпечаток строки целиком (по всем полосам): одинаковые строки в разных местах кадров.
        let rowKeys: [UInt64]
        /// Редкие полосы (не больше `rareLimit` повторов в колонке) по колонкам, отсортированы по отпечатку:
        /// колонка `j` — `indexStart[j]..<indexStart[j + 1]`. Для голосования за сдвиг.
        let indexKeys: [UInt64]
        let indexRows: [Int32]
        let indexStart: [Int]

        /// Та же подпись перевёрнутого по вертикали кадра (для склейки вверх): строки в обратном порядке, индекс
        /// и серии одинаковых строк пересчитаны.
        func flipped() -> Signature {
            func reversed<T>(_ values: [T], _ stride: Int) -> [T] {
                var out: [T] = []
                out.reserveCapacity(values.count)
                for r in (0..<rows).reversed() { out.append(contentsOf: values[(r * stride)..<((r + 1) * stride)]) }
                return out
            }
            let hashes = reversed(self.hashes, Stitcher.columns), textured = Array(self.textured.reversed())
            let (distinct, unique, keys, indexRows, start) = Stitcher.segmentIndex(hashes: hashes, textured: textured, rows: rows)
            let (uniqueRow, rowKeys) = Stitcher.uniqueRows(hashes: hashes, textured: textured, rows: rows)
            return Signature(rows: rows, fineValues: reversed(fineValues, fineColumns), fineColumns: fineColumns,
                             coarse: reversed(coarse, Stitcher.columns), detail: Array(detail.reversed()), flat: Array(flat.reversed()),
                             hashes: hashes,
                             textured: textured, distinct: distinct, unique: unique, uniqueRow: uniqueRow, rowKeys: rowKeys,
                             indexKeys: keys, indexRows: indexRows, indexStart: start)
        }

        /// Подпись без полос `mask` и соседних с ними в строках `range`: остаётся только движущийся слой
        /// (см. `layerSearch`). Строки сравниваются целиком лишь по оставшимся полосам.
        func without(_ mask: [UInt64], rows range: Range<Int>) -> Signature {
            var textured = self.textured
            for r in range {
                let m = mask[r]
                textured[r] &= ~(m | m << 1 | m >> 1)
            }
            let (uniqueRow, rowKeys) = Stitcher.uniqueRows(hashes: hashes, textured: textured, rows: rows, texturedOnly: true)
            return Signature(rows: rows, fineValues: fineValues, fineColumns: fineColumns, coarse: coarse, detail: detail, flat: flat,
                             hashes: hashes, textured: textured, distinct: zip(distinct, textured).map { $0 & $1 },
                             unique: zip(unique, textured).map { $0 & $1 }, uniqueRow: uniqueRow, rowKeys: rowKeys,
                             indexKeys: indexKeys, indexRows: indexRows, indexStart: indexStart)
        }
    }

    static let columns = 64
    static let maxFineColumns = 1024
    /// Предел итога по высоте и площади: склейка и PNG держат его в памяти целиком.
    static let maxHeight = 40_000
    static let maxPixels = 100_000_000
    /// Средняя разница грубой подписи в строке (после отсечки), при которой строка ещё считается совпавшей.
    private static let tolerance = 5
    private static let clip = 64
    /// Полоса, которая встречается в колонке чаще, — не голосует за сдвиг.
    private static let rareLimit = 8

    /// Неподвижный фон с рисунком (обои чата) по месту в кадре: полосы, которые при прокрутке совпали на своём месте.
    /// Копится за съёмку: позади сообщений обои то видны, то закрыты, и по одной паре кадров их не отличить от текста.
    struct Background {
        var hashes: [UInt64]
        /// Бит `j` строки `r` — отпечаток полосы известен.
        var known: [UInt64]

        init(rows: Int) {
            hashes = [UInt64](repeating: 0, count: rows * Stitcher.columns)
            known = [UInt64](repeating: 0, count: rows)
        }

        /// Полосы подписи, совпавшие с фоном на своём месте.
        func mask(_ s: Signature) -> [UInt64] {
            (0..<s.rows).map { r in
                var bits = known[r] & s.textured[r], out: UInt64 = 0
                while bits != 0 {
                    let j = bits.trailingZeroBitCount
                    bits &= bits - 1
                    if hashes[r * Stitcher.columns + j] == s.hashes[r * Stitcher.columns + j] { out |= 1 << UInt64(j) }
                }
                return out
            }
        }

        /// Содержимое сдвинулось, а полоса осталась на месте — это фон.
        mutating func learn(_ p: Signature, _ c: Signature, rows range: Range<Int>) {
            let w = Stitcher.columns
            for r in range {
                var bits = p.textured[r] & c.textured[r]
                while bits != 0 {
                    let j = bits.trailingZeroBitCount
                    bits &= bits - 1
                    guard p.hashes[r * w + j] == c.hashes[r * w + j] else { continue }
                    hashes[r * w + j] = c.hashes[r * w + j]
                    known[r] |= 1 << UInt64(j)
                }
            }
        }
    }

    /// Отметка неоднозначности из поиска: несколько настоящих совпадений, подсказка их не развела.
    final class Ambiguity {
        var repeated = false
        /// Строгое правило увидело, что текст сдвинулся (узкая полоса, но строка переехала или появилась), а сдвиг не
        /// нашёлся: это потеря места, а не «кадр стоит» мягкого правила.
        var textMoved = false
    }

    /// Чем найден сдвиг: точное совпадение, выбор подсказкой среди одинаковых, точное совпадение движущегося слоя
    /// поверх неподвижных обоев, шаг через пустоту, похожесть,
    /// кадр на месте, изображение опровергло события.
    enum Source: String { case exact, hint, layer, blank, fuzzy, still, refuted }

    /// Почему кадр не приклеен.
    /// `otherSide` — склейка другой стороны отвергла сдвиг: не совпал с местом, известным по первой стороне, мало
    /// перекрытия после потери места или против событий.
    /// `torn` — кадр снят посреди перерисовки (у края новых строк перекрытие не совпадает) и пропущен.
    enum Reason: String { case full, noMotion, frameSize, noMatch, still, back, hidden, limit, copy, otherSide, torn }

    /// Как решён последний кадр — для журнала съёмки: только числа и имена, без пикселей.
    struct Trace: Equatable {
        /// Решала склейка вверх (сдвиг — в её перевёрнутом кадре: > 0 — содержимое ушло вниз).
        var up = false
        var shift: Int?
        var header = 0
        var footer = 0
        var source: Source?
        /// Сдвиг по событиям; nil — подсказки нет (величина неизвестна или место потеряно).
        var expected: Int?
        var reason: Reason?
        /// Прошлая склейка откачена: кадр, приклеенный последним, был снят посреди перерисовки (см. `add`).
        var undone = false
    }
    /// Высота итога в пикселях (без строк за концом страницы, которые `makeImage` ещё вырежет).
    var height: Int {
        // Как в `makeImage`: прирост вверх — только со строками с рисунком; если вниз приросла лишь пустота, а вверх —
        // текст, итог — склейка вверх.
        let above = up.addedText ? max(0, up.grown) : 0, below = down.addedText || !up.addedText ? max(0, down.grown) : 0
        return down.rows + above + below
    }
    private(set) var isFull = false
    /// Последний `.lost` — из-за одинаковых строк (несколько сдвигов объясняют кадр одинаково), а не из-за
    /// быстрой прокрутки или другого содержимого: HUD подсказывает другое.
    private(set) var lostOnRepeats = false
    /// Как решён последний кадр (той стороной склейки, которая его приклеила или нашла).
    private(set) var trace = Trace()

    /// Склейка растёт от первого кадра в обе стороны: вниз и вверх — в историю чата, к началу документа. Вверх — та же
    /// склейка над перевёрнутыми кадрами: строки, пришедшие сверху, в перевёрнутом кадре приходят снизу.
    private var down = Strip(flipped: false)
    private var up = Strip(flipped: true)
    /// Последней росла склейка вверх: кадр сначала проверяется ею.
    private var upward = false
    /// Где последний найденный кадр относительно первого (строки, вниз > 0) и сколько кадров с тех пор место
    /// не находилось.
    private var position = 0
    private var sinceKnown = 0
    /// Сколько строк за кадр содержимое уезжало недавно (наибольшее, с затуханием); nil — ещё не двигалось.
    private var speed: Int?

    /// Куда содержимое двигалось последним: 1 — вниз по документу, −1 — вверх.
    private var direction = 0
    /// Последний кадр, для которого место не нашлось (см. `sinceKnown`).
    private var unplaced: Signature?

    private mutating func locate(_ found: Int) {
        if found != position { direction = found > position ? 1 : -1 }
        let step = abs(found - position) / (sinceKnown + 1)
        if found != position || speed != nil { speed = max(step, (speed ?? 0) * 4 / 5) }
        position = found
        sinceKnown = 0
        unplaced = nil
    }

    /// Склейка до последнего приклеенного кадра, какой стороной он приклеен, и события с него (см. `add`).
    private final class Undo {
        let state: Stitcher
        let upward: Bool
        var motion: Motion?
        /// Последний кадр, не нашедшийся после той склейки.
        var failed: Signature?
        init(state: Stitcher, upward: Bool, motion: Motion?) {
            self.state = state
            self.upward = upward
            self.motion = motion
        }
    }
    private var undo: Undo?

    /// `motion` — события ввода после прошлого кадра (nil — неизвестно: склейка только по изображению).
    @discardableResult
    mutating func add(_ frame: CGImage, motion input: Motion? = nil) -> Result {
        trace = Trace()
        guard !isFull, let signature = Self.signature(frame) else {
            trace.reason = isFull ? .full : .copy
            return .unchanged
        }
        guard down.started else {
            guard down.start(frame, signature, tracksMotion: input != nil),
                  up.start(frame, signature.flipped(), tracksMotion: input != nil) else { return .unchanged }
            return .first
        }
        var before = self
        before.undo = nil
        let result = place(frame, signature, input)
        if result == .appended {
            undo = Undo(state: before, upward: upward, motion: input)
            return result
        }
        guard let undo else { return result }
        if let input { undo.motion = (undo.motion ?? Motion()) + input }
        // Разрыв внутри новых строк (терминал дорисовал верх экрана на новом месте, низ — ещё на старом, а перекрытие
        // целиком в старой части) при склейке не виден: кадр приклеен, его верх — строки с другого места (на шве
        // «перетёртая» строка), и с ним больше не совпадает ни один кадр — место потеряно до конца съёмки (1.6.6,
        // терминал колесом вверх). Кадр не нашёлся после последней склейки, а без неё находится — та склейка
        // откатывается, как если бы кадра не было. Кадр после неё — как после потери места (перекрытие, достижимость,
        // совпавшие единственные строки, сам не рваный), только точным совпадением и той же стороной: если бы
        // откаченный кадр был цел, этот совпал бы и с ним — перекрытие с ним больше.
        // Рваным может быть и сам этот кадр (тогда он не нашёлся бы ни с той склейкой, ни без неё, но без неё — с
        // другим сдвигом мог бы найтись): откат — только когда экран стоит, два кадра подряд почти одинаковы и оба
        // не нашлись после склейки.
        guard result == .lost, trace.reason == .noMatch || trace.reason == .torn else {
            undo.failed = nil
            return result
        }
        defer { undo.failed = signature }
        guard let failed = undo.failed, Self.same(failed, signature) else { return result }
        var trial = undo.state
        trial.sinceKnown += 1
        if undo.upward { trial.up.skip(nil) } else { trial.down.skip(nil) }
        guard trial.place(frame, signature, undo.motion) == .appended, trial.upward == undo.upward,
              trial.trace.source == .exact else { return result }
        self = trial
        trace.undone = true
        return .appended
    }

    /// Кадры почти одинаковы: содержимое стоит (строки, изменившиеся на месте, — спиннер, часы — не в счёт).
    private static func same(_ a: Signature, _ b: Signature) -> Bool {
        guard a.rows == b.rows else { return false }
        let changed = (0..<a.rows).filter { a.rowKeys[$0] != b.rowKeys[$0] && (a.textured[$0] != 0 || b.textured[$0] != 0) }.count
        return changed <= a.rows / 20
    }

    private mutating func place(_ frame: CGImage, _ signature: Signature, _ input: Motion?) -> Result {
        var flipped: Signature?
        // Дальние кадры сторон — на сколько строк от первого кадра (вниз > 0): кадр, найденный одной стороной, —
        // известное место и для другой.
        let far = (down: down.advanced, up: -up.advanced)
        // Место потеряно: за каждый кадр содержимое уезжает не дальше, чем уезжало недавно (с запасом), — сдвиг
        // стороны, уводящий кадр дальше от последнего известного места, — случайное совпадение.
        let travel = speed.map { min((sinceKnown + 1) * signature.rows, (sinceKnown + 1) * ($0 + 32) + signature.rows / 4) }
            ?? (sinceKnown + 1) * signature.rows
        // Содержимое последним двигалось назад для этой стороны и место потеряно — кадр ушёл дальше назад: вперёд её
        // дальнего кадра он попал бы, лишь пройдя снятое (там бы и нашёлся), — вперёд не дальше одного кадра хода.
        func reach(up isUp: Bool) -> ClosedRange<Int> {
            let from = isUp ? far.up - position : position - far.down
            let back = (isUp ? -direction : direction) < 0
            return (from - travel)...(back ? from + (speed ?? signature.rows) + 32 : from + travel)
        }
        // То же на развороте: содержимое последним двигалось назад для этой стороны, и «вперёд» — только от того места.
        let turning = (upward ? -direction : direction) < 0
        let first = feed(up: upward, frame, signature, &flipped, input,
                         reach: sinceKnown > 0 || turning ? reach(up: upward) : nil)
        let active = upward ? up : down
        // Место — только по принятому кадру: сдвиг, найденный и отвергнутый (`otherSide`), — не место. «Кадр стоит»
        // после потери места — тоже нет: на обоях с сериями одинаковых пузырей неподвижный узор перевешивает, и место
        // сбросилось бы на дальний кадр, хотя кадр далеко от него. Но кадр, совпавший с дальним целиком, — место.
        let stillAfterLoss = active.trace.reason == .still && sinceKnown > 0 && active.trace.header < signature.rows
        if first != .lost, !stillAfterLoss, let shift = active.trace.shift {
            locate(upward ? far.up - shift : far.down + shift)
        } else if first == .lost || stillAfterLoss {
            // Пауза после потери места: кадр тот же, что прошлый ненайденный, — содержимое не двигалось, и ход от
            // последнего места не растёт (иначе после паузы «место известно точнее кадра» не наступило бы никогда).
            if unplaced.map({ !Self.same($0, signature) }) ?? true { sinceKnown += 1 }
            unplaced = signature
        }
        // Другая сторона — только если кадр может быть по ту сторону первого кадра.
        // - Эта сторона нашла кадр (возврат назад): место известно. Кадр внутри снятого — другой стороне нечего
        //   добавить; дальше её дальнего кадра — ей точная подсказка, на сколько он сдвинут.
        // - Эта сторона потеряла место, ещё не росла или последним видела движение назад: другая сторона пробует
        //   строже (без подсказки ложное «точное» совпадение на одинаковых пузырях, краях, обоях — частое).
        // Потеря места на ходу вперёд (слишком быстро) — кадр дальше, а не по ту сторону.
        // - После потери места известно последнее место и сколько кадров прошло: за кадр содержимое уезжает не дальше
        //   кадра, и сдвиг другой стороны, уводящий кадр дальше, — случайное совпадение.
        var otherSide = false, hint: Int?, strict = false, otherReach: ClosedRange<Int>?
        switch first {
        case .lost:
            otherReach = reach(up: !upward)
            otherSide = active.heading <= 0 && otherReach!.upperBound > 0
            strict = true
        case .unchanged where active.trace.reason == .back:
            let shift = upward ? position - far.down : far.up - position
            otherSide = shift > 0
            hint = shift
        default:
            break
        }
        var result = first
        if first == .appended {
            // Кадр приклеен с одной стороны — с другой он заведомо не новый: там только копятся события.
            if upward { down.skip(input) } else { up.skip(input) }
            trace = upward ? up.trace : down.trace
        } else if !otherSide {
            if upward { down.skip(input) } else { up.skip(input) }
            trace = active.trace
            if first == .lost { lostOnRepeats = active.lostOnRepeats }
        } else {
            let second = feed(up: !upward, frame, signature, &flipped, input, hint: hint, strict: strict, reach: otherReach)
            let other = upward ? down : up
            if second != .lost, let shift = other.trace.shift { locate(upward ? far.down + shift : far.up - shift) }
            if second == .appended {
                upward.toggle()
                trace = upward ? up.trace : down.trace
                result = .appended
            } else if first == .lost, second == .lost {
                // Кадр не нашёлся ни с одной стороны. Иначе он внутри уже снятого (прокрутка назад) — не потеря.
                trace = upward ? up.trace : down.trace
                lostOnRepeats = upward ? up.lostOnRepeats : down.lostOnRepeats
            } else {
                trace = first == .unchanged ? (upward ? up.trace : down.trace) : (upward ? down.trace : up.trace)
                result = .unchanged
            }
        }
        isFull = down.isFull || up.isFull
        return result
    }

    private mutating func feed(up isUp: Bool, _ frame: CGImage, _ signature: Signature, _ flipped: inout Signature?,
                               _ input: Motion?, hint: Int? = nil, strict: Bool = false,
                               reach: ClosedRange<Int>? = nil) -> Result {
        let exact = down.exactCapture || up.exactCapture, opening = down.advanced == 0 && up.advanced == 0
        let limit = min(Self.maxHeight, Self.maxPixels / max(frame.width, 1))
        if isUp {
            if flipped == nil { flipped = signature.flipped() }
            guard let flipped else { return .unchanged }
            return up.add(frame, flipped, input, limit: limit - max(0, down.grown), exactCapture: exact, hint: hint, strict: strict,
                          reach: reach, opening: opening)
        }
        return down.add(frame, signature, input, limit: limit - max(0, up.grown), exactCapture: exact, hint: hint, strict: strict,
                        reach: reach, opening: opening)
    }

    func makeImage() -> CGImage? {
        guard down.started else { return nil }
        let below = down.pieces()
        // Сверху приросли только однотонные строки (отскок у начала страницы) — их не рисуем.
        guard up.addedText else { return Self.draw(below.map { ($0.image, $0.rows, false) }) }
        let above = up.pieces()
        guard down.addedText else { return Self.draw(above.reversed().map { ($0.image, $0.rows, true) }) }
        // Обе стороны: сверху — то, что приросло вверх (с шапкой последнего кадра), ниже — первый кадр без строк,
        // которые склейка вверх сочла шапкой, и то, что приросло вниз.
        guard let kept = up.firstRows, down.firstRows != nil else { return Self.draw(below.map { ($0.image, $0.rows, false) }) }
        let header = down.rows - kept
        var parts = above.filter { !$0.first }.reversed().map { ($0.image, $0.rows, true) }
        for piece in below {
            let rows = piece.first ? max(piece.rows.lowerBound, header)..<max(piece.rows.upperBound, header) : piece.rows
            if !rows.isEmpty { parts.append((piece.image, rows, false)) }
        }
        return Self.draw(parts)
    }

    /// Кусочки сверху вниз: изображение, его строки, хранится ли оно перевёрнутым.
    private static func draw(_ parts: [(image: CGImage, rows: Range<Int>, flipped: Bool)]) -> CGImage? {
        guard let first = parts.first?.image else { return nil }
        let height = parts.reduce(0) { $0 + $1.rows.count }
        guard height > 0 else { return nil }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = first.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? sRGB
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info)
                ?? CGContext(data: nil, width: first.width, height: height, bitsPerComponent: 8,
                             bytesPerRow: 0, space: sRGB, bitmapInfo: info) else { return nil }
        var drawn = 0
        for (image, rows, flipped) in parts {
            // Строки перевёрнутого кусочка считаются в нём самом; на итоге он рисуется зеркально.
            guard let piece = rows.count == image.height ? image
                    : image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)) else { continue }
            let y = height - drawn - piece.height
            if flipped {
                context.saveGState()
                context.translateBy(x: 0, y: CGFloat(y + piece.height))
                context.scaleBy(x: 1, y: -1)
                context.draw(piece, in: CGRect(x: 0, y: 0, width: piece.width, height: piece.height))
                context.restoreGState()
            } else {
                context.draw(piece, in: CGRect(x: 0, y: y, width: piece.width, height: piece.height))
            }
            drawn += piece.height
        }
        return context.makeImage()
    }

    /// Части `range` вне `skip`.
    private static func subtract(_ skip: Range<Int>?, from range: Range<Int>) -> [Range<Int>] {
        guard let skip, skip.overlaps(range) else { return [range] }
        return [range.lowerBound..<max(range.lowerBound, skip.lowerBound), min(range.upperBound, skip.upperBound)..<range.upperBound]
            .filter { !$0.isEmpty }
    }

    // MARK: - Склейка в одну сторону

    /// Склейка от первого кадра в одну сторону: новые строки приходят снизу. Склейка вверх получает перевёрнутые
    /// кадры (`flipped`) — и подписи, и кусочки итога у неё перевёрнуты.
    private struct Strip {
        let flipped: Bool
        var started: Bool { previous != nil }
        /// Сумма приклеенных сдвигов: на сколько строк дальний кадр этой стороны ушёл от первого.
        private(set) var advanced = 0
        /// Насколько итог вырос с этой стороны от первого кадра.
        var grown: Int { bodyHeight + footerRows - rows }
        private(set) var isFull = false
        private(set) var rows = 0
        /// Склеенное содержимое без закреплённого низа. Каждый кусочек — своя копия, а не вырезка из кадра:
        /// вырезка держала бы буфер всего кадра.
        private var chunks: [CGImage] = []
        /// Первый кусочек — первый кадр (быть может, без закреплённого низа); nil — его срезали целиком.
        var firstRows: Int? { firstIntact ? chunks.first?.height : nil }
        private var firstIntact = true
        /// Приклеены строки с рисунком (а не только однотонный фон за концом страницы).
        private(set) var addedText = false
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
        private var pageGain: Double?
        /// Высота прокручиваемой части по последней уверенной склейке (между шапкой и низом).
        private var scrollSpan: Int?
        /// Обычная относительная ошибка подсказки: насколько ожидаемый сдвиг расходился с найденным по изображению
        /// (доля от ожидаемого; за серию потерянных кадров ошибка копится вместе со сдвигом).
        private var hintError = 0.25
        /// После `.lost` и до следующей склейки: содержимое могло уехать без событий (клавиши, ползунок, ссылка),
        /// поэтому сдвиг от дальнего кадра по событиям ничего не значит — решает только изображение.
        private var lostSinceAppend = false
        /// Была склейка по точному совпадению: захват точный, поиск по похожести больше не нужен (и опасен —
        /// похожие строки лога при нём совпадают).
        private(set) var exactCapture = false
        private(set) var lostOnRepeats = false
        /// Прошлый кадр пропущен как снятый посреди перерисовки (см. `torn`); в перекрытии видео или анимация — разрыв
        /// не проверяется.
        private var skippedTorn = false
        private var animated = false
        /// Куда последним двигалось содержимое: 1 — вперёд (приклеено), −1 — назад, 0 — ещё никуда.
        private(set) var heading = 0
        /// Обои позади содержимого, по уверенным склейкам (см. `Background`).
        private var background: Background?
        private(set) var trace = Trace()

        init(flipped: Bool) { self.flipped = flipped }

        mutating func start(_ frame: CGImage, _ signature: Signature, tracksMotion: Bool) -> Bool {
            guard let copy = cut(frame, rows: 0..<frame.height) else { return false }
            rows = frame.height
            chunks = [copy]
            bodyHeight = rows
            bottom = rows
            previous = signature
            self.tracksMotion = tracksMotion
            return true
        }

        /// События склейки вверх — в её перевёрнутом кадре: прокрутка вверх для неё — «вниз».
        private func oriented(_ input: Motion) -> Motion {
            flipped ? Motion(pixels: -input.pixels, lines: -input.lines, pages: -input.pages, unknown: input.unknown) : input
        }

        /// Кадр приклеен с другой стороны: события копятся, но сдвиг от дальнего кадра этой стороны по ним уже
        /// не подсказка — место отсюда «потеряно», пока изображение снова не найдёт его.
        mutating func skip(_ input: Motion?) {
            if let input {
                motion = motion + oriented(input)
                tracksMotion = true
            }
            lostSinceAppend = true
        }

        /// `hint` — точно известный сдвиг (кадр нашла другая сторона); `strict` — кадр после потери места другой
        /// стороной (или этой): без подсказки принимается лишь сдвиг с перекрытием не меньше трети (у своей стороны — четверти), достижимый от
        /// последнего известного места (`reach`), а на другой стороне — и не против событий (у своей стороны после
        /// потери места события ненадёжны: рывок, который монитор не видел).
        mutating func add(_ frame: CGImage, _ signature: Signature, _ input: Motion?, limit heightLimit: Int,
                          exactCapture shared: Bool, hint: Int? = nil, strict: Bool = false,
                          reach: ClosedRange<Int>? = nil, opening: Bool = false) -> Result {
            trace = Trace(up: flipped)
            guard let previous else { return .unchanged }
            if let input {
                motion = motion + oriented(input)
                tracksMotion = true
            }
            // Размер кадра задан при старте; кадр другого размера к склейке не подходит.
            guard frame.height == rows, signature.rows == rows, frame.width == chunks.first?.width else {
                trace.reason = .frameSize
                return lose()
            }
            // Событий прокрутки не было — содержимое на месте: видео, анимация, подсветка не прокрутка.
            if tracksMotion, motion.isEmpty {
                trace.reason = .noMotion
                return .unchanged
            }
            // События, накопленные с дальнего кадра, — хотя бы направление: и после потери места кадр не может
            // оказаться за дальним кадром, если по точным событиям содержимое ушло в другую сторону.
            let events = expectedShift
            let expected = hint ?? (lostSinceAppend ? nil : events)
            trace.expected = expected
            // Без подсказки прокрутку от анимации отличает только размер: движется почти вся область прокрутки
            // (после первой склейки — не меньше 60% уже известной прокручиваемой части, до неё — половина кадра, а
            // если на месте стоят строки и сверху, и снизу — 2/3: так выглядит панорама или карусель посреди стоящей
            // страницы), а не полоса посреди стоящего окна. С подсказкой правило действует, когда изображение с ней
            // спорит.
            let sizeRule = scrollSpan.map { $0 * 6 / 10 } ?? rows / 2
            let ambiguity = Ambiguity()
            guard let found = Stitcher.match(previous: previous, current: signature, expected: expected, hintError: hintError,
                                             minSpan: sizeRule, spanKnown: scrollSpan != nil, allowFuzzy: !shared,
                                             allowBlank: !lostSinceAppend, background: background,
                                             partialHint: motion.lines != 0 || motion.pages != 0, minColumns: flipped ? 3 : 1,
                                             ambiguity: ambiguity) else {
                // Дальше назад, чем кадр цепочки: ближе к дальнему кадр нашёлся бы и по нему (на списке из одинаковых
                // строк соседний кадр совпадает и со сдвигом на период).
                if !strict, hint == nil, let chain = chained(signature, minSpan: sizeRule), chain.shift < -retreat.rows {
                    return placeBack(chain.shift, chain.match, chain.source, signature)
                }
                // Одинаковые строки — и когда «ничья», и когда большая часть строк с рисунком в кадре повторяется.
                let textured = (0..<rows).filter { signature.textured[$0] != 0 }.count
                let repeated = textured - signature.uniqueRow.filter { $0 }.count
                trace.reason = .noMatch
                return lose(repeats: ambiguity.repeated || textured > 0 && repeated * 2 > textured)
            }
            let match = found.match
            trace.shift = match.shift
            trace.header = match.header
            trace.footer = match.footer
            trace.source = found.source
            if match.shift > 0, let hint, abs(match.shift - hint) > max(8, hint / 20) {
                trace.reason = .otherSide
                return lose()
            }
            // Кадр снят посреди перерисовки: часть экрана терминал уже нарисовал на новом месте, часть — ещё на старом.
            // Его новые строки — с другого места, чем перекрытие (на шве «перетёртая» строка), и с ним самим не совпал бы
            // больше ни один кадр — место потеряно до конца съёмки (1.6.6, терминал колесом вверх). Кадр пропускается, а
            // не теряет место: события копятся, следующий кадр сравнивается с прошлым. Рваный кадр — один: второй подряд
            // так же «рваный» — это видео или анимация в перекрытии, а не перерисовка; тогда проверка до конца съёмки
            // выключена (иначе место терялось бы до конца или через кадр).
            // Только когда по событиям содержимое ушло дальше найденного (у рваного кадра совпала старая часть): иначе на
            // обоях край пузырей у перекрытия тоже «не совпадает», а пропуск кадра на быстрой прокрутке теряет место.
            let lagging = expected.map { match.shift + max(16, $0 / 10) < $0 } ?? false
            if match.shift > 0, lagging, !animated, found.source == .exact || found.source == .hint, Self.torn(match, previous, signature) {
                if skippedTorn {
                    animated = true
                } else {
                    skippedTorn = true
                    trace.reason = .torn
                    lostOnRepeats = false
                    return .lost
                }
            }
            skippedTorn = false
            // Сдвиг вперёд после потери места — и сдвиг назад после неё: ложное «назад» стало бы местом, и от него прошло
            // бы ложное «вперёд» (обои с сериями одинаковых пузырей).
            let checked = match.shift > 0 || match.shift < 0 && (strict || lostSinceAppend)
            if checked, hint == nil {
                let span = rows - match.header - match.footer, distance = abs(match.shift)
                let lost = strict || lostSinceAppend
                // После потери места перекрытие из одних повторов (серия «Ок», края пузырей) ничего не доказывает:
                // нужно место, известное точнее кадра, — или совпавшие целиком строки, единственные в кадре. У слоя
                // обоев в ключах строк обои — ему только место (на обоях с сериями одинаковых пузырей он находит и
                // ложное «назад», и ложное «вперёд»). У похожести (до первой точной склейки) строки не совпадают
                // побайтно: своей стороне хватает перекрытия и достижимости, другой — только места.
                var unique = 0
                let overlap = max(match.header, match.header - match.shift)..<max(match.header, min(rows - match.footer, rows - match.footer - match.shift))
                for r in overlap where signature.uniqueRow[r] && previous.rowKeys[r + match.shift] == signature.rowKeys[r] { unique += 1 }
                let near = (reach?.count ?? Int.max) <= 2 * rows + 1
                // Слою обоев после долгой потери места (`near` уже не наступит: ход растёт с каждым кадром) — события:
                // сдвиг сходится с ними в пределах обычной ошибки подсказки. Ложные совпадения слоя на сериях пузырей
                // уводят на целый пузырь, а не на ошибку событий.
                // В начале съёмки (снят только первый кадр, модель обоев пуста, строки колеса в пиксели ещё не
                // переводятся) повторить можно лишь первый кадр: хватает направления событий, а без них — перекрытия.
                let moved = motion.pixels + motion.lines + motion.pages
                let toward = opening && (moved == 0 || moved * Double(match.shift) > 0)
                let agrees = toward || events.map { abs(match.shift - $0) <= min(rows / 6, max(16, Int(2 * hintError * Double(max(abs($0), 50))))) } ?? false
                let evidence = near || (found.source == .fuzzy ? !strict : found.source == .layer ? agrees : unique >= 2)
                let ok: Bool
                if match.shift > 0 {
                    ok = !lost || found.source != .blank && (span - distance) * (strict ? 3 : 4) >= span
                        && (!strict || (events ?? 0) >= 0) && evidence
                } else {
                    ok = found.source != .blank && (span - distance) * 4 >= span && (!lost || evidence)
                }
                // Назад — только нижняя граница: верхняя («вперёд не дальше кадра хода») — для сдвига вперёд, а кадр,
                // вернувшийся по снятому ближе к дальнему кадру, как раз найден.
                let reached = reach.map { match.shift < 0 ? match.shift >= $0.lowerBound : $0.contains(match.shift) } ?? true
                guard ok, reached else {
                    trace.reason = .otherSide
                    return lose()
                }
            }
            // «Назад» с малым перекрытием с дальним кадром на повторах бывает ложным (сдвиг на период), а кадр цепочки
            // перекрывается с этим почти целиком: место — по нему.
            if match.shift < 0, !strict, hint == nil, (rows - match.header - match.footer + match.shift) * 4 < rows - match.header - match.footer,
               let chain = chained(signature, minSpan: sizeRule), chain.shift != match.shift {
                return placeBack(chain.shift, chain.match, chain.source, signature)
            }
            guard match.shift > 0 else {
                trace.reason = match.shift == 0 ? .still : .back
                if match.shift < 0 { heading = -1 }
                // Без движения или прокрутка назад: ждём, пока снова пойдут новые строки.
                retreat = (-match.shift, match.shift < 0 ? signature : nil)
                // Кадр не изменился, а события были: страница упёрлась в конец (или ещё не отрисовалась). Величина
                // событий дальше не подсказка — копилась бы впустую, — но «прокрутка могла быть» остаётся.
                if match.shift == 0, match.header == rows || found.refutesMotion, motion.unknown == 0, !motion.isEmpty {
                    motion = Motion(unknown: 1)
                }
                return .unchanged
            }
            let end = rows - match.footer            // конец движущейся части нового кадра
            let start = min(bottom, end)             // строка дальнего кадра, с которой продолжается тело
            var from = start - match.shift           // та же строка в новом кадре
            // Прошлый кадр счёл строки ниже `bottom` закреплённым низом, а теперь они двигаются и успели уехать
            // под шапку: их берём из того низа. Так бывает, только когда низ стал меньше (start == bottom).
            let hidden = max(0, match.header - from)
            guard hidden <= footerRows else {
                trace.reason = .hidden
                return lose()
            }
            var patch: CGImage?
            if hidden > 0 {
                guard let footer, let piece = Stitcher.copy(footer, rows: 0..<min(hidden, footer.height)) else {
                    trace.reason = .hidden
                    return lose()
                }
                patch = piece
                from += hidden
            }
            let room = heightLimit - bodyHeight - match.footer - hidden + (bottom - start)
            guard room > 0, from < end else {
                isFull = room <= 0
                trace.reason = isFull ? .full : .limit
                return .unchanged
            }
            let count = min(end - from, room)
            guard let piece = cut(frame, rows: from..<(from + count)) else {
                trace.reason = .copy
                return .unchanged
            }
            let tail = match.footer > 0 ? cut(frame, rows: end..<rows) : nil
            trimBody(bottom - start)
            if let patch { append(patch) }
            append(piece)
            if (from..<(from + count)).contains(where: { signature.textured[$0] != 0 }) { addedText = true }
            footer = tail
            footerRows = tail?.height ?? 0
            bottom = from + count
            retreat = (0, nil)
            isFull = count < end - from || bodyHeight + footerRows >= heightLimit
            if found.confident {
                if found.exact {
                    var known = background ?? Background(rows: rows)
                    known.learn(previous, signature, rows: match.header..<(rows - match.footer))
                    background = known
                }
                scrollSpan = rows - match.header - match.footer
                if let expected { hintError = hintError * 0.7 + Double(abs(match.shift - expected)) / Double(max(abs(expected), 50)) * 0.3 }
                learnGain(shift: match.shift)
                if found.exact { exactCapture = true }
            }
            self.previous = signature
            motion = Motion()
            lostSinceAppend = false
            heading = 1
            advanced += match.shift
            return .appended
        }

        /// Возврат дальше кадра от дальнего: перекрытия с ним уже нет, и кадр ищется по последнему кадру позади него
        /// (`retreat`) — по цепочке, как его и прокручивали. Соседние кадры перекрываются почти целиком: нужно не меньше
        /// двух третей, у точного совпадения — хотя бы две совпавшие строки, единственные в кадре. Итог — сдвиг от
        /// дальнего кадра (1.6.7: ловушка после возврата больше чем на экран).
        private func chained(_ signature: Signature, minSpan: Int) -> (shift: Int, match: Match, source: Source)? {
            guard retreat.rows > 0, let latest = retreat.latest,
                  let found = Stitcher.match(previous: latest, current: signature, hintError: hintError, minSpan: minSpan,
                                             spanKnown: scrollSpan != nil, allowFuzzy: false, allowBlank: false,
                                             background: background, minColumns: flipped ? 3 : 1),
                  found.source == .exact || found.source == .layer else { return nil }
            let match = found.match, span = rows - match.header - match.footer
            guard (span - abs(match.shift)) * 3 >= span * 2 else { return nil }
            if found.source == .exact {
                var unique = 0
                let overlap = max(match.header, match.header - match.shift)..<max(match.header, min(rows - match.footer, rows - match.footer - match.shift))
                for r in overlap where signature.uniqueRow[r] && latest.rowKeys[r + match.shift] == signature.rowKeys[r] { unique += 1 }
                guard unique >= 2 else { return nil }
            }
            return (match.shift - retreat.rows, match, found.source)
        }

        /// Кадр найден по цепочке: место — назад, внутрь снятого.
        private mutating func placeBack(_ shift: Int, _ match: Match, _ source: Source, _ signature: Signature) -> Result {
            trace.shift = shift
            trace.header = match.header
            trace.footer = match.footer
            trace.source = source
            trace.reason = .back
            heading = -1
            retreat = (-shift, signature)
            return .unchanged
        }

        /// У края новых строк перекрытие не совпадает: от края подряд больше строки текста — строки, в которых заметная
        /// часть полос с рисунком не та же, что в прошлом кадре, ни на этом сдвиге, ни на своём месте (неподвижный список
        /// чатов, обои), а дальше от края строки совпадают. Одна изменившаяся строка (курсор, счётчик) — не разрыв.
        private static func torn(_ match: Match, _ previous: Signature, _ current: Signature) -> Bool {
            let w = Stitcher.columns, rows = current.rows
            func differs(_ r: Int) -> Bool {
                let moved = (r + match.shift) * w, here = r * w
                var textured = 0, wrong = 0
                for j in 0..<w where current.textured[r] >> UInt64(j) & 1 != 0 {
                    textured += 1
                    let hash = current.hashes[here + j]
                    if hash != previous.hashes[moved + j], hash != previous.hashes[here + j] { wrong += 1 }
                }
                return wrong >= max(2, textured / 4)
            }
            var band = 0, r = rows - match.footer - match.shift - 1
            while r >= match.header {
                if current.textured[r] != 0 {
                    if !differs(r) { break }
                    band += 1
                }
                r -= 1
            }
            return r >= match.header && band >= max(16, rows / 32)
        }

        private mutating func lose(repeats: Bool = false) -> Result {
            lostSinceAppend = true
            lostOnRepeats = repeats
            return .lost
        }

        /// Строки кадра в собственный буфер — в ориентации этой склейки (`rows` — строки перевёрнутого кадра).
        private func cut(_ frame: CGImage, rows range: Range<Int>) -> CGImage? {
            guard flipped else { return Stitcher.copy(frame, rows: range) }
            return Stitcher.copy(frame, rows: (frame.height - range.upperBound)..<(frame.height - range.lowerBound), flipped: true)
        }

        /// Ожидаемый сдвиг по событиям с дальнего кадра; nil — величина неизвестна (клавиши, колесо без коэффициента).
        private var expectedShift: Int? {
            guard tracksMotion, motion.unknown == 0 else { return nil }
            var shift = motion.pixels * pixelGain
            if motion.lines != 0 {
                guard let lineGain else { return nil }
                shift += motion.lines * lineGain
            }
            if motion.pages != 0 {
                guard let pageGain else { return nil }
                shift += motion.pages * pageGain
            }
            return Int(shift.rounded())
        }

        /// Коэффициент «события → пиксели» по уверенной склейке (сдвиг однозначен по изображению).
        private mutating func learnGain(shift: Int) {
            guard tracksMotion, motion.unknown == 0, shift >= 16 else { return }
            if motion.lines == 0, motion.pages == 0, abs(motion.pixels) >= 8 {
                let ratio = Double(shift) / motion.pixels
                if (0.25...4).contains(abs(ratio)) { pixelGain = pixelGain * 0.5 + ratio * 0.5 }
            } else if abs(motion.pixels) < 0.5, motion.pages == 0, motion.lines != 0 {
                let ratio = Double(shift) / motion.lines
                if (1...400).contains(abs(ratio)) { lineGain = lineGain.map { $0 * 0.5 + ratio * 0.5 } ?? ratio }
            } else if abs(motion.pixels) < 0.5, motion.lines == 0, motion.pages != 0 {
                let ratio = Double(shift) / motion.pages
                if (16...Double(rows) * 1.5).contains(abs(ratio)) { pageGain = pageGain.map { $0 * 0.5 + ratio * 0.5 } ?? ratio }
            }
        }

        /// Кусочки итога этой стороны по порядку (в её ориентации): тело и закреплённый низ, без однотонных строк
        /// за концом страницы. `first` — строки первого кадра.
        func pieces() -> [(image: CGImage, rows: Range<Int>, first: Bool)] {
            // Отскок в конце: однотонные строки за концом страницы не рисуются.
            let total = bodyHeight + footerRows
            let skip = overscroll().map { (total - (rows - $0.lowerBound))..<(total - (rows - $0.upperBound)) }
            var top = 0
            var out: [(image: CGImage, rows: Range<Int>, first: Bool)] = []
            for (index, image) in (chunks + [footer].compactMap { $0 }).enumerated() {
                let range = top..<(top + image.height)
                top += image.height
                for part in Stitcher.subtract(skip, from: range) {
                    out.append((image, (part.lowerBound - range.lowerBound)..<(part.upperBound - range.lowerBound),
                                index == 0 && firstIntact))
                }
            }
            return out
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
                    if chunks.isEmpty { firstIntact = false }
                    bodyHeight -= last.height
                    left -= last.height
                } else {
                    guard let kept = Stitcher.copy(last, rows: 0..<(last.height - left)) else { return }
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
            let w = Stitcher.columns
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
            guard cut.lowerBound > 0, rows - cut.lowerBound < bodyHeight + footerRows else { return nil }
            let reference = Int(previous[(end - 1) * w])
            for r in cut {
                let row = previous[(r * w)..<((r + 1) * w)]
                guard let low = row.min(), let high = row.max(), Int(high) - Int(low) <= 6,
                      abs(Int(low) - reference) <= 6 else { return nil }
            }
            return cut
        }
    }

    /// Копия строк `rows` в собственный буфер, в цветовом пространстве кадра. `flipped` — зеркально по вертикали
    /// (для склейки вверх).
    private static func copy(_ image: CGImage, rows: Range<Int>, flipped: Bool = false) -> CGImage? {
        guard !rows.isEmpty,
              let cropped = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count))
        else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if flipped {
            context.translateBy(x: 0, y: CGFloat(cropped.height))
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    // MARK: - Подпись

    /// Яркость `(R + 2G + B) / 4` в полном разрешении (vImage); строки сохранены, верх — первая.
    /// nil — формат не 8 бит × 4 канала (тогда подпись рисуется через CoreGraphics).
    private static func luminance(_ image: CGImage) -> [UInt8]? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.width >= columns,
              let data = image.dataProvider?.data, CFDataGetLength(data) >= image.bytesPerRow * image.height,
              let base = CFDataGetBytePtr(data) else { return nil }
        // Где цвет в 4 байтах: альфа (или пропуск) впереди или сзади, порядок байтов прямой или обратный.
        let alpha = image.alphaInfo
        let little = image.byteOrderInfo == .order32Little
        let alphaFirst = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        let alphaLast = alpha == .premultipliedLast || alpha == .last || alpha == .noneSkipLast
        guard alphaFirst || alphaLast || alpha == .none else { return nil }
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
        return converted ? luma : nil
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

    /// Отпечатки полос: строка плоскости `plane` (`width` байт) делится на `columns` полос, у каждой — 64-битный
    /// отпечаток всех её байтов. Совпадение отпечатков — совпадение пикселей (случайное совпадение невероятно).
    private static func segmentHashes(_ plane: [UInt8], width: Int, height: Int) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: columns * height)
        let bounds = (0...columns).map { $0 * width / columns }
        plane.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            out.withUnsafeMutableBufferPointer { o in
                for r in 0..<height {
                    let row = base + r * width
                    for j in 0..<columns {
                        var x = bounds[j]
                        let end = bounds[j + 1]
                        var h: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(end - x)
                        while x + 8 <= end {
                            h = (h ^ row.loadUnaligned(fromByteOffset: x, as: UInt64.self)) &* 0xFF51_AFD7_ED55_8CCD
                            h ^= h >> 31
                            x += 8
                        }
                        while x < end {
                            h = (h ^ UInt64(row.load(fromByteOffset: x, as: UInt8.self))) &* 0xC4CE_B9FE_1A85_EC53
                            x += 1
                        }
                        h ^= h >> 29
                        o[r * columns + j] = h &* 0xBF58_476D_1CE4_E5B9
                    }
                }
            }
        }
        return out
    }

    /// Подпись кадра. Первая строка буфера — верх изображения.
    static func signature(_ image: CGImage) -> Signature? {
        let height = image.height
        let fineColumns = max(columns, min(image.width, maxFineColumns))
        guard height > 0 else { return nil }
        var fine = [UInt8](repeating: 0, count: fineColumns * height)
        // Быстрый путь — яркость прямо из пикселей кадра (8 бит на канал, 4 байта на пиксель) через vImage:
        // перерисовка в серое через CoreGraphics пересчитывает цвет и на 5K стоит ~60 мс из 150 мс тика.
        var hashes: [UInt64]
        if var luma = luminance(image) {
            hashes = segmentHashes(luma, width: image.width, height: height)
            guard scale(&luma, width: image.width, height: height, into: &fine, columns: fineColumns) else { return nil }
        } else {
            let drawn = fine.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: fineColumns, height: height,
                                              bitsPerComponent: 8, bytesPerRow: fineColumns,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: fineColumns, height: height))
                return true
            }
            guard drawn else { return nil }
            hashes = segmentHashes(fine, width: fineColumns, height: height)
        }
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
        let textured = segmentTexture(fine, fineColumns: fineColumns, rows: height)
        let flat = fine.withUnsafeBufferPointer { f in
            (0..<height).map { r -> Bool in
                var low = f[r * fineColumns], high = low
                for k in (r * fineColumns)..<((r + 1) * fineColumns) {
                    let v = f[k]
                    if v < low { low = v } else if v > high { high = v }
                }
                return high - low <= 2
            }
        }
        let (distinct, unique, keys, rowsIndex, start) = segmentIndex(hashes: hashes, textured: textured, rows: height)
        let (uniqueRow, rowKeys) = uniqueRows(hashes: hashes, textured: textured, rows: height)
        var fineValues = [Float](repeating: 0, count: fine.count)
        vDSP_vfltu8(fine, 1, &fineValues, 1, vDSP_Length(fine.count))
        return Signature(rows: height, fineValues: fineValues, fineColumns: fineColumns, coarse: coarse, detail: detail, flat: flat,
                         hashes: hashes, textured: textured, distinct: distinct, unique: unique, uniqueRow: uniqueRow, rowKeys: rowKeys,
                         indexKeys: keys, indexRows: rowsIndex, indexStart: start)
    }

    /// Полосы с рисунком: разброс яркости внутри полосы (по точной подписи) не меньше 8 уровней. Однотонная полоса
    /// совпадает с любой другой того же цвета и доводом не служит.
    private static func segmentTexture(_ fine: [UInt8], fineColumns fw: Int, rows: Int) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: rows)
        let bounds = (0...columns).map { $0 * fw / columns }
        fine.withUnsafeBufferPointer { f in
            for r in 0..<rows {
                var mask: UInt64 = 0
                let a = r * fw
                for j in 0..<columns where bounds[j + 1] > bounds[j] {
                    var low = f[a + bounds[j]], high = low
                    for k in (bounds[j] + 1)..<max(bounds[j] + 1, bounds[j + 1]) {
                        let v = f[a + k]
                        if v < low { low = v } else if v > high { high = v }
                    }
                    if high - low >= 8 { mask |= 1 << UInt64(j) }
                }
                out[r] = mask
            }
        }
        return out
    }

    /// Сколько раз отпечаток полосы встречается в своей колонке кадра: частые полосы (одинаковые строки фона,
    /// линии таблицы) не доводы, редкие (не больше `rareLimit`) — в индекс для голосования. Одинаковые строки подряд
    /// (однотонная по вертикали плашка) — одно вхождение; в индекс идёт его первая строка.
    private static func segmentIndex(hashes: [UInt64], textured: [UInt64], rows: Int)
        -> (distinct: [UInt64], unique: [UInt64], keys: [UInt64], rows: [Int32], start: [Int]) {
        let w = columns
        let common = max(8, rows / 20)
        var distinct = textured
        var unique = [UInt64](repeating: 0, count: rows)
        var keys: [UInt64] = [], indexRows: [Int32] = [], start = [0]
        keys.reserveCapacity(rows * 16)
        indexRows.reserveCapacity(rows * 16)
        // Своя таблица с открытой адресацией: Dictionary на 5K (180 000 полос) заметно медленнее.
        var size = 16
        while size < rows * 2 { size <<= 1 }
        var slotKey = [UInt64](repeating: 0, count: size)
        var slotCount = [Int32](repeating: 0, count: size)
        var slotStamp = [Int32](repeating: -1, count: size)
        var slotOf = [Int](repeating: 0, count: rows)
        var entries: [(UInt64, Int32)] = []
        entries.reserveCapacity(rows)
        for j in 0..<w {
            let bit: UInt64 = 1 << UInt64(j), stamp = Int32(j)
            for r in 0..<rows where textured[r] & bit != 0 {
                let key = hashes[r * w + j]
                let continues = r > 0 && textured[r - 1] & bit != 0 && hashes[(r - 1) * w + j] == key
                var slot = Int(truncatingIfNeeded: (key ^ (key >> 33)) &* 0x9E37_79B9_7F4A_7C15) & (size - 1)
                while slotStamp[slot] == stamp && slotKey[slot] != key { slot = (slot + 1) & (size - 1) }
                if slotStamp[slot] != stamp {
                    slotStamp[slot] = stamp
                    slotKey[slot] = key
                    slotCount[slot] = 0
                }
                if !continues { slotCount[slot] += 1 }
                slotOf[r] = slot
            }
            entries.removeAll(keepingCapacity: true)
            for r in 0..<rows where textured[r] & bit != 0 {
                let count = Int(slotCount[slotOf[r]])
                if count > common { distinct[r] &= ~bit }
                if count == 1 { unique[r] |= bit }
                let continues = r > 0 && textured[r - 1] & bit != 0 && hashes[(r - 1) * w + j] == hashes[r * w + j]
                if count <= rareLimit, !continues { entries.append((hashes[r * w + j], Int32(r))) }
            }
            entries.sort { $0.0 < $1.0 }
            for (key, row) in entries {
                keys.append(key)
                indexRows.append(row)
            }
            start.append(keys.count)
        }
        return (distinct, unique, keys, indexRows, start)
    }

    /// Строки, единственные в кадре целиком (по отпечаткам всех полос); серия одинаковых строк подряд — одна.
    /// `texturedOnly` — строка сравнивается только по полосам с рисунком (без неподвижного слоя, см. `without`).
    private static func uniqueRows(hashes: [UInt64], textured: [UInt64], rows: Int, texturedOnly: Bool = false)
        -> (unique: [Bool], keys: [UInt64]) {
        var keys = [UInt64](repeating: 0, count: rows)
        for r in 0..<rows {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325
            for j in 0..<columns where !texturedOnly || textured[r] & (1 << UInt64(j)) != 0 {
                h = (h ^ hashes[r * columns + j] ^ UInt64(j)) &* 0x0000_0100_0000_01B3
            }
            keys[r] = h
        }
        var counts: [UInt64: Int] = [:]
        counts.reserveCapacity(rows)
        for r in 0..<rows where textured[r] != 0 && (r == 0 || keys[r - 1] != keys[r]) { counts[keys[r], default: 0] += 1 }
        return ((0..<rows).map { textured[$0] != 0 && counts[keys[$0]] == 1 }, keys)
    }

    // MARK: - Поиск сдвига

    struct Found {
        var match: Match
        /// Сдвиг однозначен по самому изображению (по нему можно уточнять коэффициент событий).
        var confident: Bool
        /// Найден по точному совпадению строк (а не по похожести).
        var exact = true
        /// Изображение опровергло события: содержимое сдвинулось не так, как они говорят (колесо у конца страницы,
        /// а движется анимация).
        var refutesMotion = false
        var source = Source.exact
    }

    /// Сдвиг содержимого между подписями двух кадров. nil — совпадение не найдено или неоднозначно
    /// (слишком быстрая прокрутка, другое содержимое, повторяющиеся строки без подсказки).
    /// `expected` — сдвиг по событиям прокрутки: среди равных по изображению кандидатов выбирается ближайший к нему.
    /// `hintError` — обычная относительная ошибка подсказки (по прошлым уверенным склейкам).
    /// `minSpan` — без подсказки (или когда изображение с ней спорит) движущаяся часть меньше этого — не прокрутка.
    /// `allowFuzzy` — разрешён ли поиск по похожести, когда точных совпадений нет вовсе (шумный захват).
    static func match(previous p: Signature, current c: Signature, expected: Int? = nil, hintError: Double = 0.25,
                      minSpan: Int = 0, spanKnown: Bool = true, allowFuzzy: Bool = true, allowBlank: Bool = true,
                      background: Background? = nil, partialHint: Bool = false, minColumns: Int = 1,
                      ambiguity given: Ambiguity? = nil) -> Found? {
        let ambiguity = given ?? Ambiguity()
        // Закреплённые строки сначала ищутся мягко: в шапке меняются часы, значки, подсветка. Но так же «почти не
        // меняются» строки лога или таблицы в одном и том же месте при прокрутке (отличаются цифры) — и мягкое правило
        // принимает их за закреплённый низ. Если так сдвига не нашлось, повтор со строгим правилом: закреплены только
        // строки, точно совпавшие на месте.
        let loose = search(previous: p, current: c, expected: expected, hintError: hintError, minSpan: minSpan,
                           spanKnown: spanKnown, allowFuzzy: allowFuzzy, allowBlank: allowBlank, background: background,
                           partialHint: partialHint, minColumns: minColumns, ambiguity: ambiguity, exactStatic: false)
        if let loose, loose.match.shift != 0 { return loose }
        let exact = search(previous: p, current: c, expected: expected, hintError: hintError, minSpan: minSpan,
                           spanKnown: spanKnown, allowFuzzy: allowFuzzy, allowBlank: allowBlank, background: background,
                           partialHint: partialHint, minColumns: minColumns, ambiguity: ambiguity, exactStatic: true)
        if let exact, exact.match.shift != 0 { return exact }
        // Пустые строки у краёв совпадают и на месте, и при любом сдвиге — оба правила считают их шапкой и низом окна,
        // и на редкой странице (заголовок среди пустоты) от движущейся части остаётся узкая полоса, в которой сдвиг
        // не помещается. Ещё раз — без пустых «шапки» и «низа»; принимается лишь точное совпадение.
        if let trimmed = search(previous: p, current: c, expected: expected, hintError: hintError, minSpan: minSpan,
                                spanKnown: spanKnown, allowFuzzy: false, allowBlank: false, background: nil,
                                partialHint: partialHint, minColumns: minColumns, ambiguity: nil, exactStatic: true,
                                trimBlankStatic: true),
           trimmed.match.shift != 0 {
            return trimmed
        }
        // Мягкое правило сочло кадр неподвижным, а точное — нет, и сдвиг не найден: строки на тех же местах
        // отличаются (цифры в логе, номера в JSON после рывка на период разметки, заголовок въехал после пустоты).
        // Это не «без изменений», а потеря места — с предупреждением.
        if let loose, !loose.refutesMotion, exact == nil { return nil }
        if exact == nil, ambiguity.textMoved { return nil }
        return loose ?? exact
    }

    private static func search(previous p: Signature, current c: Signature, expected: Int?, hintError: Double,
                               minSpan: Int, spanKnown: Bool, allowFuzzy: Bool, allowBlank: Bool, background: Background?,
                               partialHint: Bool, minColumns: Int, ambiguity: Ambiguity?, exactStatic: Bool,
                               trimBlankStatic: Bool = false) -> Found? {
        let w = columns, h = p.rows
        guard h > 0, c.rows == h, p.fineColumns == c.fineColumns else { return nil }
        let pc = p.coarse, cc = c.coarse

        // Строка не сдвинулась, если в ней изменились лишь отдельные места: кнопки заголовка окна,
        // подсветка под курсором, часы в строке состояния. Только для шапки и низа: несовпадения внутри
        // движущейся части этим не прощаются.
        func isStatic(_ r: Int) -> Bool {
            if exactStatic {
                let a = r * w
                for j in 0..<w where p.hashes[a + j] != c.hashes[a + j] { return false }
                return true
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
        let still = { (header: Int, footer: Int) in
            Found(match: Match(shift: 0, header: header, footer: footer), confident: true, source: .still)
        }
        if header == h { return still(h, 0) }
        var footer = 0
        while isStatic(h - 1 - footer) { footer += 1 }
        if trimBlankStatic {
            // Только пустые целиком: шапка или низ окна с надписью — настоящие, их поля не трогаем.
            let blank = { (rows: Range<Int>) in !rows.contains { p.textured[$0] != 0 || c.textured[$0] != 0 } }
            let headerBlank = header > 0 && blank(0..<header), footerBlank = footer > 0 && blank((h - footer)..<h)
            guard headerBlank || footerBlank else { return nil }
            if headerBlank { header = 0 }
            if footerBlank { footer = 0 }
        }
        let lo = header, hi = h - footer, span = hi - lo
        // Изменилась узкая полоса посреди неподвижного кадра (подсветка, анимация) — это не прокрутка.
        // Без подсказки событий — и полоса меньше половины кадра (см. `minSpan`).
        let sizeRule = max(16, h / 10, minSpan, !spanKnown && header >= 16 && footer >= 16 ? h * 2 / 3 : 0)
        if span < (expected == nil ? sizeRule : max(16, h / 10)) {
            // Узкая изменившаяся полоса — анимация в стоящем окне. Но если неподвижные строки сверху и снизу пусты, а
            // строка с текстом целиком переехала на другое место — или в новом кадре появился другой текст там, где в
            // прошлом было пусто (заголовок ушёл вверх, следующий въехал после пустоты), — это редкая страница
            // прокрутилась: «без изменений» здесь молча теряло бы заголовки. Текст, сменившийся на том же месте
            // (часы, счётчик), — не прокрутка.
            guard span >= 16, Self.staticRowsBlank(c, header: header, footer: footer),
                  Self.textAppeared(p, c, rows: lo..<hi) || Self.textMoved(p, c, rows: lo..<hi)
            else { return still(header, footer) }
            if exactStatic { ambiguity?.textMoved = true }
        }

        let frame = Frame(p: p, c: c, header: header, footer: footer, sizeRule: sizeRule, partialHint: partialHint,
                          minColumns: minColumns)
        let decision = frame.exactSearch(expected: expected, hintError: hintError)
        if trimBlankStatic {
            guard case .found(let found) = decision, found.match.shift != 0 else { return nil }
            return found
        }
        // Сдвига нет или кадр «стоит» — а может, стоят только обои позади сообщений.
        var stands = false
        switch decision {
        case .noExactMatch: stands = true
        case .found(let found): stands = found.match.shift == 0 && found.source == .still
        case .ambiguous: break
        }
        if stands, let layer = frame.layerSearch(expected: expected, hintError: hintError, background: background) { return layer }
        switch decision {
        case .found(let found):
            // Мягкое правило могло принять за шапку или низ строки, которые на самом деле уехали вместе с
            // содержимым (строки лога в одном месте отличаются лишь цифрами): тогда — строгое правило.
            if !exactStatic, found.match.shift != 0, frame.staticRowsMoved(by: found.match.shift) { return nil }
            return found
        case .ambiguous(let repeated):
            if repeated { ambiguity?.repeated = true }
            return nil
        case .noExactMatch:
            // После `.lost` через пустоту не перескакиваем: пока место потеряно, мимо могли проехать строки текста.
            if allowBlank, let neutral = frame.blankShift(expected: expected) { return neutral }
            guard allowFuzzy else { return nil }
            return frame.fuzzySearch(expected: expected, hintError: hintError)
        }
    }

    /// В неподвижных строках сверху и снизу нет рисунка.
    private static func staticRowsBlank(_ c: Signature, header: Int, footer: Int) -> Bool {
        !(0..<header).contains { c.textured[$0] != 0 } && !((c.rows - footer)..<c.rows).contains { c.textured[$0] != 0 }
    }

    /// В `rows` нового кадра есть строки с рисунком, и ни одной из них нет в прошлом кадре — ни на том же месте,
    /// ни в другом, — а там, где они стоят, прошлый кадр пуст.
    private static func textAppeared(_ p: Signature, _ c: Signature, rows: Range<Int>) -> Bool {
        var seen = Set<UInt64>()
        for r in 0..<p.rows where p.textured[r] != 0 { seen.insert(p.rowKeys[r]) }
        var any = false
        for r in rows where c.textured[r] != 0 {
            guard p.textured[r] == 0, !seen.contains(c.rowKeys[r]) else { return false }
            any = true
        }
        return any
    }

    /// Строка с рисунком из `rows` нового кадра есть в прошлом кадре целиком, но в другом месте.
    private static func textMoved(_ p: Signature, _ c: Signature, rows: Range<Int>) -> Bool {
        var where_: [UInt64: Int] = [:]
        for r in 0..<p.rows where p.textured[r] != 0 { where_[p.rowKeys[r]] = r }
        return rows.contains { r in c.textured[r] != 0 && where_[c.rowKeys[r]].map { $0 != r } == true }
    }

    /// Пара кадров и их неподвижные шапка и низ: точный поиск сдвига и запасной — по похожести.
    private struct Frame {
        let p: Signature
        let c: Signature
        let header: Int
        let footer: Int
        let sizeRule: Int
        /// Подсказка — лишь верхняя граница: колесо и PageDown прокручиваются анимацией, и кадр мог застать её
        /// в начале.
        var partialHint = false
        /// Совпавшие полосы должны быть хотя бы в стольких колонках: ползунок полосы прокрутки (одна колонка) движется
        /// навстречу содержимому, и склейка вверх иначе приняла бы его за прокрутку.
        var minColumns = 1
        var h: Int { p.rows }
        var lo: Int { header }
        var hi: Int { p.rows - footer }
        var span: Int { hi - lo }

        enum Decision { case found(Found), ambiguous(repeated: Bool), noExactMatch }

        /// Точные совпадения при сдвиге `shift`: по строкам нового кадра — совпавшие полосы-доводы; по колонкам —
        /// сколько полос с рисунком сравнено и сколько совпало.
        struct Evaluation {
            var shift: Int
            var matched: [UInt64]
            /// Совпавшие полосы, единственные в своей колонке в обоих кадрах.
            var unique: [UInt64]
            /// Не совпавшие полосы с рисунком.
            var missed: [UInt64]
            var compared = [Int](repeating: 0, count: Stitcher.columns)
            var hits = [Int](repeating: 0, count: Stitcher.columns)
        }

        func overlap(_ s: Int) -> Range<Int> { max(lo, lo - s)..<max(max(lo, lo - s), min(hi, hi - s)) }

        func evaluate(_ s: Int) -> Evaluation {
            let w = Stitcher.columns
            var e = Evaluation(shift: s, matched: [UInt64](repeating: 0, count: h), unique: [UInt64](repeating: 0, count: h),
                               missed: [UInt64](repeating: 0, count: h))
            p.hashes.withUnsafeBufferPointer { ph in
                c.hashes.withUnsafeBufferPointer { ch in
                    for r in overlap(s) {
                        let q = r + s
                        let textured = c.textured[r] | p.textured[q]
                        guard textured != 0 else { continue }
                        var equal: UInt64 = 0
                        var bits = textured
                        while bits != 0 {
                            let j = bits.trailingZeroBitCount
                            bits &= bits - 1
                            e.compared[j] += 1
                            if ch[r * w + j] == ph[q * w + j] {
                                equal |= 1 << UInt64(j)
                                e.hits[j] += 1
                            }
                        }
                        e.matched[r] = equal & (c.distinct[r] | p.distinct[q])
                        e.unique[r] = equal & c.unique[r] & p.unique[q]
                        e.missed[r] = textured & ~equal
                    }
                }
            }
            return e
        }

        /// Совпавшие полосы с рисунком при сдвиге `s`, по каждой `step`-й строке (быстрая оценка).
        func sampledHits(_ s: Int, step: Int) -> Int {
            let w = Stitcher.columns
            var hits = 0
            for r in stride(from: overlap(s).lowerBound, to: overlap(s).upperBound, by: step) {
                var bits = c.textured[r] | p.textured[r + s]
                while bits != 0 {
                    let j = bits.trailingZeroBitCount
                    bits &= bits - 1
                    if c.hashes[r * w + j] == p.hashes[(r + s) * w + j] { hits += 1 }
                }
            }
            return hits
        }

        /// Колонки, неподвижные относительно сдвига `e`: на месте совпали, при сдвиге — нет (сайдбар, ползунок,
        /// плавающая кнопка). При повторяющемся содержимом совпадает и то и другое — такие колонки не неподвижны.
        func stillColumns(_ e: Evaluation, zero: Evaluation) -> UInt64 {
            var mask: UInt64 = 0
            for j in 0..<Stitcher.columns {
                let t0 = zero.compared[j], m0 = zero.hits[j], t = e.compared[j], m = e.hits[j]
                if t0 >= 8, m0 * 10 >= t0 * 6, m * 10 <= t * 2 { mask |= 1 << UInt64(j) }
            }
            return mask
        }

        func distinctHits(_ e: Evaluation, excluding mask: UInt64) -> Int {
            e.matched.reduce(0) { $0 + ($1 & ~mask).nonzeroBitCount }
        }

        /// Сравнение двух сдвигов на общих строках перекрытий (вне них один из сдвигов считает строки новым
        /// содержимым, и возразить ему нечем): собственные доводы `a` (совпали при нём, но не при `b`), `b` — наоборот,
        /// и сколько всего полос-доводов совпало хоть при одном.
        func compare(_ a: Evaluation, _ b: Evaluation, excluding mask: UInt64) -> (a: Int, b: Int, total: Int) {
            let x = overlap(a.shift), y = overlap(b.shift)
            var own = (a: 0, b: 0, total: 0)
            for r in max(x.lowerBound, y.lowerBound)..<max(max(x.lowerBound, y.lowerBound), min(x.upperBound, y.upperBound)) {
                let ma = a.matched[r] & ~mask, mb = b.matched[r] & ~mask
                guard ma | mb != 0 else { continue }
                own.a += (ma & ~mb).nonzeroBitCount
                own.b += (mb & ~ma).nonzeroBitCount
                own.total += (ma | mb).nonzeroBitCount
            }
            return own
        }

        /// Сдвиг-кандидат: точные совпадения, неподвижные колонки, совпавшие полосы-доводы, доля совпавших полос
        /// с рисунком и сколько их не совпало.
        struct Scored {
            var e: Evaluation
            var mask: UInt64
            var hits: Int
            var rate: Double
            var misses: Int
        }

        func score(_ e: Evaluation, mask: UInt64) -> Scored {
            var compared = 0, hits = 0
            for j in 0..<Stitcher.columns where mask & (1 << UInt64(j)) == 0 {
                compared += e.compared[j]
                hits += e.hits[j]
            }
            return Scored(e: e, mask: mask, hits: distinctHits(e, excluding: mask),
                          rate: compared > 0 ? Double(hits) / Double(compared) : 0, misses: compared - hits)
        }

        /// Уникальные полосы (единственные в колонке обоих кадров), совпавшие при `a` и не совпавшие при `b`, —
        /// на всех строках: если `b` верен, эти строки — новое содержимое, а оно же есть в прошлом кадре в другом месте.
        func uniqueOwn(_ a: Evaluation, _ b: Evaluation, excluding mask: UInt64) -> Int {
            var count = 0
            for r in 0..<a.unique.count where a.unique[r] != 0 { count += (a.unique[r] & ~b.unique[r] & ~mask).nonzeroBitCount }
            return count
        }

        /// `a` объясняет кадр однозначно лучше `b`. Настоящая неоднозначность — блок одинаковых строк: оба сдвига
        /// совпадают везде, где сравнимы, и уникальных строк ни у одного нет. Иначе у `b` найдётся довод против:
        /// - у `a` совпали уникальные строки (цифры, номера), которых `b` не объясняет, а у `b` таких почти нет;
        /// - на общих строках перекрытий у `a` есть свои совпадения, а у `b` их почти нет;
        /// - `b` объясняет заметно меньшую долю своего перекрытия (сдвиг «на период» разметки совпадает лишь
        ///   повторяющимися местами) или явно не совпал там, где `a` совпал почти целиком (номер функции, цифра в логе —
        ///   за пределами общих строк);
        /// - перекрытия не пересекаются, а `b` объясняет вчетверо меньше (уголок кадра, совпавший с другим уголком).
        /// Сила довода `a` против `b`: 2 — свои совпадения (уникальные строки или общие строки перекрытий), 1 — только
        /// доли и размеры, 0 — довода нет. Два сдвига могут «побить» друг друга (у одного выше доля на маленьком
        /// перекрытии, у другого — уникальные строки): решает более сильный довод.
        func evidence(_ a: Scored, _ b: Scored, excluding mask: UInt64) -> Int {
            let mine = uniqueOwn(a.e, b.e, excluding: mask), theirs = uniqueOwn(b.e, a.e, excluding: mask)
            if mine >= 8, theirs * 4 <= mine { return 2 }
            let own = compare(a.e, b.e, excluding: mask)
            if own.total >= 16, own.a >= 8, own.b * 4 <= own.a { return 2 }
            // Массовые несовпадения при почти чистом `a`: в перекрытии `b` — другое содержимое.
            if b.misses >= 64, 1 - b.rate >= 3 * (1 - a.rate) + 0.1 { return 2 }
            if own.total < 16, b.hits * 4 <= a.hits, a.rate >= b.rate - 0.05 { return 1 }
            if b.rate <= a.rate - 0.2 { return 1 }
            return b.misses >= 8 && 1 - b.rate >= 2 * (1 - a.rate) + 0.01 ? 1 : 0
        }

        func beats(_ a: Scored, _ b: Scored, excluding mask: UInt64) -> Bool {
            let mine = evidence(a, b, excluding: mask)
            return mine > 0 && mine > evidence(b, a, excluding: b.mask)
        }

        func exactSearch(expected: Int?, hintError: Double) -> Decision {
            let w = Stitcher.columns
            // Перекрытие кадров — от 1/20 прокручиваемой части: PageDown и пробел в браузерах оставляют 40 CSS px
            // (~7% окна). Точное совпадение надёжно и на таком перекрытии.
            let minOverlap = min(span, max(24, span / 20))
            let limit = span - minOverlap
            guard limit > 0 else { return .noExactMatch }

            // 1. Кандидаты голосованием: каждая редкая полоса нового кадра ищется среди редких полос той же колонки
            // прошлого кадра, каждое точное совпадение голосует за свой сдвиг.
            var votes = [Int32](repeating: 0, count: 2 * limit + 1)
            p.indexKeys.withUnsafeBufferPointer { keys in
                for r in lo..<hi {
                    var bits = c.distinct[r]
                    while bits != 0 {
                        let j = bits.trailingZeroBitCount
                        bits &= bits - 1
                        let key = c.hashes[r * w + j]
                        // Продолжение серии одинаковых строк не голосует: голос — от её первой строки.
                        if r > 0, c.textured[r - 1] & (1 << UInt64(j)) != 0, c.hashes[(r - 1) * w + j] == key { continue }
                        var a = p.indexStart[j], b = p.indexStart[j + 1]
                        while a < b {
                            let m = (a + b) / 2
                            if keys[m] < key { a = m + 1 } else { b = m }
                        }
                        var k = a
                        while k < p.indexStart[j + 1], keys[k] == key {
                            let q = Int(p.indexRows[k])
                            let s = q - r
                            if q >= lo, q < hi, abs(s) <= limit { votes[s + limit] += 1 }
                            k += 1
                        }
                    }
                }
            }
            var proposals = Set<Int>([0])
            let voted = votes.indices.filter { votes[$0] > 0 }.sorted { a, b in
                votes[a] != votes[b] ? votes[a] > votes[b] : abs(a - limit) < abs(b - limit)
            }
            for index in voted.prefix(16) { proposals.insert(index - limit) }
            // У подсказки — все сдвиги окна (быстрая оценка по каждой 4-й строке): одинаковые строки голосов не дают,
            // а разводит их как раз подсказка.
            let window = expected.map { max(24, abs($0) * 2 / 5) }
            if let expected, let window {
                let low = max(-limit, expected - window), high = min(limit, expected + window)
                if low <= high {
                    let scored = (low...high).map { (shift: $0, hits: sampledHits($0, step: 4)) }.filter { $0.hits > 0 }
                        .sorted { $0.hits != $1.hits ? $0.hits > $1.hits : abs($0.shift - expected) < abs($1.shift - expected) }
                    for candidate in scored.prefix(6) { proposals.insert(candidate.shift) }
                }
            }

            // 2. Точная проверка кандидатов.
            let evaluations = proposals.filter { abs($0) <= limit }.sorted().map(evaluate)
            guard let zero = evaluations.first(where: { $0.shift == 0 }) else { return .noExactMatch }
            let moving: [Scored] = evaluations.filter { $0.shift != 0 }.compactMap { e in
                let mask = stillColumns(e, zero: zero)
                // Почти всё стоит на месте — это не прокрутка содержимого.
                guard mask.nonzeroBitCount * 4 <= w * 3 else { return nil }
                return score(e, mask: mask)
            }
            let found = { (shift: Int, confident: Bool) in
                Decision.found(Found(match: Match(shift: shift, header: header, footer: footer), confident: confident))
            }
            let minimum = 16
            // Кандидаты по доле совпавших полос: сдвиг «на период» повторяющейся разметки при большом перекрытии
            // набирает много совпадений, но лишь повторяющихся мест.
            // Маленький предмет (линия, значок) среди пустоты без единого промаха во всём перекрытии — тоже довод.
            let ranked = moving.filter { $0.hits >= minimum || $0.misses == 0 && $0.hits >= 4 }.sorted { a, b in
                a.rate != b.rate ? a.rate > b.rate : a.hits != b.hits ? a.hits > b.hits : abs(a.e.shift) < abs(b.e.shift)
            }
            guard !ranked.isEmpty else {
                // Содержимое не сдвинулось: на месте совпало большинство полос (меняется только видео, анимация).
                let still = score(zero, mask: 0)
                if still.hits >= minimum, still.rate >= 0.5 {
                    return .found(Found(match: Match(shift: 0, header: header, footer: footer), confident: true, source: .still))
                }
                return .noExactMatch
            }

            // 3. Однозначность: победитель — кандидат, который однозначно лучше каждого далёкого сдвига и сдвига 0
            // (без колонок, неподвижных при нём). Ближние (±2) совпадают по тем же местам и соперниками не считаются.
            func contest(_ x: Scored) -> (tied: [Scored], zero: Bool, still: Scored) {
                let still = score(zero, mask: x.mask)
                let tied = moving.filter { abs($0.e.shift - x.e.shift) > 2 && !beats(x, $0, excluding: x.mask) }
                return (tied, !beats(x, still, excluding: x.mask), still)
            }
            var best = ranked[0]
            var result = contest(best)
            // Перебираются все: у настоящего сдвига доля бывает низкой (в перекрытии видео), а выше него по доле —
            // случайные совпадения на маленьком перекрытии.
            for candidate in ranked.dropFirst() where !result.tied.isEmpty || result.zero {
                let other = contest(candidate)
                if other.tied.isEmpty, !other.zero {
                    best = candidate
                    result = other
                }
            }
            let tied = [best] + result.tied, zeroTied = result.zero, still = result.still

            // Нижняя граница: у чужого содержимого тоже есть случайные точные совпадения (одно и то же слово в начале
            // строки на том же месте) — по сотне полос при любом сдвиге. Настоящий сдвиг объясняет почти все полосы,
            // совпавшие хоть при каком-то сдвиге (видео не совпадает ни при каком и не мешает), случайный — малую часть.
            var union = [UInt64](repeating: 0, count: h)
            for e in evaluations { for r in overlap(best.e.shift) { union[r] |= e.matched[r] } }
            var covered = 0, possible = 0
            for r in overlap(best.e.shift) {
                covered += (best.e.matched[r] & ~best.mask).nonzeroBitCount
                possible += (union[r] & ~best.mask).nonzeroBitCount
            }
            guard possible > 0, covered * 10 >= possible * 6 else { return .noExactMatch }
            var columns: UInt64 = 0
            for r in overlap(best.e.shift) { columns |= best.e.matched[r] & ~best.mask }
            guard columns.nonzeroBitCount >= minColumns else { return .noExactMatch }
            // Уникальные строки нового кадра должны хоть заметной частью совпасть целиком. У настоящего сдвига так и
            // есть: не совпадают лишь строки с видео, анимацией. У похожего чужого содержимого — нет: строки лога после
            // рывка на минуту совпадут секундами, но не минутами, ни одна строка не совпадёт целиком. Серия совпавших
            // строк подряд (строка текста — 20 строк пикселей) считается одной: одна случайно совпавшая строка текста
            // не довод, нужны две или большая картинка.
            var uniqueRows = 0, cleanRows = 0, cleanRuns = 0, previousClean = false
            for r in overlap(best.e.shift) {
                let clean = c.uniqueRow[r] && best.e.missed[r] & ~best.mask == 0
                if c.uniqueRow[r] { uniqueRows += 1 }
                if clean { cleanRows += 1; if !previousClean { cleanRuns += 1 } }
                previousClean = clean
            }
            // Сдвиг, который подтверждают события, обходится и одной серией: уникальных строк мало в блоке одинаковых.
            let confirmed = expected.map { e in window.map { abs(best.e.shift - e) <= $0 } ?? false } ?? false
            // Уникальных строк нет вовсе (всё перекрытие — блок одинаковых строк): различать нечем, дальше решает подсказка.
            // Одна серия годится и когда перекрытие объяснено целиком: все уникальные строки совпали, промахов нет —
            // заголовок среди пустоты (лендинг, слайды, письмо). Даже одна строка пикселей — верхушки букв заголовка,
            // въезжающего снизу после пустоты, — если совпала она одна и больше ни одного промаха.
            let whole = cleanRows == uniqueRows && best.misses == 0
            guard uniqueRows == 0 || whole && (cleanRows >= 2 || best.hits >= 4)
                    || cleanRows >= 8 && (cleanRuns >= 2 || cleanRows >= 48 || confirmed) && cleanRows * 20 >= uniqueRows
            else { return .noExactMatch }

            if tied.count == 1, !zeroTied {
                if let expected, let window, abs(best.e.shift - expected) > window {
                    // Изображение спорит с событиями. Верим ему, только если совпадение сильное, движется большая часть
                    // кадра и расхождение похоже на другой масштаб прокрутки (приложение прокручивает не 1:1), а не на
                    // анимацию посреди стоящей страницы (колесо у конца страницы). После щелчка колеса или PageDown
                    // содержимое доезжает анимацией: кадр застаёт любую её часть — от начала до конца.
                    let ratio = Double(best.e.shift) / Double(expected == 0 ? 1 : expected)
                    let plausible = (0.25...4).contains(ratio) || partialHint && ratio > 0 && ratio < 0.25
                    if best.rate >= 0.5, span >= sizeRule, plausible { return found(best.e.shift, true) }
                    guard span < sizeRule else { return .ambiguous(repeated: false) }
                    let refuted = Found(match: Match(shift: 0, header: header, footer: footer), confident: true,
                                        refutesMotion: true, source: .refuted)
                    return .found(refuted)
                }
                return found(best.e.shift, true)
            }

            // 4. Несколько сдвигов объясняют кадр одинаково (повторяющиеся строки). Подсказка выбирает ближайший,
            // только если все они — настоящие совпадения (а не случайные полосы чужого содержимого) и подсказка
            // точнее, чем расстояние между ними. Иначе — `.lost`, а не угадывание.
            var options = tied.map { (shift: $0.e.shift, rate: $0.rate) }
            if zeroTied { options.append((0, still.rate)) }
            // Настоящих совпадений два и больше — это одинаковые строки (HUD подскажет вернуться к отличающимся).
            let repeated = options.filter { $0.rate >= 0.75 }.count >= 2
            guard let expected, let window else { return .ambiguous(repeated: repeated) }
            // Ни один вариант не похож на то, что говорят события, а движется малая часть кадра: события не про это
            // содержимое (колесо у конца страницы, а меняется анимация).
            if span < sizeRule, options.allSatisfy({ abs($0.shift - expected) > window }) {
                let refuted = Found(match: Match(shift: 0, header: header, footer: footer), confident: true,
                                    refutesMotion: true, source: .refuted)
                return .found(refuted)
            }
            // Альтернативы — только настоящие совпадения (доля ≥ 0,75): сдвиг, с которым нечем сравнить (перекрытия не
            // пересекаются), но совпавший лишь местами, не вариант. Если настоящих нет — это чужое содержимое.
            options = options.filter { $0.rate >= 0.75 }
            guard !options.isEmpty else { return .ambiguous(repeated: false) }
            options.sort { abs($0.shift - expected) < abs($1.shift - expected) }
            let accuracy = max(4, Int(2 * hintError * Double(max(abs(expected), 50))))
            guard abs(options[0].shift - expected) <= accuracy else { return .ambiguous(repeated: repeated) }
            if options.count >= 2, abs(options[1].shift - expected) < abs(options[0].shift - expected) + max(8, accuracy) {
                return .ambiguous(repeated: repeated)
            }
            return .found(Found(match: Match(shift: options[0].shift, header: header, footer: footer), confident: false, source: .hint))
        }

        /// Неподвижный слой с рисунком позади движущегося содержимого: обои чата, узор фона. Полосы обоев совпадают
        /// на месте, пузыри сообщений — при сдвиге, а края пузырей (в полосе и пузырь, и обои) — нигде: ни одна строка
        /// не совпадает целиком, и обычный поиск сдвиг отвергает (или считает кадр стоящим — по обоям). Тогда сдвиг
        /// ищется ещё раз — без неподвижных полос и соседних с ними — и принимается, только если движущийся слой
        /// занимает большую часть высоты, а не полосу посреди стоящего окна.
        func layerSearch(expected: Int?, hintError: Double, background: Background?) -> Found? {
            let w = Stitcher.columns
            // Неподвижное: совпало на месте в этой паре кадров или с обоями, известными по прошлым склейкам.
            var stillP = background?.mask(p) ?? [UInt64](repeating: 0, count: h)
            var stillC = background?.mask(c) ?? [UInt64](repeating: 0, count: h)
            var stillCount = 0, total = 0
            var columnTextured = [Int](repeating: 0, count: w), columnStill = [Int](repeating: 0, count: w)
            var columnUnique = [Int](repeating: 0, count: w)
            for r in lo..<hi {
                var bits = c.textured[r] & p.textured[r], same: UInt64 = 0
                while bits != 0 {
                    let j = bits.trailingZeroBitCount
                    bits &= bits - 1
                    if c.hashes[r * w + j] == p.hashes[r * w + j] { same |= 1 << UInt64(j) }
                }
                stillP[r] |= same
                stillC[r] |= same
                total += c.textured[r].nonzeroBitCount
                stillCount += (stillC[r] & c.textured[r]).nonzeroBitCount
                for j in 0..<w where c.textured[r] & (1 << UInt64(j)) != 0 {
                    columnTextured[j] += 1
                    if stillC[r] & (1 << UInt64(j)) != 0 { columnStill[j] += 1 }
                    if stillC[r] & c.unique[r] & (1 << UInt64(j)) != 0 { columnUnique[j] += 1 }
                }
            }
            // Неподвижный слой — заметная часть рисунка, но не весь: иначе кадр просто стоит. Движущегося бывает мало
            // (короткие «Ок» в конце переписки), решают проверки точного поиска и высота движущегося слоя.
            guard total > 0, stillCount * 5 >= total, total - stillCount >= max(64, total / 20) else { return nil }
            // Обои — узор, полосы которого в своей колонке не повторяются. Одинаковые слова соседних строк лога или JSON
            // («INFO [worker-3] GET», `"active": true`) тоже совпадают на месте, но повторяются по всей колонке: это не
            // фон, а текст, и сдвиг по оставшимся цифрам после рывка вклеил бы чужое. Колонки, неподвижные целиком
            // (список чатов слева, сайдбар), не в счёт: обои видны там, где поверх них едут сообщения.
            let layered = (0..<w).filter { columnStill[$0] * 20 < columnTextured[$0] * 19 }
            let unique = layered.reduce(0) { $0 + columnUnique[$1] }, still = layered.reduce(0) { $0 + columnStill[$1] }
            guard unique * 4 >= still else { return nil }
            let layer = Frame(p: p.without(stillP, rows: lo..<hi), c: c.without(stillC, rows: lo..<hi),
                              header: header, footer: footer, sizeRule: sizeRule, partialHint: partialHint,
                              minColumns: minColumns)
            guard case .found(var found) = layer.exactSearch(expected: expected, hintError: hintError), found.match.shift != 0
            else { return nil }
            let e = layer.evaluate(found.match.shift)
            guard let first = e.matched.firstIndex(where: { $0 != 0 }), let last = e.matched.lastIndex(where: { $0 != 0 }),
                  last - first >= min(sizeRule, span) / 2 else { return nil }
            found.source = .layer
            return found
        }

        /// Строки, принятые мягким правилом за шапку или низ, при найденном сдвиге совпадают точнее, чем на месте:
        /// значит, они уехали вместе с содержимым.
        func staticRowsMoved(by s: Int) -> Bool {
            let w = Stitcher.columns
            var moved = 0, stayed = 0
            for r in Array(0..<header) + Array((h - footer)..<h) where r + s >= 0 && r + s < h {
                var bits = c.distinct[r]
                while bits != 0 {
                    let j = bits.trailingZeroBitCount
                    bits &= bits - 1
                    if c.hashes[r * w + j] == p.hashes[(r + s) * w + j] { moved += 1 }
                    if c.hashes[r * w + j] == p.hashes[r * w + j] { stayed += 1 }
                }
            }
            return moved >= 8 && moved > stayed
        }

        // MARK: Однотонный участок

        /// Строка без рисунка совпадает с другой такой строкой — с допуском по грубой подписи.
        private func blankRowsMatch(_ q: Int, _ r: Int) -> Bool {
            let w = Stitcher.columns, a = q * w, b = r * w
            var sum = 0
            for k in 0..<w { sum += min(abs(Int(p.coarse[a + k]) - Int(c.coarse[b + k])), Stitcher.clip) }
            return sum <= Stitcher.tolerance * w
        }

        /// Однотонный участок длиннее кадра: ни при каком сдвиге в перекрытии нет строк с рисунком — нечему
        /// противоречить, сокращается пустота, а не текст. С подсказкой — ближайший к ней сдвиг, без неё — наименьший.
        func blankShift(expected: Int?) -> Found? {
            let limit = span - min(span, max(16, span / 5))
            guard limit >= 0 else { return nil }
            // Строки с рисунком есть в обоих кадрах — значит, текст виден в обоих и сдвиг должен был найтись точно.
            // Раз не нашёлся, это неоднозначность, а не пустота: `.lost`, а не сдвиг наугад (повтор или потеря заголовка).
            // Несколько совпавших строк пикселей при другом тексте — не то: у похожих заголовков («Раздел 2…»,
            // «Раздел 3…») совпадают строки, где нет цифр.
            var seen = Set<UInt64>()
            for r in 0..<h where p.textured[r] != 0 { seen.insert(p.rowKeys[r]) }
            let textured = (0..<h).filter { c.textured[$0] != 0 }
            let shared = textured.filter { seen.contains(c.rowKeys[$0]) }.count
            if shared > 0, shared * 3 >= textured.count { return nil }
            // В перекрытии — только однотонные строки (иначе сдвиг срезал бы бледные края букв заголовка) и не больше
            // двух строк-«деталей» (граница однотонных полос разного цвета), совпадающих с допуском.
            var cPrefix = [0], pPrefix = [0], cText = [0], pText = [0]
            for r in 0..<h {
                cPrefix.append(cPrefix[r] + (c.detail[r] ? 1 : 0))
                pPrefix.append(pPrefix[r] + (p.detail[r] ? 1 : 0))
                cText.append(cText[r] + (c.flat[r] ? 0 : 1))
                pText.append(pText[r] + (p.flat[r] ? 0 : 1))
            }
            func neutral(_ s: Int) -> Bool {
                guard abs(s) <= limit else { return false }
                let r0 = max(lo, lo - s), r1 = min(hi, hi - s)
                guard r0 < r1, cText[r1] == cText[r0], pText[r1 + s] == pText[r0 + s],
                      cPrefix[r1] - cPrefix[r0] + pPrefix[r1 + s] - pPrefix[r0 + s] <= 2 else { return false }
                return (r0..<r1).allSatisfy { r in !(c.detail[r] || p.detail[r + s]) || blankRowsMatch(r + s, r) }
            }
            // По порядку близости к подсказке (без неё — к нулю): первый подходящий и есть ответ, без перебора всех
            // сдвигов (на пустом кадре 5K это миллионы проверок). Через пустоту — только в ту сторону, куда растёт
            // склейка (назад — лишь по событиям): шаг назад здесь значил бы «кадр не новый», и следующий заголовок,
            // въехавший после пустоты, пропал бы молча.
            let center = expected.map { min(max($0, -limit), limit) } ?? 0
            let back = (expected ?? 0) < 0
            for d in 0...(2 * limit) {
                for s in d == 0 ? [center] : [center + d, center - d] where (back ? s <= 0 : s >= 0) && neutral(s) {
                    return Found(match: Match(shift: s, header: header, footer: footer), confident: false, exact: false,
                                 source: .blank)
                }
            }
            return nil
        }

        // MARK: Запасной поиск — по похожести

        /// Захват неточный (шум, масштабирование): точных совпадений нет вовсе. Сдвиг ищется по похожести строк:
        /// кандидаты голосованием по грубой подписи, проверка по точной подписи с допуском.
        func fuzzySearch(expected: Int?, hintError: Double) -> Found? {
            let w = Stitcher.columns
            let pc = p.coarse, cc = c.coarse
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
            let match = { (shift: Int) in Match(shift: shift, header: header, footer: footer) }
            // Почти всё стоит на месте — это не прокрутка содержимого.
            guard active.count * 4 >= w else { return Found(match: match(0), confident: true, exact: false, source: .still) }

            let fw = p.fineColumns
            let fineActive = (0..<fw).filter { !masked[$0 * w / fw] }.count
            let rowTolerance = Stitcher.tolerance * active.count
            let rowCap = rowTolerance * 4
            let minOverlap = min(span, max(16, span / 5))
            let limit = span - minOverlap

            func rowCost(_ pb: UnsafeBufferPointer<UInt8>, _ cb: UnsafeBufferPointer<UInt8>, _ q: Int, _ r: Int, cap: Int) -> Int {
                let a = q * w, b = r * w
                var sum = 0
                for k in active {
                    sum += min(abs(Int(pb[a + k]) - Int(cb[b + k])), Stitcher.clip)
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

            struct Candidate {
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
            var picks: [Candidate] = []
            for candidate in scored.sorted(by: { $0.coarseCost < $1.coarseCost }) where picks.count < 24 {
                if !picks.contains(where: { abs($0.shift - candidate.shift) <= 2 }) { picks.append(candidate) }
            }
            let window = expected.map { max(24, abs($0) * 2 / 5) }
            if let expected, let window {
                let near = scored.filter { abs($0.shift - expected) <= window }.sorted {
                    (Int($0.coarseCost) / 8, abs($0.shift - expected)) < (Int($1.coarseCost) / 8, abs($1.shift - expected))
                }
                for candidate in near.prefix(3) where !picks.contains(where: { $0.shift == candidate.shift }) { picks.append(candidate) }
            }

            let strictTolerance = 8 + fineActive / 64
            let fineTolerance = max(16, fineActive)
            let fineMask: [Float] = (0..<fw).map { masked[$0 * w / fw] ? 0 : 1 }
            var difference = [Float](repeating: 0, count: fw)
            func check(_ picks: inout [Candidate], every step: Int) {
                p.fineValues.withUnsafeBufferPointer { pf in
                c.fineValues.withUnsafeBufferPointer { cf in
                difference.withUnsafeMutableBufferPointer { diff in
                    let n = vDSP_Length(fw)
                    var low: Float = 0, high = Float(Stitcher.clip)
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
                let keep = expected.flatMap { e in window.map { w in
                    picks.filter { abs($0.shift - e) <= w }
                        .sorted { (-$0.strictRate, abs($0.shift - e)) < (-$1.strictRate, abs($1.shift - e)) }.prefix(2)
                } } ?? []
                picks = Array(picks.prefix(6)) + keep.filter { k in !picks.prefix(6).contains { $0.shift == k.shift } }
            }
            check(&picks, every: 1)
            let valid = picks.filter { $0.evidence >= 3 && $0.matched >= max(min(8, $0.evidence), $0.evidence / 20) }
            guard !valid.isEmpty else { return nil }
            let useStrict = (valid.map(\.strictRate).max() ?? 0) >= 0.15
            func rate(_ x: Candidate) -> Double { useStrict ? x.strictRate : x.matchedRate }
            let ranked = valid.sorted {
                rate($0) != rate($1) ? rate($0) > rate($1)
                    : Double($0.cost) / Double($0.evidence) < Double($1.cost) / Double($1.evidence)
            }
            let best = ranked[0]
            let level: UInt8 = useStrict ? 2 : 1
            func unique(_ x: Candidate) -> Bool {
                let others = picks.filter { abs($0.shift - x.shift) > 2 && $0.evidence >= 8 }
                let second = others.map(rate).max() ?? 0
                if rate(x) >= 0.5 {
                    guard second < rate(x) - 0.04 else { return false }
                } else {
                    let secondStrict = others.map(\.strictRate).max() ?? 0
                    let byStrict = x.strict >= 16 && x.strictRate >= 2 * secondStrict + 0.01
                    let noisy = !picks.contains { $0.strict >= 16 }
                    guard byStrict || (noisy && x.matched >= 24 && rate(x) >= 2 * second + 0.02) else { return false }
                }
                let rivals = picks.filter { abs($0.shift - x.shift) > 16 && !$0.rows.isEmpty }
                var own = 0, matched = 0
                for r in x.rows.indices where x.rows[r] >= level {
                    matched += 1
                    if !rivals.contains(where: { $0.rows[r] >= level }) { own += 1 }
                }
                return own >= min(8, matched)
            }
            let found = { (shift: Int, confident: Bool) in
                Found(match: match(shift), confident: confident, exact: false, source: .fuzzy)
            }
            guard let expected, let window else {
                return unique(best) ? found(best.shift, true) : nil
            }
            if unique(best) {
                guard abs(best.shift - expected) <= window || rate(best) >= 0.5 else { return nil }
                return found(best.shift, true)
            }
            // Несколько сдвигов объясняют кадр одинаково: подсказка выбирает, только если все они — настоящие
            // совпадения. Случайные совпадения чужого содержимого (5% строк) — не повод клеить.
            guard rate(best) >= 0.75 else { return nil }
            let accuracy = max(4, Int(2 * hintError * Double(max(abs(expected), 50))))
            let tied = ranked.filter { $0.evidence >= 8 && rate($0) >= rate(best) - 0.04 }
                .sorted { abs($0.shift - expected) < abs($1.shift - expected) }
            guard let first = tied.first, abs(first.shift - expected) <= accuracy else { return nil }
            if tied.count >= 2, abs(tied[1].shift - expected) < abs(first.shift - expected) + max(8, accuracy) { return nil }
            return found(first.shift, false)
        }
    }
}

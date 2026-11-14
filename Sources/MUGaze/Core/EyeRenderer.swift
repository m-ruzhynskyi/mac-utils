import Foundation

/// Правка одного глаза для отрисовки (A v2): радужка переносится целиком, верхнее веко поднимается вместе с ней,
/// белок растягивается только между радужкой и краем глаза. Все величины — в пикселях кадра.
package struct EyeEdit: Equatable, Codable, Sendable {
    package var frame: EyeFrame
    /// Где радужка сейчас (центр, сглаженный).
    package var iris: Vec2
    package var irisRadius: Double
    /// Сдвиг радужки (в осях кадра).
    package var shift: Vec2
    /// На сколько поднять верхнее веко в середине глаза (> 0 — вверх). К уголкам подъём сходит на нет.
    package var lidRaise: Double
    /// Точные веки (A v3). Без них веки — эллипс по рамке (A v2).
    package var lids: LidCurves?
    /// На сколько поднять нижнее веко в середине (> 0 — вверх): при взгляде вверх оно чуть поднимается вслед за
    /// радужкой. Край века берётся из подложки — без тёмного низа старой радужки.
    package var lowerRaise: Double

    package init(frame: EyeFrame, iris: Vec2, irisRadius: Double, shift: Vec2, lidRaise: Double, lids: LidCurves? = nil, lowerRaise: Double = 0) {
        self.frame = frame; self.iris = iris; self.irisRadius = irisRadius; self.shift = shift; self.lidRaise = lidRaise; self.lids = lids
        self.lowerRaise = lowerRaise
    }

    /// Сколько белка откроется под радужкой после подъёма (px): часть его закрывает поднятое нижнее веко.
    /// Если радужка и так перекрыта веком больше, чем на подъём, — ноль. Если под радужкой уже был виден белок
    /// (широко открытые глаза), тоже ноль: веко не трогаем. Между «касается века» и «белок 2 px» — плавный переход.
    package static func lowerGap(for frame: EyeFrame, lids: LidCurves?, iris: Vec2, irisRadius: Double, shift: Vec2) -> Double {
        let d = iris - frame.center
        let u = d.dot(frame.ex), v = d.dot(frame.ey)
        let lift = -shift.dot(frame.ey)
        guard lift > 0 else { return 0 }
        let bottom = lids?.bottom(u) ?? frame.halfHeight * max(0, 1 - (u / frame.halfWidth) * (u / frame.halfWidth)).squareRoot()
        let overlap = v + irisRadius - bottom // насколько низ радужки ушёл под веко (< 0 — под ней белок)
        return min(max(lift - max(overlap, 0), 0), lift) * smoothstep(-scleraShowFade, 0, overlap)
    }

    /// Сколько белка под радужкой (px) уже достаточно, чтобы не растягивать её низ.
    package static let scleraShowFade = 2.0
    /// Как далеко над веком (в полуширинах глаза) подъём века сходит на нет: складка века, но не бровь.
    package static let lidReach = 0.9
    /// То же для нижнего века: подъём затухает к щеке.
    package static let lowerReach = 0.6
    /// На скольких пикселях у нижнего века правка сходит на нет.
    package static let lowerLidBlend = 1.5
    /// Полуширина полосы смешивания цвета на границах (край века), px.
    package static let edgeBlend = 0.75

    // Локальные оси: u вдоль глаза, v вниз по лицу, начало — центр рамки глаза, в пикселях.
    @inline(__always) func local(_ p: Vec2) -> Vec2 { let d = p - frame.center; return Vec2(d.dot(frame.ex), d.dot(frame.ey)) }
    @inline(__always) func image(_ l: Vec2) -> Vec2 { frame.center + frame.ex * l.x + frame.ey * l.y }

    @inline(__always) func g(_ u: Double) -> Double { let t = u / frame.halfWidth; return max(0, 1 - t * t) }
    /// Верхнее и нижнее веко исходного кадра (эллипс по контуру Vision).
    @inline(__always) func top(_ u: Double) -> Double { lids?.top(u) ?? -frame.halfHeight * g(u).squareRoot() }
    @inline(__always) func bottom(_ u: Double) -> Double { lids?.bottom(u) ?? frame.halfHeight * g(u).squareRoot() }

    /// Край раскрытия в строке v (|u| уголка с нужной стороны): там, где строка ещё между веками.
    func openingEdge(_ v: Double, right: Bool) -> Double {
        let a = frame.halfWidth
        if lids == nil {
            let b = max(frame.halfHeight, 0.5)
            return a * (max(0, 1 - (v / b) * (v / b))).squareRoot()
        }
        // Идём от середины к уголку, пока строка внутри раскрытия.
        let steps = 32
        var last = 0.0
        for k in 0...steps {
            let u = (right ? 1.0 : -1.0) * a * Double(k) / Double(steps)
            if v > top(u) && v < bottom(u) { last = abs(u) } else if k > 0 && last > 0 { break }
        }
        return last
    }
    /// Верхнее и нижнее веко после подъёма.
    @inline(__always) func newTop(_ u: Double) -> Double { top(u) - lidRaise * g(u) }
    @inline(__always) func newBottom(_ u: Double) -> Double { bottom(u) - lowerRaise * g(u) }

    var localShift: Vec2 { Vec2(shift.dot(frame.ex), shift.dot(frame.ey)) }

    func visibleBefore(_ q: Vec2) -> Bool {
        abs(q.x) < frame.halfWidth && q.y > top(q.x) && q.y < bottom(q.x)
    }

    /// Область кадра, которую правка может менять (локальные координаты): по ней идёт отрисовка.
    package var localBounds: (minU: Double, maxU: Double, minV: Double, maxV: Double) {
        let a = frame.halfWidth
        let t = lids.map { $0.top.min() ?? -frame.halfHeight } ?? -frame.halfHeight
        let b = lids.map { $0.bottom.max() ?? frame.halfHeight } ?? frame.halfHeight
        return (-a, a, t - max(lidRaise, 0) - Self.lidReach * a - 1, b + Self.lowerReach * a + 1)
    }

    /// Откуда брать пиксель: исходный кадр (радужка переезжает с рисунком) или «подложка» — тот же кадр, где старая
    /// радужка и полоса у нижнего века под ней заполнены белком и краем века по соседям (гармоническая заливка).
    package enum Layer: Sendable { case original, clean }

    /// Обратное отображение: из каких точек (с весами, сумма 1) и какого слоя брать пиксель для точки `p`.
    /// Несколько точек — только на границах (край века, край радужки, нижнее веко): там цвета смешиваются,
    /// чтобы не было ступенек. Всё, кроме самой радужки, берётся из подложки: белок под и рядом с поднятой радужкой
    /// не собирается из кусков строк (GAZE-35: швы и заплатки при взгляде вбок), а продолжает настоящий белок.
    package func layeredSources(for p: Vec2) -> [(Vec2, Double, Layer)] {
        let l = local(p)
        let a = frame.halfWidth
        if abs(l.x) >= a { return [(p, 1, .original)] }
        let nt = newTop(l.x), nb = newBottom(l.x)
        let aa = Self.edgeBlend
        // Под нижним веком: кожа поднимается вместе с краем века, к щеке — до нуля; на краю ±aa смешиваем с раскрытием.
        func lowerSkin() -> Vec2 {
            let d = max(l.y - nb, 0)
            let h = 1 - smoothstep(0, Self.lowerReach * a, d)
            return image(Vec2(l.x, l.y + lowerRaise * g(l.x) * h))
        }
        if l.y >= nb + aa { return [(lowerSkin(), 1, .clean)] }
        let tLower = smoothstep(nb - aa, nb + aa, l.y)
        // Верхнее веко: над новым краем — веко и кожа, под ним — раскрытие; на краю ±aa смешиваем.
        let tOpen = smoothstep(nt - aa, nt + aa, l.y)
        var out: [(Vec2, Double, Layer)] = []
        if tOpen < 1 {
            let d = max(nt - l.y, 0)
            let h = 1 - smoothstep(0, Self.lidReach * a, d)
            out.append((image(Vec2(l.x, l.y + lidRaise * g(l.x) * h)), 1 - tOpen, .clean))
        }
        if tOpen > 0 {
            if tLower < 1 { for (q, w, k) in openingSources(l) { out.append((q, w * tOpen * (1 - tLower), k)) } }
            if tLower > 0 { out.append((lowerSkin(), tOpen * tLower, .clean)) }
        }
        return out.filter { $0.1 > 1e-9 }
    }

    /// Точки без слоя (для проверок геометрии).
    package func sources(for p: Vec2) -> [(Vec2, Double)] { layeredSources(for: p).map { ($0.0, $0.1) } }

    /// Совместимость: главный источник и, если есть, второй с его долей.
    package func source(for p: Vec2) -> (Vec2, blend: (Vec2, Double)?) {
        let s = sources(for: p).sorted { $0.1 > $1.1 }
        return (s[0].0, s.count > 1 ? (s[1].0, s[1].1) : nil)
    }

    /// Раскрытие глаза: подложка (белок без старой радужки) переносится по вертикали из нового раскрытия в старое,
    /// поверх — радужка целиком на новом месте, её край сглажен на полосе ±1,25 px.
    func openingSources(_ l: Vec2) -> [(Vec2, Double, Layer)] {
        let nt = newTop(l.x), nb = newBottom(l.x), t = top(l.x), bt = bottom(l.x)
        let vs = nb - nt > 0.01 ? t + (l.y - nt) * (bt - t) / (nb - nt) : l.y
        let background = image(Vec2(l.x, vs))
        let oldIris = local(iris)
        let rel = l - (oldIris + localShift)
        let r = irisRadius
        let edge = smoothstep(r - 1.25, r + 1.25, rel.length)
        if edge >= 1 { return [(background, 1, .clean)] }
        let irisSrc = image(irisSource(rel: rel, oldIris: oldIris))
        if edge <= 0 { return [(irisSrc, 1, .original)] }
        return [(irisSrc, 1 - edge, .original), (background, edge, .clean)]
    }

    /// Сколько белка вокруг старой радужки заменяется подложкой: тёмный лимб и размытый край, плюс запас на ошибку
    /// центра радужки у модели (B 184: край старой радужки оставался вторым контуром).
    package static let cleanPad = 1.5, cleanPadRatio = 0.12
    /// Радиус области подложки вокруг старой радужки, px.
    package var cleanRadius: Double { irisRadius * (1 + Self.cleanPadRatio) + Self.cleanPad }
    /// Полоса под нижним веком в столбцах радужки (px), которая тоже идёт в подложку: в исходнике там размытый низ
    /// радужки, и после подъёма он оставался тёмной дугой вдоль века (CHK-3, B 127).
    package static let cleanLowerBand = 2.0

    /// Видимый сдвиг радужки (локальные оси, px): центр видимой части круга радужки после правки минус до неё.
    /// Верх радужки под веком не виден, поэтому видимый подъём может быть меньше сдвига — индикатор показывает его.
    package var visibleShift: Vec2 {
        let oldIris = local(iris), newIris = oldIris + localShift
        let r = max(irisRadius - 0.5, 1), step = 0.5
        func centroid(_ c: Vec2, _ inside: (Vec2) -> Bool) -> Vec2? {
            var sum = Vec2.zero, n = 0.0
            var y = -r
            while y <= r {
                var x = -r
                while x <= r {
                    if x * x + y * y <= r * r { let q = c + Vec2(x, y); if inside(q) { sum += q; n += 1 } }
                    x += step
                }
                y += step
            }
            return n > 0 ? sum / n : nil
        }
        let a = frame.halfWidth
        guard let before = centroid(oldIris, { abs($0.x) < a && $0.y > self.top($0.x) && $0.y < self.bottom($0.x) }),
              let after = centroid(newIris, { abs($0.x) < a && $0.y > self.newTop($0.x) && $0.y < self.newBottom($0.x) }) else { return .zero }
        return after - before
    }

    /// Отступ от края века внутрь, в пикселях: край века (ресницы, тень) не должен переноситься вместе с радужкой.
    /// Растёт вместе со сдвигом, чтобы без сдвига отображение оставалось тождественным.
    var lidMargin: Double {
        // С точными веками достаточно полпикселя запаса (сглаживание края века), с эллипсом Vision — 1,2–2 px.
        (lids != nil ? 0.6 : max(1.2, 0.25 * frame.halfHeight)) * min(1, (localShift.length + abs(lidRaise)) / 2)
    }

    func irisVisibleBefore(_ q: Vec2) -> Bool {
        abs(q.x) < frame.halfWidth && q.y > top(q.x) + lidMargin && q.y < bottom(q.x) - lidMargin
    }

    /// Радужка переезжает целиком. Часть, которая в исходнике была скрыта веком, берётся с того же радиуса,
    /// но под ближайшим видимым углом (поворот к горизонтали): рисунок радужки радиальный, лимб — кольцо,
    /// поэтому так не появляется полос, а на границе видимости поворот нулевой и шва нет.
    func irisSource(rel: Vec2, oldIris: Vec2) -> Vec2 {
        let q = oldIris + rel
        if irisVisibleBefore(q) { return q }
        let rho = rel.length
        if rho > 1e-6 {
            let phi = atan2(rel.y, rel.x)
            let target = rel.x >= 0 ? 0.0 : (phi >= 0 ? Double.pi : -Double.pi)
            let steps = 24
            for k in 1...steps {
                let a = phi + (target - phi) * Double(k) / Double(steps)
                let c = oldIris + Vec2(cos(a), sin(a)) * rho
                if irisVisibleBefore(c) { return c }
            }
        }
        // Даже по горизонтали не видно (радиус больше раскрытия): идём по лучу к центру, пока не станет видно.
        // Так получается радиальное продолжение рисунка, а не одноцветный вертикальный столбец.
        for k in 1...12 {
            let c = oldIris + rel * (1 - Double(k) / 12)
            if irisVisibleBefore(c) { return c }
        }
        return oldIris
    }
}

/// Пиксели кадра: 4 байта на точку (порядок каналов не важен), строки по `rowBytes`.
package struct PixelView {
    package let base: UnsafeMutablePointer<UInt8>
    package let width: Int, height: Int, rowBytes: Int
    package init(base: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int) {
        self.base = base; self.width = width; self.height = height; self.rowBytes = rowBytes
    }
}

/// Отрисовка правок прямо в кадре на CPU: правится только область глаз (единицы тысяч точек), выборка бикубическая
/// (Catmull — Rom), поэтому радужка остаётся резкой. Источник — копия области до правки.
package enum EyeRenderer {
    package static func render(_ edits: [EyeEdit], into view: PixelView) {
        for edit in edits where edit.shift.length > 0.05 || abs(edit.lidRaise) > 0.05 {
            renderOne(edit, into: view)
        }
    }

    static func renderOne(_ e: EyeEdit, into v: PixelView) {
        // Прямоугольник кадра вокруг области правки.
        let b = e.localBounds
        let corners = [Vec2(b.minU, b.minV), Vec2(b.maxU, b.minV), Vec2(b.minU, b.maxV), Vec2(b.maxU, b.maxV)].map(e.image)
        let pad = 3 + e.shift.length + abs(e.lidRaise)
        let x0 = max(0, Int(floor(corners.map(\.x).min()! - pad))), x1 = min(v.width - 1, Int(ceil(corners.map(\.x).max()! + pad)))
        let y0 = max(0, Int(floor(corners.map(\.y).min()! - pad))), y1 = min(v.height - 1, Int(ceil(corners.map(\.y).max()! + pad)))
        guard x1 > x0, y1 > y0 else { return }
        // Копия исходной области: читаем из неё, пишем в кадр.
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        var src = [UInt8](repeating: 0, count: cw * ch * 4)
        for y in 0..<ch {
            memcpy(&src[y * cw * 4], v.base + (y0 + y) * v.rowBytes + x0 * 4, cw * 4)
        }
        let clean = cleanPlate(e, src: src, w: cw, h: ch, ox: x0, oy: y0)
        src.withUnsafeBufferPointer { s in
            clean.withUnsafeBufferPointer { c in
                let original = Bicubic(px: s.baseAddress!, w: cw, h: ch, ox: x0, oy: y0)
                let plate = Bicubic(px: c.baseAddress!, w: cw, h: ch, ox: x0, oy: y0)
                for y in y0...y1 {
                    let row = v.base + y * v.rowBytes
                    for x in x0...x1 {
                        let p = Vec2(Double(x) + 0.5, Double(y) + 0.5)
                        let srcs = e.layeredSources(for: p)
                        if srcs.count == 1, srcs[0].2 == .original, abs(srcs[0].0.x - p.x) < 1e-6, abs(srcs[0].0.y - p.y) < 1e-6 { continue }
                        var acc = [0.0, 0.0, 0.0, 0.0]
                        for (q, w, layer) in srcs {
                            let val = (layer == .original ? original : plate).sample(q)
                            for k in 0..<4 { acc[k] += val[k] * w }
                        }
                        let o = row + x * 4
                        for k in 0..<4 { o[k] = UInt8(min(max(acc[k].rounded(), 0), 255)) }
                    }
                }
            }
        }
    }

    /// Подложка: копия области, где старая радужка с лимбом (и полоса под нижним веком в её столбцах) заполнена
    /// по соседям гармонически — как будто радужки там нет. Белок заливается только от белка (ни ресницы, ни кожа века
    /// не затягиваются: через края век условие «без потока»), полоса у нижнего века — только от края века и кожи
    /// под ним (иначе вдоль века светлая линия). Без белка вокруг (глаз почти закрыт) подложка равна исходнику.
    static func cleanPlate(_ e: EyeEdit, src: [UInt8], w: Int, h: Int, ox: Int, oy: Int) -> [UInt8] {
        let R = e.cleanRadius, a = e.frame.halfWidth, band = EyeEdit.cleanLowerBand
        let cx = e.iris.x - Double(ox), cy = e.iris.y - Double(oy)
        let bx0 = max(1, Int(floor(cx - R - 3))), bx1 = min(w - 2, Int(ceil(cx + R + 3)))
        let by0 = max(1, Int(floor(cy - R - 3))), by1 = min(h - 2, Int(ceil(cy + R + 3 + band)))
        guard bx1 > bx0, by1 > by0 else { return src }
        // Зона: 0 — не участвует (веко сверху, вне глаза), 1 — раскрытие, 2 — полоса у нижнего века, 3 — кожа под ней.
        var zone = [UInt8](repeating: 0, count: w * h)
        var unknown = [Bool](repeating: false, count: w * h)
        var list: [Int] = []
        var knownOpen = 0
        for y in by0...by1 {
            for x in bx0...bx1 {
                let p = Vec2(Double(x + ox) + 0.5, Double(y + oy) + 0.5)
                let l = e.local(p)
                guard abs(l.x) < a - 0.5, l.y > e.top(l.x) else { continue }
                let i = y * w + x
                let bt = e.bottom(l.x)
                zone[i] = l.y < bt ? 1 : (l.y < bt + band ? 2 : 3)
                if zone[i] != 3, (p - e.iris).length < R { unknown[i] = true; list.append(i) } else if zone[i] == 1 { knownOpen += 1 }
            }
        }
        guard !list.isEmpty, knownOpen >= 4 else { return src }
        // Соседи, от которых берётся цвет: белок — только от белка (край века остаётся резким, как в исходнике),
        // полоса у века — от полосы и кожи под ней.
        @inline(__always) func usable(_ from: UInt8, _ to: UInt8) -> Bool { from == 1 ? to == 1 : (to == 2 || to == 3) }
        var f = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) where zone[i] != 0 { for c in 0..<3 { f[i * 3 + c] = Float(src[i * 4 + c]) } }
        // Начальное приближение: по строке между ближайшими известными точками той же зоны.
        for i in list {
            let y = i / w, x = i % w, z = zone[i]
            var left: Int?, right: Int?
            var k = x - 1
            while k >= bx0 { let j = y * w + k; if zone[j] != z { break }; if !unknown[j] { left = j; break }; k -= 1 }
            k = x + 1
            while k <= bx1 { let j = y * w + k; if zone[j] != z { break }; if !unknown[j] { right = j; break }; k += 1 }
            for c in 0..<3 {
                switch (left, right) {
                case let (l?, r?):
                    let t = Float(x - l % w) / Float(r % w - l % w)
                    f[i * 3 + c] = f[l * 3 + c] * (1 - t) + f[r * 3 + c] * t
                case let (l?, nil): f[i * 3 + c] = f[l * 3 + c]
                case let (nil, r?): f[i * 3 + c] = f[r * 3 + c]
                default: break
                }
            }
        }
        // Гаусс — Зейдель с верхней релаксацией: уравнение Лапласа по допустимым соседям.
        let omega: Float = 1.7
        let offsets = [-1, 1, -w, w]
        for _ in 0..<EyeRenderer.cleanIterations {
            for i in list {
                let z = zone[i]
                var s0: Float = 0, s1: Float = 0, s2: Float = 0, n: Float = 0
                for d in offsets {
                    let j = i + d
                    guard usable(z, zone[j]) else { continue }
                    s0 += f[j * 3]; s1 += f[j * 3 + 1]; s2 += f[j * 3 + 2]; n += 1
                }
                guard n > 0 else { continue }
                f[i * 3] += omega * (s0 / n - f[i * 3])
                f[i * 3 + 1] += omega * (s1 / n - f[i * 3 + 1])
                f[i * 3 + 2] += omega * (s2 / n - f[i * 3 + 2])
            }
        }
        var out = src
        for i in list { for c in 0..<3 { out[i * 4 + c] = UInt8(min(max(f[i * 3 + c].rounded(), 0), 255)) } }
        return out
    }

    /// Итераций заливки подложки: область — круг радужки (на 1080p ~ 30 px в поперечнике).
    static let cleanIterations = 60
}

/// Бикубическая выборка Catmull — Rom по копии области; координаты — в пикселях кадра (центр пикселя = +0,5).
struct Bicubic {
    let px: UnsafePointer<UInt8>
    let w: Int, h: Int, ox: Int, oy: Int

    @inline(__always) static func weights(_ t: Double) -> (Double, Double, Double, Double) {
        let t2 = t * t, t3 = t2 * t
        return (-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
    }

    func sample(_ p: Vec2) -> [Double] {
        let x = p.x - 0.5 - Double(ox), y = p.y - 0.5 - Double(oy)
        let xi = Int(floor(x)), yi = Int(floor(y))
        let wx = Self.weights(x - Double(xi)), wy = Self.weights(y - Double(yi))
        let ax = [wx.0, wx.1, wx.2, wx.3], ay = [wy.0, wy.1, wy.2, wy.3]
        var c = [0.0, 0.0, 0.0, 0.0]
        for j in 0..<4 {
            let yy = min(max(yi - 1 + j, 0), h - 1)
            var rc = (0.0, 0.0, 0.0, 0.0)
            for i in 0..<4 {
                let xx = min(max(xi - 1 + i, 0), w - 1)
                let q = px + (yy * w + xx) * 4
                let k = ax[i]
                rc.0 += Double(q[0]) * k; rc.1 += Double(q[1]) * k; rc.2 += Double(q[2]) * k; rc.3 += Double(q[3]) * k
            }
            c[0] += rc.0 * ay[j]; c[1] += rc.1 * ay[j]; c[2] += rc.2 * ay[j]; c[3] += rc.3 * ay[j]
        }
        return c
    }
}

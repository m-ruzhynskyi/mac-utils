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
    /// На сколько поднять нижнее веко в середине (> 0 — вверх). Сейчас контроллер его не двигает: на месте края века
    /// у радужки в исходнике её тёмный низ, и он переносился бы вверх линией. Оставлено для опытов.
    package var lowerRaise: Double
    /// На сколько растянуть низ радужки вниз (px), чтобы после подъёма он всё ещё уходил под нижнее веко.
    package var irisStretchDown: Double = 0

    package init(frame: EyeFrame, iris: Vec2, irisRadius: Double, shift: Vec2, lidRaise: Double, lids: LidCurves? = nil, lowerRaise: Double = 0) {
        self.frame = frame; self.iris = iris; self.irisRadius = irisRadius; self.shift = shift; self.lidRaise = lidRaise; self.lids = lids
        self.lowerRaise = lowerRaise
    }

    /// Сколько не хватает низу радужки до нижнего века после подъёма: столько растягиваем вниз (без полоски белка).
    /// Если радужка и так перекрыта веком больше, чем на подъём, — ноль.
    package static func lowerGap(for frame: EyeFrame, lids: LidCurves?, iris: Vec2, irisRadius: Double, shift: Vec2) -> Double {
        let d = iris - frame.center
        let u = d.dot(frame.ex), v = d.dot(frame.ey)
        let lift = -shift.dot(frame.ey)
        guard lift > 0 else { return 0 }
        let bottom = lids?.bottom(u) ?? frame.halfHeight * max(0, 1 - (u / frame.halfWidth) * (u / frame.halfWidth)).squareRoot()
        let overlap = v + irisRadius - bottom // насколько низ радужки ушёл под веко
        return min(max(lift - max(overlap, 0), 0), lift)
    }

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

    /// Обратное отображение: из каких точек исходного кадра (с весами, сумма 1) брать пиксель для точки `p`.
    /// Несколько точек — только на границах (край века, край радужки, нижнее веко): там цвета смешиваются,
    /// чтобы не было ступенек.
    package func sources(for p: Vec2) -> [(Vec2, Double)] {
        let l = local(p)
        let a = frame.halfWidth
        if abs(l.x) >= a { return [(p, 1)] }
        let nt = newTop(l.x), nb = newBottom(l.x)
        let aa = Self.edgeBlend
        // Под нижним веком: кожа поднимается вместе с краем века, к щеке — до нуля; на краю ±aa смешиваем с раскрытием.
        func lowerSkin() -> Vec2 {
            let d = max(l.y - nb, 0)
            let h = 1 - smoothstep(0, Self.lowerReach * a, d)
            return image(Vec2(l.x, l.y + lowerRaise * g(l.x) * h))
        }
        if l.y >= nb + aa { return [(lowerSkin(), 1)] }
        let tLower = smoothstep(nb - aa, nb + aa, l.y)
        // Верхнее веко: над новым краем — веко и кожа, под ним — раскрытие; на краю ±aa смешиваем.
        let tOpen = smoothstep(nt - aa, nt + aa, l.y)
        var out: [(Vec2, Double)] = []
        if tOpen < 1 {
            let d = max(nt - l.y, 0)
            let h = 1 - smoothstep(0, Self.lidReach * a, d)
            out.append((image(Vec2(l.x, l.y + lidRaise * g(l.x) * h)), 1 - tOpen))
        }
        if tOpen > 0 {
            if tLower < 1 { for (q, w) in openingSources(l) { out.append((q, w * tOpen * (1 - tLower))) } }
            if tLower > 0 { out.append((lowerSkin(), tOpen * tLower)) }
        }
        return out.filter { $0.1 > 1e-9 }
    }

    /// Совместимость: главный источник и, если есть, второй с его долей.
    package func source(for p: Vec2) -> (Vec2, blend: (Vec2, Double)?) {
        let s = sources(for: p).sorted { $0.1 > $1.1 }
        return (s[0].0, s.count > 1 ? (s[1].0, s[1].1) : nil)
    }

    /// Раскрытие глаза с учётом нижнего века. У нижнего века (оно не двигается) подъём сходит на нет на полосе
    /// 1,5 px — там остаётся только горизонтальный сдвиг, — а на последних ±0,75 px цвет смешивается с исходным,
    /// чтобы край века остался как был.
    func openingSources(_ l: Vec2) -> [(Vec2, Double)] {
        let toLower = newBottom(l.x) - l.y
        let keep = 1 - smoothstep(0, Self.lowerLidBlend, toLower)
        let (q, bl) = openingSource(l)
        var list: [(Vec2, Double)]
        if keep > 0, abs(localShift.y) > 1e-9 || abs(lidRaise) > 1e-9 {
            // «Плоский» вариант: тот же горизонтальный сдвиг, без подъёма; нижнее веко — как в основной правке.
            let flat = EyeEdit(frame: frame, iris: iris, irisRadius: irisRadius, shift: frame.ex * localShift.x, lidRaise: 0, lids: lids, lowerRaise: lowerRaise)
            let (qf, blf) = flat.openingSource(l)
            func mix(_ a: Vec2, _ b: Vec2) -> Vec2 { a + (b - a) * keep }
            switch (bl, blf) {
            case let (x?, y?): list = [(mix(q, qf), 1 - (x.1 * (1 - keep) + y.1 * keep)), (mix(x.0, y.0), x.1 * (1 - keep) + y.1 * keep)]
            case let (x?, nil): list = [(mix(q, qf), 1 - x.1 * (1 - keep)), (mix(x.0, qf), x.1 * (1 - keep))]
            case let (nil, y?): list = [(mix(q, qf), 1 - y.1 * keep), (mix(q, y.0), y.1 * keep)]
            default: list = [(mix(q, qf), 1)]
            }
        } else {
            list = bl.map { [(q, 1 - $0.1), ($0.0, $0.1)] } ?? [(q, 1)]
        }
        return list.map { (image($0.0), $0.1) }.filter { $0.1 > 1e-6 }
    }

    /// Источник внутри раскрытия (локальные координаты): радужка целиком или белок, плюс сглаживание края радужки.
    func openingSource(_ l: Vec2) -> (Vec2, (Vec2, Double)?) {
        let s = localShift
        let oldIris = local(iris)
        let newIris = oldIris + s
        let r = irisRadius
        // Ниже центра радужка растянута на irisStretchDown: в координатах исходной радужки сжимаем по вертикали.
        let rel0 = l - newIris
        let rel = rel0.y > 0 && irisStretchDown > 0 ? Vec2(rel0.x, rel0.y * r / (r + irisStretchDown)) : rel0
        let rho = rel.length
        let irisSrc = irisSource(rel: rel, oldIris: oldIris)
        let scleraSrc = scleraSource(l, rel: rel, rho: rho, newIris: newIris, oldIris: oldIris)
        // Край радужки (лимб) сглаживается на полосе ±1,25 px.
        let edge = smoothstep(r - 1.25, r + 1.25, rho)
        if edge <= 0 { return (irisSrc, nil) }
        if edge >= 1 { return (scleraSrc, nil) }
        return (irisSrc, (scleraSrc, edge))
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

    /// Белок построчно. Строка сначала переносится по вертикали из нового раскрытия (веко поднято) в старое,
    /// затем в строке белок между радужкой и уголком растягивается или сжимается линейно:
    /// отрезок [край новой радужки, уголок] → [край старой радужки + запас на лимб, уголок].
    /// Так белок берётся только из белка той же строки: без второй радужки и без затягивания края века.
    func scleraSource(_ l: Vec2, rel: Vec2, rho: Double, newIris: Vec2, oldIris: Vec2) -> Vec2 {
        // Вертикаль: новое раскрытие [newTop, bottom] → старое [top, bottom] в этом столбце.
        let nt = newTop(l.x), nbt = newBottom(l.x), t = top(l.x), bt = bottom(l.x)
        // Без отступа от века: на краю раскрытия белок должен непрерывно переходить в веко.
        var vs = nbt - nt > 0.01 ? t + (l.y - nt) * (bt - t) / (nbt - nt) : l.y
        // Хорды радужки в строке: старая (с запасом на тёмный лимб) и новая.
        let limbus = irisRadius + 1.5 * min(1, localShift.length / 2)
        func half(_ dv: Double, _ r: Double) -> Double { (max(0, r * r - dv * dv)).squareRoot() }
        let right = l.x >= newIris.x
        func cornerAt(_ v: Double) -> Double { openingEdge(v, right: right) }
        // У века в строке может не быть белка (старая радужка до уголка) — берём ближайшую к середине строку, где он есть.
        func hasSclera(_ v: Double) -> Bool {
            let h = half(v - oldIris.y, limbus), c = cornerAt(v)
            return right ? c > oldIris.x + h + 1 : -c < oldIris.x - h - 1
        }
        if localShift.length > 0.05, !hasSclera(vs) {
            var v = vs
            let step = vs > 0 ? -0.5 : 0.5
            while abs(v) > 0.25, !hasSclera(v) { v += step }
            vs = v
        }
        let dvN = l.y - newIris.y
        let hN = half(dvN > 0 && irisStretchDown > 0 ? dvN * irisRadius / (irisRadius + irisStretchDown) : dvN, irisRadius)
        let hO = half(vs - oldIris.y, limbus)
        let corner = cornerAt(vs)
        let oL = oldIris.x - hO, oR = oldIris.x + hO, nL = newIris.x - hN, nR = newIris.x + hN
        var us = l.x
        if l.x >= nR {
            us = corner - nR > 0.5 ? oR + (l.x - nR) * (corner - oR) / (corner - nR) : l.x
        } else if l.x <= nL {
            us = -corner - nL < -0.5 ? -corner + (l.x + corner) * (oL + corner) / (nL + corner) : l.x
        } else {
            // Внутри хорды новой радужки (полоса сглаживания края): ближайший край старой хорды.
            us = l.x >= newIris.x ? oR : oL
        }
        return Vec2(min(max(us, -corner), corner), vs)
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
        src.withUnsafeBufferPointer { s in
            let sampler = Bicubic(px: s.baseAddress!, w: cw, h: ch, ox: x0, oy: y0)
            for y in y0...y1 {
                let row = v.base + y * v.rowBytes
                for x in x0...x1 {
                    let p = Vec2(Double(x) + 0.5, Double(y) + 0.5)
                    let srcs = e.sources(for: p)
                    if srcs.count == 1, abs(srcs[0].0.x - p.x) < 1e-6, abs(srcs[0].0.y - p.y) < 1e-6 { continue }
                    var c = [0.0, 0.0, 0.0, 0.0]
                    for (q, w) in srcs {
                        let v = sampler.sample(q)
                        for k in 0..<4 { c[k] += v[k] * w }
                    }
                    let o = row + x * 4
                    for k in 0..<4 { o[k] = UInt8(min(max(c[k].rounded(), 0), 255)) }
                }
            }
        }
    }
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

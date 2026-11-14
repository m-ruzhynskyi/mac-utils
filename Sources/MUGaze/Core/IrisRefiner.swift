import Foundation

/// Уточнение центра радужки по изображению. Модель Iris при сильном взгляде в сторону ставит центр ближе к середине
/// глаза на 4–6 px (запись B, кадр 184): радужка переносилась без своего края, и старый край оставался вторым
/// контуром. Ищем сдвиг, при котором круг радиуса r темнее всего внутри и светлее всего в кольце снаружи — только по
/// видимой между веками части. Поиск узкий (по горизонтали ±0,45 r, по вертикали ±0,15 r): верх радужки обычно под веком.
package enum IrisRefiner {
    package static let rangeX = 0.45, rangeY = 0.15
    /// Минимальный выигрыш контраста (доли яркости), чтобы сдвинуть центр: на ровной картинке центр не трогаем.
    package static let minGain = 0.02

    package static func refine(_ shape: EyeShape, frame: EyeFrame, image: LumaSampler) -> EyeShape {
        let r = shape.irisRadius
        guard r >= 3 else { return shape }
        let lids = shape.lidCurves(in: frame)
        let ex = frame.ex, ey = frame.ey
        func visible(_ p: Vec2) -> Bool {
            let d = p - frame.center, u = d.dot(ex), v = d.dot(ey)
            return abs(u) < frame.halfWidth - 0.5 && v > lids.top(u) + 0.75 && v < lids.bottom(u) - 0.75
        }
        // Точки круга и кольца в осях глаза — один раз.
        var inner: [Vec2] = [], ring: [Vec2] = []
        let step = max(1, r / 8)
        var y = -r
        while y <= r {
            var x = -r
            while x <= r {
                let q = (x * x + y * y).squareRoot()
                if q > 0.25 * r && q < r - 1.5 { inner.append(Vec2(x, y)) }
                x += step
            }
            y += step
        }
        for k in 0..<40 {
            let t = Double(k) / 40 * 2 * .pi
            for rr in [r + 1.0, r + 2.5] { ring.append(Vec2(cos(t), sin(t)) * rr) }
        }
        func score(_ c: Vec2) -> Double? {
            var si = 0.0, ni = 0.0, so = 0.0, no = 0.0
            for d in inner { let p = c + ex * d.x + ey * d.y; if visible(p) { si += image.luma(p); ni += 1 } }
            for d in ring { let p = c + ex * d.x + ey * d.y; if visible(p) { so += image.luma(p); no += 1 } }
            guard ni >= Double(inner.count) * 0.25, no >= 12 else { return nil }
            return so / no - si / ni
        }
        guard let base = score(shape.iris) else { return shape }
        var best = base, bestC = shape.iris
        let sx = max(0.5, r * 0.05)
        var dy = -rangeY * r
        while dy <= rangeY * r + 1e-9 {
            var dx = -rangeX * r
            while dx <= rangeX * r + 1e-9 {
                let c = shape.iris + ex * dx + ey * dy
                if let s = score(c), s > best { best = s; bestC = c }
                dx += sx
            }
            dy += max(1, rangeY * r / 2)
        }
        guard best - base > minGain else { return shape }
        var out = shape
        out.iris = bestC
        return out
    }
}

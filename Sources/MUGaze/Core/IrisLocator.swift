import Foundation

/// Яркость кадра 0…1 в произвольной точке (билинейно). Источник — буфер кадра, тестовая картинка и т. п.
package protocol LumaSampler {
    func luma(_ p: Vec2) -> Double
}

package struct IrisFit: Equatable, Sendable {
    package var center: Vec2
    package var radius: Double
    /// Насколько радужка темнее белка, в долях яркости белка (0…1). Мало — блик на очках, закрытый глаз, темнота.
    package var contrast: Double
}

/// Поиск центра радужки внутри глаза по градиентам (Timm, Barth 2011, «Accurate eye centre localisation by means of gradients»):
/// центр — точка, из которой больше всего перепадов яркости «тёмное → светлое» направлены наружу.
/// Блики не мешают: их края дают градиенты внутрь, а такие не учитываются. Точки Vision «зрачок» слишком грубые.
package enum IrisLocator {
    package static let radiusRatio = 0.42
    /// Минимальный относительный контраст радужки к белку.
    package static let minContrast = 0.18

    private struct Grad { var p: Vec2; var g: Vec2 }

    package static func locate(in eye: EyeFrame, image: LumaSampler) -> IrisFit? {
        let a = eye.halfWidth, b = eye.halfHeight
        guard a >= 3, eye.openness > 0.12 else { return nil }
        let r = radiusRatio * a
        let step = max(0.75, a * 0.04)
        let inner = 0.95

        // Сетка внутри глаза: яркость и градиенты.
        var samples: [(p: Vec2, l: Double)] = []
        var gy = -b
        while gy <= b {
            var gx = -a
            while gx <= a {
                let p = eye.center + eye.ex * gx + eye.ey * gy
                if eye.contains(p, scale: inner) { samples.append((p, image.luma(p))) }
                gx += step
            }
            gy += step
        }
        guard samples.count >= 16 else { return nil }
        let sorted = samples.map(\.l).sorted()
        let dark = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let sclera = sorted[Int(Double(sorted.count - 1) * 0.85)]
        let highlight = sclera + 0.6 * (1 - sclera) // блики ярче белка

        var grads: [Grad] = []
        let h = 0.5 * step
        for s in samples where s.l < highlight {
            let gx = image.luma(s.p + eye.ex * h) - image.luma(s.p - eye.ex * h)
            let gy = image.luma(s.p + eye.ey * h) - image.luma(s.p - eye.ey * h)
            // Градиент рядом с бликом — от блика, не от радужки.
            if image.luma(s.p + eye.ex * step) >= highlight || image.luma(s.p - eye.ex * step) >= highlight
                || image.luma(s.p + eye.ey * step) >= highlight || image.luma(s.p - eye.ey * step) >= highlight { continue }
            let g = eye.ex * gx + eye.ey * gy
            grads.append(Grad(p: s.p, g: g))
        }
        let mags = grads.map { $0.g.length }
        guard !mags.isEmpty else { return nil }
        let mean = mags.reduce(0, +) / Double(mags.count)
        let sd = (mags.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(mags.count)).squareRoot()
        let strong = grads.filter { $0.g.length > mean + 0.3 * sd }.map { Grad(p: $0.p, g: $0.g.normalized) }
        guard strong.count >= 6 else { return nil }

        func objective(_ c: Vec2) -> Double {
            var sum = 0.0
            for s in strong {
                let d = s.p - c
                let len = d.length
                guard len > 0.5, len < 1.6 * r else { continue }
                let dot = max(0, (d / len).dot(s.g))
                sum += dot * dot
            }
            // Центр радужки тёмный: вес по яркости в центре (с бликом — по окрестности).
            let l = min(image.luma(c), (image.luma(c + eye.ex * (0.4 * r)) + image.luma(c - eye.ex * (0.4 * r))) / 2)
            return sum * max(0.05, 1 - l)
        }

        var best = (score: -1.0, at: eye.center)
        let rangeX = 0.7 * a, rangeY = max(0.5 * b, step)
        var cy = -rangeY
        while cy <= rangeY + 1e-9 {
            var cx = -rangeX
            while cx <= rangeX + 1e-9 {
                let c = eye.center + eye.ex * cx + eye.ey * cy
                let s = objective(c)
                if s > best.score { best = (s, c) }
                cx += step
            }
            cy += step
        }
        // Уточнение на сетке в четверть шага.
        let coarse = best.at
        let fine = step / 4
        for j in -4...4 {
            for i in -4...4 {
                let c = coarse + eye.ex * (Double(i) * fine) + eye.ey * (Double(j) * fine)
                let s = objective(c)
                if s > best.score { best = (s, c) }
            }
        }

        // Контраст: средняя яркость диска радужки без бликов против белка.
        var sum = 0.0, n = 0
        for s in samples where (s.p - best.at).length <= 0.8 * r && s.l < highlight { sum += s.l; n += 1 }
        guard n > 0, sclera > 0.02 else { return nil }
        let iris = min(sum / Double(n), max(dark, sum / Double(n)))
        let contrast = (sclera - iris) / sclera
        guard contrast >= minContrast else { return nil }
        return IrisFit(center: best.at, radius: r, contrast: contrast)
    }
}

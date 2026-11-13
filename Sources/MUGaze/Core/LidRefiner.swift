import Foundation

/// Уточнение верхнего века по изображению. Модель точек (MediaPipe) на опущенном взгляде и прищуре ставит веко
/// выше настоящего на 3–6 px. Вдоль нормали к веку ищем самый сильный перепад «светлая кожа → тёмный край ресниц»
/// (идём вниз — темнеет), с поправкой на расстояние от исходной точки; субпиксельно (парабола по трём точкам).
/// Затем сглаживаем смещения вдоль века (1-2-1), чтобы одиночная ошибка не ломала кривую.
package enum LidRefiner {
    package static let searchUp = 3.0, searchDown = 7.0
    /// Минимальный перепад яркости (0…1), чтобы поверить находке.
    package static let minEdge = 0.035
    /// Штраф за удаление от исходной точки (яркость на пиксель).
    package static let prior = 0.004

    package static func refineUpper(_ shape: EyeShape, axis: Vec2, image: LumaSampler) -> EyeShape {
        guard shape.upper.count >= 3 else { return shape }
        let ex = axis.normalized, ey = ex.perpendicular
        let width = (shape.cornerB - shape.cornerA).length
        let scale = max(width / 50, 0.5)               // окно поиска — в пикселях глаза шириной ~50 px
        let up = searchUp * scale, down = searchDown * scale, step = 0.5
        var offsets = [Double](repeating: 0, count: shape.upper.count)
        for i in 1..<(shape.upper.count - 1) {
            let p = shape.upper[i]
            func L(_ v: Double) -> Double {
                let c = p + ey * v
                return (image.luma(c - ex) + image.luma(c) + image.luma(c + ex)) / 3
            }
            var best = (score: -Double.infinity, v: 0.0, d: 0.0)
            var scores: [(Double, Double)] = []
            var v = -up
            while v <= down {
                let d = L(v - 0.75) - L(v + 0.75)           // > 0: ниже темнее
                let s = d - prior * abs(v) / scale
                scores.append((v, s))
                if s > best.score { best = (s, v, d) }
                v += step
            }
            guard best.d > minEdge else { continue }
            // Субпиксельно: парабола по соседям максимума.
            if let k = scores.firstIndex(where: { $0.0 == best.v }), k > 0, k < scores.count - 1 {
                let a = scores[k - 1].1, b = scores[k].1, c = scores[k + 1].1
                let den = a - 2 * b + c
                offsets[i] = best.v + (abs(den) > 1e-9 ? 0.5 * (a - c) / den * step : 0)
            } else {
                offsets[i] = best.v
            }
        }
        // Сглаживание вдоль века; уголки не двигаем.
        var smooth = offsets
        for i in 1..<(offsets.count - 1) { smooth[i] = (offsets[i - 1] + 2 * offsets[i] + offsets[i + 1]) / 4 }
        var out = shape
        out.upper = zip(shape.upper, smooth).map { $0 + ey * $1 }
        return out
    }
}

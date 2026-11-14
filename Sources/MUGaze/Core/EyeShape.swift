import Foundation

/// Точная форма глаза (A v3): уголки, кривые век и радужка — в пикселях кадра.
/// Источник — модель точек глаза (MediaPipe Iris: 71 точка контура и 5 точек радужки) или любой другой.
package struct EyeShape: Equatable, Codable, Sendable {
    /// Уголки: A — левее по оси глаз, B — правее.
    package var cornerA: Vec2, cornerB: Vec2
    /// Кривые век от уголка A к уголку B (уголки включены).
    package var upper: [Vec2], lower: [Vec2]
    package var iris: Vec2
    package var irisRadius: Double

    package init(cornerA: Vec2, cornerB: Vec2, upper: [Vec2], lower: [Vec2], iris: Vec2, irisRadius: Double) {
        self.cornerA = cornerA; self.cornerB = cornerB; self.upper = upper; self.lower = lower; self.iris = iris; self.irisRadius = irisRadius
    }

    /// Индексы MediaPipe Iris: 0…8 — нижнее веко от уголка к уголку, 9…15 — верхнее (9 у уголка 0, 15 у уголка 8).
    /// Радужка: 0 — центр, 1…4 — край.
    package static func fromMediaPipe(contour: [Vec2], iris irisPoints: [Vec2], axis: Vec2) -> EyeShape? {
        guard contour.count >= 16, irisPoints.count >= 5 else { return nil }
        var lower = Array(contour[0...8])
        var upper = [contour[0]] + Array(contour[9...15]) + [contour[8]]
        if (contour[8] - contour[0]).dot(axis) < 0 { lower.reverse(); upper.reverse() }
        let c = irisPoints[0]
        let r = irisPoints[1...4].map { ($0 - c).length }.reduce(0, +) / 4
        return EyeShape(cornerA: lower.first!, cornerB: lower.last!, upper: upper, lower: lower, iris: c, irisRadius: r)
    }

    /// Индексы Face Landmarker v2 (FaceMesh, 478 точек) для глаза слева на кадре (0) и справа (1): уголки, верхнее
    /// и нижнее веко от уголка к уголку, центр радужки и 4 точки её края.
    package struct FaceMeshEye: Sendable {
        package let corners: (Int, Int), upper: [Int], lower: [Int], iris: Int, irisEdge: [Int]
    }
    package static let faceMeshEyes = [
        FaceMeshEye(corners: (33, 133), upper: [246, 161, 160, 159, 158, 157, 173], lower: [7, 163, 144, 145, 153, 154, 155],
                    iris: 468, irisEdge: [469, 470, 471, 472]),
        FaceMeshEye(corners: (362, 263), upper: [398, 384, 385, 386, 387, 388, 466], lower: [382, 381, 380, 374, 373, 390, 249],
                    iris: 473, irisEdge: [474, 475, 476, 477]),
    ]

    /// Глаз из точек Face Landmarker (в координатах кадра). Веки — его, радужка — `iris`, если дана (модель Iris
    /// точнее по радужке: у неё свой кроп 64×64 на глаз), иначе своя из FaceMesh.
    package static func fromFaceMesh(_ points: [Vec2], eye: Int, iris: (center: Vec2, radius: Double)? = nil, axis: Vec2) -> EyeShape? {
        guard points.count >= 478, faceMeshEyes.indices.contains(eye) else { return nil }
        let e = faceMeshEyes[eye]
        let a = points[e.corners.0], b = points[e.corners.1]
        var upper = [a] + e.upper.map { points[$0] } + [b]
        var lower = [a] + e.lower.map { points[$0] } + [b]
        if (b - a).dot(axis) < 0 { upper.reverse(); lower.reverse() }
        let center = iris?.center ?? points[e.iris]
        let radius = iris?.radius ?? e.irisEdge.map { (points[$0] - points[e.iris]).length }.reduce(0, +) / 4
        return EyeShape(cornerA: lower.first!, cornerB: lower.last!, upper: upper, lower: lower, iris: center, irisRadius: radius)
    }

    /// Рамка глаза: центр — середина уголков, ось — общая ось глаз, полуширина — по уголкам, полувысота — по векам.
    package func frame(axis: Vec2) -> EyeFrame {
        let ex = axis.normalized, ey = ex.perpendicular
        let center = (cornerA + cornerB) / 2
        let a = max(abs((cornerB - cornerA).dot(ex)) / 2, 1)
        let top = upper.map { ($0 - center).dot(ey) }.min() ?? -a * 0.3
        let bottom = lower.map { ($0 - center).dot(ey) }.max() ?? a * 0.3
        return EyeFrame(center: center, ex: ex, halfWidth: a, halfHeight: max((bottom - top) / 2, 0.5))
    }

    /// Веки как функции вдоль глаза: смещение по ey (px) в равномерных точках u от −a до a.
    package func lidCurves(in frame: EyeFrame, samples n: Int = 17) -> LidCurves {
        func local(_ p: Vec2) -> Vec2 { let d = p - frame.center; return Vec2(d.dot(frame.ex), d.dot(frame.ey)) }
        let up = upper.map(local).sorted { $0.x < $1.x }, lo = lower.map(local).sorted { $0.x < $1.x }
        let a = frame.halfWidth
        let us = (0..<n).map { -a + 2 * a * Double($0) / Double(n - 1) }
        var top = us.map { LidCurves.interpolate(up, at: $0) }, bottom = us.map { LidCurves.interpolate(lo, at: $0) }
        // Веко не может пересечь другое: раскрытие не меньше нуля.
        for i in 0..<n where top[i] > bottom[i] { let m = (top[i] + bottom[i]) / 2; top[i] = m; bottom[i] = m }
        return LidCurves(halfWidth: a, top: top, bottom: bottom)
    }
}

/// Верхнее и нижнее веко в осях рамки глаза: v (вниз по лицу, px) в равномерных точках u ∈ [−a, a].
package struct LidCurves: Equatable, Codable, Sendable {
    package var halfWidth: Double
    package var top: [Double], bottom: [Double]

    package func top(_ u: Double) -> Double { Self.sample(top, u, halfWidth) }
    package func bottom(_ u: Double) -> Double { Self.sample(bottom, u, halfWidth) }

    static func sample(_ v: [Double], _ u: Double, _ a: Double) -> Double {
        guard v.count > 1 else { return v.first ?? 0 }
        let t = min(max((u + a) / (2 * a), 0), 1) * Double(v.count - 1)
        let i = min(Int(t), v.count - 2), f = t - Double(i)
        return v[i] * (1 - f) + v[i + 1] * f
    }

    /// Линейная интерполяция по точкам (u, v), отсортированным по u; за краями — крайние значения.
    static func interpolate(_ pts: [Vec2], at u: Double) -> Double {
        guard let first = pts.first, let last = pts.last else { return 0 }
        if u <= first.x { return first.y }
        if u >= last.x { return last.y }
        for k in 1..<pts.count where pts[k].x >= u {
            let p = pts[k - 1], q = pts[k]
            let f = q.x - p.x > 1e-9 ? (u - p.x) / (q.x - p.x) : 0
            return p.y + (q.y - p.y) * f
        }
        return last.y
    }
}

/// Сглаживание формы глаза между кадрами: One Euro на каждую точку. Неподвижная голова — сильное сглаживание
/// (край радужки и век не дрожит), быстрое движение — фильтр почти не запаздывает.
package struct EyeShapeSmoother: Sendable {
    package var minCutoff: Double
    package var beta: Double
    private var filters: [OneEuroFilter] = []

    package init(minCutoff: Double = 1.0, beta: Double = 0.02) { self.minCutoff = minCutoff; self.beta = beta }

    package mutating func reset() { filters = [] }

    package mutating func filter(_ s: EyeShape, dt: Double) -> EyeShape {
        let pts = [s.cornerA, s.cornerB, s.iris, Vec2(s.irisRadius, 0)] + s.upper + s.lower
        if filters.count != pts.count { filters = pts.map { _ in OneEuroFilter(minCutoff: minCutoff, beta: beta) } }
        var out: [Vec2] = []
        for (k, p) in pts.enumerated() { out.append(filters[k].filter(p, dt: dt)) }
        let nu = s.upper.count
        return EyeShape(cornerA: out[0], cornerB: out[1], upper: Array(out[4..<(4 + nu)]), lower: Array(out[(4 + nu)...]),
                        iris: out[2], irisRadius: out[3].x)
    }
}

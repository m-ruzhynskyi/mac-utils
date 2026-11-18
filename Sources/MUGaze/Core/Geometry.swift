import Foundation

/// Точка или вектор на кадре. Координаты в пикселях, начало слева сверху, y вниз.
package struct Vec2: Equatable, Codable, Sendable {
    package var x: Double
    package var y: Double
    package init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    package static let zero = Vec2(0, 0)

    package static func + (l: Vec2, r: Vec2) -> Vec2 { Vec2(l.x + r.x, l.y + r.y) }
    package static func - (l: Vec2, r: Vec2) -> Vec2 { Vec2(l.x - r.x, l.y - r.y) }
    package static func * (l: Vec2, r: Double) -> Vec2 { Vec2(l.x * r, l.y * r) }
    package static func * (l: Double, r: Vec2) -> Vec2 { Vec2(r.x * l, r.y * l) }
    package static func / (l: Vec2, r: Double) -> Vec2 { Vec2(l.x / r, l.y / r) }
    package static func += (l: inout Vec2, r: Vec2) { l = l + r }

    package func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    package var length: Double { (x * x + y * y).squareRoot() }
    package var normalized: Vec2 { let l = length; return l > 0 ? self / l : .zero }
    /// Поворот на 90° по часовой в координатах с y вниз: ось «вправо» даёт ось «вниз».
    package var perpendicular: Vec2 { Vec2(-y, x) }

    /// Вектор той же направленности, но не длиннее `limit`.
    package func clampedLength(_ limit: Double) -> Vec2 {
        let l = length
        return l > limit && l > 0 ? self * (limit / l) : self
    }
}

/// Глаз в собственных осях: `ex` — вдоль линии глаз (от глаза слева на кадре к глазу справа), `ey` — вниз по лицу.
/// Центр — середина между уголками по `ex` и между веками по `ey`.
package struct EyeFrame: Equatable, Codable, Sendable {
    package var center: Vec2
    package var ex: Vec2
    /// Половина расстояния между уголками глаза, px.
    package var halfWidth: Double
    /// Половина раскрытия век, px.
    package var halfHeight: Double

    package init(center: Vec2, ex: Vec2, halfWidth: Double, halfHeight: Double) {
        self.center = center; self.ex = ex.normalized; self.halfWidth = halfWidth; self.halfHeight = halfHeight
    }

    package var ey: Vec2 { ex.perpendicular }
    /// Раскрытие глаза: высота к ширине. Около 0,3–0,4 у открытого глаза, ниже 0,15 — моргание.
    package var openness: Double { halfWidth > 0 ? halfHeight / halfWidth : 0 }

    /// Рамка глаза по точкам контура века и направлению линии глаз.
    package static func fit(contour: [Vec2], axis: Vec2) -> EyeFrame? {
        guard contour.count >= 4 else { return nil }
        let ex = axis.normalized
        guard ex.length > 0 else { return nil }
        let ey = ex.perpendicular
        let origin = contour[0]
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for p in contour {
            let d = p - origin
            let u = d.dot(ex), v = d.dot(ey)
            minX = min(minX, u); maxX = max(maxX, u); minY = min(minY, v); maxY = max(maxY, v)
        }
        let halfWidth = (maxX - minX) / 2
        guard halfWidth > 0.5 else { return nil }
        let center = origin + ex * ((minX + maxX) / 2) + ey * ((minY + maxY) / 2)
        return EyeFrame(center: center, ex: ex, halfWidth: halfWidth, halfHeight: max(0, (maxY - minY) / 2))
    }

    /// Точка кадра в долях полуширины глаза (обе оси в одних единицах, чтобы сдвиг был изотропным).
    package func local(_ p: Vec2) -> Vec2 {
        let d = p - center
        return Vec2(d.dot(ex) / halfWidth, d.dot(ey) / halfWidth)
    }

    /// Обратно: доли полуширины → точка кадра.
    package func image(_ l: Vec2) -> Vec2 { center + ex * (l.x * halfWidth) + ey * (l.y * halfWidth) }

    /// Вектор в долях полуширины → вектор в пикселях.
    package func imageVector(_ l: Vec2) -> Vec2 { ex * (l.x * halfWidth) + ey * (l.y * halfWidth) }

    /// Лежит ли точка внутри эллипса глаза, ужатого в `scale` раз.
    package func contains(_ p: Vec2, scale: Double = 1) -> Bool {
        let d = p - center
        let u = d.dot(ex) / (halfWidth * scale)
        let v = d.dot(ey) / max(halfHeight * scale, 0.5)
        return u * u + v * v <= 1
    }
}

@inline(__always) func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = min(max((x - e0) / (e1 - e0), 0), 1)
    return t * t * (3 - 2 * t)
}

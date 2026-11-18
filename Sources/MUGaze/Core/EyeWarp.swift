import Foundation

/// Сдвиг радужки одного глаза для отрисовки. Отрисовка (Core Image / Metal) берёт пиксель из `p - shift * weight(p)`:
/// внутри глаза радужка переезжает целиком, к уголкам и векам вес плавно падает до нуля, края век не двигаются.
package struct EyeWarp: Equatable, Codable, Sendable {
    package var frame: EyeFrame
    /// Сдвиг в пикселях кадра.
    package var shift: Vec2

    /// Вдоль глаза вес 1 до 0,55 полуширины и 0 у уголков.
    package static let cornerFalloff = (start: 0.55, end: 1.0)
    /// Поперёк глаза — в долях раскрытия века в этом месте (эллипс): 1 внутри, 0 за краем века.
    /// Запас за 1,0 — потому что контур Vision на малых глазах смещён на 1–2 px.
    package static let lidFalloff = (start: 0.85, end: 1.3)

    /// Вес сдвига в точке кадра. Та же формула — в ядре отрисовки.
    package func weight(at p: Vec2) -> Double {
        let d = p - frame.center
        let u = abs(d.dot(frame.ex)) / frame.halfWidth
        // Высота века в этом месте: эллипс, к уголкам сходится в ноль (не меньше 0,15 высоты, чтобы не делить на ноль).
        let lid = max(frame.halfHeight, 0.5) * max((1 - min(u * u, 1)).squareRoot(), 0.15)
        let v = abs(d.dot(frame.ey)) / lid
        return (1 - smoothstep(Self.cornerFalloff.start, Self.cornerFalloff.end, u))
            * (1 - smoothstep(Self.lidFalloff.start, Self.lidFalloff.end, v))
    }

    /// Откуда брать пиксель для точки выхода.
    package func source(for p: Vec2) -> Vec2 { p - shift * weight(at: p) }

    /// Область, которую меняет сдвиг (для отрисовки только её).
    package var affectedRadius: Double { frame.halfWidth * 1.05 + shift.length }
}

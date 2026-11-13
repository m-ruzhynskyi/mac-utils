import CoreGraphics

/// Геометрия «скрытого экрана». Все прямоугольники — в глобальных координатах Quartz
/// (начало в левом верхнем углу главного дисплея, y вниз): так их отдают `CGDisplayBounds`,
/// `CGWindowListCopyWindowInfo` и атрибуты AX `AXPosition`/`AXSize`.
public enum HiddenScreenGeometry {
    /// Длина общего края двух прямоугольников (0 — касаются только углом или не касаются).
    public static func sharedEdgeLength(_ a: CGRect, _ b: CGRect) -> CGFloat {
        if a.maxX == b.minX || b.maxX == a.minX {
            return max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        }
        if a.maxY == b.minY || b.maxY == a.minY {
            return max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        }
        return 0
    }

    /// Начало скрытого дисплея: правый нижний угол самого «правого нижнего» настоящего дисплея.
    /// Скрытый дисплей касается раскладки только углом — курсор попадает на него, лишь пройдя точно через угол.
    /// macOS может сдвинуть дисплей, чтобы раскладка была связной (без запуска не проверить), поэтому после
    /// `CGConfigureDisplayOrigin` начало перечитывается и при общем крае включается `CursorGuard`.
    public static func cornerOrigin(size: CGSize, beside displays: [CGRect]) -> CGPoint {
        guard let anchor = displays.max(by: { ($0.maxX + $0.maxY, $0.maxX) < ($1.maxX + $1.maxY, $1.maxX) }) else {
            return .zero
        }
        var origin = CGPoint(x: anchor.maxX, y: anchor.maxY)
        // Другой дисплей может лежать правее или ниже угла: тогда отодвигаемся за него, пока нет пересечений.
        for _ in 0..<displays.count {
            let candidate = CGRect(origin: origin, size: size)
            guard let blocker = displays.first(where: { $0.intersects(candidate) }) else { break }
            origin.x = max(origin.x, blocker.maxX)
        }
        return origin
    }

    /// Прямоугольник AppKit (начало слева снизу главного экрана) → Quartz (слева сверху). `primaryHeight` — высота экрана со строкой меню.
    public static func quartz(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Курсор на скрытом дисплее → ближайшая точка на настоящих дисплеях (куда его вернуть), иначе nil.
    public static func pullBack(_ cursor: CGPoint, hidden: CGRect, physical: [CGRect]) -> CGPoint? {
        guard hidden.contains(cursor), !physical.isEmpty else { return nil }
        var best: (CGPoint, CGFloat)?
        for rect in physical {
            let inside = CGRect(x: rect.minX, y: rect.minY, width: max(rect.width - 1, 0), height: max(rect.height - 1, 0))
            let point = CGPoint(x: min(max(cursor.x, inside.minX), inside.maxX), y: min(max(cursor.y, inside.minY), inside.maxY))
            let distance = hypot(point.x - cursor.x, point.y - cursor.y)
            if best == nil || distance < best!.1 { best = (point, distance) }
        }
        return best?.0
    }
}

/// Соответствие точек окна-зеркала и настоящего окна на скрытом дисплее.
/// `viewSize` — размер картинки в зеркале (точки, начало слева сверху), `target` — рамка настоящего окна (Quartz).
/// Картинка вписывается с сохранением пропорций и центрируется; поля вокруг ввода не принимают.
public struct MirrorMapping: Equatable, Sendable {
    public var viewSize: CGSize
    public var target: CGRect

    public init(viewSize: CGSize, target: CGRect) {
        self.viewSize = viewSize
        self.target = target
    }

    /// Где в зеркале лежит картинка окна.
    public var contentRect: CGRect {
        guard target.width > 0, target.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / target.width, viewSize.height / target.height)
        let size = CGSize(width: target.width * scale, height: target.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    public var scale: CGFloat {
        let content = contentRect
        return content.width > 0 ? content.width / target.width : 0
    }

    /// Точка зеркала → глобальная точка на скрытом дисплее; nil — щелчок по полю вокруг картинки.
    public func toTarget(_ point: CGPoint) -> CGPoint? {
        let content = contentRect
        guard content.width > 0, point.x >= content.minX, point.x < content.maxX,
              point.y >= content.minY, point.y < content.maxY else { return nil }
        let s = scale
        return CGPoint(x: target.minX + (point.x - content.minX) / s, y: target.minY + (point.y - content.minY) / s)
    }

    /// Глобальная точка на скрытом дисплее → точка зеркала (для курсора-подсказки и проверки).
    public func toView(_ point: CGPoint) -> CGPoint {
        let content = contentRect
        let s = scale
        return CGPoint(x: content.minX + (point.x - target.minX) * s, y: content.minY + (point.y - target.minY) * s)
    }

    /// Размер, до которого стоит изменить настоящее окно, чтобы зеркало показывало его 1:1 (без размытия и полей):
    /// размер зеркала, но не больше скрытого дисплея.
    public static func targetSize(forMirror viewSize: CGSize, hidden: CGRect) -> CGSize {
        CGSize(width: min(viewSize.width, hidden.width), height: min(viewSize.height, hidden.height))
    }
}

import CoreGraphics

/// Самопроверка «окно не видно в демонстрации» (`hidingVerified` в интерфейсе): снимок основного дисплея через
/// ScreenCaptureKit сравнивается с кадром зеркала в том же месте. Совпадают — зеркало попало в захват (видно в звонке);
/// отличаются — на его месте то, что под ним. Так же проверял менеджер на Mac пользователя 13.11.
public enum HidingCheck {
    /// Сторона уменьшенной серой картинки для сравнения.
    public static let side = 16
    /// Средняя разница яркости (0…255), ниже которой картинки считаются одинаковыми.
    public static let sameBelow: Double = 10
    /// Выше — точно разные.
    public static let differentAbove: Double = 28
    /// Однотонное зеркало (пустое окно) не отличить от того, что под ним, — проверку не засчитываем.
    public static let minimumContrast: Double = 6

    /// true — зеркало не попало в захват, false — попало, nil — не понять (пустая картинка, пограничная разница).
    public static func verdict(captured: [UInt8], mirror: [UInt8]) -> Bool? {
        guard !mirror.isEmpty, captured.count == mirror.count else { return nil }
        let mean = Double(mirror.reduce(0) { $0 + Int($1) }) / Double(mirror.count)
        let deviation = mirror.reduce(0.0) { $0 + abs(Double($1) - mean) } / Double(mirror.count)
        guard deviation >= minimumContrast else { return nil }
        let difference = zip(captured, mirror).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(mirror.count)
        if difference < sameBelow { return false }
        if difference > differentAbove { return true }
        return nil
    }

    /// Уменьшенная серая копия (side × side, по строкам сверху вниз).
    public static func thumbnail(_ image: CGImage, side: Int = HidingCheck.side) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? pixels : []
    }

    /// Где зеркало на снимке дисплея (пиксели снимка, начало слева сверху). `mirror` и `display` — Quartz, точки.
    public static func cropRect(mirror: CGRect, display: CGRect, scale: CGFloat) -> CGRect? {
        let visible = mirror.intersection(display)
        guard !visible.isNull, visible.width >= 8, visible.height >= 8 else { return nil }
        return CGRect(x: (visible.minX - display.minX) * scale, y: (visible.minY - display.minY) * scale,
                      width: visible.width * scale, height: visible.height * scale).integral
    }
}

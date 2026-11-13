import CoreGraphics

/// Самопроверка «окно не видно в демонстрации» (`hidingVerified` в интерфейсе) — как проверял менеджер 13.11:
/// поверх зеркала на долю секунды показывается маленькое окно-проба (`sharingType = .none`, шахматка из пурпурного
/// и зелёного), основной дисплей снимается через ScreenCaptureKit, и на месте пробы ищется та же шахматка.
/// Нашлась — окна с `.none` попадают в захват (видно в звонке); нет — скрыто. Сравнение с картинкой зеркала
/// («не понять» при похожем фоне) больше не используется.
public enum HidingCheck {
    public struct RGB: Equatable, Sendable {
        public var r: UInt8, g: UInt8, b: UInt8
        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    /// Клеток по стороне и размер пробы в точках.
    public static let cells = 4
    public static let side: CGFloat = 32
    public static let magenta = RGB(255, 0, 255)
    public static let green = RGB(0, 255, 0)

    /// Цвет клетки (строка сверху вниз, столбец слева направо).
    public static func expected(row: Int, column: Int) -> RGB {
        (row + column).isMultiple(of: 2) ? magenta : green
    }

    /// Клетка похожа на ожидаемую: насыщенные цвета остаются узнаваемыми и после перевода в цветовой профиль дисплея.
    static func matches(_ color: RGB, _ expected: RGB) -> Bool {
        if expected == magenta { return color.r > 170 && color.b > 170 && color.g < 110 }
        return color.g > 170 && color.r < 120 && color.b < 120
    }

    /// true — проба не попала в захват (скрыто), false — попала (видно в звонке), nil — не понять (частично, сдвиг).
    /// Ищется именно шахматка: и пурпурные, и зелёные клетки на своих местах. Сплошной фон одного из цветов — не она.
    public static func verdict(cells colors: [RGB]) -> Bool? {
        guard colors.count == cells * cells else { return nil }
        var magentaHits = 0, greenHits = 0
        for (index, color) in colors.enumerated() {
            let want = expected(row: index / cells, column: index % cells)
            guard matches(color, want) else { continue }
            if want == magenta { magentaHits += 1 } else { greenHits += 1 }
        }
        let half = cells * cells / 2
        if magentaHits >= half - 2, greenHits >= half - 2 { return false }
        if magentaHits <= 2 || greenHits <= 2 { return true }
        return nil
    }

    /// Картинка пробы (для слоя окна-пробы).
    public static func probeImage(scale: CGFloat = 2) -> CGImage? {
        let pixels = Int(side * scale)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let cell = CGFloat(pixels) / CGFloat(cells)
        for row in 0..<cells {
            for column in 0..<cells {
                let color = expected(row: row, column: column)
                context.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
                // CGContext — начало снизу: строка 0 (верхняя) рисуется у верхнего края.
                context.fill(CGRect(x: CGFloat(column) * cell, y: CGFloat(cells - 1 - row) * cell, width: cell, height: cell))
            }
        }
        return context.makeImage()
    }

    /// Цвета клеток из снимка области пробы: середина каждой клетки (края размыты сглаживанием), по строкам сверху вниз.
    public static func cellColors(_ image: CGImage) -> [RGB] {
        let width = image.width, height = image.height
        guard width >= cells, height >= cells,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return [] }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var result: [RGB] = []
        for row in 0..<cells {
            for column in 0..<cells {
                let x = Int((Double(column) + 0.5) * Double(width) / Double(cells))
                // Память контекста — сверху вниз (первая строка буфера — верх картинки).
                let y = Int((Double(row) + 0.5) * Double(height) / Double(cells))
                let offset = (y * width + x) * 4
                result.append(RGB(bytes[offset], bytes[offset + 1], bytes[offset + 2]))
            }
        }
        return result
    }

    /// Где проба на снимке дисплея (пиксели снимка, начало слева сверху). `rect` и `display` — Quartz, точки.
    public static func cropRect(_ rect: CGRect, display: CGRect, scale: CGFloat) -> CGRect? {
        let visible = rect.intersection(display)
        guard !visible.isNull, visible.width >= 8, visible.height >= 8, visible.size == rect.size else { return nil }
        return CGRect(x: (visible.minX - display.minX) * scale, y: (visible.minY - display.minY) * scale,
                      width: visible.width * scale, height: visible.height * scale).integral
    }
}

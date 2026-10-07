import AppKit

/// Фон под оформленным снимком или коллажем.
enum ShotBackground: String, CaseIterable, Identifiable {
    case sky, sunset, mint, graphite, white, transparent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sky: return "Небо"
        case .sunset: return "Закат"
        case .mint: return "Мята"
        case .graphite: return "Графит"
        case .white: return "Белый"
        case .transparent: return "Прозрачный"
        }
    }

    /// Цвета градиента сверху вниз (для белого — один цвет, для прозрачного — нет).
    var colors: [NSColor] {
        switch self {
        case .sky: return [NSColor(srgbHex: 0x74B9FF), NSColor(srgbHex: 0xA29BFE)]
        case .sunset: return [NSColor(srgbHex: 0xFF9A8B), NSColor(srgbHex: 0xFF6A88), NSColor(srgbHex: 0xFF99AC)]
        case .mint: return [NSColor(srgbHex: 0x43E97B), NSColor(srgbHex: 0x38F9D7)]
        case .graphite: return [NSColor(srgbHex: 0x5A5A5E), NSColor(srgbHex: 0x1C1C1E)]
        case .white: return [.white]
        case .transparent: return []
        }
    }

    static var current: ShotBackground {
        ShotBackground(rawValue: UserDefaults.standard.string(forKey: Pref.screenshotBackground) ?? "") ?? .sky
    }
}

extension NSColor {
    convenience init(srgbHex hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Сборка итоговой картинки: один снимок или коллаж шагов, по желанию —
/// в рамке окна macOS, с номерами и на фоне.
@MainActor
enum ShotComposer {
    struct Options {
        var layout: StepsLayout = .auto
        var equalSize = false
        var windowFrame = false
        var titles = false
        var badges = false
        var background: ShotBackground = .white
        /// Пикселей в точке (2 на Retina): все отступы и рамки — в точках.
        var unit: CGFloat = 2
        var dark = false
    }

    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Один снимок в рамке окна на фоне (кнопка «Рамка» / клавиша F).
    static func framedSingle(_ image: CGImage, unit: CGFloat) -> CGImage? {
        var options = Options()
        options.windowFrame = true
        options.background = .current
        options.unit = unit
        options.dark = systemIsDark
        return compose([image], options: options)
    }

    static func compose(_ source: [CGImage], options: Options) -> CGImage? {
        guard !source.isEmpty else { return nil }
        let u = options.unit
        let images = options.equalSize ? equalized(source, layout: options.layout) : source
        let items = images.enumerated().map { index, image -> CGImage in
            guard options.windowFrame else { return image }
            return windowFramed(image, title: options.titles ? "Шаг \(index + 1)" : nil,
                                unit: u, dark: options.dark) ?? image
        }

        let badgeRadius = 18 * u
        // Отступ вмещает тень и номер, который выступает за угол.
        let gap = (options.windowFrame || options.background != .white ? 48 : 32) * u
            + (options.badges ? badgeRadius * 0.5 : 0)
        let columns = columnCount(for: items, layout: options.layout)
        let rows = (items.count + columns - 1) / columns
        var columnWidths = [CGFloat](repeating: 0, count: columns)
        var rowHeights = [CGFloat](repeating: 0, count: rows)
        for (index, item) in items.enumerated() {
            columnWidths[index % columns] = max(columnWidths[index % columns], CGFloat(item.width))
            rowHeights[index / columns] = max(rowHeights[index / columns], CGFloat(item.height))
        }
        let width = columnWidths.reduce(0, +) + gap * CGFloat(columns + 1)
        let height = rowHeights.reduce(0, +) + gap * CGFloat(rows + 1)
        guard width < 32_000, height < 32_000,
              let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let canvas = NSRect(x: 0, y: 0, width: width, height: height)
        let colors = options.background.colors
        if colors.count > 1 {
            NSGradient(colors: colors)?.draw(in: canvas, angle: -60)
        } else if let color = colors.first {
            color.setFill()
            canvas.fill()
        }

        var top = height - gap
        for row in 0..<rows {
            // Неполный последний ряд — по центру (3 шага в 2×2: третий посередине).
            let inRow = min(columns, items.count - row * columns)
            let missing = columnWidths[inRow..<columns].reduce(0, +) + gap * CGFloat(columns - inRow)
            var left = gap + missing / 2
            for column in 0..<columns {
                let index = row * columns + column
                guard index < items.count else { break }
                let item = items[index]
                let w = CGFloat(item.width), h = CGFloat(item.height)
                // В ячейке — по центру.
                let rect = CGRect(x: left + (columnWidths[column] - w) / 2, y: top - (rowHeights[row] + h) / 2,
                                  width: w, height: h)

                context.saveGState()
                if options.windowFrame {
                    context.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u,
                                      color: CGColor(gray: 0, alpha: 0.35))
                } else {
                    context.setShadow(offset: CGSize(width: 0, height: -2 * u), blur: 10 * u,
                                      color: CGColor(gray: 0, alpha: 0.25))
                }
                context.draw(item, in: rect)
                context.restoreGState()
                if !options.windowFrame {
                    context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
                    context.setLineWidth(u)
                    context.stroke(rect.insetBy(dx: -u / 2, dy: -u / 2))
                }

                if options.badges {
                    // В рамке номер сидит на углу окна, чтобы не закрывать «светофор».
                    let center = options.windowFrame
                        ? NSPoint(x: rect.minX - badgeRadius * 0.35, y: rect.maxY + badgeRadius * 0.35)
                        : NSPoint(x: rect.minX + badgeRadius + 10 * u, y: rect.maxY - badgeRadius - 10 * u)
                    drawBadge(index + 1, center: center, radius: badgeRadius, unit: u)
                }
                left += columnWidths[column] + gap
            }
            top -= rowHeights[row] + gap
        }
        return context.makeImage()
    }

    // MARK: - Расположение

    private static func columnCount(for items: [CGImage], layout: StepsLayout) -> Int {
        let n = items.count
        switch layout {
        case .vertical: return 1
        case .horizontal: return n
        // Сетка — как можно ближе к квадрату: 4 снимка — 2×2, 9 — 3×3.
        case .grid: return Int(Double(n).squareRoot().rounded(.up))
        case .auto:
            if n <= 2 { return n }
            if n <= 4 { return 2 }
            // 5+: 2 или 3 колонки — что даёт полотно ближе к квадрату.
            let w = CGFloat(items.map(\.width).sorted()[n / 2])
            let h = CGFloat(items.map(\.height).sorted()[n / 2])
            func squareness(_ columns: Int) -> CGFloat {
                let rows = (n + columns - 1) / columns
                let ratio = (w * CGFloat(columns)) / (h * CGFloat(rows))
                return abs(log(ratio))
            }
            return squareness(2) <= squareness(3) ? 2 : 3
        }
    }

    // MARK: - Одинаковый размер

    /// Столбик — общая ширина, ряд — общая высота, сетка — общая ячейка.
    /// Цель — медиана; увеличиваем не больше чем вдвое, чтобы не размыть.
    private static func equalized(_ images: [CGImage], layout: StepsLayout) -> [CGImage] {
        guard images.count > 1 else { return images }
        func median(_ values: [Int]) -> CGFloat {
            let sorted = values.sorted()
            return CGFloat(sorted[sorted.count / 2])
        }
        let targetWidth = median(images.map(\.width))
        let targetHeight = median(images.map(\.height))
        return images.map { image in
            let w = CGFloat(image.width), h = CGFloat(image.height)
            var scale: CGFloat
            switch layout {
            case .vertical: scale = targetWidth / w
            case .horizontal: scale = targetHeight / h
            case .grid, .auto: scale = min(targetWidth / w, targetHeight / h)
            }
            scale = min(scale, 2)
            guard abs(scale - 1) > 0.01 else { return image }
            return resized(image, scale: scale) ?? image
        }
    }

    private static func resized(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - Рамка окна

    /// Снимок как содержимое окна macOS: заголовок со «светофором»,
    /// скруглённые углы 10 pt и тонкая обводка. Тень добавляет compose().
    static func windowFramed(_ image: CGImage, title: String?, unit u: CGFloat, dark: Bool) -> CGImage? {
        let titleBar = 28 * u
        let radius = 10 * u
        let width = CGFloat(image.width)
        let height = CGFloat(image.height) + titleBar
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()

        // Заголовок окна.
        let bar = NSRect(x: 0, y: height - titleBar, width: width, height: titleBar)
        let barColors = dark ? [NSColor(srgbHex: 0x3A3A3C), NSColor(srgbHex: 0x2C2C2E)]
                             : [NSColor(srgbHex: 0xF6F6F6), NSColor(srgbHex: 0xE6E6E6)]
        NSGradient(colors: barColors)?.draw(in: bar, angle: -90)
        (dark ? NSColor.black.withAlphaComponent(0.6) : NSColor(srgbHex: 0xD0D0D0)).setFill()
        NSRect(x: 0, y: bar.minY - u, width: width, height: u).fill()

        // Содержимое.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: CGFloat(image.height)))
        NSGraphicsContext.restoreGraphicsState()

        // «Светофор»: 12 pt, центры через 20 pt, первый — в 20 pt от края.
        let lights: [(Int, Int)] = [(0xFF5F57, 0xE0443E), (0xFEBC2E, 0xDEA123), (0x28C840, 0x1AAB29)]
        for (index, colors) in lights.enumerated() {
            let center = NSPoint(x: (20 + CGFloat(index) * 20) * u, y: bar.midY)
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 6 * u, y: center.y - 6 * u, width: 12 * u, height: 12 * u))
            NSColor(srgbHex: colors.0).setFill()
            dot.fill()
            dot.lineWidth = 0.5 * u
            NSColor(srgbHex: colors.1).setStroke()
            dot.stroke()
        }

        if let title, width > 160 * u {
            let label = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13 * u, weight: .semibold),
                .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.3, alpha: 1),
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: (width - size.width) / 2, y: bar.midY - size.height / 2))
        }

        // Тонкая обводка окна.
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: u / 2, dy: u / 2),
                                  xRadius: radius - u / 2, yRadius: radius - u / 2)
        border.lineWidth = u
        (dark ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.18)).setStroke()
        border.stroke()

        return context.makeImage()
    }

    // MARK: - Номер

    /// Номер шага в стиле инструмента «Нумерация».
    private static func drawBadge(_ number: Int, center: NSPoint, radius: CGFloat, unit u: CGFloat) {
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -u)
        shadow.shadowBlurRadius = 4 * u
        shadow.set()
        NSColor.systemRed.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        circle.lineWidth = 2.5 * u
        NSColor.white.setStroke()
        circle.stroke()

        let label = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: radius * (number > 9 ? 0.9 : 1.15), weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }
}

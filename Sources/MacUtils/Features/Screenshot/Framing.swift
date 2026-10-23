import AppKit
import MUCore
import MUDesign

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

/// Сборка итоговой картинки: один снимок или коллаж шагов, по желанию — в рамке окна macOS, с номерами, подписями,
/// стрелками и на фоне.
///
/// Шаги бывают разного размера и сняты на разных экранах (Retina и обычный). Сначала все приводятся к одной плотности —
/// самой высокой среди шагов, — чтобы одинаковый по экрану размер выглядел одинаково. Потом, если нужно, к одному
/// размеру. Итог не больше `maxSide` по стороне и `maxPixels` по площади: иначе он уменьшается целиком.
///
/// Сборка не привязана к главному потоку (рисует в свой битмап): большой коллаж собирается в фоне.
enum ShotComposer {
    struct Options: Sendable {
        var layout: StepsLayout = .auto
        var equalSize = false
        var windowFrame = false
        var titles = false
        var badges = false
        /// Стрелки между соседними шагами (в ряду — вправо, в столбике — вниз).
        var arrows = false
        /// Подписи под шагами по порядку; пустая строка — без подписи.
        var captions: [String] = []
        var background: ShotBackground = .white
        /// Пикселей в точке (2 на Retina) — для одного снимка; у шагов коллажа плотность своя у каждого.
        var unit: CGFloat = 2
        var dark = false
        /// Предел итога: сторона и площадь в пикселях.
        var maxSide: CGFloat = 16_000
        var maxPixels: CGFloat = 80_000_000
    }

    /// Раскладка коллажа без рисования. Координаты — в пикселях холста до уменьшения, начало сверху слева.
    struct Plan: Equatable {
        /// Холст до уменьшения.
        var canvas: CGSize
        /// Итог = холст × `scale` (≤ 1, уменьшение под предел размера).
        var scale: CGFloat
        /// Плотность итога (пикселей в точке до уменьшения): по ней — отступы, рамки, номера.
        var unit: CGFloat
        var columns: Int
        var gap: CGFloat
        /// Где рисуется содержимое каждого шага (без рамки окна).
        var content: [CGRect]
        /// Рамка окна (заголовок + содержимое) или само содержимое без рамки.
        var window: [CGRect]
        /// Подпись под шагом; nil — без подписи.
        var caption: [CGRect?]

        /// Размер итоговой картинки в пикселях.
        var outputSize: CGSize {
            CGSize(width: max(1, (canvas.width * scale).rounded(.down)), height: max(1, (canvas.height * scale).rounded(.down)))
        }
    }

    /// Тёмная ли тема системы; без приложения (тесты, ранний запуск) — светлая.
    @MainActor
    static var systemIsDark: Bool {
        guard let app = NSApp else { return false }
        return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Один снимок в рамке окна на фоне (кнопка «Рамка» / клавиша F).
    @MainActor
    static func framedSingle(_ image: CGImage, unit: CGFloat) -> CGImage? {
        var options = Options()
        options.windowFrame = true
        options.background = .current
        options.unit = unit
        options.dark = systemIsDark
        return compose([image], options: options)
    }

    /// Снимки одной плотности (`options.unit`).
    static func compose(_ source: [CGImage], options: Options) -> CGImage? {
        compose(steps: source.map { ($0, options.unit) }, options: options)
    }

    /// Шаги со своей плотностью каждый.
    static func compose(steps: [(image: CGImage, unit: CGFloat)], options: Options) -> CGImage? {
        guard !steps.isEmpty else { return nil }
        let plan = plan(sizes: steps.map { CGSize(width: $0.image.width, height: $0.image.height) },
                        units: steps.map(\.unit), options: options)
        return render(steps.map(\.image), plan: plan, options: options)
    }

    // MARK: - Раскладка

    /// Высота заголовка окна и подписи, отступы — в точках, умножаются на плотность итога.
    private static let titleBarPoints: CGFloat = 28
    private static let captionPoints: CGFloat = 30
    private static let captionGapPoints: CGFloat = 10
    private static let badgeRadiusPoints: CGFloat = 18

    /// Плотность итога и множитель для каждого шага: всё приводится к самой высокой плотности.
    static func normalizedScales(units: [CGFloat]) -> (unit: CGFloat, scales: [CGFloat]) {
        let clean = units.map { $0.isFinite && $0 > 0 ? $0 : 1 }
        let unit = clean.max() ?? 1
        return (unit, clean.map { unit / $0 })
    }

    static func plan(sizes: [CGSize], units: [CGFloat], options: Options) -> Plan {
        let (u, density) = normalizedScales(units: units.count == sizes.count ? units : sizes.map { _ in options.unit })
        var shown = zip(sizes, density).map { CGSize(width: $0.width * $1, height: $0.height * $1) }
        if options.equalSize { shown = equalized(shown, layout: options.layout) }

        let titleBar = options.windowFrame ? titleBarPoints * u : 0
        let hasCaption = sizes.indices.map { index in
            index < options.captions.count && !options.captions[index].trimmingCharacters(in: .whitespaces).isEmpty
        }
        let captionBlock = (captionPoints + captionGapPoints) * u
        // Ячейка шага: окно (заголовок + содержимое) и, если есть, подпись под ним.
        let boxes = shown.indices.map { index in
            CGSize(width: shown[index].width, height: shown[index].height + titleBar + (hasCaption[index] ? captionBlock : 0))
        }

        let badgeRadius = badgeRadiusPoints * u
        // Отступ вмещает тень и номер, который выступает за угол; стрелке нужно место между шагами.
        var gap = (options.windowFrame || options.background != .white ? 48 : 32) * u + (options.badges ? badgeRadius * 0.5 : 0)
        if options.arrows, sizes.count > 1 { gap = max(gap, 64 * u) }

        let columns = columnCount(for: boxes, layout: options.layout)
        let rows = (boxes.count + columns - 1) / columns
        var columnWidths = [CGFloat](repeating: 0, count: columns)
        var rowHeights = [CGFloat](repeating: 0, count: rows)
        for (index, box) in boxes.enumerated() {
            columnWidths[index % columns] = max(columnWidths[index % columns], box.width)
            rowHeights[index / columns] = max(rowHeights[index / columns], box.height)
        }
        let width = columnWidths.reduce(0, +) + gap * CGFloat(columns + 1)
        let height = rowHeights.reduce(0, +) + gap * CGFloat(rows + 1)

        var content: [CGRect] = [], window: [CGRect] = [], caption: [CGRect?] = []
        var top = gap
        for row in 0..<rows {
            // Неполный последний ряд — по центру (3 шага в 2×2: третий посередине).
            let inRow = min(columns, boxes.count - row * columns)
            let missing = columnWidths[inRow..<columns].reduce(0, +) + gap * CGFloat(columns - inRow)
            var left = gap + missing / 2
            for column in 0..<inRow {
                let index = row * columns + column
                let box = boxes[index]
                // В ячейке — по центру.
                let origin = CGPoint(x: left + (columnWidths[column] - box.width) / 2, y: top + (rowHeights[row] - box.height) / 2)
                let frame = CGRect(x: origin.x, y: origin.y, width: shown[index].width, height: shown[index].height + titleBar)
                window.append(frame)
                content.append(CGRect(x: frame.minX, y: frame.minY + titleBar, width: shown[index].width, height: shown[index].height))
                caption.append(hasCaption[index]
                    ? CGRect(x: frame.minX, y: frame.maxY + captionGapPoints * u, width: frame.width, height: captionPoints * u) : nil)
                left += columnWidths[column] + gap
            }
            top += rowHeights[row] + gap
        }

        // Предел размера: уменьшаем всё целиком.
        let scale = min(1, options.maxSide / max(width, height), (options.maxPixels / max(width * height, 1)).squareRoot())
        return Plan(canvas: CGSize(width: width, height: height), scale: scale, unit: u, columns: columns, gap: gap,
                    content: content, window: window, caption: caption)
    }

    static func columnCount(for items: [CGImage], layout: StepsLayout) -> Int {
        columnCount(for: items.map { CGSize(width: $0.width, height: $0.height) }, layout: layout)
    }

    static func columnCount(for items: [CGSize], layout: StepsLayout) -> Int {
        let n = items.count
        guard n > 0 else { return 1 }
        switch layout {
        case .vertical: return 1
        case .horizontal: return n
        // Сетка — как можно ближе к квадрату: 4 снимка — 2×2, 9 — 3×3.
        case .grid: return Int(Double(n).squareRoot().rounded(.up))
        case .auto:
            if n <= 2 { return n }
            if n <= 4 { return 2 }
            // 5+: 2 или 3 колонки — что даёт полотно ближе к квадрату.
            let w = items.map(\.width).sorted()[n / 2]
            let h = items.map(\.height).sorted()[n / 2]
            func squareness(_ columns: Int) -> CGFloat {
                let rows = (n + columns - 1) / columns
                let ratio = (w * CGFloat(columns)) / (h * CGFloat(rows))
                return abs(log(ratio))
            }
            return squareness(2) <= squareness(3) ? 2 : 3
        }
    }

    /// Столбик — общая ширина, ряд — общая высота, сетка — общая ячейка.
    /// Цель — медиана; увеличиваем не больше чем вдвое, чтобы не размыть.
    static func equalized(_ sizes: [CGSize], layout: StepsLayout) -> [CGSize] {
        guard sizes.count > 1 else { return sizes }
        func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }
        let targetWidth = median(sizes.map(\.width))
        let targetHeight = median(sizes.map(\.height))
        return sizes.map { size in
            var scale: CGFloat
            switch layout {
            case .vertical: scale = targetWidth / size.width
            case .horizontal: scale = targetHeight / size.height
            case .grid, .auto: scale = min(targetWidth / size.width, targetHeight / size.height)
            }
            scale = min(scale, 2)
            guard abs(scale - 1) > 0.01 else { return size }
            return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        }
    }

    // MARK: - Рисование

    private static func render(_ images: [CGImage], plan: Plan, options: Options) -> CGImage? {
        let size = plan.outputSize
        guard size.width < 32_000, size.height < 32_000,
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.scaleBy(x: plan.scale, y: plan.scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }

        let u = plan.unit
        let height = plan.canvas.height
        // План — сверху вниз, CoreGraphics — снизу вверх.
        func flip(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height) }

        let canvas = NSRect(origin: .zero, size: plan.canvas)
        let colors = options.background.colors
        if colors.count > 1 {
            NSGradient(colors: colors)?.draw(in: canvas, angle: -60)
        } else if let color = colors.first {
            color.setFill()
            canvas.fill()
        }
        let onDark = options.background != .white && options.background != .transparent

        if options.arrows { drawArrows(plan: plan, flip: flip, onDark: onDark) }

        for (index, image) in images.enumerated() where index < plan.content.count {
            let content = flip(plan.content[index])
            let window = flip(plan.window[index])
            context.saveGState()
            if options.windowFrame {
                context.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: CGColor(gray: 0, alpha: 0.35))
                drawWindow(image, frame: window, content: content, title: options.titles ? "Шаг \(index + 1)" : nil,
                           unit: u, dark: options.dark)
            } else {
                context.setShadow(offset: CGSize(width: 0, height: -2 * u), blur: 10 * u, color: CGColor(gray: 0, alpha: 0.25))
                context.draw(image, in: content)
            }
            context.restoreGState()
            if !options.windowFrame {
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.12))
                context.setLineWidth(u)
                context.stroke(content.insetBy(dx: -u / 2, dy: -u / 2))
            }
            if options.badges {
                let radius = badgeRadiusPoints * u
                // В рамке номер сидит на углу окна, чтобы не закрывать «светофор».
                let center = options.windowFrame
                    ? NSPoint(x: window.minX - radius * 0.35, y: window.maxY + radius * 0.35)
                    : NSPoint(x: content.minX + radius + 10 * u, y: content.maxY - radius - 10 * u)
                drawBadge(index + 1, center: center, radius: radius, unit: u)
            }
            if let rect = plan.caption[index], index < options.captions.count {
                drawCaption(options.captions[index], in: flip(rect), unit: u)
            }
        }
        return context.makeImage()
    }

    /// Рамка окна macOS прямо на холсте: заголовок со «светофором», скруглённые углы 10 pt, тонкая обводка.
    private static func drawWindow(_ image: CGImage, frame: CGRect, content: CGRect, title: String?, unit u: CGFloat, dark: Bool) {
        let radius = 10 * u
        let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        // Тень — от сплошной формы окна, а не от каждой части.
        (dark ? NSColor(srgbHex: 0x2C2C2E) : NSColor(srgbHex: 0xE6E6E6)).setFill()
        shape.fill()
        NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let bar = NSRect(x: frame.minX, y: content.maxY, width: frame.width, height: frame.maxY - content.maxY)
        let barColors = dark ? [NSColor(srgbHex: 0x3A3A3C), NSColor(srgbHex: 0x2C2C2E)]
                             : [NSColor(srgbHex: 0xF6F6F6), NSColor(srgbHex: 0xE6E6E6)]
        NSGradient(colors: barColors)?.draw(in: bar, angle: -90)
        (dark ? NSColor.black.withAlphaComponent(0.6) : NSColor(srgbHex: 0xD0D0D0)).setFill()
        NSRect(x: frame.minX, y: bar.minY - u, width: frame.width, height: u).fill()
        NSGraphicsContext.current?.cgContext.draw(image, in: content)
        NSGraphicsContext.restoreGraphicsState()

        // «Светофор»: 12 pt, центры через 20 pt, первый — в 20 pt от края.
        let lights: [(Int, Int)] = [(0xFF5F57, 0xE0443E), (0xFEBC2E, 0xDEA123), (0x28C840, 0x1AAB29)]
        for (index, colors) in lights.enumerated() {
            let center = NSPoint(x: frame.minX + (20 + CGFloat(index) * 20) * u, y: bar.midY)
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 6 * u, y: center.y - 6 * u, width: 12 * u, height: 12 * u))
            NSColor(srgbHex: colors.0).setFill()
            dot.fill()
            dot.lineWidth = 0.5 * u
            NSColor(srgbHex: colors.1).setStroke()
            dot.stroke()
        }

        if let title, frame.width > 160 * u {
            let label = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 13 * u, weight: .semibold),
                .foregroundColor: dark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.3, alpha: 1),
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: frame.midX - size.width / 2, y: bar.midY - size.height / 2))
        }

        let border = NSBezierPath(roundedRect: frame.insetBy(dx: u / 2, dy: u / 2), xRadius: radius - u / 2, yRadius: radius - u / 2)
        border.lineWidth = u
        (dark ? NSColor.white.withAlphaComponent(0.15) : NSColor.black.withAlphaComponent(0.18)).setStroke()
        border.stroke()
    }

    /// Подпись — светлая плашка с тёмным текстом: читается на любом фоне. Длинная обрезается многоточием.
    private static func drawCaption(_ text: String, in rect: CGRect, unit u: CGFloat) {
        let caption = text.trimmingCharacters(in: .whitespaces)
        guard !caption.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15 * u, weight: .semibold),
            .foregroundColor: NSColor(white: 0.12, alpha: 1),
            .paragraphStyle: paragraph,
        ]
        let label = NSAttributedString(string: caption, attributes: attributes)
        let padding = 12 * u
        let width = min(rect.width, label.size().width + padding * 2)
        let pill = NSRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        NSColor.white.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: pill, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let textHeight = label.size().height
        label.draw(with: NSRect(x: pill.minX + padding, y: pill.midY - textHeight / 2, width: pill.width - padding * 2, height: textHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Стрелки между соседними шагами: в одном ряду — вправо, в столбике — вниз. С ряда на ряд — без стрелки:
    /// порядок там показывают номера.
    private static func drawArrows(plan: Plan, flip: (CGRect) -> CGRect, onDark: Bool) {
        let u = plan.unit
        let color = onDark ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.22, alpha: 0.85)
        for index in 0..<max(0, plan.window.count - 1) {
            let a = plan.window[index], b = plan.window[index + 1]
            let sameRow = plan.columns > 1 && index / plan.columns == (index + 1) / plan.columns
            let start: CGPoint, end: CGPoint
            if sameRow {
                let y = (a.midY + b.midY) / 2
                start = CGPoint(x: a.maxX + 12 * u, y: y)
                end = CGPoint(x: b.minX - 12 * u, y: y)
            } else if plan.columns == 1 {
                let x = (a.midX + b.midX) / 2
                let captionBottom = plan.caption[index]?.maxY ?? a.maxY
                start = CGPoint(x: x, y: captionBottom + 12 * u)
                end = CGPoint(x: x, y: b.minY - 12 * u)
            } else {
                continue
            }
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 16 * u else { continue }
            // В координатах CoreGraphics (y вверх).
            let s = flip(CGRect(origin: start, size: .zero)).origin, e = flip(CGRect(origin: end, size: .zero)).origin
            let angle = atan2(e.y - s.y, e.x - s.x)
            let head = 12 * u
            let path = NSBezierPath()
            path.move(to: s)
            path.line(to: NSPoint(x: e.x - cos(angle) * head * 0.6, y: e.y - sin(angle) * head * 0.6))
            path.lineWidth = 4 * u
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
            let tip = NSBezierPath()
            tip.move(to: e)
            tip.line(to: NSPoint(x: e.x - cos(angle - 0.5) * head * 1.4, y: e.y - sin(angle - 0.5) * head * 1.4))
            tip.line(to: NSPoint(x: e.x - cos(angle + 0.5) * head * 1.4, y: e.y - sin(angle + 0.5) * head * 1.4))
            tip.close()
            color.setFill()
            tip.fill()
        }
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

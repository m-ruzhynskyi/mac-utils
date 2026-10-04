// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

enum Tool: CaseIterable {
    case select, arrow, rectangle, pen, marker, text, counter, pixelate

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "mosaic"
        }
    }

    var title: String {
        switch self {
        case .select: return "Выбор и перемещение (V)"
        case .arrow: return "Стрелка (1)"
        case .rectangle: return "Прямоугольник (2)"
        case .pen: return "Карандаш (3)"
        case .marker: return "Маркер (4)"
        case .text: return "Текст (5)"
        case .counter: return "Нумерация 1, 2, 3 (6)"
        case .pixelate: return "Размытие (7)"
        }
    }

    /// Клавиша-цифра для инструмента (без «выбора», у него V).
    static let numbered: [Tool] = [.arrow, .rectangle, .pen, .marker, .text, .counter, .pixelate]
}

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    /// Стрелка / прямоугольник / размытие: [начало, конец]. Карандаш / маркер: путь.
    /// Текст: [левый нижний угол]. Номер: [центр].
    var points: [NSPoint]
    var text = ""
    var fontSize: CGFloat = 22
    var number = 0

    static let counterRadius: CGFloat = 15

    var isMeaningful: Bool {
        switch tool {
        case .text:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter:
            return !points.isEmpty
        case .pen, .marker:
            return points.count > 1
        default:
            guard let a = points.first, let b = points.last else { return false }
            return hypot(b.x - a.x, b.y - a.y) > 3
        }
    }

    mutating func offset(dx: CGFloat, dy: CGFloat) {
        points = points.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    // MARK: - Попадание курсора

    @MainActor
    var bounds: NSRect {
        switch tool {
        case .text:
            guard let origin = points.first else { return .zero }
            let size = NSAttributedString(string: text, attributes: Self.textAttributes(color: color, size: fontSize)).size()
            return NSRect(origin: origin, size: size)
        case .counter:
            guard let c = points.first else { return .zero }
            let r = Self.counterRadius
            return NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        default:
            guard !points.isEmpty else { return .zero }
            let xs = points.map(\.x), ys = points.map(\.y)
            let minX = xs.min()!, minY = ys.min()!
            return NSRect(x: minX, y: minY, width: xs.max()! - minX, height: ys.max()! - minY)
        }
    }

    @MainActor
    func hitTest(_ p: NSPoint) -> Bool {
        let slop = max(width, 4) + 5
        switch tool {
        case .text, .counter, .pixelate:
            return bounds.insetBy(dx: -4, dy: -4).contains(p)
        case .rectangle:
            let rect = bounds
            return rect.insetBy(dx: -slop, dy: -slop).contains(p)
                && !rect.insetBy(dx: slop, dy: slop).contains(p)
        case .arrow:
            guard let a = points.first, let b = points.last else { return false }
            return Self.distance(p, a, b) <= slop
        case .pen, .marker:
            let reach = tool == .marker ? width * 2.5 + 4 : slop
            guard points.count > 1 else { return false }
            for i in 1..<points.count where Self.distance(p, points[i - 1], points[i]) <= reach {
                return true
            }
            return false
        case .select:
            return false
        }
    }

    private static func distance(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Отрисовка

    @MainActor
    static func textAttributes(color: NSColor, size: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2
        return [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
            .shadow: shadow,
        ]
    }

    /// Рисует аннотацию в текущем NSGraphicsContext (координаты вида, не перевёрнутые).
    @MainActor
    func draw(pixelated: NSImage?, canvas: NSRect) {
        switch tool {
        case .select:
            return

        case .arrow:
            guard let a = points.first, let b = points.last else { return }
            drawArrow(from: a, to: b)

        case .rectangle:
            guard let a = points.first, let b = points.last else { return }
            let path = NSBezierPath(roundedRect: Self.rect(a, b), xRadius: 4, yRadius: 4)
            path.lineWidth = width
            color.setStroke()
            path.stroke()

        case .pen, .marker:
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if tool == .marker {
                path.lineWidth = width * 5
                color.withAlphaComponent(0.35).setStroke()
            } else {
                path.lineWidth = width
                color.setStroke()
            }
            path.stroke()

        case .text:
            guard let origin = points.first else { return }
            NSAttributedString(string: text, attributes: Self.textAttributes(color: color, size: fontSize))
                .draw(at: origin)

        case .counter:
            guard let center = points.first else { return }
            drawCounter(at: center)

        case .pixelate:
            guard let a = points.first, let b = points.last, let pixelated else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: Self.rect(a, b)).addClip()
            pixelated.draw(in: canvas)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    @MainActor
    private func drawCounter(at center: NSPoint) {
        let r = Self.counterRadius
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        color.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        circle.lineWidth = 2
        NSColor.white.setStroke()
        circle.stroke()

        let light = color.usingColorSpace(.sRGB).map { $0.brightnessComponent > 0.85 && $0.saturationComponent < 0.5 } ?? false
        let isYellow = color == .systemYellow
        let textColor: NSColor = (light || isYellow) ? .black : .white
        let label = NSAttributedString(string: "\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: number > 9 ? 13 : 16, weight: .bold),
            .foregroundColor: textColor,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    @MainActor
    private func drawArrow(from a: NSPoint, to b: NSPoint) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 1 else { return }
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = min(max(14, width * 4.5), length * 0.6)
        let spread: CGFloat = .pi / 7
        let left = NSPoint(x: b.x - head * cos(angle - spread), y: b.y - head * sin(angle - spread))
        let right = NSPoint(x: b.x - head * cos(angle + spread), y: b.y - head * sin(angle + spread))
        let base = NSPoint(x: b.x - head * 0.8 * cos(angle), y: b.y - head * 0.8 * sin(angle))

        color.setStroke()
        color.setFill()
        let shaft = NSBezierPath()
        shaft.move(to: a)
        shaft.line(to: base)
        shaft.lineWidth = width
        shaft.lineCapStyle = .round
        shaft.stroke()

        let tip = NSBezierPath()
        tip.move(to: b)
        tip.line(to: left)
        tip.line(to: right)
        tip.close()
        tip.fill()
    }

    static func rect(_ a: NSPoint, _ b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

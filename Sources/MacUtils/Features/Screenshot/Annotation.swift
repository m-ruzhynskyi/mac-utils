// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

enum Tool: CaseIterable {
    case arrow, rectangle, pen, marker, text, pixelate

    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .pen: return "pencil.tip"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .pixelate: return "mosaic"
        }
    }

    var title: String {
        switch self {
        case .arrow: return "Стрелка (1)"
        case .rectangle: return "Прямоугольник (2)"
        case .pen: return "Карандаш (3)"
        case .marker: return "Маркер (4)"
        case .text: return "Текст (5)"
        case .pixelate: return "Размытие (6)"
        }
    }
}

struct Annotation {
    var tool: Tool
    var color: NSColor
    var width: CGFloat
    /// Стрелка / прямоугольник / размытие: [начало, конец]. Карандаш / маркер: путь.
    /// Текст: [левый нижний угол].
    var points: [NSPoint]
    var text = ""
    var fontSize: CGFloat = 22

    var isMeaningful: Bool {
        switch tool {
        case .text:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .pen, .marker:
            return points.count > 1
        default:
            guard let a = points.first, let b = points.last else { return false }
            return hypot(b.x - a.x, b.y - a.y) > 3
        }
    }

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

        case .pixelate:
            guard let a = points.first, let b = points.last, let pixelated else { return }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: Self.rect(a, b)).addClip()
            pixelated.draw(in: canvas)
            NSGraphicsContext.restoreGraphicsState()
        }
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

import AppKit
import MUDesign
import MUAudio

/// Заглушка непрозрачного элемента на странице (`d05`): пунктирная рамка, тип и размер, «Показать в коде» и
/// «Открыть в Word». Сам элемент в исходнике не трогается.
final class DocPlaceholderCell: NSTextAttachmentCell {
    enum Action { case showInCode, openInWord }

    let placeholder: RTFPlaceholder
    let width: CGFloat
    static let height: CGFloat = 96
    /// Кнопка нажата: действие и номер символа заглушки в показанном тексте.
    var onAction: ((Action, Int) -> Void)?

    init(placeholder: RTFPlaceholder, width: CGFloat) {
        self.placeholder = placeholder
        self.width = max(240, width)
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { NSSize(width: width, height: Self.height) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -4) }

    private static func font(_ size: CGFloat, bold: Bool) -> NSFont {
        NSFont(name: bold ? "Manrope-Bold" : "Manrope-Medium", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .medium)
    }

    private var symbol: String {
        switch placeholder.kind {
        case .shape, .drawing: return "square.on.circle"
        case .object: return "shippingbox"
        case .picture: return "photo.badge.exclamationmark"
        }
    }

    func codeButton(in frame: NSRect) -> NSRect {
        NSRect(x: frame.minX + 14, y: frame.maxY - 40, width: 136, height: 28)
    }

    func wordButton(in frame: NSRect) -> NSRect {
        NSRect(x: frame.minX + 158, y: frame.maxY - 40, width: 128, height: 28)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let frame = cellFrame.insetBy(dx: 1, dy: 3)
        let box = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSColor(srgbRed: 0.957, green: 0.965, blue: 0.98, alpha: 1).setFill()
        box.fill()
        box.setLineDash([5, 3], count: 2, phase: 0)
        box.lineWidth = 1.2
        NSColor(srgbRed: 0.6, green: 0.64, blue: 0.71, alpha: 1).setStroke()
        box.stroke()
        let ink = NSColor(srgbRed: 0.11, green: 0.13, blue: 0.16, alpha: 1)
        let mute = NSColor(srgbRed: 0.42, green: 0.45, blue: 0.5, alpha: 1)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [NSColor(srgbRed: 0.27, green: 0.38, blue: 0.55, alpha: 1)]))) {
            image.draw(in: NSRect(x: frame.minX + 14, y: frame.minY + 11, width: 20, height: 18), from: .zero, operation: .sourceOver,
                       fraction: 1, respectFlipped: true, hints: nil)
        }
        (placeholder.title as NSString).draw(at: NSPoint(x: frame.minX + 42, y: frame.minY + 10),
                                             withAttributes: [.font: Self.font(14, bold: true), .foregroundColor: ink])
        (placeholder.subtitle as NSString).draw(at: NSPoint(x: frame.minX + 14, y: frame.minY + 36),
                                                withAttributes: [.font: Self.font(12, bold: false), .foregroundColor: mute])
        drawButton("Показать в коде", in: codeButton(in: frame), filled: true)
        drawButton("Открыть в Word", in: wordButton(in: frame), filled: false)
    }

    private func drawButton(_ title: String, in rect: NSRect, filled: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        if filled {
            NSColor(srgbRed: 0.784, green: 0.941, blue: 0.353, alpha: 1).setFill()
            path.fill()
        } else {
            NSColor.white.setFill()
            path.fill()
            NSColor(srgbRed: 0.8, green: 0.82, blue: 0.85, alpha: 1).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font(12, bold: true),
                                                         .foregroundColor: NSColor(srgbRed: 0.08, green: 0.1, blue: 0.04, alpha: 1)]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool {
        true
    }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int,
                             untilMouseUp flag: Bool) -> Bool {
        guard let controlView else { return false }
        let point = controlView.convert(theEvent.locationInWindow, from: nil)
        let frame = cellFrame.insetBy(dx: 1, dy: 3)
        if codeButton(in: frame).contains(point) {
            onAction?(.showInCode, charIndex)
        } else if wordButton(in: frame).contains(point) {
            onAction?(.openInWord, charIndex)
        } else {
            // Мимо кнопок — обычный клик: заглушка выделяется как символ.
            return false
        }
        return true
    }
}

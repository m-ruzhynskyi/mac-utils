import AppKit

/// Опора плавающей фигуры (`RTFFloat`) в тексте: нулевого размера, как у Word, — на перенос строк и высоту не влияет.
/// Сама фигура рисуется слоем страницы (`DocFloatingLayer`) от этой опоры.
final class DocFloatingCell: NSTextAttachmentCell {
    let shape: RTFFloat
    let picture: NSImage?

    init(shape: RTFFloat, image: NSImage?) {
        self.shape = shape
        self.picture = image
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func cellSize() -> NSSize { .zero }
    override func cellBaselineOffset() -> NSPoint { .zero }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
    override func wantsToTrackMouse() -> Bool { false }

    /// Нарисовать фигуру в рамке (координаты страницы, ось Y вниз).
    func drawShape(in rect: NSRect) {
        if shape.shapeType == 75 {
            picture?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            return
        }
        let path: NSBezierPath
        let isLine = shape.shapeType == 20 || shape.shapeType == 32
        switch shape.shapeType {
        case 20, 32:
            path = NSBezierPath()
            // Линия — по диагонали рамки; отражение по одной оси меняет диагональ.
            let rising = shape.flipH != shape.flipV
            path.move(to: NSPoint(x: rect.minX, y: rising ? rect.maxY : rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rising ? rect.minY : rect.maxY))
        case 2:
            let radius = min(rect.width, rect.height) / 6
            path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        case 3:
            path = NSBezierPath(ovalIn: rect)
        default:
            path = NSBezierPath(rect: rect)
        }
        if shape.filled, !isLine {
            Self.color(shape.fillColor, system: .white).setFill()
            path.fill()
        }
        if shape.line {
            path.lineWidth = max(0.25, CGFloat(shape.lineWidth) / 12_700)
            Self.color(shape.lineColor, system: .black).setStroke()
            path.stroke()
        }
    }

    /// Цвет Word: R + G·256 + B·65536.
    /// Цвет Office в `\sp` (BGR). Со старшим байтом-флагом (0x10000000 — системный цвет, 0x08000000 — цвет схемы) это
    /// не RGB: Word рисует такую заливку цветом окна (белым), линию — цветом текста (`system`).
    static func color(_ value: Int, system: NSColor) -> NSColor {
        guard value & ~0xFFFFFF == 0 else { return system }
        return NSColor(srgbRed: CGFloat(value & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat((value >> 16) & 0xFF) / 255, alpha: 1)
    }
}

/// Слой страницы с плавающими фигурами, опоры которых на этой странице: под текстом (`\shpfblwtxt1`) или над ним.
/// Рисует все фигуры страницы целиком при любой перерисовке; мышь не ловит.
final class DocFloatingLayer: NSView {
    weak var page: DocPageView?
    let behind: Bool

    init(behind: Bool) {
        self.behind = behind
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let page else { return }
        for (cell, rect) in page.floatingShapes() where cell.shape.behind == behind {
            cell.drawShape(in: rect)
        }
    }
}

extension DocPageView {
    /// Плавающие фигуры с опорой на этой странице и их рамки в координатах страницы.
    /// По горизонтали — от края листа, поля или колонки (в ячейке — от ячейки); по вертикали — от листа, поля или абзаца.
    func floatingShapes() -> [(DocFloatingCell, NSRect)] {
        guard let manager = container.layoutManager, let storage = manager.textStorage, storage.length > 0 else { return [] }
        let glyphs = manager.glyphRange(for: container)
        guard glyphs.length > 0 else { return [] }
        let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let origin = textView.frame.origin
        let margins = Self.bodyRect(props)
        let text = storage.string as NSString
        var result: [(DocFloatingCell, NSRect)] = []
        storage.enumerateAttribute(.attachment, in: characters) { value, range, _ in
            guard let cell = (value as? NSTextAttachment)?.attachmentCell as? DocFloatingCell else { return }
            let shape = cell.shape
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            let block = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textBlocks.last as? NSTextTableBlock
            var cellRect: NSRect?
            if let block, shape.layoutInCell {
                let blockRange = storage.range(of: block, at: range.location)
                cellRect = manager.layoutRect(for: block, glyphRange: manager.glyphRange(forCharacterRange: blockRange, actualCharacterRange: nil))
            }
            let x: CGFloat
            switch shape.horizontal {
            case .page: x = cellRect.map { origin.x + $0.minX } ?? 0
            case .margin: x = cellRect.map { origin.x + $0.minX } ?? margins.minX
            case .column: x = origin.x + (cellRect?.minX ?? 0)
            }
            let y: CGFloat
            switch shape.vertical {
            case .page: y = 0
            case .margin: y = margins.minY
            case .paragraph:
                // Верх абзаца опоры (если абзац начался на прошлой странице — верх строки опоры).
                let start = text.paragraphRange(for: NSRange(location: range.location, length: 0)).location
                let first = manager.glyphIndexForCharacter(at: start)
                let line = NSLocationInRange(first, glyphs) ? manager.lineFragmentRect(forGlyphAt: first, effectiveRange: nil)
                    : manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                y = origin.y + line.minY
            }
            let rect = NSRect(x: x + CGFloat(shape.left) / 20, y: y + CGFloat(shape.top) / 20,
                              width: CGFloat(shape.width) / 20, height: CGFloat(shape.height) / 20)
            result.append((cell, rect))
        }
        return result
    }
}

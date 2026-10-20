import AppKit

/// Раскладка страниц документа: обычный `NSLayoutManager` плюс невидимые знаки Word (¶ · ° → ↵ ¤ и разрывы).
final class DocLayoutManager: NSLayoutManager {
    var showsInvisibles = false
    /// Вид показанной единицы по карте: конец ячейки — «¤», разрыв раздела — своя подпись.
    var unitKind: ((Int) -> DocSourceMap.Kind?)?
    static let markColor = NSColor(srgbRed: 0.27, green: 0.45, blue: 0.85, alpha: 1)

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard showsInvisibles, let storage = textStorage, storage.length > 0 else { return }
        let text = storage.mutableString
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for index in characters.location..<min(NSMaxRange(characters), text.length) {
            let unit = text.character(at: index)
            let mark: String
            switch unit {
            case 0x20: mark = "·"
            case 0xA0: mark = "°"
            case 0x09: mark = "→"
            case 0x2028: mark = "↵"
            case 0x0A: mark = unitKind?(index) == .cellEnd ? "¤" : "¶"
            case 0x0C:
                drawBreak(at: index, kind: unitKind?(index) ?? .pageBreak, origin: origin)
                continue
            default: continue
            }
            let glyph = glyphIndexForCharacter(at: index)
            guard let container = textContainer(forGlyphAt: glyph, effectiveRange: nil) else { continue }
            let rect = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 12)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: max(7, font.pointSize * 0.85)), .foregroundColor: Self.markColor,
            ]
            let size = (mark as NSString).size(withAttributes: attributes)
            // Знак — на базовой линии символа: место глифа в строке + начало строки.
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = line.minY + location(forGlyphAt: glyph).y
            let markFont = attributes[.font] as! NSFont
            let x = unit == 0x20 || unit == 0xA0 ? rect.midX - size.width / 2 : line.minX + location(forGlyphAt: glyph).x + 1
            let point = NSPoint(x: origin.x + x, y: origin.y + baseline - markFont.ascender)
            (mark as NSString).draw(at: point, withAttributes: attributes)
        }
    }

    /// Разрыв страницы или раздела — пунктир с подписью под строкой, где стоит разрыв.
    private func drawBreak(at index: Int, kind: DocSourceMap.Kind, origin: NSPoint) {
        let glyph = glyphIndexForCharacter(at: index)
        guard let container = textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return }
        let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let title = kind == .sectionBreak ? "Разрыв раздела (со следующей страницы)" : "Разрыв страницы"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: Self.markColor]
        let size = (title as NSString).size(withAttributes: attributes)
        let y = origin.y + line.maxY + 8
        let width = container.size.width
        let path = NSBezierPath()
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.lineWidth = 1
        path.move(to: NSPoint(x: origin.x, y: y))
        path.line(to: NSPoint(x: origin.x + (width - size.width) / 2 - 8, y: y))
        path.move(to: NSPoint(x: origin.x + (width + size.width) / 2 + 8, y: y))
        path.line(to: NSPoint(x: origin.x + width, y: y))
        Self.markColor.setStroke()
        path.stroke()
        (title as NSString).draw(at: NSPoint(x: origin.x + (width - size.width) / 2, y: y - size.height / 2), withAttributes: attributes)
    }
}

/// Текст одной страницы: все страницы делят одно хранилище и один `DocLayoutManager`, у каждой — свой контейнер.
final class DocTextView: NSTextView {
    weak var page: DocPageView?
    /// Двойной клик по полю страницы (колонтитул) — передаётся странице.
    var onDoubleClickOutside: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let handler = onDoubleClickOutside, handler(event) { return }
        super.mouseDown(with: event)
    }

    // В документе нет «умных» замен: набранное должно попадать в исходник как есть.
    func disableSubstitutions() {
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = false
    }
}

/// Страница: белая бумага с тенью (в обеих темах), поля, колонтитулы и текст.
final class DocPageView: NSView {
    let textView: DocTextView
    let container: NSTextContainer
    private(set) var props: RTFSectionProps
    var section: Int
    var number = 1
    /// Первая страница своего раздела (для `\titlepg`).
    var firstInSection = false
    var header: NSAttributedString? { didSet { if header != oldValue { needsDisplay = true } } }
    var footer: NSAttributedString? { didSet { if footer != oldValue { needsDisplay = true } } }
    /// Правится колонтитул: основной текст бледнее.
    var faded = false {
        didSet {
            textView.alphaValue = faded ? 0.45 : 1
            needsDisplay = true
        }
    }
    /// Рамка правки колонтитула (`d11`): прямоугольник и подпись.
    var headerFrame: (rect: NSRect, title: String)? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(props: RTFSectionProps, section: Int) {
        self.props = props
        self.section = section
        let body = Self.bodyRect(props)
        container = NSTextContainer(size: body.size)
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        // Контейнер в раскладку добавляет владелец — уже после того, как страница встала в список (раскладка тут же
        // может попросить следующую страницу).
        textView = DocTextView(frame: body, textContainer: container)
        super.init(frame: NSRect(origin: .zero, size: Self.size(props)))
        appearance = NSAppearance(named: .aqua)
        textView.page = self
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.insertionPointColor = .black
        textView.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.7, green: 0.82, blue: 1, alpha: 1)]
        textView.disableSubstitutions()
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func size(_ props: RTFSectionProps) -> NSSize {
        NSSize(width: CGFloat(max(props.pageWidth, 2_000)) / 20, height: CGFloat(max(props.pageHeight, 2_000)) / 20)
    }

    static func bodyRect(_ props: RTFSectionProps) -> NSRect {
        let size = size(props)
        let left = CGFloat(max(props.marginLeft, 0)) / 20, right = CGFloat(max(props.marginRight, 0)) / 20
        let top = CGFloat(max(props.marginTop, 0)) / 20, bottom = CGFloat(max(props.marginBottom, 0)) / 20
        return NSRect(x: left, y: top, width: max(72, size.width - left - right), height: max(72, size.height - top - bottom))
    }

    var bodyRect: NSRect { Self.bodyRect(props) }

    /// Где рисуется верхний и нижний колонтитул.
    var headerRect: NSRect {
        let body = bodyRect
        let top = CGFloat(max(props.headerY, 0)) / 20
        return NSRect(x: body.minX, y: top, width: body.width, height: max(14, body.minY - top))
    }

    var footerRect: NSRect {
        let body = bodyRect
        let bottom = bounds.height - CGFloat(max(props.footerY, 0)) / 20
        return NSRect(x: body.minX, y: body.maxY, width: body.width, height: max(14, bottom - body.maxY))
    }

    func update(props: RTFSectionProps, section: Int) {
        self.section = section
        guard props != self.props else { return }
        self.props = props
        let body = Self.bodyRect(props)
        setFrameSize(Self.size(props))
        container.size = body.size
        textView.frame = body
        needsDisplay = true
        superview?.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Только своя бумага: при отрисовке в картинку `dirtyRect` бывает шире страницы — иначе стёрли бы соседнюю.
        NSColor.white.setFill()
        dirtyRect.intersection(bounds).fill()
        if let header {
            header.draw(with: NSRect(x: headerRect.minX, y: headerRect.minY, width: headerRect.width, height: 10_000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        if let footer {
            let height = footer.boundingRect(with: NSSize(width: footerRect.width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            let y = bounds.height - CGFloat(max(props.footerY, 0)) / 20 - height
            footer.draw(with: NSRect(x: footerRect.minX, y: max(footerRect.minY, y), width: footerRect.width, height: 10_000),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        if let frame = headerFrame {
            let path = NSBezierPath(rect: frame.rect)
            path.setLineDash([5, 3], count: 2, phase: 0)
            path.lineWidth = 1.5
            NSColor(srgbRed: 0.42, green: 0.62, blue: 0.0, alpha: 1).setStroke()
            path.stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Manrope-Bold", size: 11) ?? .boldSystemFont(ofSize: 11),
                .foregroundColor: NSColor(srgbRed: 0.08, green: 0.1, blue: 0.04, alpha: 1),
            ]
            let size = (frame.title as NSString).size(withAttributes: attributes)
            let label = NSRect(x: frame.rect.minX, y: frame.rect.minY - size.height - 6, width: size.width + 12, height: size.height + 6)
            NSColor(srgbRed: 0.784, green: 0.941, blue: 0.353, alpha: 1).setFill()
            NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
            (frame.title as NSString).draw(at: NSPoint(x: label.minX + 6, y: label.minY + 3), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Двойной клик по полю страницы — колонтитул (как в Word).
        if event.clickCount == 2, let handler = textView.onDoubleClickOutside, handler(event) { return }
        super.mouseDown(with: event)
    }
}

/// Стол со страницами: колонка страниц по центру, зазор 24 pt.
final class DocPagesView: NSView {
    static let gap: CGFloat = 24
    private(set) var pages: [DocPageView] = []

    override var isFlipped: Bool { true }

    func append(_ page: DocPageView) {
        pages.append(page)
        addSubview(page)
        layoutPages()
    }

    func removePages(from index: Int) {
        guard index < pages.count else { return }
        for page in pages[index...] { page.removeFromSuperview() }
        pages.removeSubrange(index...)
        layoutPages()
    }

    /// Стол и тени страниц рисуются здесь, без слоёв: так их видно и на офскрин-снимках.
    override func draw(_ dirtyRect: NSRect) {
        DS.Palette.bg.setFill()
        dirtyRect.fill()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        for page in pages where page.frame.insetBy(dx: -12, dy: -12).intersects(dirtyRect) { page.frame.fill() }
        NSGraphicsContext.restoreGraphicsState()
    }

    func layoutPages() {
        let width = (pages.map(\.frame.width).max() ?? 595) + 2 * Self.gap
        var y = Self.gap
        // Рамки — только если изменились: перестановка во время рисования сбивает отрисовку страниц.
        for page in pages {
            let origin = NSPoint(x: ((width - page.frame.width) / 2).rounded(), y: y)
            if page.frame.origin != origin { page.setFrameOrigin(origin) }
            y += page.frame.height + Self.gap
        }
        let size = NSSize(width: width, height: max(y, Self.gap * 2))
        if frame.size != size { setFrameSize(size) }
    }

    /// Страница под точкой (в координатах этого вида).
    func page(at point: NSPoint) -> DocPageView? {
        pages.first { $0.frame.contains(point) }
    }
}

/// Прокрутка документа держит узкие страницы по центру (при уменьшенном масштабе).
final class DocCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let document = documentView, document.frame.width < rect.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        return rect
    }
}

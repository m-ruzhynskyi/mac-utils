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
        // По полосе текста, без выступа рамки в поля.
        let outdent = (container.textView as? DocTextView)?.page?.outdent ?? DocOutdent()
        let x = origin.x + outdent.left
        let width = container.size.width - outdent.left - outdent.right
        let path = NSBezierPath()
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.lineWidth = 1
        path.move(to: NSPoint(x: x, y: y))
        path.line(to: NSPoint(x: x + (width - size.width) / 2 - 8, y: y))
        path.move(to: NSPoint(x: x + (width + size.width) / 2 + 8, y: y))
        path.line(to: NSPoint(x: x + width, y: y))
        Self.markColor.setStroke()
        path.stroke()
        (title as NSString).draw(at: NSPoint(x: x + (width - size.width) / 2, y: y - size.height / 2), withAttributes: attributes)
    }
}

/// Текст одной страницы: все страницы делят одно хранилище и один `DocLayoutManager`, у каждой — свой контейнер.
final class DocTextView: NSTextView {
    weak var page: DocPageView?
    weak var controller: DocumentController?
    /// Двойной клик по полю страницы (колонтитул) — передаётся странице.
    var onDoubleClickOutside: ((NSEvent) -> Bool)?

    /// Таблица шире листа выходит за его край — как в Word, видно только то, что на листе.
    override func draw(_ dirtyRect: NSRect) {
        if let page { NSBezierPath(rect: convert(page.bounds, from: page)).addClip() }
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let controller, controller.dragTableBoundary(event, in: self) { return }
        if event.clickCount == 2, let handler = onDoubleClickOutside, handler(event) { return }
        super.mouseDown(with: event)
    }

    // MARK: Ввод через метод ввода (японский, китайский…): набираемое — только на экране, в исходник — по подтверждению.

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() {
            controller?.beginComposition(replacing: replacementRange.location == NSNotFound ? self.selectedRange() : replacementRange)
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if hasMarkedText(), let controller {
            let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
            super.unmarkText()
            controller.commitComposition(text)
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func unmarkText() {
        super.unmarkText()
        controller?.cancelComposition()
    }


    // Вставка: форматированная (RTF/HTML) — `DocFormatter` (D-4), иначе обычным текстом.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func paste(_ sender: Any?) {
        if let controller, DocFormatter.of(controller).pasteFormatted(in: self) { return }
        let rich = NSPasteboard.general.availableType(from: [.rtf, .rtfd, .html]) != nil
        pasteAsPlainText(sender)
        if rich { controller?.show(notice: "Вставлено без части форматирования") }
    }

    // MARK: Меню и перетаскивание

    /// Контекстное меню: «Показать в коде» — то же место в исходнике; в таблице — строки.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: "Показать в коде", action: #selector(showInCode(_:)), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        // Таблица: строки, столбцы, объединение, границы, заливка; вне таблицы — вставка таблицы.
        for (index, item) in (controller?.tableMenuItems() ?? []).enumerated() { menu.insertItem(item, at: 2 + index) }
        if controller != nil { menu.insertItem(.separator(), at: 3) }
        return menu
    }

    // Граница ячеек таблицы: курсор «←→», перетаскивание — ширина столбца.
    override func mouseMoved(with event: NSEvent) {
        if let controller, controller.tableBoundary(at: convert(event.locationInWindow, from: nil), in: self) != nil {
            NSCursor.resizeLeftRight.set()
            return
        }
        super.mouseMoved(with: event)
    }

    // Tab в таблице — по ячейкам, как в Word (и в пункте списка внутри ячейки); вне таблицы Tab в начале пункта
    // списка — уровень ниже (ввод «\t» → `DocListEdit`), ⇧Tab — выше.
    override func insertTab(_ sender: Any?) {
        if controller?.tabInTable(forward: true) != true { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if controller?.tabInTable(forward: false) == true || controller?.backtab() == true { return }
        super.insertBacktab(sender)
    }

    @objc func showInCode(_ sender: Any?) {
        guard let controller, let tab = controller.tab else { return }
        tab.showInCode(controller.sourceSelection)
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    /// Брошенные на страницу файлы открываются вкладками (как в «Коде»), а не вставляются путём.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        MainActor.assumeIsolated { EditorWindowController.shared.open(urls) }
        return true
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
    /// Плавающие фигуры (`DocFloatingLayer`): под текстом и над ним.
    private let shapesBehind = DocFloatingLayer(behind: true)
    private let shapesFront = DocFloatingLayer(behind: false)
    private(set) var props: RTFSectionProps
    var section: Int
    var number = 1
    /// Первая страница своего раздела (для `\titlepg`).
    var firstInSection = false
    private(set) var header: NSAttributedString?
    private(set) var footer: NSAttributedString?
    /// Раскладка колонтитулов — та же TextKit, что у основного текста (высота строк, таблицы).
    private let headerLayout = DocStoryLayout()
    private let footerLayout = DocStoryLayout()
    /// Насколько колонтитулы выходят в поля (отрицательные отступы абзацев) и их высота — по ним считается геометрия.
    private var headerOutdent = (left: CGFloat(0), right: CGFloat(0))
    private var footerOutdent = (left: CGFloat(0), right: CGFloat(0))
    private(set) var headerHeight: CGFloat = 0
    private(set) var footerHeight: CGFloat = 0
    /// Выступ текста раздела в поля (таблицы шире полосы текста): рамка текста шире `bodyRect` на столько же.
    private(set) var outdent = DocOutdent()
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

    init(props: RTFSectionProps, section: Int, outdent: DocOutdent = DocOutdent()) {
        self.props = props
        self.section = section
        self.outdent = outdent
        let body = Self.textRect(Self.bodyRect(props), outdent)
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
        for layer in [shapesBehind, shapesFront] {
            layer.page = self
            layer.frame = bounds
        }
        addSubview(shapesBehind)
        addSubview(textView)
        addSubview(shapesFront)
    }

    /// Раскладка страницы изменилась — фигуры перерисовать от новых мест опор.
    func refreshFloating() {
        shapesBehind.needsDisplay = true
        shapesFront.needsDisplay = true
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

    /// Текст страницы — как в Word: колонтитул выше своего поля сдвигает текст (верхний — вниз, нижний — вверх).
    var bodyRect: NSRect {
        var body = Self.bodyRect(props)
        let top = max(body.minY, headerHeight > 0 ? CGFloat(max(props.headerY, 0)) / 20 + headerHeight : 0)
        let bottom = min(body.maxY, footerHeight > 0 ? Self.size(props).height - CGFloat(max(props.footerY, 0)) / 20 - footerHeight : body.maxY)
        if bottom - top >= 72 { body = NSRect(x: body.minX, y: top, width: body.width, height: bottom - top) }
        return body
    }

    /// Верхний колонтитул: верх — на `\headery` от края листа, ширина — поля текста плюс выступ в поля.
    var headerRect: NSRect {
        let base = Self.bodyRect(props)
        let top = CGFloat(max(props.headerY, 0)) / 20
        return NSRect(x: base.minX - headerOutdent.left, y: top, width: base.width + headerOutdent.left + headerOutdent.right,
                      height: max(14, headerHeight))
    }

    /// Нижний колонтитул: низ — на `\footery` от низа листа (растёт вверх), так он всегда на своей странице.
    var footerRect: NSRect {
        let base = Self.bodyRect(props)
        let height = max(14, footerHeight)
        let bottom = Self.size(props).height - CGFloat(max(props.footerY, 0)) / 20
        return NSRect(x: base.minX - footerOutdent.left, y: max(0, bottom - height), width: base.width + footerOutdent.left + footerOutdent.right,
                      height: height)
    }

    /// Поставить колонтитулы страницы (текст и выступ в поля); высота меряется, текст страницы подвигается.
    func setHeaders(header: NSAttributedString?, headerOutdent: (CGFloat, CGFloat), footer: NSAttributedString?, footerOutdent: (CGFloat, CGFloat)) {
        guard header != self.header || footer != self.footer || headerOutdent != self.headerOutdent || footerOutdent != self.footerOutdent else { return }
        self.header = header
        self.footer = footer
        self.headerOutdent = (headerOutdent.0, headerOutdent.1)
        self.footerOutdent = (footerOutdent.0, footerOutdent.1)
        layoutHeaders()
    }

    /// Высота колонтитулов по ширине страницы — без пустой строки после последнего конца абзаца (у Word её нет).
    private func layoutHeaders() {
        let width = Self.bodyRect(props).width
        headerHeight = headerLayout.set(header, width: width + headerOutdent.left + headerOutdent.right)
        footerHeight = footerLayout.set(footer, width: width + footerOutdent.left + footerOutdent.right)
        applyBody()
        needsDisplay = true
    }

    /// Рамка текста: полоса текста плюс выступ в поля. `bodyRect` остаётся полосой — от неё линейка и колонтитулы.
    var textRect: NSRect { Self.textRect(bodyRect, outdent) }

    private static func textRect(_ body: NSRect, _ outdent: DocOutdent) -> NSRect {
        NSRect(x: body.minX - outdent.left, y: body.minY, width: body.width + outdent.left + outdent.right, height: body.height)
    }

    /// Рамка текста страницы — по `textRect` (после колонтитулов).
    private func applyBody() {
        let body = textRect
        if textView.frame != body { textView.frame = body }
        if container.size != body.size { container.size = body.size }
    }

    func update(props: RTFSectionProps, section: Int, outdent: DocOutdent) {
        self.section = section
        guard props != self.props || outdent != self.outdent else { return }
        self.props = props
        self.outdent = outdent
        setFrameSize(Self.size(props))
        layoutHeaders()
        needsDisplay = true
        superview?.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Только своя бумага: при отрисовке в картинку `dirtyRect` бывает шире страницы — иначе стёрли бы соседнюю.
        NSColor.white.setFill()
        dirtyRect.intersection(bounds).fill()
        if header != nil { headerLayout.draw(at: headerRect.origin) }
        if footer != nil { footerLayout.draw(at: NSPoint(x: footerRect.minX, y: footerRect.maxY - footerHeight)) }
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

/// Колонтитул на странице: своя раскладка TextKit (как у основного текста), высота и рисование.
@MainActor
final class DocStoryLayout {
    private let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 400, height: 10_000))

    init() {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.delegate = DocLineMetricsDelegate.shared
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    /// Новый текст и ширина; ответ — высота текста без пустой строки после последнего `\n` (0 — текста нет).
    func set(_ string: NSAttributedString?, width: CGFloat) -> CGFloat {
        let string = string ?? NSAttributedString()
        if !storage.isEqual(to: string) { storage.setAttributedString(string) }
        if container.size.width != width { container.size = NSSize(width: width, height: 10_000) }
        guard storage.length > 0 else { return 0 }
        return Self.height(layoutManager, container)
    }

    /// Высота разложенного текста контейнера без пустой строки после последнего `\n`.
    static func height(_ layoutManager: NSLayoutManager, _ container: NSTextContainer) -> CGFloat {
        layoutManager.ensureLayout(for: container)
        let height = layoutManager.usedRect(for: container).height
        guard layoutManager.extraLineFragmentTextContainer === container else { return height }
        return max(0, min(height, layoutManager.extraLineFragmentRect.minY))
    }

    func draw(at origin: NSPoint) {
        let glyphs = layoutManager.glyphRange(for: container)
        guard glyphs.length > 0 else { return }
        layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
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

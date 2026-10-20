import AppKit

/// Цвета и шрифт редактора. Синтаксис приглушён, чтобы выделялись знаки `$` (макет a).
enum EditorStyle {
    static let fontSize: CGFloat = 12.5
    static let lineHeight: CGFloat = 19.5
    static let zoomRange: ClosedRange<CGFloat> = 0.5...3

    /// Без лигатур и контекстных замен: в исходнике `->` и `!=` должны оставаться как набраны, и строки в десятки
    /// тысяч символов раскладываются быстрее.
    static func font(zoom: CGFloat) -> NSFont {
        let base = NSFont(name: "JetBrainsMonoRoman-Medium", size: fontSize * zoom)
            ?? .monospacedSystemFont(ofSize: fontSize * zoom, weight: .medium)
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
        ]
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    static func gutterFont(zoom: CGFloat) -> NSFont {
        NSFont(name: "JetBrainsMonoRoman-Medium", size: 11 * zoom) ?? .monospacedDigitSystemFont(ofSize: 11 * zoom, weight: .medium)
    }

    static let text = DS.Palette.text
    static let faint = DS.color(dark: 0x5D6673, light: 0xA0A7B0)
    static let control = DS.color(dark: 0x8FA6C8, light: 0x44618C)
    static let brace = DS.color(dark: 0x7C8594, light: 0x7A838F)
    static let escape = DS.color(dark: 0xE0A867, light: 0x9A5B00)
    static let string = DS.color(dark: 0xA8D27A, light: 0x3F7A12)
    static let number = DS.color(dark: 0xE0A867, light: 0x9A5B00)
    static let keyword = DS.color(dark: 0xB79BFF, light: 0x7A4FE0)
    static let comment = DS.color(dark: 0x6B7480, light: 0x8A929C)
    static let currentLine = DS.color(dark: 0x1C2026, light: 0xF3F5EF)
    static let gutter = DS.color(dark: 0x14171B, light: 0xF8F9F6)

    /// Шесть оттенков знаков `$` (тёмная / светлая тема; кандидаты в `DS.Palette.mark1…6`) и нейтральный — для пустых значений.
    private static let huePairs: [(dark: UInt32, light: UInt32)] = [
        (0xC8F05A, 0x4F7A00), (0x6EA8FF, 0x1F6FDB), (0xF5B83D, 0xA86400),
        (0xFF7A6B, 0xD03A2B), (0xB79BFF, 0x7A4FE0), (0x4FD8C4, 0x0E8577),
    ]
    private static let neutralPair: (dark: UInt32, light: UInt32) = (0x9AA3AF, 0x59626E)
    static let hueCount = huePairs.count

    private static func pair(_ index: Int?) -> (dark: UInt32, light: UInt32) {
        index.map { huePairs[$0 % huePairs.count] } ?? neutralPair
    }

    private static let hueColors = (0...huePairs.count).map { i in
        let pair = pair(i < huePairs.count ? i : nil)
        return DS.color(dark: pair.dark, light: pair.light)
    }

    /// Заливка значения: 22 % в тёмной теме, 15 % в светлой; выбранное в списке — плотнее.
    private static let fillColors = [false, true].map { selected in
        (0...huePairs.count).map { i in
            let pair = pair(i < huePairs.count ? i : nil)
            return NSColor(name: nil) { appearance in
                let dark = DS.isDark(appearance)
                return DS.rgb(dark ? pair.dark : pair.light, alpha: selected ? 0.4 : (dark ? 0.22 : 0.15))
            }
        }
    }

    static func hue(_ index: Int?) -> NSColor { hueColors[index.map { $0 % huePairs.count } ?? huePairs.count] }

    static func hueFill(_ index: Int?, selected: Bool = false) -> NSColor {
        fillColors[selected ? 1 : 0][index.map { $0 % huePairs.count } ?? huePairs.count]
    }

    static let match = DS.color(dark: 0xC8F05A, light: 0xC8F05A)
    static let matchFill = NSColor(name: nil) { appearance in
        DS.rgb(0xC8F05A, alpha: DS.isDark(appearance) ? 0.22 : 0.3)
    }
}

/// Текст редактора: TextKit 1 (на 10 МБ предсказуемее TextKit 2), все автозамены выключены — исходник RTF не портится.
final class EditorTextView: NSTextView {
    /// Перевод строки, который вставляет Enter (как в документе).
    var lineBreak = "\n"
    /// Режим замены (Insert): набранный символ заменяет следующий.
    var overwrite = false {
        didSet { if overwrite != oldValue { onOverwriteChange?(overwrite); updateInsertionPointStateAndRestartTimer(true) } }
    }
    var onOverwriteChange: ((Bool) -> Void)?
    /// Файлы, брошенные на текст, открываются вкладками, а не вставляются путём.
    var onFileDrop: (([URL]) -> Void)?
    var highlightsCurrentLine = true

    static func make() -> (scroll: NSScrollView, text: EditorTextView) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = true
        // Без фоновой раскладки: на 10 МБ она раскладывает весь текст, и потом каждая большая правка его заново инвалидирует.
        layout.backgroundLayoutEnabled = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 10
        layout.addTextContainer(container)

        let scroll = NSScrollView()
        // С macOS 14 виды по умолчанию рисуют и за своими границами — колонка номеров залезала бы на панели выше.
        scroll.clipsToBounds = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = DS.Palette.panel

        let text = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        text.configure()
        scroll.documentView = text
        return (scroll, text)
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = false
        isIncrementalSearchingEnabled = false
        usesFontPanel = false
        usesRuler = false
        allowsDocumentBackgroundColorChange = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        enabledTextCheckingTypes = 0
        if #available(macOS 15.0, *) { writingToolsBehavior = .none }
        inlinePredictionType = .no
        drawsBackground = true
        backgroundColor = DS.Palette.panel
        insertionPointColor = DS.Palette.text
        selectedTextAttributes = [.backgroundColor: DS.color(dark: 0x2C3A52, light: 0xCFE0FA)]
        textContainerInset = NSSize(width: 0, height: 6)
        isVerticallyResizable = true
        isHorizontallyResizable = true
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        registerForDraggedTypes([.fileURL])
    }

    /// Перенос строк: контейнер по ширине окна, без горизонтальной прокрутки.
    func setWraps(_ wraps: Bool) {
        guard let container = textContainer, let scroll = enclosingScrollView else { return }
        if wraps {
            scroll.hasHorizontalScroller = false
            isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.size = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
            frame.size.width = scroll.contentSize.width
        } else {
            scroll.hasHorizontalScroller = true
            isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
        layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0), actualCharacterRange: nil)
        needsDisplay = true
    }

    /// Прокрутка AppKit готовит текст далеко за краями экрана. При строках в 20 000 символов это десятки строк
    /// раскладки на каждую правку и прокрутку — ограничиваем видимой областью с небольшим запасом.
    override func prepareContent(in rect: NSRect) {
        let visible = visibleRect
        guard visible.height > 0 else { return super.prepareContent(in: rect) }
        let limit = visible.insetBy(dx: -visible.width / 2, dy: -visible.height / 4)
        let limited = rect.intersection(limit)
        super.prepareContent(in: limited.isEmpty ? visible : limited)
    }

    // MARK: - Ввод

    override func insertNewline(_ sender: Any?) {
        insertText(lineBreak, replacementRange: selectedRange())
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Замена: один набранный символ вместо следующего, но не вместо перевода строки и не при вводе через IME.
        if overwrite, !hasMarkedText(), replacementRange.location == NSNotFound, selectedRange().length == 0,
           let typed = (string as? String) ?? (string as? NSAttributedString)?.string, !typed.contains(where: \.isNewline) {
            let text = textStorage?.mutableString ?? ""
            let caret = selectedRange().location
            var end = caret
            for _ in 0..<(typed as NSString).length where end < text.length {
                let unit = text.character(at: end)
                if unit == 0x0A || unit == 0x0D { break }
                end += text.rangeOfComposedCharacterSequence(at: end).length
            }
            super.insertText(string, replacementRange: NSRange(location: caret, length: end - caret))
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    /// ⌃Tab / ⌃⇧Tab — соседняя вкладка; Esc — закрыть панель поиска.
    var onSwitchTab: ((Int) -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Insert на полной клавиатуре — клавиша Help (код 114).
        if event.keyCode == 114 {
            overwrite.toggle()
            return
        }
        if event.keyCode == 48, event.modifierFlags.contains(.control), let onSwitchTab {
            onSwitchTab(event.modifierFlags.contains(.shift) ? -1 : 1)
            return
        }
        super.keyDown(with: event)
    }

    /// Esc не открывает список автодополнения слов (в исходнике он только мешает).
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    /// В режиме замены — курсор-блок шириной в символ.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard overwrite else { return super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
        var block = rect
        block.size.width = max(rect.width, ("0" as NSString).size(withAttributes: [.font: font ?? EditorStyle.font(zoom: 1)]).width)
        if flag {
            color.withAlphaComponent(0.45).setFill()
            block.fill()
        } else {
            setNeedsDisplay(block, avoidAdditionalLayout: true)
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = rect
        if overwrite { rect.size.width += 12 }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    // MARK: - Текущая строка

    /// Где нарисована подсветка текущей строки — чтобы перерисовать это место, не раскладывая строку заново.
    private var drawnLineRect: NSRect?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightsCurrentLine, let lineRect = currentLineRect() else { drawnLineRect = nil; return }
        drawnLineRect = lineRect
        EditorStyle.currentLine.setFill()
        lineRect.intersection(rect).fill()
    }

    /// Прямоугольник логической строки с курсором (все её отрезки при переносе) на всю ширину.
    func currentLineRect() -> NSRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let text: NSString = textStorage?.mutableString ?? ""
        let caret = min(selectedRange().location, text.length)
        if caret == text.length, text.length == 0 || [0x0A, 0x0D].contains(text.character(at: text.length - 1)) {
            let extra = layout.extraLineFragmentRect
            guard extra.height > 0 else { return nil }
            return NSRect(x: 0, y: extra.minY + textContainerOrigin.y, width: bounds.width, height: extra.height)
        }
        // Только отрезки первой и последней строки абзаца: `boundingRect` по всей строке раскладывает её целиком
        // (у строки в 20 000 символов — на каждое нажатие).
        _ = container
        let line = text.lineRange(for: NSRange(location: caret, length: 0))
        let first = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: line.location), effectiveRange: nil)
        var last = first
        if textContainer?.widthTracksTextView == true, line.length > 1 {
            last = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: NSMaxRange(line) - 1), effectiveRange: nil)
        }
        return NSRect(x: 0, y: first.minY + textContainerOrigin.y, width: bounds.width, height: max(first.maxY, last.maxY) - first.minY)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard highlightsCurrentLine else { return }
        if let old = drawnLineRect { setNeedsDisplay(old) }
        if let new = currentLineRect(), new != drawnLineRect { setNeedsDisplay(new) }
    }

    // MARK: - Перетаскивание файлов

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty, let onFileDrop else { return super.performDragOperation(sender) }
        onFileDrop(urls)
        return true
    }

    // MARK: - Правка несколькими диапазонами — один шаг отмены

    /// Заменяет непересекающиеся диапазоны одной правкой: один шаг Cmd+Z. Диапазоны — в координатах текста до правки.
    @discardableResult
    func replace(_ ranges: [NSRange], with strings: [String], actionName: String) -> Bool {
        guard !ranges.isEmpty, ranges.count == strings.count, let storage = textStorage else { return false }
        let order = ranges.indices.sorted { ranges[$0].location < ranges[$1].location }
        let sortedRanges = order.map { ranges[$0] }
        let sortedStrings = order.map { strings[$0] }
        // Тысячи правок по одной (4 000 значений `$` в 10 МБ) — это секунды; новый текст целиком собирается за один проход.
        if sortedRanges.count > Self.wholeTextThreshold {
            return replaceWhole(sortedRanges, with: sortedStrings, actionName: actionName)
        }
        // Отдельный шаг: не склеивается с набранным перед этим текстом.
        breakUndoCoalescing()
        guard shouldChangeText(inRanges: sortedRanges.map { NSValue(range: $0) }, replacementStrings: sortedStrings) else { return false }
        storage.beginEditing()
        for index in sortedRanges.indices.reversed() {
            storage.replaceCharacters(in: sortedRanges[index], with: sortedStrings[index])
        }
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName(actionName)
        breakUndoCoalescing()
        return true
    }
}

extension EditorTextView {
    static let wholeTextThreshold = 300

    /// Правка через замену всего текста одним куском (один шаг отмены); выделение и прокрутка сохраняются.
    fileprivate func replaceWhole(_ ranges: [NSRange], with strings: [String], actionName: String) -> Bool {
        guard let storage = textStorage else { return false }
        let text = storage.mutableString
        let result = NSMutableString(capacity: text.length)
        var cursor = 0
        for (range, string) in zip(ranges, strings) {
            guard range.location >= cursor, NSMaxRange(range) <= text.length else { return false }
            result.append(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            result.append(string)
            cursor = NSMaxRange(range)
        }
        result.append(text.substring(from: cursor))
        // Где окажется курсор: сдвиг на сумму изменений до него.
        let selection = selectedRange()
        var shift = 0
        for (range, string) in zip(ranges, strings) where NSMaxRange(range) <= selection.location {
            shift += (string as NSString).length - range.length
        }
        let origin = enclosingScrollView?.contentView.bounds.origin
        let full = NSRange(location: 0, length: text.length)
        breakUndoCoalescing()
        guard shouldChangeText(in: full, replacementString: result as String) else { return false }
        storage.beginEditing()
        storage.replaceCharacters(in: full, with: result as String)
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName(actionName)
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: min(max(0, selection.location + shift), storage.length), length: 0))
        if let scroll = enclosingScrollView, let origin {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        return true
    }
}

// MARK: - Номера строк

/// Колонка номеров строк слева от прокрутки (свой вид, а не `NSRulerView`: у линейки с macOS 26 системный «карман»
/// у края прокрутки, он залезает на панели выше). Рисуются только видимые номера; номер — из индекса строк вкладки.
final class LineNumberGutter: NSView {
    weak var tab: EditorTab?
    weak var textView: EditorTextView?
    var zoom: CGFloat = 1 { didSet { updateThickness() } }
    private(set) var thickness: CGFloat = 40
    var onThicknessChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func updateThickness() {
        let digits = max(3, String(tab?.lines.lineCount ?? 1).count)
        let width = ceil(("8" as NSString).size(withAttributes: [.font: EditorStyle.gutterFont(zoom: zoom)]).width * CGFloat(digits)) + 26
        if abs(thickness - width) > 0.5 {
            thickness = width
            onThicknessChange?(width)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Клик по номеру — выделить строку.
        guard let tab, let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inText = NSPoint(x: 0, y: point.y + (text.enclosingScrollView?.contentView.bounds.minY ?? 0) - text.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: inText, in: container)
        let char = layout.characterIndexForGlyph(at: glyph)
        let line = tab.lines.line(at: char)
        let start = tab.lines.starts[line - 1]
        let end = line < tab.lines.lineCount ? tab.lines.starts[line] : tab.storage.length
        text.window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: start, length: end - start))
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = dirtyRect.intersection(bounds)
        EditorStyle.gutter.setFill()
        rect.fill()
        DS.Palette.line.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let tab, let text = textView, let layout = text.layoutManager, let container = text.textContainer,
              let clip = text.enclosingScrollView?.contentView else { return }
        let string: NSString = text.textStorage?.mutableString ?? ""
        let visible = text.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: 0, dy: -text.textContainerOrigin.y), in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let lines = tab.lines
        let caretLine = lines.line(at: min(text.selectedRange().location, string.length))
        let font = EditorStyle.gutterFont(zoom: zoom)
        let shift = text.textContainerOrigin.y - clip.bounds.minY
        var line = lines.line(at: chars.location)
        while line <= lines.lineCount {
            let start = lines.starts[line - 1]
            if start > NSMaxRange(chars) { break }
            let fragment: NSRect
            if start >= string.length {
                fragment = layout.extraLineFragmentRect
                if fragment.height == 0 { break }
            } else {
                fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let y = fragment.minY + shift
            if y > rect.maxY { break }
            if y + fragment.height >= rect.minY {
                let color = line == caretLine ? EditorStyle.text : EditorStyle.faint
                let label = "\(line)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = label.size(withAttributes: attributes)
                let height = min(fragment.height, EditorStyle.lineHeight * zoom)
                label.draw(at: NSPoint(x: bounds.maxX - 10 - size.width, y: y + max(0, (height - size.height) / 2)), withAttributes: attributes)
                if tab.bookmarks.contains(line) {
                    DS.Palette.blue.setFill()
                    NSBezierPath(ovalIn: NSRect(x: 4, y: y + height / 2 - 3, width: 6, height: 6)).fill()
                }
            }
            line += 1
        }
    }
}

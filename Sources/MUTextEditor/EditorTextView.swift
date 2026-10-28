import AppKit
import MUCore
import MUDesign

/// Цвета и шрифт редактора. Синтаксис приглушён, чтобы выделялись знаки `$` (макет a).
package enum EditorStyle {
    package static let fontSize: CGFloat = 12.5
    package static let lineHeight: CGFloat = 19.5
    package static let zoomRange: ClosedRange<CGFloat> = 0.5...3

    /// Без лигатур и контекстных замен: в исходнике `->` и `!=` должны оставаться как набраны, и строки в десятки
    /// тысяч символов раскладываются быстрее.
    package static func font(zoom: CGFloat) -> NSFont {
        let base = NSFont(name: "JetBrainsMonoRoman-Medium", size: fontSize * zoom)
            ?? .monospacedSystemFont(ofSize: fontSize * zoom, weight: .medium)
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
        ]
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    package static func gutterFont(zoom: CGFloat) -> NSFont {
        NSFont(name: "JetBrainsMonoRoman-Medium", size: 11 * zoom) ?? .monospacedDigitSystemFont(ofSize: 11 * zoom, weight: .medium)
    }

    package static let text = DS.Palette.text
    package static let faint = DS.color(dark: 0x5D6673, light: 0xA0A7B0)
    package static let control = DS.color(dark: 0x8FA6C8, light: 0x44618C)
    package static let brace = DS.color(dark: 0x7C8594, light: 0x7A838F)
    package static let escape = DS.color(dark: 0xE0A867, light: 0x9A5B00)
    package static let string = DS.color(dark: 0xA8D27A, light: 0x3F7A12)
    package static let number = DS.color(dark: 0xE0A867, light: 0x9A5B00)
    package static let keyword = DS.color(dark: 0xB79BFF, light: 0x7A4FE0)
    package static let comment = DS.color(dark: 0x6B7480, light: 0x8A929C)
    package static let currentLine = DS.color(dark: 0x1C2026, light: 0xF3F5EF)
    /// Невидимые символы (·, →, ¶, ¤) — бледнее текста, но различимы в обеих темах.
    package static let invisible = DS.color(dark: 0x4A525E, light: 0xB4BAC2)
    /// Парная скобка у курсора и скобка без пары.
    package static let bracketFill = NSColor(name: nil) { DS.rgb(0xC8F05A, alpha: DS.isDark($0) ? 0.3 : 0.45) }
    package static let bracketUnmatched = NSColor(name: nil) { DS.rgb(DS.isDark($0) ? 0xFF7A6B : 0xD03A2B, alpha: 0.35) }
    package static let gutter = DS.color(dark: 0x14171B, light: 0xF8F9F6)

    /// Шесть оттенков знаков `$` (тёмная / светлая тема; кандидаты в `DS.Palette.mark1…6`) и нейтральный — для пустых значений.
    private static let huePairs: [(dark: UInt32, light: UInt32)] = [
        (0xC8F05A, 0x4F7A00), (0x6EA8FF, 0x1F6FDB), (0xF5B83D, 0xA86400),
        (0xFF7A6B, 0xD03A2B), (0xB79BFF, 0x7A4FE0), (0x4FD8C4, 0x0E8577),
    ]
    private static let neutralPair: (dark: UInt32, light: UInt32) = (0x9AA3AF, 0x59626E)
    package static let hueCount = huePairs.count

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

    package static func hue(_ index: Int?) -> NSColor { hueColors[index.map { $0 % huePairs.count } ?? huePairs.count] }

    package static func hueFill(_ index: Int?, selected: Bool = false) -> NSColor {
        fillColors[selected ? 1 : 0][index.map { $0 % huePairs.count } ?? huePairs.count]
    }

    package static let match = DS.color(dark: 0xC8F05A, light: 0xC8F05A)
    package static let matchFill = NSColor(name: nil) { appearance in
        DS.rgb(0xC8F05A, alpha: DS.isDark(appearance) ? 0.22 : 0.3)
    }
}

/// Текст редактора: TextKit 1 (на 10 МБ предсказуемее TextKit 2), все автозамены выключены — исходник RTF не портится.
package final class EditorTextView: NSTextView {
    /// Перевод строки, который вставляет Enter (как в документе).
    package var lineBreak = "\n"
    /// Режим замены (Insert): набранный символ заменяет следующий.
    package var overwrite = false {
        didSet { if overwrite != oldValue { onOverwriteChange?(overwrite); updateInsertionPointStateAndRestartTimer(true) } }
    }
    package var onOverwriteChange: ((Bool) -> Void)?
    /// Файлы, брошенные на текст, открываются вкладками, а не вставляются путём.
    package var onFileDrop: (([URL]) -> Void)?
    package var highlightsCurrentLine = true

    package static func make() -> (scroll: NSScrollView, text: EditorTextView) {
        let storage = NSTextStorage()
        let layout = EditorLayoutManager()
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
    package func setWraps(_ wraps: Bool) {
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
    package override func prepareContent(in rect: NSRect) {
        let visible = visibleRect
        guard visible.height > 0 else { return super.prepareContent(in: rect) }
        let limit = visible.insetBy(dx: -visible.width / 2, dy: -visible.height / 4)
        let limited = rect.intersection(limit)
        super.prepareContent(in: limited.isEmpty ? visible : limited)
    }

    // MARK: - Ввод

    private var isInsertingBreak = false

    package override func insertNewline(_ sender: Any?) {
        isInsertingBreak = true
        defer { isInsertingBreak = false }
        insertText(lineBreak, replacementRange: selectedRange())
    }

    package override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }

    // MARK: - Несколько выделений и курсоров

    /// Дополнительные курсоры (кроме выделения `NSTextView`, которое пустым бывает только одно). Появляются после ввода
    /// в прямоугольное выделение (⌥ + перетаскивание) и по ⌘-клику / ⌃⇧↑↓.
    package private(set) var extraCarets: [Int] = []
    /// Курсоров и выделений всего (для строки состояния).
    package var cursorCount: Int { selectedRanges.count + extraCarets.count }
    package var onCursorsChange: (() -> Void)?
    private var keepingCarets = false

    /// Все места правки: выделения и дополнительные курсоры, по возрастанию, без пересечений.
    package var editTargets: [NSRange] {
        let ranges = selectedRanges.map(\.rangeValue) + extraCarets.map { NSRange(location: $0, length: 0) }
        var result: [NSRange] = []
        for range in ranges.sorted(by: { ($0.location, $0.length) < ($1.location, $1.length) }) {
            if let last = result.last {
                // Тот же курсор дважды или курсор в начале выделения — одно место.
                if range.length == 0, range.location == last.location { continue }
                if range.location < NSMaxRange(last) {
                    result[result.count - 1] = NSUnionRange(last, range)
                    continue
                }
            }
            result.append(range)
        }
        return result
    }

    package var hasMultipleTargets: Bool { editTargets.count > 1 }

    /// Поставить курсоры: первый — выделение `NSTextView`, остальные — дополнительные.
    package func setCarets(_ positions: [Int]) {
        let length = textStorage?.length ?? 0
        let sorted = Array(Set(positions.map { min(max($0, 0), length) })).sorted()
        guard let first = sorted.first else { return }
        keepingCarets = true
        setSelectedRange(NSRange(location: first, length: 0))
        keepingCarets = false
        extraCarets = Array(sorted.dropFirst())
        needsDisplay = true
        onCursorsChange?()
    }

    package func clearExtraCarets() {
        guard !extraCarets.isEmpty || selectedRanges.count > 1 else { return }
        extraCarets = []
        keepingCarets = true
        setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        keepingCarets = false
        needsDisplay = true
        onCursorsChange?()
    }

    /// Каждой цели — своя строка замены; один шаг отмены, затем курсор за каждой вставкой.
    private func editAll(_ make: (NSRange) -> (range: NSRange, string: String)?) {
        let edits = editTargets.compactMap(make).filter { $0.range.length > 0 || !$0.string.isEmpty }
        guard !edits.isEmpty else { return Feedback.beep() }
        guard replace(edits.map(\.range), with: edits.map(\.string), actionName: "Ввод") else { return }
        var shift = 0
        var carets: [Int] = []
        for edit in edits {
            let inserted = (edit.string as NSString).length
            carets.append(edit.range.location + shift + inserted)
            shift += inserted - edit.range.length
        }
        setCarets(carets)
    }

    /// ⌘-клик: курсор в точке клика добавляется к остальным (клик по уже стоящему курсору его убирает).
    package override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, event.clickCount == 1 else { return super.mouseDown(with: event) }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        var positions = editTargets.map { $0.length == 0 ? $0.location : NSMaxRange($0) }
        if positions.count > 1, let existing = positions.firstIndex(of: index) {
            positions.remove(at: existing)
        } else {
            positions.append(index)
        }
        window?.makeFirstResponder(self)
        setCarets(positions)
    }

    /// ⌃⇧↑ / ⌃⇧↓: ещё курсор строкой выше (над самым верхним) или ниже (под самым нижним), в том же столбце.
    package func addCaret(lineOffset: Int) {
        guard let text = textStorage?.mutableString else { return }
        let positions = editTargets.map { $0.length == 0 ? $0.location : NSMaxRange($0) }
        guard let from = lineOffset < 0 ? positions.min() : positions.max() else { return }
        let line = LineCommands.lineBlock(text, NSRange(location: from, length: 0))
        let column = from - line.location
        let target: NSRange
        if lineOffset < 0 {
            guard line.location > 0 else { return Feedback.beep() }
            target = LineCommands.lineBlock(text, NSRange(location: line.location - 1, length: 0))
        } else {
            guard NSMaxRange(line) < text.length || (NSMaxRange(line) == text.length && line.length > 0
                  && LineCommands.isBreak(text.character(at: NSMaxRange(line) - 1))) else { return Feedback.beep() }
            target = LineCommands.lineBlock(text, NSRange(location: NSMaxRange(line), length: 0))
        }
        var body = target.length
        while body > 0, LineCommands.isBreak(text.character(at: target.location + body - 1)) { body -= 1 }
        setCarets(positions + [target.location + min(column, body)])
        scrollRangeToVisible(NSRange(location: target.location + min(column, body), length: 0))
    }

    /// ← → при нескольких курсорах двигают все (↑ ↓ и остальное — снова один курсор).
    package override func moveLeft(_ sender: Any?) { moveCarets(by: -1) { super.moveLeft(sender) } }
    package override func moveRight(_ sender: Any?) { moveCarets(by: 1) { super.moveRight(sender) } }

    private func moveCarets(by step: Int, single: () -> Void) {
        guard !extraCarets.isEmpty, let text = textStorage?.mutableString else { return single() }
        let positions = editTargets.map { range -> Int in
            if range.length > 0 { return step < 0 ? range.location : NSMaxRange(range) }
            if step < 0 { return range.location > 0 ? text.rangeOfComposedCharacterSequence(at: range.location - 1).location : 0 }
            return range.location < text.length ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: range.location)) : text.length
        }
        setCarets(positions)
    }

    private func insertEverywhere(_ typed: String) {
        editAll { ($0, typed) }
    }

    package override func deleteBackward(_ sender: Any?) {
        guard hasMultipleTargets, let text = textStorage?.mutableString else { return super.deleteBackward(sender) }
        // Пустой курсор удаляет символ перед собой, но не перевод строки (столбец не склеивает строки).
        editAll { range in
            if range.length > 0 { return (range, "") }
            guard range.location > 0, !LineCommands.isBreak(text.character(at: range.location - 1)) else { return nil }
            return (text.rangeOfComposedCharacterSequence(at: range.location - 1), "")
        }
    }

    package override func deleteForward(_ sender: Any?) {
        guard hasMultipleTargets, let text = textStorage?.mutableString else { return super.deleteForward(sender) }
        editAll { range in
            if range.length > 0 { return (range, "") }
            guard range.location < text.length, !LineCommands.isBreak(text.character(at: range.location)) else { return nil }
            return (text.rangeOfComposedCharacterSequence(at: range.location), "")
        }
    }

    package override func insertText(_ string: Any, replacementRange: NSRange) {
        if hasMultipleTargets, !hasMarkedText(), replacementRange.location == NSNotFound || isInsertingBreak,
           let typed = (string as? String) ?? (string as? NSAttributedString)?.string {
            insertEverywhere(typed)
            return
        }
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
    package var onSwitchTab: ((Int) -> Void)?
    package var onEscape: (() -> Void)?

    package override func keyDown(with event: NSEvent) {
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

    /// Esc: несколько курсоров — снова один; иначе закрыть панель поиска. Список автодополнения слов не открывается.
    package override func cancelOperation(_ sender: Any?) {
        if hasMultipleTargets { return clearExtraCarets() }
        onEscape?()
    }

    /// Дополнительные курсоры рисуем сами: `NSTextView` рисует только один.
    package override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !extraCarets.isEmpty, let layout = layoutManager, let container = textContainer else { return }
        insertionPointColor.setFill()
        let length = textStorage?.length ?? 0
        for caret in extraCarets where caret <= length {
            let glyph = layout.glyphIndexForCharacter(at: min(caret, max(0, length - 1)))
            var rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: caret < length ? 1 : 0), in: container)
            if caret >= length, length > 0 { rect.origin.x = rect.maxX }
            let line = NSRect(x: rect.minX + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y, width: 1.5, height: max(rect.height, 14))
            if line.intersects(dirtyRect) { line.fill() }
        }
    }

    /// В режиме замены — курсор-блок шириной в символ.
    package override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
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

    package override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = rect
        if overwrite { rect.size.width += 12 }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    // MARK: - Текущая строка

    /// Где нарисована подсветка текущей строки — чтобы перерисовать это место, не раскладывая строку заново.
    private var drawnLineRect: NSRect?

    package override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightsCurrentLine, let lineRect = currentLineRect() else { drawnLineRect = nil; return }
        drawnLineRect = lineRect
        EditorStyle.currentLine.setFill()
        lineRect.intersection(rect).fill()
    }

    /// Прямоугольник логической строки с курсором (все её отрезки при переносе) на всю ширину.
    package func currentLineRect() -> NSRect? {
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

    package override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        // Любой другой переход (клик, стрелки, поиск) — снова один курсор.
        if !keepingCarets, !extraCarets.isEmpty {
            extraCarets = []
            needsDisplay = true
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !keepingCarets { onCursorsChange?() }
        guard highlightsCurrentLine else { return }
        if let old = drawnLineRect { setNeedsDisplay(old) }
        if let new = currentLineRect(), new != drawnLineRect { setNeedsDisplay(new) }
    }

    // MARK: - Перетаскивание файлов

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    package override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    package override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    package override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty, let onFileDrop else { return super.performDragOperation(sender) }
        onFileDrop(urls)
        return true
    }

    // MARK: - Правка несколькими диапазонами — один шаг отмены

    /// Заменяет непересекающиеся диапазоны одной правкой: один шаг Cmd+Z. Диапазоны — в координатах текста до правки.
    @discardableResult
    package func replace(_ ranges: [NSRange], with strings: [String], actionName: String) -> Bool {
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
    package static let wholeTextThreshold = 300

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
package final class LineNumberGutter: NSView {
    package weak var tab: EditorTab?
    package weak var textView: EditorTextView?
    package var zoom: CGFloat = 1 { didSet { updateThickness() } }
    package private(set) var thickness: CGFloat = 40
    package var onThicknessChange: ((CGFloat) -> Void)?

    package override var isFlipped: Bool { true }

    package override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package func updateThickness() {
        let digits = max(3, String(tab?.lines.lineCount ?? 1).count)
        let width = ceil(("8" as NSString).size(withAttributes: [.font: EditorStyle.gutterFont(zoom: zoom)]).width * CGFloat(digits)) + 26
        if abs(thickness - width) > 0.5 {
            thickness = width
            onThicknessChange?(width)
        }
    }

    package override func mouseDown(with event: NSEvent) {
        // Клик по номеру — выделить строку.
        guard let tab, let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inText = NSPoint(x: 0, y: point.y + (text.enclosingScrollView?.contentView.bounds.minY ?? 0) - text.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: inText, in: container)
        let char = layout.characterIndexForGlyph(at: glyph)
        var line = tab.lines.line(at: char)
        // Под последней строкой (пустая строка после перевода) — она же.
        if char == tab.storage.length, layout.extraLineFragmentRect.height > 0, inText.y >= layout.extraLineFragmentRect.minY {
            line = tab.lines.lineCount
        }
        // Левая полоса колонки — закладка, остальное — выделить строку.
        if point.x < 14 {
            tab.toggleBookmark(line: line)
            return
        }
        let start = tab.lines.starts[line - 1]
        let end = line < tab.lines.lineCount ? tab.lines.starts[line] : tab.storage.length
        text.window?.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: start, length: end - start))
    }

    package override func draw(_ dirtyRect: NSRect) {
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

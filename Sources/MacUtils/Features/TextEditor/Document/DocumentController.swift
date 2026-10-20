import AppKit
import Combine

/// Режим вкладки: исходник или документ (только для RTF).
enum EditorViewMode: String, Codable, CaseIterable {
    case code, document
}

/// Что показывает панель форматирования про выделение (смешанное — `nil`).
struct DocSelectionInfo: Equatable {
    var fontName: String?
    var displayFont: String?
    var halfPoints: Int?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var strike: Bool?
    var alignment: RTFAlignment?
    var paragraph: RTFParaProps?
    var inTable = false
    var inObject = false
}

/// Режим «Документ» одной вкладки. Исходник — тот же текст вкладки (`EditorTab.storage`), отмена общая с режимом «Код».
/// Показ — свой: модель `RTFReader` → `DocRenderer` → страницы TextKit 1; после правки исходника перерисовываются только
/// изменившиеся абзацы.
@MainActor
final class DocumentController: NSObject, ObservableObject, NSLayoutManagerDelegate, NSTextViewDelegate {
    weak var tab: EditorTab?
    let storage = NSTextStorage()
    let layoutManager = DocLayoutManager()
    let renderer = DocRenderer()
    let pagesView = DocPagesView()
    let scrollView = NSScrollView()
    private(set) var model = RTFDocumentModel()
    private(set) var rendering = DocRendering()
    private var renderedVersion = -1
    private var refreshScheduled = false
    private var headerCache: [String: NSAttributedString] = [:]
    private var highlighted = false
    private var observers: [NSObjectProtocol] = []

    @Published private(set) var pageCount = 1
    @Published private(set) var currentPage = 1
    @Published private(set) var currentSection = 1
    @Published private(set) var wordCount = 0
    @Published private(set) var selection = DocSelectionInfo()

    enum Fit: String { case none, width, page }
    @Published var fit = Fit.none { didSet { applyZoom() } }
    @Published var zoom: CGFloat = 1 { didSet { if oldValue != zoom { applyZoom() } } }
    static let zoomRange: ClosedRange<CGFloat> = 0.5...2

    @Published var showsInvisibles = false {
        didSet {
            guard showsInvisibles != oldValue else { return }
            layoutManager.showsInvisibles = showsInvisibles
            renderer.showsHidden = showsInvisibles
            refresh(force: true)
        }
    }

    init(tab: EditorTab) {
        self.tab = tab
        super.init()
        storage.addLayoutManager(layoutManager)
        layoutManager.delegate = self
        layoutManager.allowsNonContiguousLayout = false
        layoutManager.unitKind = { [weak self] unit in
            guard let self, unit < self.rendering.map.count else { return nil }
            return self.rendering.map.kind(at: unit)
        }
        renderer.placeholderAction = { [weak self] action, character in self?.placeholder(action, at: character) }
        scrollView.contentView = DocCenteringClipView()
        scrollView.documentView = pagesView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DS.Palette.bg
        pagesView.wantsLayer = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = Self.zoomRange.lowerBound
        scrollView.maxMagnification = Self.zoomRange.upperBound
        scrollView.postsFrameChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.fit != Fit.none { self?.applyZoom() } }
        })
        refresh(force: true)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Текст вкладки — RTF, который можно показать документом.
    static func canShow(_ text: NSString) -> Bool {
        var index = 0
        while index < min(text.length, 64), [0x20, 0x09, 0x0A, 0x0D, 0xFEFF].contains(text.character(at: index)) { index += 1 }
        return text.length - index >= 5 && text.substring(with: NSRange(location: index, length: 5)) == "{\\rtf"
    }

    // MARK: - Обновление из исходника

    /// Исходник изменился (правка в коде, отмена, «Убрать значения») — перерисовать в конце прохода цикла событий.
    func sourceDidChange() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
    }

    /// Перечитать исходник и поправить показ. `select` — показанное выделение после правки (иначе — прежнее место).
    func refresh(force: Bool = false, select: ((DocRendering) -> NSRange)? = nil) {
        guard let tab else { return }
        guard force || tab.sourceRevision != renderedVersion else { return }
        renderedVersion = tab.sourceRevision
        // Выделение — через исходник: после правки до него единицы сдвинулись.
        let oldSelection = textViews.first?.selectedRange() ?? NSRange(location: 0, length: 0)
        let sourceStart = rendering.map.sourceLocation(beforeUnit: oldSelection.location)
        let sourceEnd = rendering.map.sourceLocation(beforeUnit: NSMaxRange(oldSelection))
        let fresh = RTFReader.read(tab.text, fallback: tab.document.encoding)
        renderer.contentWidth = DocPageView.bodyRect(fresh.sections.first?.props ?? RTFSectionProps()).width
        // Полная перерисовка (первый показ, ¶) — весь текст заново; иначе заплатка на изменившиеся абзацы.
        let (next, patch) = renderer.render(fresh, previous: force ? nil : rendering)
        let replaced = force ? NSRange(location: 0, length: storage.length) : patch.range
        let string = patch.string
        model = fresh
        rendering = next
        headerCache = [:]
        storage.beginEditing()
        storage.replaceCharacters(in: replaced, with: string)
        storage.endEditing()
        if pagesView.pages.isEmpty { addPage(section: 0) }
        updatePageSections()
        updateHeaders()
        let target = select?(next) ?? {
            let start = next.map.unit(forSource: sourceStart)
            let end = max(start, next.map.unit(forSource: sourceEnd))
            return NSRange(location: min(start, storage.length), length: min(end, storage.length) - min(start, storage.length))
        }()
        if let view = textViews.first {
            let location = min(target.location, storage.length)
            view.setSelectedRange(NSRange(location: location, length: min(target.length, storage.length - location)))
        }
        wordCount = Self.words(fresh.body)
        highlightDollars()
        updateStatus()
    }

    static func words(_ story: RTFStory) -> Int {
        var count = 0
        var inWord = false
        for paragraph in story.paragraphs {
            for run in paragraph.runs where !run.props.hidden && (run.kind == .text) {
                for scalar in run.text.unicodeScalars {
                    let letter = !scalar.properties.isWhitespace
                    if letter, !inWord { count += 1 }
                    inWord = letter
                }
            }
            inWord = false
        }
        return count
    }

    // MARK: - Страницы

    var textViews: [DocTextView] { pagesView.pages.map(\.textView) }

    private func addPage(section: Int) {
        let props = section < model.sections.count ? model.sections[section].props : (model.sections.first?.props ?? RTFSectionProps())
        let page = DocPageView(props: props, section: section)
        page.textView.delegate = self
        page.textView.isEditable = false
        page.textView.isSelectable = true
        page.textView.onDoubleClickOutside = { [weak self, weak page] event in
            guard let self, let page else { return false }
            return self.doubleClick(event, on: page)
        }
        page.number = pagesView.pages.count + 1
        pagesView.append(page)
        if pageCount != pagesView.pages.count { pageCount = pagesView.pages.count }
        layoutManager.addTextContainer(page.container)
    }

    nonisolated func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor container: NSTextContainer?, atEnd: Bool) {
        MainActor.assumeIsolated { completedLayout(container, atEnd: atEnd) }
    }

    private func completedLayout(_ container: NSTextContainer?, atEnd: Bool) {
        let containers = layoutManager.textContainers
        guard let container, let index = containers.firstIndex(where: { $0 === container }) else {
            if containers.isEmpty { addPage(section: 0) }
            return
        }
        if !atEnd, index == containers.count - 1 {
            // Текст не поместился — следующая страница: её раздел — у следующего символа.
            let glyphs = layoutManager.glyphRange(for: container)
            let next = NSMaxRange(layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            addPage(section: rendering.section(atUnit: next))
        } else if atEnd {
            // Лишние страницы, разделы и колонтитулы — после прохода: раскладка бывает и во время рисования страниц.
            let keep = index + 1
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.finishPagination(keeping: keep) }
            }
        }
    }

    private func finishPagination(keeping count: Int) {
        guard count >= 1, count <= pagesView.pages.count else { return }
        // Раскладка могла продвинуться дальше — убираем только то, что так и осталось пустым.
        if count < pagesView.pages.count {
            let lastUsed = pagesView.pages.lastIndex { layoutManager.glyphRange(for: $0.container).length > 0 } ?? 0
            if lastUsed + 1 < pagesView.pages.count { pagesView.removePages(from: max(count, lastUsed + 1)) }
        }
        if pageCount != pagesView.pages.count { pageCount = pagesView.pages.count }
        updatePageSections()
        updateHeaders()
    }

    /// Раздел каждой страницы — по её первому символу; размер страницы — из раздела.
    private func updatePageSections() {
        var previousSection = -1
        for (index, page) in pagesView.pages.enumerated() {
            let glyphs = layoutManager.glyphRange(for: page.container)
            let first = glyphs.length > 0 ? layoutManager.characterIndexForGlyph(at: glyphs.location) : storage.length
            let section = min(rendering.section(atUnit: first), max(0, model.sections.count - 1))
            if section < model.sections.count { page.update(props: model.sections[section].props, section: section) }
            page.number = index + 1
            page.firstInSection = section != previousSection
            previousSection = section
        }
        pagesView.layoutPages()
        if pageCount != pagesView.pages.count { pageCount = pagesView.pages.count }
    }

    // MARK: - Колонтитулы

    /// Колонтитул страницы: первая страница раздела при `\titlepg`, чётные/нечётные при `\facingp`, иначе общий.
    func headerKind(for page: DocPageView, header: Bool) -> RTFHeaderKind? {
        guard page.section < model.sections.count else { return nil }
        let section = model.sections[page.section]
        let available = headers(of: page.section)
        if section.props.titlePage, page.firstInSection { return RTFHeaderKind.kind(header: header, page: .first) }
        if model.facingPages {
            let kind = RTFHeaderKind.kind(header: header, page: page.number % 2 == 0 ? .even : .odd)
            if available[kind] != nil { return kind }
        }
        for kind in [RTFHeaderKind.kind(header: header, page: .all), RTFHeaderKind.kind(header: header, page: .odd), RTFHeaderKind.kind(header: header, page: .even)]
        where available[kind] != nil {
            return kind
        }
        return nil
    }

    /// Колонтитулы раздела; которых в нём нет — от предыдущего раздела («как в предыдущем», как в Word).
    func headers(of section: Int) -> [RTFHeaderKind: RTFHeader] {
        var result: [RTFHeaderKind: RTFHeader] = [:]
        var index = min(section, model.sections.count - 1)
        while index >= 0 {
            for (kind, header) in model.sections[index].headers where result[kind] == nil { result[kind] = header }
            index -= 1
        }
        return result
    }

    private func updateHeaders() {
        let total = pagesView.pages.count
        var sectionPages: [Int: Int] = [:]
        for page in pagesView.pages { sectionPages[page.section, default: 0] += 1 }
        for page in pagesView.pages {
            page.header = headerString(page, header: true, total: total, sectionTotal: sectionPages[page.section] ?? 1)
            page.footer = headerString(page, header: false, total: total, sectionTotal: sectionPages[page.section] ?? 1)
        }
    }

    private func headerString(_ page: DocPageView, header: Bool, total: Int, sectionTotal: Int) -> NSAttributedString? {
        guard let kind = headerKind(for: page, header: header), let story = headers(of: page.section)[kind]?.story else { return nil }
        let key = "\(page.section)-\(kind.rawValue)-\(page.number)-\(total)-\(sectionTotal)"
        if let cached = headerCache[key] { return cached }
        let (string, _) = renderer.renderStory(story, model: model) { field in
            switch field {
            case .page: return "\(page.number)"
            case .numPages: return "\(total)"
            case .sectionPages: return "\(sectionTotal)"
            case .other: return nil
            }
        }
        headerCache[key] = string
        return string
    }

    /// Двойной клик по полю страницы — правка колонтитула (D-4а); пока — нет.
    func doubleClick(_ event: NSEvent, on page: DocPageView) -> Bool { false }

    // MARK: - Знаки $

    /// Подсветка `$` на страницах: видимая часть диапазона значения (по окончательному правилу — до конца строки исходника).
    func highlightDollars() {
        guard let tab else { return }
        let full = NSRange(location: 0, length: storage.length)
        let keys: [NSAttributedString.Key] = [.backgroundColor, .underlineStyle, .underlineColor, .foregroundColor]
        if highlighted { for key in keys { layoutManager.removeTemporaryAttribute(key, forCharacterRange: full) } }
        highlighted = false
        guard storage.length > 0, tab.dollars.isCurrent || !tab.dollars.entries.isEmpty else { return }
        let skip = max(tab.dollars.skip ?? 0, 0)
        let map = rendering.map
        for entry in tab.dollars.entries where !entry.isHidden {
            let mark = entry.mark
            let dollar = map.unit(forSource: mark.dollar)
            guard dollar < map.count, map.range(at: dollar) == NSRange(location: mark.dollar, length: 1) else { continue }
            let parts = mark.parts.flatMap { map.units(inside: $0) }.filter { NSMaxRange($0) <= storage.length }
            let order = entry.order ?? 0
            if order < skip {
                let faint: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1),
                    .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                ]
                for range in [NSRange(location: dollar, length: 1)] + parts { layoutManager.addTemporaryAttributes(faint, forCharacterRange: range) }
            } else {
                let selected = tab.dollars.selected == mark.dollar
                let fill = EditorStyle.hueFill(entry.hue, selected: selected)
                layoutManager.addTemporaryAttributes([.foregroundColor: EditorStyle.hue(entry.hue), .backgroundColor: fill],
                                                     forCharacterRange: NSRange(location: dollar, length: 1))
                for range in parts {
                    layoutManager.addTemporaryAttributes([
                        .backgroundColor: fill, .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: EditorStyle.hue(entry.hue),
                    ], forCharacterRange: range)
                }
            }
            highlighted = true
        }
    }

    /// Значение знака так, как его видно на странице (для панели «$» в «Документе»); `nil` — знака не видно.
    func visibleValue(of mark: DollarMark) -> String? {
        let map = rendering.map
        let dollar = map.unit(forSource: mark.dollar)
        guard dollar < map.count, map.range(at: dollar).location == mark.dollar else { return nil }
        let text = storage.mutableString
        let value = mark.parts.flatMap { map.units(inside: $0) }.filter { NSMaxRange($0) <= text.length }
            .map { text.substring(with: $0) }.joined()
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Номер страницы, на которой стоит место исходника (для строк панели «$»); `nil` — не видно на странице.
    func page(ofSource location: Int) -> Int? {
        let unit = rendering.map.unit(forSource: location)
        guard unit < rendering.map.count, NSLocationInRange(location, rendering.map.range(at: unit)) else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: unit)
        guard let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return nil }
        return pagesView.pages.firstIndex { $0.container === container }.map { $0 + 1 }
    }

    // MARK: - Выделение и переходы

    /// Выделение документа → кусок исходника (для перехода в «Код»).
    var sourceSelection: NSRange {
        let selection = textViews.first?.selectedRange() ?? NSRange(location: 0, length: 0)
        if selection.length == 0 {
            return NSRange(location: rendering.map.sourceLocation(beforeUnit: selection.location), length: 0)
        }
        return rendering.map.sourceRange(ofUnits: selection)
    }

    /// Выделение исходника → ближайшие видимые символы (переход из «Кода»).
    func select(source range: NSRange, reveal: Bool = true) {
        let start = rendering.map.unit(forSource: range.location)
        let end = range.length > 0 ? max(start, rendering.map.firstUnit(atOrAfter: NSMaxRange(range))) : start
        let location = min(start, storage.length)
        let target = NSRange(location: location, length: min(end, storage.length) - location)
        guard let view = textView(forUnit: target.location) ?? textViews.first else { return }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(target)
        if reveal { self.reveal(target) }
    }

    /// Прокрутить к показанным единицам (и коротко подсветить).
    func reveal(_ range: NSRange, flash: Bool = false) {
        guard let view = textView(forUnit: range.location) else { return }
        view.scrollRangeToVisible(range)
        if flash { view.showFindIndicator(for: range) }
    }

    func textView(forUnit unit: Int) -> DocTextView? {
        guard storage.length > 0 else { return textViews.first }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(unit, storage.length - 1))
        guard let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return textViews.first }
        return pagesView.pages.first { $0.container === container }?.textView
    }

    /// Первый видимый символ сверху — для синхронизации прокрутки с «Кодом».
    var topSourceLocation: Int {
        let visible = scrollView.contentView.documentVisibleRect
        for page in pagesView.pages where page.frame.maxY > visible.minY {
            let point = page.textView.convert(NSPoint(x: 0, y: max(0, visible.minY - page.frame.minY - page.bodyRect.minY)), from: page)
            let glyph = layoutManager.glyphIndex(for: point, in: page.container)
            let unit = layoutManager.characterIndexForGlyph(at: glyph)
            return rendering.map.sourceLocation(beforeUnit: unit)
        }
        return 0
    }

    /// Поставить место исходника наверх видимой части.
    func scrollToSource(_ location: Int) {
        let unit = min(rendering.map.unit(forSource: location), max(0, storage.length - 1))
        guard storage.length > 0, let view = textView(forUnit: unit), let page = view.page else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: unit)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = page.frame.minY + page.bodyRect.minY + line.minY - 12
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    nonisolated func textViewDidChangeSelection(_ notification: Notification) {
        MainActor.assumeIsolated { updateStatus() }
    }

    nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { tab?.undo }
    }

    /// Страница, раздел и свойства у курсора — строке состояния и панели форматирования.
    func updateStatus() {
        let selection = textViews.first?.selectedRange() ?? NSRange(location: 0, length: 0)
        if let view = textView(forUnit: selection.location), let page = view.page,
           let index = pagesView.pages.firstIndex(where: { $0 === page }) {
            if currentPage != index + 1 { currentPage = index + 1 }
            if currentSection != page.section + 1 { currentSection = page.section + 1 }
        }
        let info = selectionInfo(selection)
        if info != self.selection { self.selection = info }
    }

    private func selectionInfo(_ selection: NSRange) -> DocSelectionInfo {
        var info = DocSelectionInfo()
        guard storage.length > 0 else { return info }
        let range = selection.length > 0 ? selection : NSRange(location: max(0, min(selection.location, storage.length) - 1), length: 1)
        var chars: [DocCharInfo] = []
        storage.enumerateAttribute(.docChar, in: NSIntersectionRange(range, NSRange(location: 0, length: storage.length))) { value, _, stop in
            if let value = value as? DocCharInfo { chars.append(value) }
            if chars.count > 400 { stop.pointee = true }
        }
        func same<T: Equatable>(_ values: [T]) -> T? { values.allSatisfy { $0 == values.first } ? values.first : nil }
        info.fontName = same(chars.map(\.fontName))
        info.displayFont = same(chars.map(\.displayFont))
        info.halfPoints = same(chars.map(\.props.halfPoints))
        info.bold = same(chars.map(\.props.bold))
        info.italic = same(chars.map(\.props.italic))
        info.underline = same(chars.map { $0.props.underline != .none })
        info.strike = same(chars.map(\.props.strike))
        let location = min(selection.location, storage.length - 1)
        let para = storage.attribute(.docPara, at: max(0, location), effectiveRange: nil) as? DocParaInfo
        info.paragraph = para?.props
        info.alignment = para?.props.alignment
        info.inTable = para?.props.inTable ?? false
        if selection.length <= 1, location < rendering.map.count { info.inObject = rendering.map.kind(at: location) == .object }
        return info
    }

    // MARK: - Масштаб

    /// Шаги масштаба (⌘+ / ⌘−), как в Word.
    static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    func step(zoom direction: Int) {
        fit = .none
        let current = zoom
        let next = direction > 0 ? Self.zoomSteps.first { $0 > current + 0.001 } : Self.zoomSteps.last { $0 < current - 0.001 }
        zoom = next ?? current
    }

    private func applyZoom() {
        let clip = scrollView.contentView.bounds.size
        let page = pagesView.pages.first.map { $0.frame.size } ?? NSSize(width: 595, height: 842)
        let viewSize = scrollView.frame.size
        var magnification = zoom
        switch fit {
        case .none: break
        case .width: magnification = (viewSize.width - 2 * DocPagesView.gap - 16) / max(page.width, 1)
        case .page: magnification = min((viewSize.width - 2 * DocPagesView.gap) / max(page.width, 1),
                                        (viewSize.height - 2 * DocPagesView.gap) / max(page.height, 1))
        }
        _ = clip
        magnification = min(max(magnification, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        if abs(scrollView.magnification - magnification) > 0.001 { scrollView.magnification = magnification }
        if fit != .none, abs(zoom - magnification) > 0.001 { zoom = magnification }
    }

    // MARK: - Заглушки

    private func placeholder(_ action: DocPlaceholderCell.Action, at character: Int) {
        guard character < rendering.map.count else { return }
        let group = rendering.map.range(at: character)
        switch action {
        case .showInCode:
            tab?.showInCode(group)
        case .openInWord:
            EditorWindowController.shared.openInWord(tab)
        }
    }
}

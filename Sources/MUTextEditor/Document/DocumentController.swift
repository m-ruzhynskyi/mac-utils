import AppKit
import Combine
import MUCore
import MUDesign

/// Режим вкладки: исходник или документ (только для RTF).
package enum EditorViewMode: String, Codable, CaseIterable {
    case code, document
}

/// Точечная правка исходника: кусок `range` (в координатах исходника до правки) заменяется на `text`.
package struct DocEdit: Equatable {
    package var range: NSRange
    package var text: String
}

/// Что показывает панель форматирования про выделение (смешанное — `nil`).
package struct DocSelectionInfo: Equatable {
    package var fontName: String?
    package var displayFont: String?
    package var halfPoints: Int?
    package var bold: Bool?
    package var italic: Bool?
    package var underline: Bool?
    package var strike: Bool?
    package var alignment: RTFAlignment?
    package var paragraph: RTFParaProps?
    package var inTable = false
    package var inObject = false
}

/// Режим «Документ» одной вкладки. Исходник — тот же текст вкладки (`EditorTab.storage`), отмена общая с режимом «Код».
/// Показ — свой: модель `RTFReader` → `DocRenderer` → страницы TextKit 1; после правки исходника перерисовываются только
/// изменившиеся абзацы.
@MainActor
package final class DocumentController: NSObject, ObservableObject, NSLayoutManagerDelegate, NSTextViewDelegate {
    package weak var tab: EditorTab?
    package let storage = NSTextStorage()
    package let layoutManager = DocLayoutManager()
    package let renderer = DocRenderer()
    package let pagesView = DocPagesView()
    /// Запасной контейнер — всегда за последней страницей, не показывается. Абзац с рамкой или заливкой (`NSTextBlock`),
    /// не уместившийся в последний контейнер, typesetter без следующего перекладывает бесконечно; с запасным — переносит
    /// туда, и по завершении страницы добавляется новая.
    private let spare: NSTextContainer = {
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        return container
    }()
    package let scrollView = NSScrollView()
    package private(set) var model = RTFDocumentModel()
    package private(set) var rendering = DocRendering()
    private var renderedVersion = -1
    private var refreshScheduled = false
    private var headerCache: [String: DocRenderer.StoryRendering] = [:]
    private var headerSignature = 0
    private var highlighted = false
    /// Совпадения поиска (показанные единицы) и текущее — `DocFind.swift`.
    package internal(set) var findMatches: [NSRange] = []
    package internal(set) var findCurrent: Int?
    /// Орфография (`DocSpelling.swift`).
    package lazy var spelling = DocSpelling(controller: self)
    private var observers: [NSObjectProtocol] = []

    @Published package private(set) var pageCount = 1
    @Published package private(set) var currentPage = 1
    @Published package private(set) var currentSection = 1
    /// Язык текста у курсора (`\lang`), для строки состояния.
    @Published package private(set) var languageName: String?
    @Published package private(set) var wordCount = 0
    @Published package private(set) var selection = DocSelectionInfo()

    package enum Fit: String { case none, width, page }
    @Published package var fit = Fit.none { didSet { applyZoom() } }
    @Published package var zoom: CGFloat = 1 { didSet { if oldValue != zoom { applyZoom() } } }
    package static let zoomRange: ClosedRange<CGFloat> = 0.5...2

    @Published package var showsInvisibles = false {
        didSet {
            guard showsInvisibles != oldValue else { return }
            layoutManager.showsInvisibles = showsInvisibles
            renderer.showsHidden = showsInvisibles
            refresh(force: true)
        }
    }

    package init(tab: EditorTab) {
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
    package nonisolated static func canShow(_ text: NSString) -> Bool {
        var index = 0
        while index < min(text.length, 64), [0x20, 0x09, 0x0A, 0x0D, 0xFEFF].contains(text.character(at: index)) { index += 1 }
        return text.length - index >= 5 && text.substring(with: NSRange(location: index, length: 5)) == "{\\rtf"
    }

    // MARK: - Обновление из исходника

    /// Исходник изменился (правка в коде, отмена, «Убрать значения») — перерисовать в конце прохода цикла событий.
    package func sourceDidChange() {
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
    package func refresh(force: Bool = false, select: ((DocRendering) -> NSRange)? = nil) {
        guard let tab else { return }
        guard force || tab.sourceRevision != renderedVersion else { return }
        renderedVersion = tab.sourceRevision
        // Выделение — через исходник: после правки до него единицы сдвинулись.
        let oldSelection = textViews.first?.selectedRange() ?? NSRange(location: 0, length: 0)
        let sourceStart = rendering.map.sourceLocation(beforeUnit: oldSelection.location)
        let sourceEnd = rendering.map.sourceLocation(beforeUnit: NSMaxRange(oldSelection))
        let fresh = RTFReader.read(tab.text, fallback: tab.document.encoding)
        // Шрифты Word (Calibri, Cambria…) — до раскладки, чтобы ширины строк были как у Word.
        WordFonts.prepare(fresh.fonts.values.map(\.name))
        renderer.contentWidth = DocPageView.bodyRect(fresh.sections.first?.props ?? RTFSectionProps()).width
        // Полная перерисовка (первый показ, ¶) — весь текст заново; иначе заплатка на изменившиеся абзацы.
        let (next, patch) = renderer.render(fresh, previous: force ? nil : rendering)
        let replaced = force ? NSRange(location: 0, length: storage.length) : patch.range
        let string = patch.string
        model = fresh
        rendering = next
        if spelling.isEnabled { spelling.schedule() }
        // Колонтитулы перерисовываются, только если изменились их группы (иначе — по кэшу).
        var hasher = Hasher()
        let source = tab.text
        hasher.combine(fresh.facingPages)
        for section in fresh.sections {
            hasher.combine(section.props)
            for (kind, header) in section.headers.sorted(by: { $0.key.rawValue < $1.key.rawValue }) where NSMaxRange(header.group) <= source.length {
                hasher.combine(kind)
                hasher.combine(source.substring(with: header.group))
            }
        }
        let headers = hasher.finalize()
        let headersChanged = force || headers != headerSignature
        headerSignature = headers
        if headersChanged { headerCache = [:] }
        // Разрывы по правилам Word — заново после правки (`DocPagination` в конце раскладки).
        for page in pagesView.pages { page.breakLimit = nil }
        pagesView.paginationStamp += 1
        storage.beginEditing()
        storage.replaceCharacters(in: replaced, with: string)
        storage.endEditing()
        if pagesView.pages.isEmpty { addPage(section: 0) }
        // Выступ раздела в поля поменялся (таблица стала шире полосы) — рамки текста страниц тоже.
        for page in pagesView.pages where page.section < model.sections.count {
            page.update(props: model.sections[page.section].props, section: page.section,
                        outdent: next.sectionOutdents[safe: page.section] ?? DocOutdent())
        }
        // Разделы страниц и номера — по завершении раскладки (`finishPagination`): спрашивать раскладку всех страниц
        // на каждое нажатие — это разложить весь документ заново.
        // Колонтитулы — сразу (по уже известным страницам); разделы страниц уточнятся, когда раскладка дойдёт до конца.
        if force || headersChanged { updateHeaders() }
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
        // Подсветка `$` двигается вместе с текстом; свежий список знаков придёт после пересчёта (`dollars.onUpdate`).
        if force { highlightDollars() }
        updateStatus()
    }

    package static func words(_ story: RTFStory) -> Int {
        var count = 0
        var inWord = false
        for paragraph in story.paragraphs {
            for run in paragraph.runs where !run.props.hidden {
                // Перевод строки, табуляция, поле, рисунок разделяют слова (`слово\lineслово` — два слова), в счёт не входят.
                // Результат поля (номер страницы) Word считает словом, как и текст.
                if case .field = run.kind {} else { guard run.kind == .text else { inWord = false; continue } }
                for scalar in run.text.unicodeScalars {
                    let letter = !scalar.properties.isWhitespace || scalar.value == 0xA0
                    if letter, !inWord { count += 1 }
                    inWord = letter
                }
            }
            inWord = false
        }
        return count
    }

    // MARK: - Страницы

    package var textViews: [DocTextView] { pagesView.pages.map(\.textView) }

    private func addPage(section: Int) {
        let props = section < model.sections.count ? model.sections[section].props : (model.sections.first?.props ?? RTFSectionProps())
        let page = DocPageView(props: props, section: section, outdent: rendering.sectionOutdents[safe: section] ?? DocOutdent())
        page.textView.delegate = self
        page.textView.controller = self
        page.textView.isEditable = true
        page.textView.isSelectable = true
        page.textView.onDoubleClickOutside = { [weak self, weak page] event in
            guard let self, let page else { return false }
            return self.doubleClick(event, on: page)
        }
        page.number = pagesView.pages.count + 1
        page.firstInSection = pagesView.pages.last.map { $0.section != section } ?? true
        pagesView.append(page)
        if pageCount != pagesView.pages.count { pageCount = pagesView.pages.count }
        if let index = layoutManager.textContainers.firstIndex(where: { $0 === spare }) {
            layoutManager.insertTextContainer(page.container, at: index)
        } else {
            layoutManager.addTextContainer(page.container)
            layoutManager.addTextContainer(spare)
        }
        spare.size = page.container.size
        // Колонтитулы новой страницы — до отрисовки (номера уточнятся по завершении раскладки), иначе она мигает без них.
        // Не внутри обратного вызова раскладки: там смена рамки сбивает перенос по «\f».
        DispatchQueue.main.async { [weak self, weak page] in
            MainActor.assumeIsolated {
                guard let self, let page, self.pagesView.pages.contains(where: { $0 === page }) else { return }
                self.setHeaders(page, total: self.pagesView.pages.count,
                                sectionTotal: self.pagesView.pages.filter { $0.section == page.section }.count)
            }
        }
    }

    /// Высота строк — как у Word (`DocLineMetrics`).
    package nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                                   lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                                   in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        MainActor.assumeIsolated {
            DocLineMetrics.adjust(layoutManager, rect: &lineFragmentRect.pointee, used: &lineFragmentUsedRect.pointee,
                                  baseline: &baselineOffset.pointee, container: textContainer, glyphs: glyphRange)
        }
    }

    package nonisolated func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor container: NSTextContainer?, atEnd: Bool) {
        MainActor.assumeIsolated {
            DocLineMetrics.completed(layoutManager)
            completedLayout(container, atEnd: atEnd)
        }
    }

    /// Перенос по словам — только там, где его делает Word (`WordLineBreaks`).
    package nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldBreakLineByWordBeforeCharacterAt charIndex: Int) -> Bool {
        MainActor.assumeIsolated {
            guard let text = layoutManager.textStorage?.mutableString else { return true }
            return WordLineBreaks.allowsBreak(before: charIndex, in: text)
        }
    }

    private func completedLayout(_ container: NSTextContainer?, atEnd: Bool) {
        let containers = layoutManager.textContainers
        guard let container, container !== spare, let index = containers.firstIndex(where: { $0 === container }) else {
            if containers.isEmpty { addPage(section: 0) }
            return
        }
        if index < pagesView.pages.count { pagesView.pages[index].refreshFloating() }
        if !atEnd, index == pagesView.pages.count - 1 {
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
            let from = max(count, lastUsed + 1)
            if from < pagesView.pages.count {
                // Контейнеры убранных страниц — тоже: следующим за последней страницей остаётся запасной.
                for page in pagesView.pages[from...] {
                    if let index = layoutManager.textContainers.firstIndex(where: { $0 === page.container }) { layoutManager.removeTextContainer(at: index) }
                }
                pagesView.removePages(from: from)
            }
        }
        // Разрывы по правилам Word; если страницы сдвинулись — раскладка дойдёт до конца и вызовет нас снова.
        if DocPagination.apply(pagesView, layoutManager: layoutManager) {
            if let last = layoutManager.textContainers.last { layoutManager.ensureLayout(for: last) }
        }
        if pageCount != pagesView.pages.count { pageCount = pagesView.pages.count }
        updatePageSections()
        updateHeaders()
        // Номера страниц в панели «$» — теперь известны.
        tab?.dollars.objectWillChange.send()
    }

    /// Раздел каждой страницы — по её первому символу; размер страницы — из раздела.
    private func updatePageSections() {
        var previousSection = -1
        for (index, page) in pagesView.pages.enumerated() {
            let glyphs = layoutManager.glyphRange(for: page.container)
            let first = glyphs.length > 0 ? layoutManager.characterIndexForGlyph(at: glyphs.location) : storage.length
            let section = min(rendering.section(atUnit: first), max(0, model.sections.count - 1))
            if section < model.sections.count {
                page.update(props: model.sections[section].props, section: section,
                            outdent: rendering.sectionOutdents[safe: section] ?? DocOutdent())
            }
            page.number = index + 1
            page.firstInSection = section != previousSection
            previousSection = section
        }
        pagesView.layoutPages()
        if pageCount != pagesView.pages.count { pageCount = pagesView.pages.count }
        if let last = pagesView.pages.last, spare.size != last.container.size { spare.size = last.container.size }
    }

    // MARK: - Колонтитулы

    /// Колонтитул страницы: первая страница раздела при `\titlepg`, чётные/нечётные при `\facingp`, иначе общий.
    package func headerKind(for page: DocPageView, header: Bool) -> RTFHeaderKind? {
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
    package func headers(of section: Int) -> [RTFHeaderKind: RTFHeader] {
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
        for page in pagesView.pages { setHeaders(page, total: total, sectionTotal: sectionPages[page.section] ?? 1) }
    }

    /// Колонтитулы страницы вместе с выступом в поля (страница по ним подвигает текст).
    private func setHeaders(_ page: DocPageView, total: Int, sectionTotal: Int) {
        let header = headerString(page, header: true, total: total, sectionTotal: sectionTotal)
        let footer = headerString(page, header: false, total: total, sectionTotal: sectionTotal)
        page.setHeaders(header: header?.string, headerOutdent: (header?.outdentLeft ?? 0, header?.outdentRight ?? 0),
                        footer: footer?.string, footerOutdent: (footer?.outdentLeft ?? 0, footer?.outdentRight ?? 0))
    }

    private func headerString(_ page: DocPageView, header: Bool, total: Int, sectionTotal: Int) -> DocRenderer.StoryRendering? {
        guard let kind = headerKind(for: page, header: header), let story = headers(of: page.section)[kind]?.story else { return nil }
        let key = "\(page.section)-\(kind.rawValue)-\(page.number)-\(total)-\(sectionTotal)"
        if let cached = headerCache[key] { return cached }
        let rendering = renderer.renderMargins(story, model: model, textWidth: DocPageView.bodyRect(page.props).width) { field in
            switch field {
            case .page: return "\(page.number)"
            case .numPages: return "\(total)"
            case .sectionPages: return "\(sectionTotal)"
            case .other: return nil
            }
        }
        headerCache[key] = rendering
        return rendering
    }

    /// Двойной клик по полю страницы — правка колонтитула (D-4а): `true` — обработан.
    package var onPageDoubleClick: ((NSEvent, DocPageView) -> Bool)?

    package func doubleClick(_ event: NSEvent, on page: DocPageView) -> Bool { onPageDoubleClick?(event, page) ?? false }

    // MARK: - Правка исходника

    /// Все правки из «Документа» идут сюда: одним шагом отмены (общей с «Кодом»), только указанные куски исходника,
    /// затем показ обновляется сразу. `select` — показанное выделение после правки (по новой карте).
    @discardableResult
    package func apply(_ edits: [DocEdit], actionName: String, select: ((DocRendering) -> NSRange)? = nil) -> Bool {
        guard let tab, !edits.isEmpty else { return false }
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        for (a, b) in zip(sorted, sorted.dropFirst()) where NSMaxRange(a.range) > b.range.location {
            assertionFailure("Правки «Документа» не должны пересекаться")
            return false
        }
        guard sorted.allSatisfy({ NSMaxRange($0.range) <= tab.storage.length }) else { return false }
        guard tab.textView.replace(sorted.map(\.range), with: sorted.map(\.text), actionName: actionName) else { return false }
        tab.noteDocumentEdit()
        refresh(select: select)
        return true
    }

    /// Показанное выделение (у всех страниц оно общее).
    package var selectedUnits: NSRange { textViews.first?.selectedRange() ?? NSRange(location: 0, length: 0) }

    /// Абзацы модели, которых касается выделение (у курсора — его абзац).
    package func paragraphs(in units: NSRange) -> [Int] {
        guard let first = rendering.paragraph(atUnit: units.location) else { return [] }
        let last = rendering.paragraph(atUnit: max(units.location, NSMaxRange(units) - 1)) ?? first
        return Array(first...max(first, last))
    }

    // MARK: - Знаки $

    /// Знаки `$` подсвечиваются, только пока открыта панель «Знаки $»; иначе страница — как в Word.
    var showsDollarMarks = false {
        didSet { if showsDollarMarks != oldValue { highlightDollars() } }
    }

    /// Подсветка `$` на страницах: видимая часть диапазона значения (по окончательному правилу — до конца строки исходника).
    /// Только заливка и подчёркивание: цвет текста — из документа, как в Word.
    package func highlightDollars() {
        guard let tab else { return }
        defer { paintFind() }  // подсветка `$` снимает фон со всего текста — совпадения поиска возвращаем
        let full = NSRange(location: 0, length: storage.length)
        let keys: [NSAttributedString.Key] = [.backgroundColor, .underlineStyle, .underlineColor]
        if highlighted { for key in keys { layoutManager.removeTemporaryAttribute(key, forCharacterRange: full) } }
        highlighted = false
        guard showsDollarMarks, storage.length > 0, tab.dollars.isCurrent || !tab.dollars.entries.isEmpty else { return }
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
                    .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                    .underlineColor: NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1),
                ]
                for range in [NSRange(location: dollar, length: 1)] + parts { layoutManager.addTemporaryAttributes(faint, forCharacterRange: range) }
            } else {
                let selected = tab.dollars.selected == mark.dollar
                let fill = EditorStyle.hueFill(entry.hue, selected: selected)
                layoutManager.addTemporaryAttributes([.backgroundColor: fill], forCharacterRange: NSRange(location: dollar, length: 1))
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
    package func visibleValue(of mark: DollarMark) -> String? {
        let map = rendering.map
        let dollar = map.unit(forSource: mark.dollar)
        guard dollar < map.count, map.range(at: dollar).location == mark.dollar else { return nil }
        let text = storage.mutableString
        let value = mark.parts.flatMap { map.units(inside: $0) }.filter { NSMaxRange($0) <= text.length }
            .map { text.substring(with: $0) }.joined()
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Номер страницы, на которой стоит место исходника (для строк панели «$»); `nil` — не видно на странице.
    /// Раскладку не заставляет: для ещё не разложенного текста — `nil`, панель обновится по завершении раскладки
    /// (иначе каждая перерисовка панели после правки раскладывала бы весь документ заново).
    package func page(ofSource location: Int) -> Int? {
        let unit = rendering.map.unit(forSource: location)
        guard unit < rendering.map.count, NSLocationInRange(location, rendering.map.range(at: unit)),
              unit < layoutManager.firstUnlaidCharacterIndex() else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: unit)
        guard let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return nil }
        return pagesView.pages.firstIndex { $0.container === container }.map { $0 + 1 }
    }

    // MARK: - Выделение и переходы

    /// Выделение документа → кусок исходника (для перехода в «Код»).
    package var sourceSelection: NSRange {
        let selection = textViews.first?.selectedRange() ?? NSRange(location: 0, length: 0)
        if selection.length == 0 {
            return NSRange(location: rendering.map.sourceLocation(beforeUnit: selection.location), length: 0)
        }
        return rendering.map.sourceRange(ofUnits: selection)
    }

    /// Выделение исходника → ближайшие видимые символы (переход из «Кода»).
    package func select(source range: NSRange, reveal: Bool = true) {
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
    package func reveal(_ range: NSRange, flash: Bool = false) {
        guard let view = textView(forUnit: range.location) else { return }
        view.scrollRangeToVisible(range)
        if flash { view.showFindIndicator(for: range) }
    }

    package func textView(forUnit unit: Int) -> DocTextView? {
        guard storage.length > 0 else { return textViews.first }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(unit, storage.length - 1))
        guard let container = layoutManager.textContainer(forGlyphAt: glyph, effectiveRange: nil) else { return textViews.first }
        return pagesView.pages.first { $0.container === container }?.textView
    }

    /// Первый видимый символ сверху — для синхронизации прокрутки с «Кодом».
    package var topSourceLocation: Int {
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
    package func scrollToSource(_ location: Int) {
        let unit = min(rendering.map.unit(forSource: location), max(0, storage.length - 1))
        guard storage.length > 0, let view = textView(forUnit: unit), let page = view.page else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: unit)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = page.frame.minY + page.bodyRect.minY + line.minY - 12
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Ввод

    /// Набор, удаление, вставка, перетаскивание: показ напрямую не меняется — правка уходит в исходник, показ
    /// перерисовывается из него.
    package nonisolated func textView(_ textView: NSTextView, shouldChangeTextInRanges ranges: [NSValue], replacementStrings: [String]?) -> Bool {
        MainActor.assumeIsolated {
            if composing { return true }
            guard ranges.count == 1, let replacement = replacementStrings?.first else {
                show(notice: "Правка нескольких мест сразу не поддерживается — выделите одно")
                Feedback.beep()
                return false
            }
            perform(replacing: ranges[0].rangeValue, with: replacement)
            return false
        }
    }

    /// Заменить показанные единицы текстом (пустой — удаление). `false` — правка невозможна (подсказка).
    @discardableResult
    package func perform(replacing units: NSRange, with text: String) -> Bool {
        guard let tab else { return false }
        // ↩ в пустом пункте, Tab в начале пункта, ⌫ у номера — команды списка (E-2).
        if let list = DocListEdit.intercept(units, text: text, model: model, rendering: rendering, source: tab.text) {
            return perform(list)
        }
        // Автозамена (выключена по умолчанию): один набранный знак может заменить и знак слева («--» → «—»).
        var units = units, text = text
        if UserDefaults.standard.bool(forKey: Pref.docAutocorrect), !composing,
           let fix = DocAutoCorrect.resolve(units: units, typed: text, shown: storage.string as NSString, isPlainText: { [rendering] in rendering.map.kind(at: $0) == .text }) {
            units = fix.units
            text = fix.text
        }
        var result = DocTextEditor.replace(units, with: text, model: model, map: rendering.map, source: tab.text)
        if let refusal = result.refusal {
            show(notice: refusal)
            Feedback.beep()
            return false
        }
        guard !result.edits.isEmpty else {
            if units.length > 0 || !text.isEmpty {
                // Границу ячейки, как в Word, Delete/⌫ не трогают и без подсказки (она вылезала бы на каждом ⌫ в начале ячейки);
                // всё остальное — не тишина.
                let onlyCellEnds = units.length > 0 && (units.location..<NSMaxRange(units)).allSatisfy { rendering.map.kind(at: $0) == .cellEnd }
                if !onlyCellEnds { show(notice: text.isEmpty ? "Здесь нечего удалять. " + DocTextEditor.codeHint : "Здесь нельзя набирать. " + DocTextEditor.codeHint) }
                Feedback.beep()
            }
            return false
        }
        // Новые и сдвинутые пункты списков — готовый номер `{\listtext}` переписывается вместе с правкой.
        if units.length > 0 || text.contains(where: \.isNewline) {
            (result.edits, result.caretSource) = DocListText.synced(result.edits, caret: result.caretSource, model: model, source: tab.text)
        }
        let caret = result.caretSource
        let single = result.edits.count == 1 && result.edits[0].range.length == 0 && !text.isEmpty && !text.contains(where: \.isNewline)
        // Набор подряд — один шаг отмены, как в Word: прошлый шаг отменяется и применяется вместе с новым символом.
        if single, let burst = typingBurst, burst.revision == tab.sourceRevision, tab.undo.canUndo, tab.undo.undoActionName == "Ввод",
           result.edits[0].range.location == burst.source + (burst.text as NSString).length,
           Date().timeIntervalSince(burst.time) < Self.typingBurstPause, (burst.text as NSString).length < 512 {
            let combined = burst.text + result.edits[0].text
            tab.undo.undo()
            let end = burst.source + (combined as NSString).length
            let done = apply([DocEdit(range: NSRange(location: burst.source, length: 0), text: combined)], actionName: "Ввод") { rendering in
                NSRange(location: rendering.caretUnit(atSource: end), length: 0)
            }
            // Не вышло — возвращаем отменённый символ, а не теряем его.
            if !done, tab.undo.canRedo { tab.undo.redo() }
            typingBurst = done ? TypingBurst(source: burst.source, text: combined, revision: tab.sourceRevision, time: Date()) : nil
            return done
        }
        let done = apply(result.edits, actionName: text.isEmpty ? "Удаление" : "Ввод") { rendering in
            NSRange(location: rendering.caretUnit(atSource: caret), length: 0)
        }
        typingBurst = done && single
            ? TypingBurst(source: result.edits[0].range.location, text: result.edits[0].text, revision: tab.sourceRevision, time: Date()) : nil
        return done
    }

    /// Команда списка: правки одним шагом отмены, курсор — в начале текста пункта.
    @discardableResult
    func perform(_ list: DocListEdit.Result) -> Bool {
        typingBurst = nil
        if let refusal = list.refusal {
            show(notice: refusal)
            Feedback.beep()
            return false
        }
        guard !list.edits.isEmpty else {
            Feedback.beep()
            return false
        }
        let caret = list.caretSource
        return apply(list.edits, actionName: list.actionName) { NSRange(location: $0.caretUnit(atSource: caret), length: 0) }
    }

    /// ⇧Tab: уровень пункта списка выше. `false` — не пункт списка (обычное поведение).
    func backtab() -> Bool {
        guard let tab, let list = DocListEdit.backtab(selectedUnits, model: model, rendering: rendering, source: tab.text) else { return false }
        perform(list)
        return true
    }

    /// Серия набора для склейки отмены: куда, что набрано, ревизия исходника после последнего символа, когда.
    struct TypingBurst {
        package var source: Int
        package var text: String
        package var revision: Int
        package var time: Date
    }

    var typingBurst: TypingBurst?
    /// Пауза, после которой набор — уже новый шаг отмены.
    package static let typingBurstPause: TimeInterval = 2

    /// Курсор не встаёт внутрь номера страницы (поле неделимо) — переносится за поле.
    package nonisolated func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                              toCharacterRange new: NSRange) -> NSRange {
        MainActor.assumeIsolated {
            if let moved = DocListEdit.caretOutsideNumber(new, from: old, map: rendering.map) { return moved }
            guard new.length == 0, new.location > 0, new.location < rendering.map.count,
                  rendering.map.kind(at: new.location - 1) == .field, rendering.map.kind(at: new.location) == .field,
                  rendering.map.range(at: new.location - 1) == rendering.map.range(at: new.location) else { return new }
            var end = new.location
            while end < rendering.map.count, rendering.map.kind(at: end) == .field, rendering.map.range(at: end) == rendering.map.range(at: new.location) {
                end += 1
            }
            return NSRange(location: end, length: 0)
        }
    }

    // MARK: Метод ввода

    package private(set) var composing = false
    private var compositionRange = NSRange(location: 0, length: 0)

    package func beginComposition(replacing range: NSRange) {
        composing = true
        compositionRange = range
    }

    /// Набранное подтверждено: на экране — временный текст, в исходник — правка по карте до набора.
    package func commitComposition(_ text: String) {
        composing = false
        // На экране осталось набранное методом ввода — показ целиком заново из исходника (с правкой или без).
        perform(replacing: compositionRange, with: text)
        refresh(force: true)
    }

    package func cancelComposition() {
        guard composing else { return }
        composing = false
        refresh(force: true)
    }

    // MARK: Подсказки

    /// Короткая подсказка над документом (отказ правки, вставка без форматирования); гаснет сама.
    @Published package private(set) var notice: String?
    private var noticeWork: DispatchWorkItem?

    package func show(notice text: String) {
        notice = text
        noticeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.notice = nil } }
        noticeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    package nonisolated func textViewDidChangeSelection(_ notification: Notification) {
        MainActor.assumeIsolated { updateStatus() }
    }

    package nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { tab?.undo }
    }

    /// Страница, раздел и свойства у курсора — строке состояния и панели форматирования.
    package func updateStatus() {
        let selection = textViews.first?.selectedRange() ?? NSRange(location: 0, length: 0)
        // Правка колонтитула: страница и раздел — те, где эта правка, а не те, где курсор основного текста.
        if let page = DocFormatter.existing(for: self)?.headerSession?.page,
           let index = pagesView.pages.firstIndex(where: { $0 === page }) {
            if currentPage != index + 1 { currentPage = index + 1 }
            if currentSection != page.section + 1 { currentSection = page.section + 1 }
        } else if let view = textView(forUnit: selection.location), let page = view.page,
           let index = pagesView.pages.firstIndex(where: { $0 === page }) {
            if currentPage != index + 1 { currentPage = index + 1 }
            if currentSection != page.section + 1 { currentSection = page.section + 1 }
        }
        let language = languageAtCaret(selection)
        if language != languageName { languageName = language }
        let info = selectionInfo(selection)
        if info != self.selection { self.selection = info }
        if tab?.mode == .document { tab?.dollars.caretMoved(to: sourceSelection) }  // статус «правится» в панели «$»
    }

    private func languageAtCaret(_ selection: NSRange) -> String? {
        guard let tab, storage.length > 0 else { return nil }
        let unit = min(selection.location, storage.length)
        let location = rendering.map.sourceLocation(beforeUnit: unit)
        let paragraph = rendering.paragraph(atUnit: min(unit, max(0, storage.length - 1))).flatMap { model.body.paragraphs[safe: $0] }
        let start = paragraph?.regionStart ?? max(0, location - 2000)
        return DocLanguage.name(lcid: DocLanguage.lcid(atSource: location, from: start, in: tab.text))
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
    package static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    package func step(zoom direction: Int) {
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

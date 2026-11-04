import AppKit
import MUDesign

/// Текст колонтитула при правке: свой вид поверх поля страницы. Изменения текста не идут в хранилище показа —
/// они превращаются в точечные правки исходника, после чего колонтитул перерисовывается.
package final class DocHeaderTextView: NSTextView {
    package weak var session: DocHeaderSession?

    // Вставка — обычным текстом.
    package override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    package override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return false }
        MainActor.assumeIsolated { session?.replace(affectedCharRange, with: replacementString) }
        return false
    }

    package override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { session?.formatter?.endHeaderEditing() }
    }

    package override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) { return cancelOperation(nil) }
        super.doCommand(by: selector)
    }
}

/// Правка одного колонтитула (`d11`): вид текста на странице, его карта «символ ↔ исходник» и история модели.
@MainActor
package final class DocHeaderSession: NSObject, NSTextViewDelegate {
    package weak var formatter: DocFormatter?
    package weak var controller: DocumentController?
    package weak var page: DocPageView?
    package let isHeader: Bool
    /// Раздел, в котором записан колонтитул (страница может наследовать его от предыдущего раздела).
    package private(set) var section: Int
    package private(set) var kind: RTFHeaderKind
    package let storage = NSTextStorage()
    package let layoutManager = DocLayoutManager()
    package let container = NSTextContainer(size: NSSize(width: 400, height: 10_000))
    package let textView: DocHeaderTextView
    package private(set) var map = DocSourceMap()
    private var observer: NSObjectProtocol?
    private var reloadScheduled = false

    package var story: DocStoryRef { .header(section: section, kind: kind) }

    package init(formatter: DocFormatter, controller: DocumentController, page: DocPageView, isHeader: Bool, section: Int, kind: RTFHeaderKind) {
        self.formatter = formatter
        self.controller = controller
        self.page = page
        self.isHeader = isHeader
        self.section = section
        self.kind = kind
        storage.addLayoutManager(layoutManager)
        layoutManager.delegate = DocLineMetricsDelegate.shared
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        textView = DocHeaderTextView(frame: .zero, textContainer: container)
        super.init()
        textView.session = self
        textView.delegate = self
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = .zero
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.insertionPointColor = .black
        textView.selectedTextAttributes = [.backgroundColor: NSColor(srgbRed: 0.7, green: 0.82, blue: 1, alpha: 1)]
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        layoutManager.showsInvisibles = controller.showsInvisibles
        // Исходник меняется (правка, отмена, «Код») — перерисовать после того, как контроллер перечитал модель.
        if let tab = controller.tab {
            observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: tab.storage,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
        }
    }

    package func invalidate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        textView.removeFromSuperview()
    }

    // MARK: - Показ

    package func install() {
        guard let page else { return }
        page.addSubview(textView)
        reload(selectSource: nil)
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: storage.length > 0 ? storage.length - 1 : 0, length: 0))
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reloadScheduled = false
                self.controller?.refresh()
                self.reload(selectSource: self.selectedSource)
            }
        }
    }

    /// Перерисовать с тем же показанным выделением (команда оформления не меняет текст).
    package func reload(selectUnits units: NSRange) {
        reload(selectSource: nil)
        let location = min(units.location, storage.length)
        textView.setSelectedRange(NSRange(location: location, length: min(units.length, storage.length - location)))
    }

    static let fieldShade = NSColor(white: 0.5, alpha: 0.16)

    /// Показанный текст колонтитула по модели контроллера; `selectSource` — выделение после правки.
    package func reload(selectSource: NSRange?) {
        guard let controller, let page else { return }
        guard let header = controller.model.sections[safe: section]?.headers[kind] else {
            // Своего колонтитула раздела больше нет (отмена «Отвязать от предыдущего», «Как в предыдущем»): раздел снова показывает
            // колонтитул предыдущего — правка переходит на него. Нет и его (отмена добавления) — правка закончилась.
            if section > 0, let provider = DocHeaderFooterEdits.provider(of: kind, before: min(section, controller.model.sections.count), model: controller.model) {
                self.section = provider
                reload(selectSource: nil)
            } else {
                formatter?.endHeaderEditing()
            }
            return
        }
        let total = controller.pageCount
        let sectionTotal = controller.pagesView.pages.filter { $0.section == page.section }.count
        let width = DocPageView.bodyRect(page.props).width
        let rendering = controller.renderer.renderMargins(header.story, model: controller.model, textWidth: width) { field in
            switch field {
            case .page: return "\(page.number)"
            case .numPages: return "\(total)"
            case .sectionPages: return "\(sectionTotal)"
            case .other: return nil
            }
        }
        let (string, map) = (rendering.string, rendering.map)
        self.map = map
        storage.setAttributedString(string)
        // Поля — серым фоном, как у Word в правке колонтитула: видно, что это поле, а не набранный текст.
        // Вычисляемые (номер страницы) — единицы вида `.field`; остальные (дата, время, имя файла) — текст внутри группы поля.
        let groups = controller.model.fields.map(\.group).filter { NSIntersectionRange($0, header.group).length > 0 }
        for unit in 0..<min(map.count, storage.length) {
            let inGroup = groups.contains { NSLocationInRange(map.range(at: unit).location, $0) }
            if map.kind(at: unit) == .field || inGroup {
                storage.addAttribute(.backgroundColor, value: Self.fieldShade, range: NSRange(location: unit, length: 1))
            }
        }
        layoutManager.showsInvisibles = controller.showsInvisibles
        layout()
        if let selectSource {
            let start = map.unit(forSource: selectSource.location)
            let end = selectSource.length > 0 ? max(start, map.firstUnit(atOrAfter: NSMaxRange(selectSource))) : start
            let location = min(start, storage.length)
            textView.setSelectedRange(NSRange(location: location, length: min(end, storage.length) - location))
        }
        formatter?.updateState()
    }

    /// Рамка текста: ширина — поле страницы, высота — по тексту; нижний колонтитул прижат к низу, как на странице.
    private func layout() {
        guard let page else { return }
        let area = isHeader ? page.headerRect : page.footerRect
        container.size = NSSize(width: area.width, height: 10_000)
        let height = max(16, DocStoryLayout.height(layoutManager, container))
        // Как на странице (`DocPageView`): верхний — от `\headery` вниз, нижний — низом на `\footery`, растёт вверх.
        let y = isHeader ? area.minY : page.bounds.height - CGFloat(max(page.props.footerY, 0)) / 20 - height
        textView.frame = NSRect(x: area.minX, y: y, width: area.width, height: height)
        page.headerFrame = (textView.frame.insetBy(dx: -8, dy: -6), title)
    }

    /// Подпись над рамкой: «— чётные» и «— нечётные» — только когда они и правда разные (`\facingp`); раздел показывает
    /// колонтитул предыдущего — « · Как в предыдущем» (как в Word).
    package var title: String {
        let facing = controller?.model.facingPages ?? false
        var base = kind.title
        if !facing, kind.page == .even || kind.page == .odd { base = RTFHeaderKind.kind(header: isHeader, page: .all).title }
        return formatter?.headerLink == .linked ? base + " · Как в предыдущем" : base
    }

    // MARK: - Выделение

    /// Выделение колонтитула → кусок исходника.
    package var selectedSource: NSRange {
        let selection = textView.selectedRange()
        if selection.length == 0 { return NSRange(location: map.sourceLocation(beforeUnit: selection.location), length: 0) }
        return map.sourceRange(ofUnits: selection)
    }

    package func target() -> DocFormatter.Target? {
        guard let controller, let story = controller.model.story(self.story) else { return nil }
        let selection = textView.selectedRange()
        var units = selection
        if units.length == 0 { units = LineCommands.word(storage.mutableString, at: selection.location) }
        let span = units.length > 0 ? map.sourceRange(ofUnits: units) : NSRange(location: map.sourceLocation(beforeUnit: selection.location), length: 0)
        let whole = selection.length > 0 ? map.sourceRange(ofUnits: selection) : NSRange(location: map.sourceLocation(beforeUnit: selection.location), length: 0)
        let first = DocHeaderFooterEdits.position(of: whole.location, in: story).paragraph
        let last = DocHeaderFooterEdits.position(of: max(whole.location, NSMaxRange(whole) - 1), in: story).paragraph
        return DocFormatter.Target(story: self.story, span: span, paragraphs: Array(first...max(first, last)), hasCharacters: units.length > 0)
    }

    package nonisolated func textViewDidChangeSelection(_ notification: Notification) {
        MainActor.assumeIsolated { formatter?.updateState() }
    }

    package nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { controller?.tab?.undo }
    }

    // MARK: - Ввод текста

    /// Набранный текст (или удаление) в колонтитуле → правка исходника генератором ввода режима «Документ» (D-3).
    package func replace(_ units: NSRange, with text: String) {
        guard let controller, let tab = controller.tab, let story = controller.model.story(self.story) else { return }
        let result = DocTextEditor.replace(units, with: text, model: controller.model, story: story, map: map, source: tab.text)
        if let refusal = result.refusal { return controller.show(notice: refusal) }
        guard !result.edits.isEmpty else { return }
        guard controller.apply(result.edits, actionName: text.isEmpty ? "Удаление" : "Ввод") else { return }
        reload(selectSource: NSRange(location: result.caretSource, length: 0))
    }

    /// Курсор не встаёт внутрь номера страницы (поле неделимо) — переносится за поле.
    package nonisolated func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange,
                              toCharacterRange new: NSRange) -> NSRange {
        MainActor.assumeIsolated {
            guard new.length == 0, new.location > 0, new.location < map.count, map.kind(at: new.location - 1) == .field,
                  map.kind(at: new.location) == .field, map.range(at: new.location - 1) == map.range(at: new.location) else { return new }
            var end = new.location
            while end < map.count, map.kind(at: end) == .field, map.range(at: end) == map.range(at: new.location) { end += 1 }
            return NSRange(location: end, length: 0)
        }
    }

    /// Номер колонтитула меняется вместе с переключателями (первая страница, чётные) — правка переходит на нужный.
    package func retarget(section: Int, kind: RTFHeaderKind) {
        self.section = section
        self.kind = kind
        reload(selectSource: nil)
    }
}

extension Array {
    package subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Рамка правки колонтитула на странице (макет `.audit/word-ui-design`, «★2»): синяя пунктирная рамка и метка на её верхней
/// границе справа — белая плашка с синим текстом и рамкой. Бумага всегда белая, поэтому цвета постоянные (синий светлой темы).
package enum DocHeaderFrameStyle {
    package static let blue = NSColor(srgbRed: 0x1F / 255.0, green: 0x6F / 255.0, blue: 0xDB / 255.0, alpha: 1)
    package static let labelInk = NSColor(srgbRed: 0x1F / 255.0, green: 0x5F / 255.0, blue: 0xC0 / 255.0, alpha: 1)
    /// Отступ метки от правого края рамки.
    package static let labelInset: CGFloat = 24

    /// Где стоит метка (для теста и рисования): по центру верхней границы, справа.
    package static func labelRect(for rect: NSRect, title: String) -> NSRect {
        let size = (title as NSString).size(withAttributes: attributes)
        let width = size.width + 12, height = size.height + 4
        return NSRect(x: max(rect.minX, rect.maxX - labelInset - width), y: rect.minY - height / 2, width: width, height: height)
    }

    package static var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont(name: "Manrope-Bold", size: 10.5) ?? .boldSystemFont(ofSize: 10.5), .foregroundColor: labelInk]
    }

    package static func draw(_ rect: NSRect, title: String) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.lineWidth = 1
        blue.setStroke()
        path.stroke()
        let label = labelRect(for: rect, title: title)
        let plate = NSBezierPath(roundedRect: label, xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        plate.fill()
        labelInk.setStroke()
        plate.lineWidth = 1
        plate.stroke()
        (title as NSString).draw(at: NSPoint(x: label.minX + 6, y: label.minY + 2), withAttributes: attributes)
    }
}

// MARK: - Вход, выход и команды вкладки «Колонтитулы»

extension DocFormatter {
    /// Двойной клик по странице: по верхнему или нижнему полю — правка колонтитула, по тексту во время правки — выход.
    package func pageDoubleClick(_ event: NSEvent, on page: DocPageView) -> Bool {
        let point = page.convert(event.locationInWindow, from: nil)
        let body = page.bodyRect
        if point.y < body.minY { beginHeaderEditing(page: page, header: true); return true }
        if point.y > body.maxY { beginHeaderEditing(page: page, header: false); return true }
        guard headerSession != nil else { return false }
        endHeaderEditing()
        return true
    }

    /// Какой колонтитул показан на странице и в каком разделе он записан; нет — какой создать.
    package func headerPlace(page: DocPageView, header: Bool) -> (section: Int, kind: RTFHeaderKind, exists: Bool)? {
        guard let controller, page.section < controller.model.sections.count else { return nil }
        let model = controller.model
        if let kind = controller.headerKind(for: page, header: header) {
            if let section = (0...page.section).reversed().first(where: { model.sections[$0].headers[kind] != nil }) {
                return (section, kind, true)
            }
            return (page.section, kind, false)
        }
        let props = model.sections[page.section].props
        let kind: RTFHeaderKind
        if props.titlePage, page.firstInSection {
            kind = .kind(header: header, page: .first)
        } else if model.facingPages {
            kind = .kind(header: header, page: page.number % 2 == 0 ? .even : .odd)
        } else {
            kind = .kind(header: header, page: .all)
        }
        return (page.section, kind, false)
    }

    package func beginHeaderEditing(page: DocPageView, header: Bool) {
        guard let controller, let tab = controller.tab, var place = headerPlace(page: page, header: header) else { return }
        if headerSession?.page === page, headerSession?.isHeader == header { return }
        endHeaderEditing()
        if !place.exists {
            let result = DocHeaderFooterEdits.add([place.kind], section: place.section, source: tab.text, model: controller.model)
            perform(result, name: header ? "Добавить верхний колонтитул" : "Добавить нижний колонтитул")
            guard controller.model.sections[safe: place.section]?.headers[place.kind] != nil else { return }
            place.exists = true
        }
        let session = DocHeaderSession(formatter: self, controller: controller, page: page, isHeader: header, section: place.section, kind: place.kind)
        headerSession = session
        for other in controller.pagesView.pages { other.faded = true }
        session.install()
        updateState()
        controller.updateStatus()
    }

    package func endHeaderEditing() {
        guard let session = headerSession else { return }
        headerSession = nil
        session.invalidate()
        guard let controller else { return }
        for page in controller.pagesView.pages {
            page.faded = false
            page.headerFrame = nil
        }
        if let view = controller.textViews.first { view.window?.makeFirstResponder(view) }
        updateState()
        controller.updateStatus()
    }

    /// После переключателя (первая страница, чётные/нечётные) страница может показывать другой колонтитул.
    private func retargetSession() {
        guard let session = headerSession, let page = session.page, let place = headerPlace(page: page, header: session.isHeader) else { return }
        guard let controller, let tab = controller.tab else { return }
        if !place.exists {
            perform(DocHeaderFooterEdits.add([place.kind], section: place.section, source: tab.text, model: controller.model), name: "Добавить колонтитул")
        }
        guard let fresh = headerPlace(page: page, header: session.isHeader), fresh.exists else { return endHeaderEditing() }
        session.retarget(section: fresh.section, kind: fresh.kind)
    }

    package var titlePageOn: Bool {
        guard let controller, let page = headerSession?.page else { return false }
        return controller.model.sections[safe: page.section]?.props.titlePage ?? false
    }

    package var facingPagesOn: Bool { controller?.model.facingPages ?? false }

    /// «Как в предыдущем» у показанного колонтитула: `.linked` — раздел показывает колонтитул предыдущего, `.own` — свой (его можно
    /// связать с предыдущим). `nil` — кнопки нет: правки колонтитула нет, раздел первый или в предыдущих такого колонтитула нет.
    package enum HeaderLink: Equatable { case linked, own }

    package var headerLink: HeaderLink? {
        guard let controller, let session = headerSession, let page = session.page, page.section > 0 else { return nil }
        let model = controller.model
        if DocHeaderFooterEdits.isLinkedToPrevious(session.kind, section: page.section, model: model) { return .linked }
        guard model.sections[safe: page.section]?.headers[session.kind] != nil,
              DocHeaderFooterEdits.provider(of: session.kind, before: page.section, model: model) != nil else { return nil }
        return .own
    }

    /// Включить или выключить «Как в предыдущем» у показанного колонтитула (одна правка файла, один шаг отмены).
    package func setLinkedToPrevious(_ linked: Bool) {
        guard let controller, let tab = controller.tab, let session = headerSession, let page = session.page, let state = headerLink else { return }
        let model = controller.model
        if linked {
            guard state == .own, let provider = DocHeaderFooterEdits.provider(of: session.kind, before: page.section, model: model) else { return }
            // Сначала правка переходит на колонтитул предыдущего раздела — свой исчезнет вместе с правкой.
            session.retarget(section: provider, kind: session.kind)
            perform(DocHeaderFooterEdits.link(session.kind, section: page.section, source: tab.text, model: model), name: "Как в предыдущем")
        } else {
            guard state == .linked else { return }
            perform(DocHeaderFooterEdits.unlink(session.kind, section: page.section, source: tab.text, model: model), name: "Отвязать колонтитул от предыдущего")
            if controller.model.sections[safe: page.section]?.headers[session.kind] != nil { session.retarget(section: page.section, kind: session.kind) }
        }
    }

    package func setTitlePage(_ on: Bool) {
        guard let controller, let tab = controller.tab, let page = headerSession?.page else { return }
        let inherited: Set<RTFHeaderKind> = page.section > 0 ? Set(controller.headers(of: page.section - 1).keys) : []
        perform(DocHeaderFooterEdits.titlePage(on, section: page.section, inherited: inherited, source: tab.text, model: controller.model),
                name: "Другой колонтитул первой страницы")
        retargetSession()
    }

    package func setFacingPages(_ on: Bool) {
        guard let controller, let tab = controller.tab else { return }
        perform(DocHeaderFooterEdits.facingPages(on, source: tab.text, model: controller.model), name: "Чётные и нечётные колонтитулы")
        retargetSession()
    }

    package func insertPageNumber(_ number: DocHeaderFooterEdits.PageNumber) {
        guard let controller, let tab = controller.tab, let session = headerSession else { return }
        let unit = session.textView.selectedRange().location
        let result = DocHeaderFooterEdits.insertPageNumber(number, story: session.story, unit: unit, map: session.map, source: tab.text,
                                                           model: controller.model)
        perform(result, name: "Номер страницы")
    }

    /// Поле у курсора: дата, время, число страниц, имя файла… (`HeaderField.catalog`).
    package func insertField(_ field: HeaderField) {
        guard let controller, let tab = controller.tab, let session = headerSession else { return }
        let unit = session.textView.selectedRange().location
        let name = tab.document.url?.lastPathComponent ?? ""
        let result = DocHeaderFooterEdits.insertField(field, story: session.story, unit: unit, map: session.map, source: tab.text,
                                                      model: controller.model, fileName: name)
        perform(result, name: field.title)
    }

    package func removeHeader() {
        guard let controller, let tab = controller.tab, let session = headerSession else { return }
        let result = DocHeaderFooterEdits.remove(session.kind, section: session.section, source: tab.text, model: controller.model)
        endHeaderEditing()
        perform(result, name: session.isHeader ? "Удалить верхний колонтитул" : "Удалить нижний колонтитул")
    }
}

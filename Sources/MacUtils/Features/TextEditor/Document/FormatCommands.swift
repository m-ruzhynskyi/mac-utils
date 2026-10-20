import AppKit
import Combine

/// Что панель форматирования показывает про выделение (смешанное — `nil`): шрифт, размер, начертания, цвета, абзац.
struct DocFormatState: Equatable {
    var fontName: String?
    var displayFont: String?
    var halfPoints: Int?
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var color: RTFColor??
    var highlight: RTFColor??
    var alignment: RTFAlignment?
    var paragraph: RTFParaProps?
    var inTable = false
}

/// Команды форматирования одной вкладки в режиме «Документ» (D-4): выделение → точечные правки (`FormatEdits`) →
/// `DocumentController.apply` (один шаг отмены, общий с «Кодом»). Команда, которую нельзя выполнить без потерь, ничего
/// не меняет и говорит почему — с подсказкой «Изменить в коде».
@MainActor
final class DocFormatter: ObservableObject {
    private(set) weak var controller: DocumentController?
    @Published private(set) var state = DocFormatState()
    /// Правка колонтитула (`d11`): какая история и где её показанный текст.
    @Published var headerSession: DocHeaderSession?
    private var observers: Set<AnyCancellable> = []

    private static let registry = NSMapTable<DocumentController, DocFormatter>.weakToStrongObjects()

    /// Свой форматировщик у каждого контроллера документа (создаётся при первом показе панели).
    static func of(_ controller: DocumentController) -> DocFormatter {
        if let existing = registry.object(forKey: controller) { return existing }
        let formatter = DocFormatter(controller: controller)
        registry.setObject(formatter, forKey: controller)
        return formatter
    }

    private init(controller: DocumentController) {
        self.controller = controller
        controller.onPageDoubleClick = { [weak self] event, page in self?.pageDoubleClick(event, on: page) ?? false }
        controller.$selection.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateState() } }
        }.store(in: &observers)
        updateState()
    }

    // MARK: - Цель команды

    /// Где применить команду: история, кусок исходника (символы) и абзацы.
    struct Target {
        var story: DocStoryRef
        var span: NSRange
        var paragraphs: [Int]
        var hasCharacters: Bool
    }

    /// Выделение основного текста или колонтитула. У курсора без выделения символы — слово под курсором, как в Word.
    func target() -> Target? {
        if let session = headerSession { return session.target() }
        guard let controller else { return nil }
        let selection = controller.selectedUnits
        var units = selection
        if units.length == 0 {
            units = LineCommands.word(controller.storage.mutableString, at: selection.location)
        }
        let span = units.length > 0 ? controller.rendering.map.sourceRange(ofUnits: units) : NSRange(location: 0, length: 0)
        return Target(story: .body, span: span, paragraphs: controller.paragraphs(in: selection), hasCharacters: units.length > 0)
    }

    // MARK: - Команды

    func apply(_ change: CharChange) {
        guard let controller, let tab = controller.tab, let target = target() else { return }
        guard target.hasCharacters else { return notify("Выделите текст, который нужно оформить") }
        let result = FormatEdits.character(change, span: target.span, story: target.story, source: tab.text, model: controller.model)
        perform(result, name: change.actionName)
    }

    func apply(_ change: ParaChange, name: String) {
        guard let controller, let tab = controller.tab, let target = target(), !target.paragraphs.isEmpty else { return }
        let result = FormatEdits.paragraph(change, paragraphs: target.paragraphs, story: target.story, source: tab.text, model: controller.model)
        perform(result, name: name)
    }

    func clearFormatting() {
        guard let controller, let tab = controller.tab, let target = target() else { return }
        let span = target.hasCharacters ? target.span : NSRange(location: 0, length: 0)
        let result = FormatEdits.clear(span: span, paragraphs: target.paragraphs, story: target.story, source: tab.text, model: controller.model)
        perform(result, name: CharChange.clear.actionName)
    }

    /// Применить план: правки — через контроллер документа, выделение остаётся на тех же символах.
    func perform(_ result: Result<FormatPlan, FormatFailure>, name: String) {
        guard let controller else { return }
        switch result {
        case .failure(let failure):
            notify("Нельзя без потерь: \(failure.reason.lowercasedFirst). Изменить это можно в режиме «Код»")
        case .success(let plan):
            guard !plan.edits.isEmpty else { return }
            guard let edits = FormatCheck.merged(plan.edits) else { return notify("Правки пересекаются — изменить это можно в режиме «Код»") }
            let selection = controller.selectedUnits
            let headerSelection = headerSession?.textView.selectedRange()
            controller.apply(edits.map { DocEdit(range: $0.range, text: $0.string) }, actionName: name) { _ in selection }
            if let headerSelection { headerSession?.reload(selectUnits: headerSelection) }
            updateState()
        }
    }

    // MARK: - Кнопки панели

    func toggleBold() { apply(.bold(!state.bold)) }
    func toggleItalic() { apply(.italic(!state.italic)) }
    func toggleUnderline() { apply(.underline(!state.underline)) }
    func toggleStrike() { apply(.strike(!state.strike)) }
    func setFont(_ name: String) { apply(.font(name)) }
    func setColor(_ color: RTFColor?) { apply(.color(color)) }
    func setHighlight(_ color: RTFColor?) { apply(.highlight(color)) }

    /// Размер в пунктах (можно 10,5): в файл — `\fsN` в половинках.
    func setSize(points: Double) {
        guard points.isFinite else { return }
        apply(.size(min(max(Int((points * 2).rounded()), 2), 3_276)))
    }

    /// Список размеров Word и шаг − / + по нему (⌘⇧< / ⌘⇧>).
    static let sizes: [Double] = [8, 9, 10, 10.5, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72]

    static func steppedSize(from points: Double, direction: Int) -> Double {
        if direction > 0 {
            return sizes.first { $0 > points + 0.01 } ?? min(1_638, (points / 10).rounded(.down) * 10 + 10)
        }
        if points > 72.01 { return max(72, ((points - 0.01) / 10).rounded(.down) * 10) }
        return sizes.last { $0 < points - 0.01 } ?? max(1, points - 1)
    }

    func stepSize(_ direction: Int) {
        let current = Double(state.halfPoints ?? 24) / 2
        setSize(points: Self.steppedSize(from: current, direction: direction))
    }

    func setAlignment(_ alignment: RTFAlignment) {
        let names: [RTFAlignment: String] = [.left: "По левому краю", .center: "По центру", .right: "По правому краю", .justify: "По ширине"]
        apply(ParaChange(alignment: alignment), name: names[alignment] ?? "Выравнивание")
    }

    /// Отступ слева − / +: к соседней позиции табуляции по умолчанию, как в Word.
    func stepIndent(_ direction: Int) {
        guard let controller else { return }
        let step = max(controller.model.defaultTab, 1)
        let left = state.paragraph?.left ?? 0
        let next = direction > 0 ? (left / step + 1) * step : max(0, ((left - 1) / step) * step)
        apply(ParaChange(left: max(0, next)), name: direction > 0 ? "Увеличить отступ" : "Уменьшить отступ")
    }

    /// Межстрочный интервал: множитель одинарного (`\sl240\slmult1` — одинарный).
    func setLineSpacing(_ multiple: Double) {
        apply(ParaChange(lineSpacing: (Int((240 * multiple).rounded()), true)), name: "Междустрочный интервал")
    }

    func setSpacing(before: Int? = nil, after: Int? = nil) {
        apply(ParaChange(spaceBefore: before, spaceAfter: after), name: "Интервал")
    }

    /// Отступы абзаца с линейки (твипы).
    func setIndents(left: Int, firstLine: Int, right: Int) {
        apply(ParaChange(left: left, right: right, firstLine: firstLine), name: "Отступы")
    }

    /// Позиция табуляции с линейки: добавить, сдвинуть, убрать.
    func editTabs(_ edit: TabEdit) {
        guard let controller, let tab = controller.tab, let target = target(), !target.paragraphs.isEmpty else { return }
        let names: String
        switch edit {
        case .add: names = "Добавить табуляцию"
        case .move: names = "Сдвинуть табуляцию"
        case .remove: names = "Убрать табуляцию"
        }
        perform(FormatEdits.tabs(edit, paragraphs: target.paragraphs, story: target.story, source: tab.text, model: controller.model), name: names)
    }

    // MARK: - Состояние панели

    func updateState() {
        if let session = headerSession {
            state = Self.state(in: session.storage, selection: session.textView.selectedRange())
            return
        }
        guard let controller else { return }
        state = Self.state(in: controller.storage, selection: controller.selectedUnits, model: controller.model)
    }

    /// Свойства выделения по атрибутам показанного текста (у курсора — символ перед ним).
    static func state(in storage: NSAttributedString, selection: NSRange, model: RTFDocumentModel? = nil) -> DocFormatState {
        var state = DocFormatState()
        guard storage.length > 0 else { return state }
        let location = min(max(0, selection.location), storage.length)
        let range = selection.length > 0 ? NSIntersectionRange(selection, NSRange(location: 0, length: storage.length))
            : NSRange(location: max(0, location - 1), length: 1)
        var chars: [DocCharInfo] = []
        storage.enumerateAttribute(.docChar, in: range) { value, _, stop in
            if let value = value as? DocCharInfo { chars.append(value) }
            if chars.count > 400 { stop.pointee = true }
        }
        func same<T: Equatable>(_ values: [T]) -> T? { values.allSatisfy { $0 == values.first } ? values.first : nil }
        state.fontName = same(chars.map(\.fontName))
        state.displayFont = same(chars.map(\.displayFont))
        state.halfPoints = same(chars.map(\.props.halfPoints))
        state.bold = !chars.isEmpty && chars.allSatisfy(\.props.bold)
        state.italic = !chars.isEmpty && chars.allSatisfy(\.props.italic)
        state.underline = !chars.isEmpty && chars.allSatisfy { $0.props.underline != .none }
        state.strike = !chars.isEmpty && chars.allSatisfy(\.props.strike)
        if let model {
            state.color = same(chars.map { model.color($0.props.color) })
            state.highlight = same(chars.map { model.color($0.props.highlight) })
        }
        let paragraphAt = min(location, storage.length - 1)
        let para = storage.attribute(.docPara, at: paragraphAt, effectiveRange: nil) as? DocParaInfo
        state.paragraph = para?.props
        state.alignment = para?.props.alignment
        state.inTable = para?.props.inTable ?? false
        return state
    }

    // MARK: - Подсказки

    /// Подсказка капсулой над страницами.
    func notify(_ text: String) {
        controller?.show(notice: text)
    }
}

extension String {
    /// С маленькой буквы — для вставки причины в середину фразы.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

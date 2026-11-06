import AppKit
import MUCore

/// Параметры страницы (R4): поля, ориентация и размер бумаги раздела — точечные правки кодов RTF. Раскладка читает коды так:
/// `\paperw/\paperh/\margl…/\landscape` у документа задают страницу всем разделам, `\sectd` берёт их, а `\pgwsxn/\pghsxn/\marglsxn…/\lndscpsxn`
/// после `\sectd` перекрывают для своего раздела. Правка пишет в тот же слой, который сейчас действует на раздел; колонтитулы
/// (`\headery/\footery`) не трогаются. Чистая логика: без окон и системных вызовов.
package enum DocPageSetup {
    /// Размеры бумаги в твипах (книжная ориентация).
    package enum Paper: CaseIterable, Equatable {
        case a4, a5, letter, legal

        package var title: String {
            switch self {
            case .a4: return "A4"
            case .a5: return "A5"
            case .letter: return "Letter"
            case .legal: return "Legal"
            }
        }

        package var size: (width: Int, height: Int) {
            switch self {
            case .a4: return (11906, 16838)
            case .a5: return (8391, 11906)
            case .letter: return (12240, 15840)
            case .legal: return (12240, 20160)
            }
        }
    }

    /// Поля, твипы.
    package struct Margins: Equatable {
        package var left: Int, right: Int, top: Int, bottom: Int
        package init(left: Int, right: Int, top: Int, bottom: Int) {
            self.left = left
            self.right = right
            self.top = top
            self.bottom = bottom
        }

        /// Пресеты Word: «Обычные» (верх и низ 2 см, слева 3, справа 1,5), «Узкие» (1,27), «Средние» (2,54 / 1,91), «Широкие» (2,54 / 5,08).
        package static let normal = Margins(left: 1701, right: 851, top: 1134, bottom: 1134)
        package static let narrow = Margins(left: 720, right: 720, top: 720, bottom: 720)
        package static let moderate = Margins(left: 1083, right: 1083, top: 1440, bottom: 1440)
        package static let wide = Margins(left: 2880, right: 2880, top: 1440, bottom: 1440)
    }

    package enum Preset: CaseIterable {
        case normal, narrow, moderate, wide

        package var title: String {
            switch self {
            case .normal: return "Обычные"
            case .narrow: return "Узкие"
            case .moderate: return "Средние"
            case .wide: return "Широкие"
            }
        }

        package var margins: Margins {
            switch self {
            case .normal: return .normal
            case .narrow: return .narrow
            case .moderate: return .moderate
            case .wide: return .wide
            }
        }
    }

    /// Правка страницы раздела.
    package enum Change: Equatable {
        case margins(Margins)
        case landscape(Bool)
        case paper(Paper)
    }

    /// Страница раздела, как её читает раскладка.
    package struct Page: Equatable {
        package var width: Int
        package var height: Int
        package var margins: Margins
        package var isLandscape: Bool { width > height }
    }

    package static func page(of props: RTFSectionProps) -> Page {
        Page(width: props.pageWidth, height: props.pageHeight,
             margins: Margins(left: props.marginLeft, right: props.marginRight, top: props.marginTop, bottom: props.marginBottom))
    }

    /// Бумага страницы (в любой ориентации, допуск 20 твипов); `nil` — нестандартная.
    package static func paper(of page: Page) -> Paper? {
        let (long, short) = (max(page.width, page.height), min(page.width, page.height))
        return Paper.allCases.first { abs($0.size.height - long) <= 20 && abs($0.size.width - short) <= 20 }
    }

    /// Какой пресет полей сейчас (допуск 5 твипов); `nil` — свои.
    package static func preset(of margins: Margins) -> Preset? {
        Preset.allCases.first { preset in
            let m = preset.margins
            return abs(m.left - margins.left) <= 5 && abs(m.right - margins.right) <= 5 && abs(m.top - margins.top) <= 5 && abs(m.bottom - margins.bottom) <= 5
        }
    }

    /// Страница после правки (то, что должна прочитать раскладка).
    package static func result(of change: Change, on page: Page) -> Page {
        var page = page
        switch change {
        case .margins(let margins): page.margins = margins
        case .landscape(let on):
            if on != page.isLandscape { swap(&page.width, &page.height) }
        case .paper(let paper):
            let size = paper.size
            let landscape = page.isLandscape
            page.width = landscape ? size.height : size.width
            page.height = landscape ? size.width : size.height
        }
        return page
    }

    // MARK: - Поля в сантиметрах

    /// Сантиметры → твипы (1 см = 567 твипов, как у Word).
    package static func twips(cm: Double) -> Int { Int((cm * 567).rounded()) }

    package static func cm(twips: Int) -> Double { (Double(twips) / 567 * 100).rounded() / 100 }

    /// Число из поля ввода: «2,5», «2.5», «2,5 см»; `nil` — не число.
    package static func parse(cm text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "см", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    /// Почему такие поля нельзя: отрицательные, больше половины листа или оставляют меньше 2,5 см под текст. `nil` — можно.
    package static func problem(_ margins: Margins, page: Page) -> String? {
        let values = [margins.left, margins.right, margins.top, margins.bottom]
        guard values.allSatisfy({ $0 >= 0 }) else { return "Поле не может быть отрицательным" }
        guard margins.left + margins.right <= page.width - 1417 else { return "Слева и справа не остаётся места под текст (нужно не меньше 2,5 см)" }
        guard margins.top + margins.bottom <= page.height - 1417 else { return "Сверху и снизу не остаётся места под текст (нужно не меньше 2,5 см)" }
        return nil
    }

    // MARK: - Правка исходника

    /// Какие слои кодов есть у раздела: свои после `\sectd` и у документа.
    private struct Words {
        var section: [String: RTFToken] = [:]
        var document: [String: RTFToken] = [:]
    }

    private static let sectionNames = ["pgwsxn", "pghsxn", "marglsxn", "margrsxn", "margtsxn", "margbsxn", "lndscpsxn"]
    private static let documentNames = ["paperw", "paperh", "margl", "margr", "margt", "margb", "landscape"]

    /// Коды документа до первого `\sectd` (корень файла, глубина 1).
    private static func documentTokens(_ name: String, source: NSString, model: RTFDocumentModel) -> [RTFToken] {
        let end = model.documentPropsInsertion > 0 ? model.documentPropsInsertion : source.length
        var depth = 0
        return RTFLexer.tokens(source, in: NSRange(location: 0, length: min(end, source.length))).filter { token in
            switch token.kind {
            case .open: depth += 1
            case .close: depth -= 1
            default: break
            }
            return depth == 1 && token.kind == .word && token.name == name
        }
    }

    /// Правки кодов: куда и что писать. Раздел с собственными кодами — они; иначе документ из одного раздела (или раздел без `\sectd`) —
    /// коды документа; иначе (несколько разделов) — новые коды после `\sectd` этого раздела, чтобы не менять остальные.
    package static func plan(_ change: Change, section: Int, source: NSString, model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard model.sections.indices.contains(section) else { return .failure(FormatFailure(reason: "Нет такого раздела")) }
        let props = model.sections[section]
        let before = page(of: props.props)
        let after = result(of: change, on: before)
        let groups = RTFGroupIndex(source)

        var own: [String: RTFToken] = [:]
        for name in sectionNames { if let token = DocHeaderFooterEdits.sectionTokens(name, section: section, source: source, model: model, groups: groups).last { own[name] = token } }
        var doc: [String: RTFToken] = [:]
        for name in documentNames { if let token = documentTokens(name, source: source, model: model).last { doc[name] = token } }

        // Слой, в который пишем.
        enum Layer { case section, document }
        let hasOwnPageCodes = own.keys.contains { $0 != "lndscpsxn" }
        let layer: Layer
        if hasOwnPageCodes { layer = .section }
        else if model.sections.count == 1 || props.sectd == nil {
            if props.sectd == nil, model.sections.count > 1 { return .failure(FormatFailure(reason: "У раздела нет кода \\sectd")) }
            layer = .document
        } else { layer = .section }

        let names: (width: String, height: String, left: String, right: String, top: String, bottom: String, landscape: String) = layer == .section
            ? ("pgwsxn", "pghsxn", "marglsxn", "margrsxn", "margtsxn", "margbsxn", "lndscpsxn")
            : ("paperw", "paperh", "margl", "margr", "margt", "margb", "landscape")
        let existing = layer == .section ? own : doc
        let anchor: Int
        if layer == .section {
            guard let sectd = props.sectd else { return .failure(FormatFailure(reason: "У раздела нет кода \\sectd")) }
            anchor = NSMaxRange(sectd)
        } else {
            anchor = model.documentPropsInsertion
            guard anchor > 0 else { return .failure(FormatFailure(reason: "Нет места для кодов страницы в начале файла")) }
        }

        var edits: [FormatEdit] = []
        var order = 1
        // Свой код слоя — заменить число; кода нет, а значение иное, чем сейчас читается, — вписать.
        func set(_ name: String, _ value: Int, effective: Int) {
            if let token = existing[name] {
                if token.number != value { edits.append(FormatEdits.replacement(token, with: "\\\(name)\(value)", source: source, order: order)) }
            } else if value != effective {
                edits.append(FormatEdit(range: NSRange(location: anchor, length: 0), string: "\\\(name)\(value) ", order: order))
                order += 1
            }
        }
        switch change {
        case .margins:
            set(names.left, after.margins.left, effective: before.margins.left)
            set(names.right, after.margins.right, effective: before.margins.right)
            set(names.top, after.margins.top, effective: before.margins.top)
            set(names.bottom, after.margins.bottom, effective: before.margins.bottom)
        case .landscape, .paper:
            set(names.width, after.width, effective: before.width)
            set(names.height, after.height, effective: before.height)
            // Метка ориентации рядом с размером: у альбомной нужна, у книжной — убирается.
            let flagToken = existing[names.landscape]
            if after.isLandscape, flagToken == nil, after.isLandscape != before.isLandscape {
                edits.append(FormatEdit(range: NSRange(location: anchor, length: 0), string: "\\\(names.landscape) ", order: order))
                order += 1
            } else if !after.isLandscape, let token = flagToken {
                edits.append(DocHeaderFooterEdits.deletion(token, source: source))
            }
        }
        var plan = FormatPlan()
        plan.edits = edits
        guard !edits.isEmpty else { return .success(plan) }

        // Проверка: после правки разбор даёт ту же страницу этого раздела, а остальное — как было.
        if let problem = verify(plan, source: source, model: model, section: section, after: after) { return .failure(FormatFailure(reason: problem)) }
        return .success(plan)
    }

    /// `\landscape` у документа читается как «альбомная» у всех разделов, пока нет кода, который это отменяет; поэтому флаг в проверке
    /// берётся по факту чтения (раскладка по нему не считает — размер задают ширина и высота).
    private static func verify(_ plan: FormatPlan, source: NSString, model: RTFDocumentModel, section: Int, after: Page) -> String? {
        guard let text = FormatCheck.apply(plan.edits, to: source) else { return "Правки пересекаются" }
        guard DollarMarks.unbalancedBraces(in: text) == DollarMarks.unbalancedBraces(in: source) else { return "Нарушен баланс скобок {}" }
        var fresh = RTFReader.read(text, fallback: model.codePage)
        var expected = model
        for index in expected.sections.indices {
            expected.sections[index].props.landscape = false
            if fresh.sections.indices.contains(index) { fresh.sections[index].props.landscape = false }
        }
        expected.sections[section].props.pageWidth = after.width
        expected.sections[section].props.pageHeight = after.height
        expected.sections[section].props.marginLeft = after.margins.left
        expected.sections[section].props.marginRight = after.margins.right
        expected.sections[section].props.marginTop = after.margins.top
        expected.sections[section].props.marginBottom = after.margins.bottom
        guard fresh.sections.count == expected.sections.count else { return "Изменилось число разделов" }
        for index in expected.sections.indices where expected.sections[index].props != fresh.sections[index].props {
            return index == section ? "Страница раздела прочиталась не так" : "Изменилась страница другого раздела"
        }
        guard fresh.body.paragraphs.count == model.body.paragraphs.count, sameHeaders(fresh, model) else { return "Изменились абзацы или колонтитулы" }
        let sameText = DocPageSetup.visibleText(model.body) == DocPageSetup.visibleText(fresh.body)
        return sameText ? nil : "Изменился текст документа"
    }

    private static func sameHeaders(_ a: RTFDocumentModel, _ b: RTFDocumentModel) -> Bool {
        guard a.sections.count == b.sections.count else { return false }
        for (x, y) in zip(a.sections, b.sections) {
            guard Set(x.headers.keys) == Set(y.headers.keys) else { return false }
            for (kind, header) in x.headers where visibleText(header.story) != y.headers[kind].map({ visibleText($0.story) }) { return false }
        }
        return true
    }

    private static func visibleText(_ story: RTFStory) -> String {
        story.paragraphs.map { $0.runs.map(\.text).joined() }.joined(separator: "\n")
    }
}

/// Команда «Параметры страницы» для ленты и `DocumentController`: доступность и выполнение (одна правка — один шаг отмены).
package enum DocPageSetupCommand {
    package enum Availability: Equatable {
        case hidden
        case disabled(String)
        case enabled

        package var isEnabled: Bool { self == .enabled }
    }

    package static func availability(_ change: DocPageSetup.Change, isDocument: Bool, page: DocPageSetup.Page?) -> Availability {
        guard isDocument else { return .hidden }
        guard let page else { return .disabled("Нет страницы") }
        if case .margins(let margins) = change, let problem = DocPageSetup.problem(margins, page: page) { return .disabled(problem) }
        return .enabled
    }

    package static func actionName(_ change: DocPageSetup.Change) -> String {
        switch change {
        case .margins: return "Поля страницы"
        case .landscape: return "Ориентация страницы"
        case .paper: return "Размер страницы"
        }
    }
}

extension DocumentController {
    /// Раздел под курсором (в правке колонтитула — раздел его страницы).
    package var pageSetupSection: Int {
        if let session = openHeaderSession, let page = session.page { return page.section }
        guard let index = rendering.paragraph(atUnit: min(selectedUnits.location, max(0, rendering.length - 1))) else { return 0 }
        return model.body.paragraphs[safe: index]?.section ?? 0
    }

    /// Страница раздела под курсором.
    package var currentPageSetup: DocPageSetup.Page? {
        model.sections[safe: pageSetupSection].map { DocPageSetup.page(of: $0.props) }
    }

    /// Применить правку страницы к разделу под курсором. `false` — недоступно или отказ (причина показана подсказкой).
    @discardableResult
    package func perform(_ change: DocPageSetup.Change) -> Bool {
        guard let tab, tab.mode == .document else { return false }
        if case .disabled(let reason) = DocPageSetupCommand.availability(change, isDocument: true, page: currentPageSetup) {
            show(notice: reason)
            Feedback.beep()
            return false
        }
        typingBurst = nil
        switch DocPageSetup.plan(change, section: pageSetupSection, source: tab.text, model: model) {
        case .failure(let failure):
            show(notice: "Нельзя без потерь: \(failure.reason.lowercasedFirst). Изменить это можно в режиме «Код»")
            Feedback.beep()
            return false
        case .success(let plan):
            guard !plan.edits.isEmpty else { return true }
            guard let edits = FormatCheck.merged(plan.edits) else { return false }
            let selection = selectedUnits
            let done = apply(edits.map { DocEdit(range: $0.range, text: $0.string) }, actionName: DocPageSetupCommand.actionName(change)) { _ in selection }
            objectWillChange.send()  // отметки в ленте — по новой странице
            return done
        }
    }
}

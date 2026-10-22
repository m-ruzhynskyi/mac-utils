import Foundation

/// Проверка команды форматирования до записи в исходник: правки применяются к копии, копия перечитывается
/// `RTFReader`, и всё, кроме цели команды, должно совпасть с прежней моделью — текст, свойства символов и абзацев,
/// таблицы, колонтитулы, разделы, поля, шрифты и цвета. Цель должна получить ровно то, что просили.
enum FormatCheck {
    /// Что ещё разрешено поменять (команды колонтитулов).
    struct Allowance {
        /// Прежние разделы и `\facingp` → ожидаемые.
        var sections: ((inout [RTFSection], inout Bool) -> Void)?
        /// Новые поля (номер страницы) и вырезанные (вместе с колонтитулом).
        var extraFields: [RTFFieldKind] = []
        var removedFields: [RTFFieldKind] = []
        /// История, которую проверяет `storyCheck` (вставка текста): прежняя и новая → что не так.
        var story: DocStoryRef?
        var storyCheck: ((RTFStory, RTFStory) -> String?)?
    }

    // MARK: - Правки

    /// Правки по порядку исходника; вставки в одном месте склеены по `order`. `nil` — правки пересекаются.
    static func merged(_ edits: [FormatEdit]) -> [FormatEdit]? {
        let sorted = edits.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            // В одном месте: сначала вставки (по `order`), потом замена.
            if (a.range.length == 0) != (b.range.length == 0) { return a.range.length == 0 }
            if a.order != b.order { return a.order < b.order }
            return lhs.offset < rhs.offset
        }.map(\.element)
        var result: [FormatEdit] = []
        for edit in sorted {
            if var last = result.last, last.range.location == edit.range.location, last.range.length == 0 {
                last.range.length = edit.range.length
                last.string += edit.string
                result[result.count - 1] = last
                continue
            }
            if let last = result.last, edit.range.location < NSMaxRange(last.range) { return nil }
            result.append(edit)
        }
        return result
    }

    /// Исходник после правок (правки — из `merged`).
    static func apply(_ edits: [FormatEdit], to source: NSString) -> NSString? {
        guard let edits = merged(edits) else { return nil }
        let result = NSMutableString(capacity: source.length + edits.reduce(0) { $0 + ($1.string as NSString).length })
        var cursor = 0
        for edit in edits {
            guard edit.range.location >= cursor, NSMaxRange(edit.range) <= source.length else { return nil }
            result.append(source.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)))
            result.append(edit.string)
            cursor = NSMaxRange(edit.range)
        }
        result.append(source.substring(from: cursor))
        return result
    }

    // MARK: - Проверка

    /// `nil` — всё в порядке, иначе — что не так (для подсказки и журнала).
    static func verify(_ plan: FormatPlan, source: NSString, model: RTFDocumentModel, allowing allowance: Allowance = Allowance()) -> String? {
        guard let text = apply(plan.edits, to: source) else { return "Правки пересекаются" }
        let before = DollarMarks.unbalancedBraces(in: source)
        guard DollarMarks.unbalancedBraces(in: text) == before else { return "Нарушен баланс скобок {}" }
        let fresh = RTFReader.read(text, fallback: model.codePage)
        return compare(old: model, new: fresh, plan: plan, allowing: allowance)
    }

    static func compare(old: RTFDocumentModel, new: RTFDocumentModel, plan: FormatPlan, allowing allowance: Allowance = Allowance()) -> String? {
        guard old.isRTF == new.isRTF, old.codePage == new.codePage, old.defaultTab == new.defaultTab else { return "Изменились свойства документа" }
        guard old.defaultFont == new.defaultFont else { return "Изменился шрифт по умолчанию" }
        if let problem = compareFonts(old: old, new: new, added: plan.addedFonts) { return problem }
        if let problem = compareColors(old: old, new: new, added: plan.addedColors) { return problem }
        // Поля — как набор: новые (номер страницы) встают в середину списка.
        var fields = Dictionary(grouping: old.fields.map(\.kind) + allowance.extraFields, by: { $0 }).mapValues(\.count)
        for kind in allowance.removedFields { fields[kind, default: 0] -= 1 }
        guard fields.filter({ $0.value != 0 }) == Dictionary(grouping: new.fields.map(\.kind), by: { $0 }).mapValues(\.count) else {
            return "Изменились поля"
        }
        var sections = old.sections
        var facing = old.facingPages
        allowance.sections?(&sections, &facing)
        guard facing == new.facingPages else { return "Изменился режим чётных и нечётных страниц" }
        guard sections.count == new.sections.count else { return "Изменилось число разделов" }
        if let problem = check(old.body, new.body, ref: .body, plan: plan, allowance: allowance, old: old, new: new) { return problem }
        for (index, section) in sections.enumerated() {
            let fresh = new.sections[index]
            guard section.props == fresh.props else { return "Изменились свойства раздела \(index + 1)" }
            guard Set(section.headers.keys) == Set(fresh.headers.keys) else { return "Изменились колонтитулы раздела \(index + 1)" }
            for (kind, header) in section.headers {
                guard let other = fresh.headers[kind] else { return "Пропал колонтитул" }
                let ref = DocStoryRef.header(section: index, kind: kind)
                if let problem = check(header.story, other.story, ref: ref, plan: plan, allowance: allowance, old: old, new: new) { return problem }
            }
        }
        return nil
    }

    private static func compareFonts(old: RTFDocumentModel, new: RTFDocumentModel, added: [RTFFont]) -> String? {
        for (number, font) in old.fonts where new.fonts[number] != font { return "Изменилась запись таблицы шрифтов" }
        guard new.fonts.count == old.fonts.count + added.count else { return "Лишние записи в таблице шрифтов" }
        for font in added {
            guard let parsed = new.fonts[font.number], parsed.name == font.name, parsed.charset == font.charset,
                  parsed.codePage == font.codePage else { return "Новый шрифт записался не так" }
        }
        return nil
    }

    private static func compareColors(old: RTFDocumentModel, new: RTFDocumentModel, added: [RTFColor]) -> String? {
        let base = added.isEmpty ? old.colors.count : max(old.colors.count, 1)
        guard new.colors.count == base + added.count else { return "Лишние записи в таблице цветов" }
        guard Array(new.colors.prefix(old.colors.count)) == old.colors else { return "Изменилась запись таблицы цветов" }
        if !added.isEmpty, old.colors.isEmpty, new.colors.first != .some(nil) { return "Цвет «авто» записался не так" }
        guard Array(new.colors.suffix(added.count)) == added.map(Optional.some) else { return "Новый цвет записался не так" }
        return nil
    }

    // MARK: - Истории

    private static func check(_ before: RTFStory, _ after: RTFStory, ref: DocStoryRef, plan: FormatPlan, allowance: Allowance,
                              old: RTFDocumentModel, new: RTFDocumentModel) -> String? {
        if allowance.story == ref, let storyCheck = allowance.storyCheck { return storyCheck(before, after) }
        return compareStory(before, after, ref: ref, plan: plan, old: old, new: new)
    }

    private static func compareStory(_ before: RTFStory, _ after: RTFStory, ref: DocStoryRef, plan: FormatPlan,
                                     old: RTFDocumentModel, new: RTFDocumentModel) -> String? {
        let isTarget = plan.story == ref
        guard before.paragraphs.count == after.paragraphs.count else { return "Изменилось число абзацев" }
        guard before.tables.count == after.tables.count else { return "Изменились таблицы" }
        for (table, fresh) in zip(before.tables, after.tables) {
            guard table.rows.count == fresh.rows.count else { return "Изменились строки таблицы" }
            for (row, other) in zip(table.rows, fresh.rows) {
                guard row.cells == other.cells, row.paragraphs == other.paragraphs, row.left == other.left, row.gap == other.gap,
                      row.height == other.height, row.header == other.header else { return "Изменились ячейки таблицы" }
            }
        }
        for (index, (paragraph, fresh)) in zip(before.paragraphs, after.paragraphs).enumerated() {
            guard paragraph.end == fresh.end, paragraph.cell == fresh.cell, paragraph.section == fresh.section else { return "Изменилась структура абзацев" }
            var props = paragraph.props
            if isTarget, plan.paraTargets.contains(index), let change = plan.paraChange { props = change.apply(to: props) }
            guard props == fresh.props else { return isTarget && plan.paraTargets.contains(index) ? "Свойства абзаца не применились" : "Изменились свойства другого абзаца" }
            if isTarget, let targets = plan.charTargets[index], let change = plan.charChange {
                if let problem = compareUnits(paragraph, fresh, targets: targets, change: change, old: old, new: new) { return problem }
            } else if !sameRuns(paragraph.runs, fresh.runs, old: old, new: new) {
                return "Изменился текст или формат вне выделения"
            }
        }
        return nil
    }

    static func sameRuns(_ lhs: [RTFRun], _ rhs: [RTFRun], old: RTFDocumentModel, new: RTFDocumentModel) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            guard a.kind == b.kind, a.text == b.text, a.props == b.props, a.picture == b.picture,
                  fieldKey(a.field, old) == fieldKey(b.field, new) else { return false }
        }
        return true
    }

    /// Поле по смыслу, а не по номеру: номера сдвигаются, когда в начало вставлено новое поле.
    static func fieldKey(_ index: Int?, _ model: RTFDocumentModel) -> String? {
        guard let index, index < model.fields.count else { return nil }
        return model.fields[index].instruction
    }

    /// Единица показанного текста абзаца: символ UTF-16, вид прогона и его свойства.
    struct Unit {
        var unit: UInt16
        var kind: RTFRun.Kind
        var props: RTFCharProps
        var field: String?
    }

    static func units(_ paragraph: RTFParagraph, model: RTFDocumentModel) -> [Unit] {
        var result: [Unit] = []
        for run in paragraph.runs {
            let field = fieldKey(run.field, model)
            for unit in run.text.utf16 { result.append(Unit(unit: unit, kind: run.kind, props: run.props, field: field)) }
        }
        return result
    }

    private static func compareUnits(_ before: RTFParagraph, _ after: RTFParagraph, targets: Set<Int>, change: CharChange,
                                     old: RTFDocumentModel, new: RTFDocumentModel) -> String? {
        let lhs = units(before, model: old), rhs = units(after, model: new)
        guard lhs.count == rhs.count else { return "Изменился текст абзаца" }
        for (index, (a, b)) in zip(lhs, rhs).enumerated() {
            guard a.unit == b.unit, a.kind == b.kind, a.field == b.field else { return "Изменился текст абзаца" }
            if targets.contains(index) {
                guard expected(b.props, from: a.props, change: change, old: old, new: new) else { return "Формат не применился" }
            } else if a.props != b.props {
                return "Изменился формат вне выделения"
            }
        }
        return nil
    }

    /// Получил ли символ то, что просила команда, — и ничего больше.
    static func expected(_ props: RTFCharProps, from original: RTFCharProps, change: CharChange, old: RTFDocumentModel,
                         new: RTFDocumentModel) -> Bool {
        var expect = original
        let encoding = FormatTables.encoding(of: old.font(original.font), model: old)
        switch change {
        case .bold(let on): expect.bold = on
        case .italic(let on): expect.italic = on
        case .underline(let on): expect.underline = on ? .single : .none
        case .strike(let on): expect.strike = on
        case .vertical(let vertical): expect.vertical = vertical
        case .smallCaps(let on): expect.smallCaps = on
        case .caps(let on): expect.caps = on
        case .hidden(let on): expect.hidden = on
        case .size(let halfPoints): expect.halfPoints = min(max(halfPoints, 2), 3_276)
        case .color(let color):
            guard new.color(props.color) == color, color != nil || props.color == 0 else { return false }
            expect.color = props.color
        case .highlight(let color):
            guard new.color(props.highlight) == color, color != nil || props.highlight == 0 else { return false }
            expect.highlight = props.highlight
        case .font(let name):
            let font = new.font(props.font)
            guard font?.name == name.trimmingCharacters(in: .whitespaces), FormatTables.encoding(of: font, model: new) == encoding else { return false }
            expect.font = props.font
        case .clear:
            expect = RTFCharProps()
            let font = new.font(props.font)
            guard font?.name == old.font(nil)?.name, FormatTables.encoding(of: font, model: new) == encoding || font == nil else { return false }
            expect.font = props.font
        }
        return expect == props
    }
}

import Foundation
import MUCore
import MUDesign
import MUAudio
import MUScreenshot

/// Точечные правки колонтитулов (D-4а): новая пустая группа `{\header… }`, удаление группы, `\titlepg` у раздела,
/// `\facingp` у документа, поле номера страницы. Всё остальное в исходнике остаётся байт в байт; каждая правка
/// проверяется тем же `FormatCheck`, с разрешением ровно на свою перемену.
enum DocHeaderFooterEdits {
    /// Пустой колонтитул, как его пишет Word: один абзац со шрифтом документа.
    static func emptyGroup(_ kind: RTFHeaderKind) -> String { "{\\\(kind.rawValue) \\pard\\plain \\par}" }

    // MARK: - Колонтитул целиком

    /// Добавить пустой колонтитул `kinds` разделу `section` (после его последнего колонтитула или перед текстом).
    static func add(_ kinds: [RTFHeaderKind], section: Int, source: NSString, model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard section < model.sections.count else { return .failure(FormatFailure(reason: "Нет такого раздела")) }
        let missing = kinds.filter { model.sections[section].headers[$0] == nil }
        guard !missing.isEmpty else { return .success(FormatPlan()) }
        let groups = RTFGroupIndex(source)
        let location = rootLevel(model.sections[section].headerInsertion, groups: groups)
        var plan = FormatPlan()
        plan.edits = [FormatEdit(range: NSRange(location: location, length: 0), string: missing.map(emptyGroup).joined(), order: 1)]
        let allowance = FormatCheck.Allowance(sections: { sections, _ in
            for kind in missing { sections[section].headers[kind] = RTFHeader(kind: kind, story: emptyStory(section: section), group: NSRange()) }
        })
        if let problem = FormatCheck.verify(plan, source: source, model: model, allowing: allowance) { return .failure(FormatFailure(reason: problem)) }
        return .success(plan)
    }

    /// Каким должен прочитаться новый пустой колонтитул.
    static func emptyStory(section: Int) -> RTFStory {
        var paragraph = RTFParagraph()
        paragraph.end = .paragraph
        paragraph.section = section
        return RTFStory(paragraphs: [paragraph])
    }

    /// Удалить колонтитул: вырезать его группу целиком.
    static func remove(_ kind: RTFHeaderKind, section: Int, source: NSString, model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard section < model.sections.count, let header = model.sections[section].headers[kind] else {
            return .failure(FormatFailure(reason: "Колонтитула нет"))
        }
        var plan = FormatPlan()
        plan.edits = [FormatEdit(range: header.group, string: "")]
        // Поля внутри колонтитула уходят вместе с ним.
        let removed = model.fields.filter { NSLocationInRange($0.group.location, header.group) }.map(\.kind)
        let allowance = FormatCheck.Allowance(sections: { sections, _ in sections[section].headers[kind] = nil }, removedFields: removed)
        if let problem = FormatCheck.verify(plan, source: source, model: model, allowing: allowance) { return .failure(FormatFailure(reason: problem)) }
        return .success(plan)
    }

    // MARK: - Особый первый лист и чётные/нечётные

    /// «Другой на первой странице»: `\titlepg` у раздела (и пустые `\headerf`/`\footerf`, если их нет и не наследуются);
    /// выключить — убрать `\titlepg`, сами колонтитулы первой страницы остаются в файле, как в Word.
    static func titlePage(_ on: Bool, section: Int, inherited: Set<RTFHeaderKind>, source: NSString,
                          model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard section < model.sections.count else { return .failure(FormatFailure(reason: "Нет такого раздела")) }
        guard model.sections[section].props.titlePage != on else { return .success(FormatPlan()) }
        let groups = RTFGroupIndex(source)
        var plan = FormatPlan()
        var added: [RTFHeaderKind] = []
        if on {
            let location = model.sections[section].sectd.map(NSMaxRange) ?? rootLevel(model.sections[section].headerInsertion, groups: groups)
            plan.edits.append(FormatEdit(range: NSRange(location: location, length: 0), string: "\\titlepg ", order: 1))
            added = [.headerFirst, .footerFirst].filter { model.sections[section].headers[$0] == nil && !inherited.contains($0) }
            if !added.isEmpty {
                let insertion = rootLevel(model.sections[section].headerInsertion, groups: groups)
                plan.edits.append(FormatEdit(range: NSRange(location: insertion, length: 0), string: added.map(emptyGroup).joined(), order: 2))
            }
        } else {
            let tokens = sectionTokens("titlepg", section: section, source: source, model: model, groups: groups)
            guard !tokens.isEmpty else { return .failure(FormatFailure(reason: "Не нашёл код \\titlepg раздела")) }
            plan.edits = tokens.map { deletion($0, source: source) }
        }
        let allowance = FormatCheck.Allowance(sections: { sections, _ in
            sections[section].props.titlePage = on
            for kind in added { sections[section].headers[kind] = RTFHeader(kind: kind, story: emptyStory(section: section), group: NSRange()) }
        })
        if let problem = FormatCheck.verify(plan, source: source, model: model, allowing: allowance) { return .failure(FormatFailure(reason: problem)) }
        return .success(plan)
    }

    /// «Чётные и нечётные»: `\facingp` у документа и пустые колонтитулы чётных страниц у первого раздела, если их нет;
    /// выключить — убрать `\facingp`.
    static func facingPages(_ on: Bool, source: NSString, model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard model.facingPages != on else { return .success(FormatPlan()) }
        let groups = RTFGroupIndex(source)
        var plan = FormatPlan()
        var added: [RTFHeaderKind] = []
        if on {
            let location = rootLevel(model.documentPropsInsertion, groups: groups)
            plan.edits.append(FormatEdit(range: NSRange(location: location, length: 0), string: "\\facingp ", order: 1))
            if let first = model.sections.first {
                added = [.headerLeft, .footerLeft].filter { first.headers[$0] == nil }
                if !added.isEmpty {
                    let insertion = rootLevel(first.headerInsertion, groups: groups)
                    plan.edits.append(FormatEdit(range: NSRange(location: insertion, length: 0), string: added.map(emptyGroup).joined(), order: 2))
                }
            }
        } else {
            guard let range = model.facingPagesRange else { return .failure(FormatFailure(reason: "Не нашёл код \\facingp")) }
            plan.edits = [deletion(RTFLexer.controlToken(source, at: range.location), source: source)]
        }
        let allowance = FormatCheck.Allowance(sections: { sections, facing in
            facing = on
            for kind in added where !sections.isEmpty {
                sections[0].headers[kind] = RTFHeader(kind: kind, story: emptyStory(section: 0), group: NSRange())
            }
        })
        if let problem = FormatCheck.verify(plan, source: source, model: model, allowing: allowance) { return .failure(FormatFailure(reason: problem)) }
        return .success(plan)
    }

    // MARK: - Номер страницы

    enum PageNumber: Equatable {
        /// `PAGE`.
        case page
        /// «Стр. X из Y»: `PAGE` и `NUMPAGES`.
        case pageOfTotal
    }

    /// Поле номера страницы в колонтитуле перед показанной единицей `unit` его истории (`map` — карта показанного
    /// колонтитула). Поля неделимы: внутрь поля не вставляется.
    static func insertPageNumber(_ number: PageNumber, story ref: DocStoryRef, unit: Int, map: DocSourceMap, source: NSString,
                                 model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard let story = model.story(ref) else { return .failure(FormatFailure(reason: "Нет такого колонтитула")) }
        guard unit <= map.count else { return .failure(FormatFailure(reason: "Курсор вне колонтитула")) }
        if unit < map.count, map.kind(at: unit) == .field, unit > 0, map.kind(at: unit - 1) == .field, map.range(at: unit) == map.range(at: unit - 1) {
            return .failure(FormatFailure(reason: "Курсор внутри поля"))
        }
        let location = map.sourceLocation(beforeUnit: unit)
        // Кодировка и `\ucN` — у текста в этом месте.
        let (paragraphIndex, offset, run) = position(of: location, in: story)
        let encoding = FormatTables.encoding(of: model.font(run?.props.font), model: model)
        let uc = run?.uc ?? 1
        let page = "{\\field{\\*\\fldinst PAGE }{\\fldrslt 1}}"
        let text: String
        let inserted: [(String, RTFRun.Kind)]
        var fields: [RTFFieldKind] = [.page]
        switch number {
        case .page:
            text = page
            inserted = [("1", .field(.page))]
        case .pageOfTotal:
            text = FormatText.encode("Стр. ", encoding: encoding, uc: uc) + page + FormatText.encode(" из ", encoding: encoding, uc: uc)
                + "{\\field{\\*\\fldinst NUMPAGES }{\\fldrslt 1}}"
            inserted = [("Стр. ", .text), ("1", .field(.page)), (" из ", .text), ("1", .field(.numPages))]
            fields.append(.numPages)
        }
        var plan = FormatPlan()
        plan.edits = [FormatEdit(range: NSRange(location: location, length: 0), string: text, order: 1)]
        let expectedUnits = inserted.flatMap { piece in piece.0.utf16.map { ($0, piece.1) } }
        let allowance = FormatCheck.Allowance(extraFields: fields, story: ref) { before, after in
            insertionCheck(before, after, paragraph: paragraphIndex, offset: offset, units: expectedUnits)
        }
        if let problem = FormatCheck.verify(plan, source: source, model: model, allowing: allowance) { return .failure(FormatFailure(reason: problem)) }
        return .success(plan)
    }

    /// Абзац и номер единицы в нём, перед которой стоит место исходника, и прогон, чей текст там.
    static func position(of location: Int, in story: RTFStory) -> (paragraph: Int, offset: Int, run: RTFRun?) {
        for (index, paragraph) in story.paragraphs.enumerated() where location <= NSMaxRange(paragraph.endRange) || index == story.paragraphs.count - 1 {
            var offset = 0
            for run in paragraph.runs {
                for range in run.map {
                    if range.location >= location { return (index, offset, run) }
                    offset += 1
                }
            }
            return (index, offset, paragraph.runs.last)
        }
        return (0, 0, nil)
    }

    /// После вставки: в абзаце те же единицы, плюс вставленные на своём месте; остальные абзацы — как были.
    private static func insertionCheck(_ before: RTFStory, _ after: RTFStory, paragraph: Int, offset: Int,
                                       units: [(UInt16, RTFRun.Kind)]) -> String? {
        guard before.paragraphs.count == after.paragraphs.count else { return "Изменилось число абзацев колонтитула" }
        for (index, (old, new)) in zip(before.paragraphs, after.paragraphs).enumerated() {
            guard old.props == new.props, old.end == new.end else { return "Изменились свойства абзаца колонтитула" }
            let lhs = FormatCheck.units(old, model: RTFDocumentModel()), rhs = FormatCheck.units(new, model: RTFDocumentModel())
            if index != paragraph {
                guard lhs.count == rhs.count, zip(lhs, rhs).allSatisfy({ $0.unit == $1.unit && $0.kind == $1.kind && $0.props == $1.props }) else {
                    return "Изменился другой абзац колонтитула"
                }
                continue
            }
            guard rhs.count == lhs.count + units.count else { return "Вставилось не то" }
            for (k, unit) in lhs.enumerated() {
                let other = rhs[k < offset ? k : k + units.count]
                guard unit.unit == other.unit, unit.kind == other.kind, unit.props == other.props else { return "Изменился текст колонтитула" }
            }
            for (k, unit) in units.enumerated() {
                let other = rhs[offset + k]
                guard other.unit == unit.0, other.kind == unit.1 else { return "Номер страницы вставился не так" }
            }
        }
        return nil
    }

    // MARK: - Помощники

    /// Место на уровне документа: если `location` внутри вложенной группы — перед этой группой.
    static func rootLevel(_ location: Int, groups: RTFGroupIndex) -> Int {
        guard var group = groups.innermost(containing: location) else { return location }
        guard groups.parents[group] >= 0 else { return location }
        while groups.parents[group] >= 0, groups.parents[groups.parents[group]] >= 0 { group = groups.parents[group] }
        return groups.opens[group]
    }

    /// Коды `name` раздела на уровне документа — от `\sectd` (или начала раздела) до его первого абзаца.
    static func sectionTokens(_ name: String, section: Int, source: NSString, model: RTFDocumentModel, groups: RTFGroupIndex) -> [RTFToken] {
        let props = model.sections[section]
        let body = model.body.paragraphs
        var start = props.sectd?.location ?? 0
        if props.sectd == nil, section > 0, props.firstParagraph > 0, props.firstParagraph - 1 < body.count {
            start = NSMaxRange(body[props.firstParagraph - 1].endRange)
        }
        let end = props.firstParagraph < body.count ? body[props.firstParagraph].contentStart : source.length
        guard end > start, let group = groups.innermost(containing: start), groups.parents[group] < 0 else { return [] }
        var depth = 0
        return RTFLexer.tokens(source, in: NSRange(location: start, length: end - start)).filter { token in
            switch token.kind {
            case .open: depth += 1
            case .close: depth -= 1
            default: break
            }
            return depth == 0 && token.kind == .word && token.name == name
        }
    }

    /// Вырезать код. Если слева слово без разделителя, а справа буква или цифра — оставить пробел, чтобы они не слились.
    static func deletion(_ token: RTFToken, source: NSString) -> FormatEdit {
        let range = token.range
        let end = NSMaxRange(range)
        guard range.location > 0, end < source.length else { return FormatEdit(range: range, string: "") }
        let before = source.character(at: range.location - 1), after = source.character(at: end)
        let wordBefore = RTFLexer.isLetter(before) || RTFLexer.isDigit(before)
        let joins = wordBefore && (RTFLexer.isLetter(after) || RTFLexer.isDigit(after) || after == 0x2D || after == 0x20)
        // Слева — конец управляющего слова (а не текст)? Ищем `\` перед буквами и цифрами.
        if joins {
            var k = range.location - 1
            while k > 0, RTFLexer.isLetter(source.character(at: k)) || RTFLexer.isDigit(source.character(at: k)) || source.character(at: k) == 0x2D { k -= 1 }
            if source.character(at: k) == 0x5C { return FormatEdit(range: range, string: " ") }
        }
        return FormatEdit(range: range, string: "")
    }
}

/// Текст для вставки в исходник: ASCII как есть (служебные `\ { }` экранируются), остальное — `\'hh` в кодировке
/// места, а что в неё не входит — `\uN` с заменителями `\'3f` по `\ucN`.
enum FormatText {
    static func encode(_ text: String, encoding: TextEncoding, uc: Int) -> String {
        let table = SingleByteTable.table(for: encoding)
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x5C, 0x7B, 0x7D: out += "\\" + String(scalar)
            case 0x20..<0x80: out.unicodeScalars.append(scalar)
            default:
                if let byte = table?.byte(for: scalar.value) {
                    out += String(format: "\\'%02x", byte)
                } else {
                    for unit in String(scalar).utf16 {
                        out += "\\u\(Int(Int16(bitPattern: unit)))" + String(repeating: "\\'3f", count: max(0, uc))
                    }
                }
            }
        }
        return out
    }
}

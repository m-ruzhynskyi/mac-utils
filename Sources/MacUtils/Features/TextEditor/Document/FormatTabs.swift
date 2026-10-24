import Foundation
import MUAudio
import MUScreenshot

/// Правка позиции табуляции с линейки.
enum TabEdit: Equatable {
    /// Новая позиция (в конец списка кодов абзаца — так её и прочитает `RTFReader`).
    case add(RTFTabStop)
    /// Позицию номер `index` (по порядку кодов) — на `to` твипов от левого поля.
    case move(Int, to: Int)
    case remove(Int)
}

extension FormatEdits {
    /// Код одной позиции табуляции в абзаце: необязательные `\tqr`/`\tldot`… и сам `\txN` (или `\tbN`).
    struct TabCode {
        /// От первого кода вида до конца `\tx` с разделителем.
        var range: NSRange
        var tx: RTFToken
    }

    /// Позиции табуляции правятся только у абзаца со своим `\pard`, все коды которого стоят на уровне этого `\pard`:
    /// тогда каждая позиция — ровно свой кусок исходника.
    static func tabCodes(_ paragraph: RTFParagraph, story: DocStoryRef, source: NSString, groups: RTFGroupIndex) -> [TabCode]? {
        guard let pard = paragraph.pard else { return nil }
        let end = endLocation(paragraph, story: story, groups: groups)
        guard end > NSMaxRange(pard) else { return paragraph.props.tabs.isEmpty ? [] : nil }
        var codes: [TabCode] = []
        var depth = 0
        var pending: Int?
        for token in RTFLexer.tokens(source, in: NSRange(location: NSMaxRange(pard), length: end - NSMaxRange(pard))) {
            switch token.kind {
            case .open: depth += 1
            case .close: depth -= 1
            case .word where depth == 0:
                if ["tqr", "tqc", "tqdec", "tldot", "tlhyph", "tlul", "tlth", "tleq", "tlmdot"].contains(token.name) {
                    pending = pending ?? token.range.location
                } else if token.name == "tx" || token.name == "tb" {
                    let start = pending ?? token.range.location
                    codes.append(TabCode(range: NSRange(location: start, length: NSMaxRange(token.range) - start), tx: token))
                    pending = nil
                } else if token.name == "pard" {
                    return nil
                }
            default: break
            }
        }
        // Столько же, сколько прочитал разбор, — значит, никакая позиция не пришла из вложенной группы.
        return codes.count == paragraph.props.tabs.count ? codes : nil
    }

    /// Текст кодов новой позиции, как пишет Word: `\tqr\tldot\tx9355`.
    static func tabText(_ stop: RTFTabStop) -> String {
        var text = ""
        switch stop.kind {
        case .left, .bar: break
        case .center: text += "\\tqc"
        case .right: text += "\\tqr"
        case .decimal: text += "\\tqdec"
        }
        if stop.leader { text += "\\tldot" }
        text += stop.kind == .bar ? "\\tb\(stop.position)" : "\\tx\(stop.position)"
        return text
    }

    static func tabs(_ edit: TabEdit, paragraphs: [Int], story ref: DocStoryRef = .body, source: NSString,
                     model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard let story = model.story(ref) else { return .failure(FormatFailure(reason: "Нет такого колонтитула")) }
        let targets = paragraphs.filter { $0 >= 0 && $0 < story.paragraphs.count }
        guard let first = targets.first else { return .failure(FormatFailure(reason: "Нет абзаца")) }
        guard targets.allSatisfy({ story.paragraphs[$0].props.tabs == story.paragraphs[first].props.tabs }) else {
            return .failure(FormatFailure(reason: "У выделенных абзацев разные табуляции"))
        }
        let groups = RTFGroupIndex(source)
        var plan = FormatPlan(story: ref, paraChange: ParaChange(tabs: edit))
        plan.paraTargets = Set(targets)
        for index in targets {
            let paragraph = story.paragraphs[index]
            guard let codes = tabCodes(paragraph, story: ref, source: source, groups: groups) else {
                return .failure(FormatFailure(reason: "Табуляции этого абзаца записаны не у него самого"))
            }
            switch edit {
            case .add(let stop):
                let location = codes.last.map { NSMaxRange($0.range) } ?? NSMaxRange(paragraph.pard!)
                plan.edits.append(FormatEdit(range: NSRange(location: location, length: 0), string: tabText(stop) + " ", order: 1))
            case .move(let number, let position):
                guard codes.indices.contains(number) else { return .failure(FormatFailure(reason: "Нет такой позиции табуляции")) }
                let word = (codes[number].tx.name == "tb" ? "\\tb" : "\\tx") + "\(position)"
                plan.edits.append(replacement(codes[number].tx, with: word, source: source))
            case .remove(let number):
                guard codes.indices.contains(number) else { return .failure(FormatFailure(reason: "Нет такой позиции табуляции")) }
                plan.edits.append(cut(codes[number].range, source: source))
            }
        }
        if let problem = FormatCheck.verify(plan, source: source, model: model) { return .failure(FormatFailure(reason: problem)) }
        return .success(plan)
    }

    /// Вырезать кусок кодов; если слева слово без разделителя, а справа буква, цифра или минус — оставить пробел.
    static func cut(_ range: NSRange, source: NSString) -> FormatEdit {
        let end = NSMaxRange(range)
        guard range.location > 0, end < source.length else { return FormatEdit(range: range, string: "") }
        let after = source.character(at: end)
        guard RTFLexer.isLetter(after) || RTFLexer.isDigit(after) || after == 0x2D || after == 0x20 else { return FormatEdit(range: range, string: "") }
        var k = range.location - 1
        while k > 0, RTFLexer.isLetter(source.character(at: k)) || RTFLexer.isDigit(source.character(at: k)) || source.character(at: k) == 0x2D { k -= 1 }
        return FormatEdit(range: range, string: k < range.location - 1 && source.character(at: k) == 0x5C ? " " : "")
    }
}

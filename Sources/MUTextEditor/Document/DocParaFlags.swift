import Foundation

/// Флаг абзаца без числа (E-4): «Не отрывать от следующего» (`\keepn`), «Не разрывать абзац» (`\keep`),
/// «С новой страницы» (`\pagebb`).
package enum DocParaFlag: String, CaseIterable {
    case keepNext = "keepn", keepTogether = "keep", pageBreakBefore = "pagebb"

    package var title: String {
        switch self {
        case .keepNext: return "Не отрывать от следующего"
        case .keepTogether: return "Не разрывать абзац"
        case .pageBreakBefore: return "С новой страницы"
        }
    }

    package func value(_ props: RTFParaProps) -> Bool {
        switch self {
        case .keepNext: return props.keepNext
        case .keepTogether: return props.keepTogether
        case .pageBreakBefore: return props.pageBreakBefore
        }
    }

    package func change(_ on: Bool) -> ParaChange {
        switch self {
        case .keepNext: return ParaChange(keepNext: on)
        case .keepTogether: return ParaChange(keepTogether: on)
        case .pageBreakBefore: return ParaChange(pageBreakBefore: on)
        }
    }
}

extension FormatEdits {
    /// Включить или снять флаг абзацев. Включить — код сразу после `\pard` абзаца (как пишет Word), не прошла проверка —
    /// перед его концом. Снять — вырезать собственный код абзаца: число у этих флагов RTF не определяет (`\keepn0`
    /// читатели понимают по-разному), поэтому выключение — только удалением. Всё проверяет `FormatCheck`: другие абзацы,
    /// которые наследовали бы флаг, не меняются, иначе команда отказывает.
    package static func flag(_ flag: DocParaFlag, on: Bool, paragraphs: [Int], story ref: DocStoryRef = .body, source: NSString,
                     model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard let story = model.story(ref) else { return .failure(FormatFailure(reason: "Нет такого колонтитула")) }
        var plan = FormatPlan(story: ref, paraChange: flag.change(on))
        plan.paraTargets = Set(paragraphs.filter { $0 >= 0 && $0 < story.paragraphs.count })
        guard !plan.paraTargets.isEmpty else { return .failure(FormatFailure(reason: "Нет абзаца")) }
        let changing = plan.paraTargets.sorted().filter { flag.value(story.paragraphs[$0].props) != on }
        guard !changing.isEmpty else { return .success(plan) }
        let groups = RTFGroupIndex(source)
        var lastFailure = FormatFailure(reason: "Нечего менять")
        for afterPard in on ? [true, false] : [true] {
            var edits: [FormatEdit] = []
            for index in changing {
                let paragraph = story.paragraphs[index]
                if on {
                    if afterPard, let pard = paragraph.pard {
                        edits.append(FormatEdit(range: NSRange(location: NSMaxRange(pard), length: 0), string: "\\\(flag.rawValue) ", order: 1))
                    } else {
                        let end = endLocation(paragraph, story: ref, groups: groups)
                        edits.append(FormatEdit(range: NSRange(location: end, length: 0), string: "\\\(flag.rawValue) ", order: 1))
                    }
                } else {
                    guard let token = paragraph.propTokens[flag.rawValue] else {
                        return .failure(FormatFailure(reason: "Свойство абзаца задано раньше, у предыдущего абзаца"))
                    }
                    let whole = RTFLexer.controlToken(source, at: token.location).range
                    edits.append(FormatEdit(range: whole, string: DocTextEditor.delimiterAfterRemoval(whole, source: source) ? " " : ""))
                }
            }
            plan.edits = edits
            if let problem = FormatCheck.verify(plan, source: source, model: model) {
                lastFailure = FormatFailure(reason: problem)
                continue
            }
            return .success(plan)
        }
        return .failure(lastFailure)
    }
}

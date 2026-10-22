import Foundation

/// Правка списков в «Документе» (E-2), как в Word: ↩ в пункте — новый пункт (свойства абзаца в RTF наследуются через
/// `\par`, номер считается сам), ↩ в пустом пункте — уровень выше, а на первом уровне — выход из списка; Tab в начале
/// пункта — уровень ниже, ⇧Tab — выше; ⌫ сразу после номера — номер снимается. Уровень и список пишутся кодами
/// `\ilvl`/`\ls` через `FormatEdits` (с проверкой `FormatCheck`), готовый номер `{\listtext}` переписывается, когда
/// номер пункта изменился. Чистые функции — проверяются без окон.
enum DocListEdit {
    struct Result: Equatable {
        var edits: [DocEdit] = []
        /// Место исходника, перед которым встанет курсор (в координатах ПОСЛЕ правки).
        var caretSource = 0
        var actionName = "Список"
        var refusal: String?
    }

    // MARK: - Клавиши

    /// Что делает ввод `text` на месте показанных единиц `units`, если это команда списка; `nil` — обычная правка.
    static func intercept(_ units: NSRange, text: String, model: RTFDocumentModel, rendering: DocRendering, source: NSString) -> Result? {
        guard !model.lists.isEmpty else { return nil }
        let labels = DocListNumbers.labels(model.body, lists: model.lists)
        guard !labels.isEmpty else { return nil }
        switch text {
        case "\n", "\r":
            guard units.length == 0, let index = rendering.paragraph(atUnit: units.location), let label = labels[index],
                  isEmptyItem(index, rendering: rendering) else { return nil }
            // Пустой пункт: ↩ — уровень выше, на первом уровне — выход из списка.
            if label.levelIndex > 0 { return changeLevel([index], by: -1, model: model, labels: labels, source: source) }
            return removeNumber(index, model: model, labels: labels, source: source, resetIndent: true, name: "Конец списка")
        case "\t":
            let paragraphs = targets(units, labels: labels, rendering: rendering)
            guard !paragraphs.isEmpty else { return nil }
            return changeLevel(paragraphs, by: 1, model: model, labels: labels, source: source)
        case "":
            // ⌫ сразу после номера: выделен только номер (или его часть) одного пункта.
            guard units.length > 0, (units.location..<NSMaxRange(units)).allSatisfy({ $0 < rendering.map.count && rendering.map.kind(at: $0) == .listText }),
                  let index = rendering.paragraph(atUnit: units.location), labels[index] != nil else { return nil }
            return removeNumber(index, model: model, labels: labels, source: source, resetIndent: false, name: "Снять номер")
        default:
            return nil
        }
    }

    /// ⇧Tab в начале пункта (или на выделенных пунктах) — уровень выше. `nil` — не пункт списка.
    static func backtab(_ units: NSRange, model: RTFDocumentModel, rendering: DocRendering, source: NSString) -> Result? {
        let labels = DocListNumbers.labels(model.body, lists: model.lists)
        let paragraphs = targets(units, labels: labels, rendering: rendering)
        guard !paragraphs.isEmpty else { return nil }
        return changeLevel(paragraphs, by: -1, model: model, labels: labels, source: source)
    }

    /// Пункты, уровень которых меняют Tab и ⇧Tab: курсор в начале текста пункта или выделение через несколько абзацев,
    /// все — пункты списка.
    static func targets(_ units: NSRange, labels: [Int: DocListLabel], rendering: DocRendering) -> [Int] {
        guard let first = rendering.paragraph(atUnit: units.location) else { return [] }
        if units.length == 0 {
            guard labels[first] != nil, units.location == contentUnit(first, rendering: rendering) else { return [] }
            return [first]
        }
        let last = rendering.paragraph(atUnit: max(units.location, NSMaxRange(units) - 1)) ?? first
        guard last > first else { return [] }
        let paragraphs = Array(first...last)
        return paragraphs.allSatisfy { labels[$0] != nil } ? paragraphs : []
    }

    /// Первая показанная единица текста абзаца — после разрыва и номера.
    static func contentUnit(_ paragraph: Int, rendering: DocRendering) -> Int {
        guard let range = rendering.paragraphRanges[safe: paragraph] else { return 0 }
        var unit = range.location
        while unit < NSMaxRange(range), [.listText, .sectionBreak, .pageBreak].contains(rendering.map.kind(at: unit)) { unit += 1 }
        return unit
    }

    /// В пункте нет текста (только номер и конец абзаца).
    static func isEmptyItem(_ paragraph: Int, rendering: DocRendering) -> Bool {
        guard let range = rendering.paragraphRanges[safe: paragraph] else { return false }
        return !(range.location..<NSMaxRange(range)).contains { rendering.map.kind(at: $0).isEditable }
    }

    // MARK: - Команды

    /// Уровень пунктов на `delta`. Отступ, который был у старого уровня, меняется на отступ нового (как в Word).
    static func changeLevel(_ paragraphs: [Int], by delta: Int, model: RTFDocumentModel, labels: [Int: DocListLabel],
                            source: NSString) -> Result {
        var changes: [ParaChange] = []
        for index in paragraphs {
            guard let label = labels[index], let found = model.lists.level(list: label.list, level: label.levelIndex),
                  let paragraph = model.body.paragraphs[safe: index] else { return Result(refusal: "Это не пункт списка") }
            let target = label.levelIndex + delta
            guard target >= 0, target < found.list.levels.count, target < DocListNumbers.levelCount else {
                return Result(refusal: delta > 0 ? "Ниже уровня в этом списке нет" : "Это уже первый уровень списка")
            }
            var change = ParaChange(listLevel: target)
            if let next = model.lists.level(list: label.list, level: target)?.level,
               paragraph.props.left == (found.level.left ?? 0), paragraph.props.firstLine == (found.level.firstLine ?? 0) {
                if let left = next.left, left != paragraph.props.left { change.left = left }
                if let firstLine = next.firstLine, firstLine != paragraph.props.firstLine { change.firstLine = firstLine }
            }
            changes.append(change)
        }
        guard let change = changes.first, changes.allSatisfy({ $0 == change }) else {
            return Result(refusal: "Выделите пункты одного уровня")
        }
        return paragraphCommand(change, paragraphs: paragraphs, removing: [], model: model, source: source,
                                name: delta > 0 ? "Понизить уровень" : "Повысить уровень")
    }

    /// Снять номер: `\ls0` и без выступа первой строки; `resetIndent` — и без отступа уровня (выход из списка по ↩).
    /// Готовый номер `{\listtext}` вырезается.
    static func removeNumber(_ index: Int, model: RTFDocumentModel, labels: [Int: DocListLabel], source: NSString, resetIndent: Bool,
                             name: String) -> Result {
        guard let label = labels[index], let paragraph = model.body.paragraphs[safe: index] else { return Result(refusal: "Это не пункт списка") }
        var change = ParaChange(list: 0)
        if paragraph.props.firstLine != 0 { change.firstLine = 0 }
        if resetIndent, paragraph.props.left != 0, label.level.left == nil || label.level.left == paragraph.props.left { change.left = 0 }
        var removing: [NSRange] = []
        if let group = paragraph.listTextGroup { removing.append(group) }
        return paragraphCommand(change, paragraphs: [index], removing: removing, model: model, source: source, name: name)
    }

    /// Свойства абзацев через `FormatEdits` (с проверкой) и вырезание групп `removing`; курсор — в начале текста первого.
    private static func paragraphCommand(_ change: ParaChange, paragraphs: [Int], removing: [NSRange], model: RTFDocumentModel,
                                         source: NSString, name: String) -> Result {
        let plan: FormatPlan
        switch FormatEdits.paragraph(change, paragraphs: paragraphs, source: source, model: model) {
        case .failure(let failure): return Result(refusal: "Нельзя без потерь: \(failure.reason.lowercasedFirst). " + DocTextEditor.codeHint)
        case .success(let success): plan = success
        }
        var edits = plan.edits
        for group in removing {
            edits.append(FormatEdit(range: group, string: DocTextEditor.delimiterAfterRemoval(group, source: source) ? " " : ""))
        }
        guard let merged = FormatCheck.merged(edits) else { return Result(refusal: "Правки пересекаются. " + DocTextEditor.codeHint) }
        let docEdits = merged.map { DocEdit(range: $0.range, text: $0.string) }
        let start = model.body.paragraphs[paragraphs[0]].textStart
        let caret = shifted(start, by: docEdits)
        let synced = DocListText.synced(docEdits, caret: caret, model: model, source: source)
        return Result(edits: synced.edits, caretSource: synced.caret, actionName: name)
    }

    /// Место исходника до правок → после (правки левее сдвигают; внутри правки — её конец).
    static func shifted(_ location: Int, by edits: [DocEdit]) -> Int {
        var shift = 0
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            if NSMaxRange(edit.range) <= location, edit.range.location < location || edit.range.length > 0 {
                shift += (edit.text as NSString).length - edit.range.length
            } else if edit.range.location < location {
                return edit.range.location + shift + (edit.text as NSString).length
            }
        }
        return location + shift
    }
}

extension DocListEdit {
    /// Курсор не встаёт внутрь номера списка и перед ним: вперёд (или щелчком) — за номер, назад — в конец прошлого абзаца.
    /// `nil` — курсор не в номере.
    static func caretOutsideNumber(_ new: NSRange, from old: NSRange, map: DocSourceMap) -> NSRange? {
        guard new.length == 0, new.location < map.count, map.kind(at: new.location) == .listText else { return nil }
        var start = new.location
        while start > 0, map.kind(at: start - 1) == .listText { start -= 1 }
        var end = new.location
        while end < map.count, map.kind(at: end) == .listText { end += 1 }
        if old.length == 0, old.location >= end, new.location < old.location, start > 0 { return NSRange(location: start - 1, length: 0) }
        return NSRange(location: end, length: 0)
    }
}

extension DocRendering {
    /// Показанная единица для курсора у места исходника: не внутри номера списка (номер не правится — курсор за ним).
    func caretUnit(atSource location: Int) -> Int {
        var unit = map.firstUnit(atOrAfter: location)
        while unit < map.count, map.kind(at: unit) == .listText { unit += 1 }
        return unit
    }
}

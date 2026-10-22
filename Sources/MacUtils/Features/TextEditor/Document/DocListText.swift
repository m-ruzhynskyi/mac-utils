import Foundation

/// Готовый номер `{\listtext …}` после правки. Word его не читает, но другие программы показывают номер по нему —
/// поэтому, если в файле он есть, он не должен расходиться с номером: у пункта, чей номер правка изменила, текст номера
/// переписывается; новый пункт (↩) получает копию группы соседа с новым номером. Номера, которые правка не меняла,
/// не трогаются, даже если в файле они уже неверные (байты вне правки — те же).
enum DocListText {
    /// Правки `edits` (координаты исходника до них) и курсор после них → вместе с переписанными номерами.
    static func synced(_ edits: [DocEdit], caret: Int, model: RTFDocumentModel, source: NSString) -> (edits: [DocEdit], caret: Int) {
        guard !edits.isEmpty, !model.lists.isEmpty,
              model.body.paragraphs.contains(where: { $0.listTextGroup != nil }) else { return (edits, caret) }
        var primary = edits.sorted { $0.range.location < $1.range.location }
        // Где каждая правка оказалась в новом исходнике.
        var starts: [Int] = []
        var shift = 0
        for edit in primary {
            starts.append(edit.range.location + shift)
            shift += (edit.text as NSString).length - edit.range.length
        }
        let fresh = applied(primary, to: source)
        let newModel = RTFReader.read(fresh, fallback: model.codePage)
        let newLabels = DocListNumbers.labels(newModel.body, lists: newModel.lists)
        let oldLabels = DocListNumbers.labels(model.body, lists: model.lists)
        var oldByGroup: [Int: String] = [:]
        for (index, label) in oldLabels {
            if let group = model.body.paragraphs[index].listTextGroup { oldByGroup[group.location] = label.number }
        }

        func containing(_ location: Int, inclusiveEnd: Bool) -> Int? {
            primary.indices.first { index in
                let end = starts[index] + (primary[index].text as NSString).length
                return location >= starts[index] && (inclusiveEnd ? location <= end : location < end) && end > starts[index]
            }
        }
        func toOld(_ location: Int) -> Int {
            var delta = 0
            for (index, edit) in primary.enumerated() where starts[index] + (edit.text as NSString).length <= location {
                delta += (edit.text as NSString).length - edit.range.length
            }
            return location - delta
        }

        /// Вставки в новые куски правок (по месту в новом исходнике) и отдельные правки старого исходника.
        var patches: [(edit: Int, offset: Int, length: Int, text: String)] = []
        var extra: [DocEdit] = []
        var moves: [(location: Int, delta: Int)] = []
        for (index, label) in newLabels {
            let paragraph = newModel.body.paragraphs[index]
            guard let group = paragraph.listTextGroup else {
                // Новый пункт без готового номера: если он появился внутри правки (↩) после пункта с номером — копия.
                guard let edit = containing(paragraph.regionStart, inclusiveEnd: true), primary[edit].text.contains("\\par"),
                      let copy = copiedGroup(near: primary[edit].range.location, number: label.number, model: model, source: source) else { continue }
                let offset = paragraph.regionStart - starts[edit]
                patches.append((edit, offset, 0, copy))
                moves.append((paragraph.regionStart, (copy as NSString).length))
                continue
            }
            guard let segment = segment(paragraph), segment.text != label.number else { continue }
            let encoded = encodedNumber(label.number, at: segment.range.location, paragraph: paragraph, model: newModel, source: fresh)
            if let edit = containing(group.location, inclusiveEnd: false) {
                patches.append((edit, segment.range.location - starts[edit], segment.range.length, encoded))
            } else {
                let old = toOld(group.location)
                guard let before = oldByGroup[old], before != label.number else { continue }
                let range = NSRange(location: toOld(segment.range.location), length: segment.range.length)
                extra.append(DocEdit(range: range, text: encoded))
            }
            moves.append((segment.range.location, (encoded as NSString).length - segment.range.length))
        }
        for patch in patches.sorted(by: { ($0.edit, $0.offset) > ($1.edit, $1.offset) }) {
            let text = NSMutableString(string: primary[patch.edit].text)
            guard patch.offset >= 0, patch.offset + patch.length <= text.length else { continue }
            text.replaceCharacters(in: NSRange(location: patch.offset, length: patch.length), with: patch.text)
            primary[patch.edit].text = text as String
        }
        let all = (primary + extra).sorted { $0.range.location < $1.range.location }
        for (a, b) in zip(all, all.dropFirst()) where NSMaxRange(a.range) > b.range.location { return (edits, caret) }
        let newCaret = caret + moves.filter { $0.location <= caret }.reduce(0) { $0 + $1.delta }
        return (all, newCaret)
    }

    /// Текст номера в `{\listtext}` абзаца (без табуляции после него) и где он в исходнике.
    static func segment(_ paragraph: RTFParagraph) -> (text: String, range: NSRange)? {
        var units: [UInt16] = []
        var start: Int?
        var end: Int?
        var tab: Int?
        for run in paragraph.runs where run.kind == .listText {
            for (offset, unit) in run.text.utf16.enumerated() where offset < run.map.count {
                let range = run.map[offset]
                if unit == 0x09 {
                    if tab == nil { tab = range.location }
                    continue
                }
                units.append(unit)
                if start == nil { start = range.location }
                end = NSMaxRange(range)
            }
        }
        if let start, let end { return (String(utf16CodeUnits: units, count: units.count), NSRange(location: start, length: end - start)) }
        if let tab { return ("", NSRange(location: tab, length: 0)) }
        return nil
    }

    /// Номер кодами RTF — теми же свойствами, что у готового номера (кодовая страница шрифта, `\uc`).
    private static func encodedNumber(_ number: String, at location: Int, paragraph: RTFParagraph, model: RTFDocumentModel,
                                      source: NSString) -> String {
        let run = paragraph.runs.first { $0.kind == .listText }
        let encoded = DocTextEditor.encode(number, props: run?.props, uc: run?.uc ?? 1, model: model)
        return (DocTextEditor.needsDelimiter(before: location, source: source) ? " " : "") + encoded
    }

    /// Копия `{\listtext}` пункта, внутри которого правка (старый исходник), с номером `number`.
    private static func copiedGroup(near location: Int, number: String, model: RTFDocumentModel, source: NSString) -> String? {
        let index = FormatEdits.firstParagraph(in: model.body, atOrAfter: location)
        guard let paragraph = model.body.paragraphs[safe: index], let group = paragraph.listTextGroup,
              let segment = segment(paragraph), NSLocationInRange(segment.range.location, group) || segment.range.location == NSMaxRange(group) else { return nil }
        let text = NSMutableString(string: source.substring(with: group))
        let offset = segment.range.location - group.location
        guard offset >= 0, offset + segment.range.length <= text.length else { return nil }
        let run = paragraph.runs.first { $0.kind == .listText }
        var encoded = DocTextEditor.encode(number, props: run?.props, uc: run?.uc ?? 1, model: model)
        if DocTextEditor.needsDelimiter(before: segment.range.location, source: source) { encoded = " " + encoded }
        text.replaceCharacters(in: NSRange(location: offset, length: segment.range.length), with: encoded)
        return text as String
    }

    static func applied(_ edits: [DocEdit], to source: NSString) -> NSString {
        let result = NSMutableString(string: source)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: edit.range, with: edit.text)
        }
        return result
    }
}

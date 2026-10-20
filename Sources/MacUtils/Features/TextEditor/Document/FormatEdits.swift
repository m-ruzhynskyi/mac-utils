import Foundation

/// Одна точечная правка исходника. Байты вне `range` не меняются.
struct FormatEdit: Equatable {
    var range: NSRange
    var string: String
    /// Порядок вставок в одном месте: закрытие группы (0), коды абзаца и таблиц (1), открытие группы (2).
    var order = 1
}

/// История документа, в которой идёт правка: основной текст или колонтитул раздела.
enum DocStoryRef: Hashable {
    case body
    case header(section: Int, kind: RTFHeaderKind)
}

extension RTFDocumentModel {
    func story(_ ref: DocStoryRef) -> RTFStory? {
        switch ref {
        case .body: return body
        case .header(let section, let kind): return section < sections.count ? sections[section].headers[kind]?.story : nil
        }
    }
}

/// Команда для символов (Ж, К, Ч, S, шрифт, размер, цвет, маркер, очистить).
enum CharChange: Equatable {
    case bold(Bool), italic(Bool), underline(Bool), strike(Bool)
    /// Имя шрифта, как в `\fonttbl` (исходное имя, даже если на Mac его нет).
    case font(String)
    /// `\fsN` — в половинках пункта.
    case size(Int)
    /// `nil` — «Авто».
    case color(RTFColor?)
    /// `nil` — без маркера.
    case highlight(RTFColor?)
    /// Шрифт и размер документа по умолчанию, без начертаний.
    case clear

    var actionName: String {
        switch self {
        case .bold: return "Полужирный"
        case .italic: return "Курсив"
        case .underline: return "Подчёркнутый"
        case .strike: return "Зачёркнутый"
        case .font: return "Шрифт"
        case .size: return "Размер шрифта"
        case .color: return "Цвет текста"
        case .highlight: return "Цвет выделения"
        case .clear: return "Очистить формат"
        }
    }
}

/// Команда для абзацев: заданные поля меняются, остальные остаются как были.
struct ParaChange: Equatable {
    var alignment: RTFAlignment?
    var left: Int?
    var right: Int?
    var firstLine: Int?
    var spaceBefore: Int?
    var spaceAfter: Int?
    /// `\sl` и `\slmult`: 0 — авто (одинарный).
    var lineSpacing: (value: Int, multiple: Bool)?
    /// Табуляции с линейки (`FormatEdits.tabs`).
    var tabs: TabEdit?

    static func == (lhs: ParaChange, rhs: ParaChange) -> Bool {
        lhs.tabs == rhs.tabs && lhs.alignment == rhs.alignment && lhs.left == rhs.left && lhs.right == rhs.right && lhs.firstLine == rhs.firstLine
            && lhs.spaceBefore == rhs.spaceBefore && lhs.spaceAfter == rhs.spaceAfter
            && lhs.lineSpacing?.value == rhs.lineSpacing?.value && lhs.lineSpacing?.multiple == rhs.lineSpacing?.multiple
    }

    /// «Очистить формат» для абзаца: без отступов и интервалов, по левому краю. Табуляции, рамки и стиль не трогаются.
    static let clear = ParaChange(alignment: .left, left: 0, right: 0, firstLine: 0, spaceBefore: 0, spaceAfter: 0, lineSpacing: (0, false))

    /// Поля абзаца, которые команда пишет кодами: имя — как в `RTFParagraph.propTokens`.
    enum Field: String, CaseIterable {
        case align, li, lin, ri, rin, fi, sb, sa, sl, slmult
    }

    var settings: [(Field, Int)] {
        var result: [(Field, Int)] = []
        if let alignment { result.append((.align, Self.code(alignment))) }
        if let left { result += [(.li, left), (.lin, left)] }
        if let right { result += [(.ri, right), (.rin, right)] }
        if let firstLine { result.append((.fi, firstLine)) }
        if let spaceBefore { result.append((.sb, spaceBefore)) }
        if let spaceAfter { result.append((.sa, spaceAfter)) }
        if let lineSpacing { result += [(.sl, lineSpacing.value), (.slmult, lineSpacing.multiple ? 1 : 0)] }
        return result
    }

    static func code(_ alignment: RTFAlignment) -> Int { RTFAlignment.allCases.firstIndex(of: alignment) ?? 0 }

    static func value(_ field: Field, of props: RTFParaProps) -> Int {
        switch field {
        case .align: return code(props.alignment)
        case .li, .lin: return props.left
        case .ri, .rin: return props.right
        case .fi: return props.firstLine
        case .sb: return props.spaceBefore
        case .sa: return props.spaceAfter
        case .sl: return props.lineSpacing
        case .slmult: return props.lineMultiple ? 1 : 0
        }
    }

    static func token(_ field: Field, _ value: Int) -> String {
        switch field {
        case .align: return "\\" + RTFAlignment.allCases[min(max(value, 0), 3)].word
        default: return "\\\(field.rawValue)\(value)"
        }
    }

    func apply(to props: RTFParaProps) -> RTFParaProps {
        var props = props
        if let alignment { props.alignment = alignment }
        if let left { props.left = left }
        if let right { props.right = right }
        if let firstLine { props.firstLine = firstLine }
        if let spaceBefore { props.spaceBefore = spaceBefore }
        if let spaceAfter { props.spaceAfter = spaceAfter }
        if let lineSpacing {
            props.lineSpacing = lineSpacing.value
            props.lineMultiple = lineSpacing.multiple
        }
        switch tabs {
        case .add(let stop): props.tabs.append(stop)
        case .move(let index, let position) where props.tabs.indices.contains(index): props.tabs[index].position = position
        case .remove(let index) where props.tabs.indices.contains(index): props.tabs.remove(at: index)
        default: break
        }
        return props
    }
}

/// Почему команду нельзя выполнить без потерь — тогда она неактивна с подсказкой «Изменить в коде».
struct FormatFailure: Error, Equatable {
    var reason: String
}

/// Готовая команда: правки исходника и что после них должно получиться (для проверки).
struct FormatPlan {
    var edits: [FormatEdit] = []
    var story = DocStoryRef.body
    /// Символы-цели: номер абзаца → номера единиц в его прогонах (по порядку, как в `FormatCheck.units`).
    var charTargets: [Int: Set<Int>] = [:]
    var charChange: CharChange?
    var paraTargets: Set<Int> = []
    var paraChange: ParaChange?
    var addedFonts: [RTFFont] = []
    var addedColors: [RTFColor] = []
}

/// Генераторы точечных правок свойств символов и абзацев. Модель не пишется заново: каждый кусок выделения либо
/// оборачивается в свою группу `{\b …}` (её `}` возвращает прежнее состояние байт в байт), либо, если кусок — весь
/// текст своей группы, получает код в начале этой группы. Свойства абзаца — код после его `\pard`, замена его
/// собственного кода или код перед его `\par`; следующий абзац, который их наследовал, получает прежнее значение.
/// Каждая команда проверяет себя (`FormatCheck`): применённые правки перечитываются, и всё, кроме цели, должно остаться
/// как было.
enum FormatEdits {
    // MARK: - Символы

    /// Правки для символов истории `story`, чьи куски исходника лежат внутри `span`.
    static func character(_ change: CharChange, span: NSRange, story ref: DocStoryRef = .body, source: NSString,
                          model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard let story = model.story(ref) else { return .failure(FormatFailure(reason: "Нет такого колонтитула")) }
        let groups = RTFGroupIndex(source)
        var lastFailure = FormatFailure(reason: "Нечего менять")
        // Сначала — коды в начале групп (чище), если проверка не прошла — только обёртки.
        for inGroup in [true, false] {
            switch characterPlan(change, span: span, story: story, ref: ref, source: source, model: model, groups: groups, inGroup: inGroup) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let plan):
                if let problem = FormatCheck.verify(plan, source: source, model: model) {
                    lastFailure = FormatFailure(reason: problem)
                    continue
                }
                return .success(plan)
            }
        }
        return .failure(lastFailure)
    }

    /// Кусок выделения внутри одной группы: единицы подряд, между ними — только переводы строк и целые группы.
    private struct Piece {
        var paragraph: Int
        var group: Int
        var start: Int
        var end: Int
        var font: Int?
        var firstUnit: (run: Int, index: Int)
        var lastUnit: (run: Int, index: Int)
    }

    private static func characterPlan(_ change: CharChange, span: NSRange, story: RTFStory, ref: DocStoryRef, source: NSString,
                                      model: RTFDocumentModel, groups: RTFGroupIndex, inGroup: Bool) -> Result<FormatPlan, FormatFailure> {
        var plan = FormatPlan(story: ref, charChange: change)
        var pieces: [Piece] = []
        let spanEnd = NSMaxRange(span)
        var paragraphIndex = firstParagraph(in: story, atOrAfter: span.location)
        while paragraphIndex < story.paragraphs.count {
            let paragraph = story.paragraphs[paragraphIndex]
            if paragraph.regionStart >= spanEnd, paragraphIndex > 0 { break }
            var current: Piece?
            var unitNumber = 0
            for (runIndex, run) in paragraph.runs.enumerated() {
                let target = isTarget(run.kind)
                let group = run.map.first.flatMap { groups.innermost(containing: $0.location) } ?? -1
                var previous: NSRange?
                for (index, range) in run.map.enumerated() {
                    defer { unitNumber += 1 }
                    // Вторая половина суррогатной пары — тот же кусок исходника.
                    if previous == range { if current != nil { plan.charTargets[paragraphIndex, default: []].insert(unitNumber) }; continue }
                    previous = range
                    let inside = range.length > 0 && range.location >= span.location && NSMaxRange(range) <= spanEnd
                    guard inside, target else {
                        if let piece = current { pieces.append(piece) }
                        current = nil
                        continue
                    }
                    plan.charTargets[paragraphIndex, default: []].insert(unitNumber)
                    if var piece = current, piece.group == group, cleanGap(source, from: piece.end, to: range.location) {
                        piece.end = NSMaxRange(range)
                        piece.lastUnit = (runIndex, index)
                        current = piece
                        continue
                    }
                    if let piece = current { pieces.append(piece) }
                    current = Piece(paragraph: paragraphIndex, group: group, start: range.location, end: NSMaxRange(range), font: run.props.font,
                                    firstUnit: (runIndex, index), lastUnit: (runIndex, index))
                }
            }
            if let piece = current { pieces.append(piece) }
            paragraphIndex += 1
        }
        guard !pieces.isEmpty else { return .failure(FormatFailure(reason: "В выделении нет текста, который можно оформить")) }
        guard pieces.allSatisfy({ $0.group >= 0 }) else { return .failure(FormatFailure(reason: "Текст вне группы RTF")) }
        var tables = FormatTables(source: source, model: model)
        for piece in pieces {
            guard let words = characterWords(change, font: model.font(piece.font), tables: &tables, model: model) else {
                return .failure(FormatFailure(reason: "В файле нет таблицы шрифтов или цветов, куда дописать новый"))
            }
            if inGroup, coversGroup(piece, story: story, groups: groups) {
                plan.edits += groupStartEdits(change, words: words, piece: piece, source: source, groups: groups)
            } else {
                plan.edits.append(FormatEdit(range: NSRange(location: piece.start, length: 0), string: "{" + words + " ", order: 2))
                plan.edits.append(FormatEdit(range: NSRange(location: piece.end, length: 0), string: "}", order: 0))
            }
        }
        plan.edits += tables.edits()
        plan.addedFonts = tables.addedFonts
        plan.addedColors = tables.addedColors
        return .success(plan)
    }

    /// Какие прогоны оформляются: текст, табуляция, разрыв строки и результат поля. Номера списков, рисунки и заглушки —
    /// нет.
    static func isTarget(_ kind: RTFRun.Kind) -> Bool {
        switch kind {
        case .text, .tab, .lineBreak, .field: return true
        case .pageBreak, .listText, .picture, .placeholder: return false
        }
    }

    /// Первый абзац, который может лежать не раньше `location` (абзацы идут по порядку исходника).
    static func firstParagraph(in story: RTFStory, atOrAfter location: Int) -> Int {
        var low = 0, high = story.paragraphs.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(story.paragraphs[mid].endRange) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Между единицами только переводы строк и целые группы — значит, их можно обернуть одной группой.
    static func cleanGap(_ source: NSString, from start: Int, to end: Int) -> Bool {
        guard end > start else { return end == start }
        var depth = 0
        for token in RTFLexer.tokens(source, in: NSRange(location: start, length: end - start)) {
            switch token.kind {
            case .open: depth += 1
            case .close:
                depth -= 1
                if depth < 0 { return false }
            case .newline: break
            default: if depth == 0 { return false }
            }
        }
        return depth == 0
    }

    /// Кусок — весь видимый текст своей группы: до и после него в истории ничего видимого в этой группе нет.
    private static func coversGroup(_ piece: Piece, story: RTFStory, groups: RTFGroupIndex) -> Bool {
        let content = groups.content(of: piece.group)
        if let before = neighbour(story, paragraph: piece.paragraph, unit: piece.firstUnit, forward: false), NSLocationInRange(before, content) {
            return false
        }
        if let after = neighbour(story, paragraph: piece.paragraph, unit: piece.lastUnit, forward: true), NSLocationInRange(after, content) {
            return false
        }
        return true
    }

    /// Место исходника соседней единицы истории (любого вида) до или после данной.
    private static func neighbour(_ story: RTFStory, paragraph: Int, unit: (run: Int, index: Int), forward: Bool) -> Int? {
        var p = paragraph, r = unit.run, i = unit.index
        let own = story.paragraphs[p].runs[r].map[i]
        while p >= 0, p < story.paragraphs.count {
            let runs = story.paragraphs[p].runs
            while r >= 0, r < runs.count {
                let map = runs[r].map
                while i >= 0, i < map.count {
                    if map[i] != own { return map[i].location }
                    i += forward ? 1 : -1
                }
                r += forward ? 1 : -1
                if r >= 0, r < runs.count { i = forward ? 0 : runs[r].map.count - 1 }
            }
            p += forward ? 1 : -1
            if p >= 0, p < story.paragraphs.count {
                r = forward ? 0 : story.paragraphs[p].runs.count - 1
                i = forward ? 0 : (r >= 0 ? story.paragraphs[p].runs[r].map.count - 1 : 0)
            }
        }
        return nil
    }

    /// Код свойства в начале группы: если там уже есть код того же свойства (и после него нет `\plain`) — замена,
    /// иначе вставка перед первым символом группы.
    private static func groupStartEdits(_ change: CharChange, words: String, piece: Piece, source: NSString, groups: RTFGroupIndex) -> [FormatEdit] {
        let content = groups.content(of: piece.group)
        let leading = NSRange(location: content.location, length: piece.start - content.location)
        let family = Self.family(change)
        var depth = 0
        var candidate: RTFToken?
        var ambiguous = false
        for token in RTFLexer.tokens(source, in: leading) {
            switch token.kind {
            case .open: depth += 1
            case .close: depth -= 1
            case .word where depth == 0:
                if family.contains(token.name) {
                    if candidate != nil { ambiguous = true }
                    candidate = token
                } else if token.name == "plain" {
                    candidate = nil
                    ambiguous = false
                }
            default: break
            }
        }
        if let candidate, !ambiguous, !family.isEmpty, !words.contains("\\", after: 1) {
            return [replacement(candidate, with: words, source: source)]
        }
        return [FormatEdit(range: NSRange(location: piece.start, length: 0), string: words + " ", order: 2)]
    }

    /// Управляющие слова того же свойства (их можно заменить одним новым).
    private static func family(_ change: CharChange) -> Set<String> {
        switch change {
        case .bold: return ["b"]
        case .italic: return ["i"]
        case .underline: return ["ul", "ulnone"]
        case .strike: return []
        case .font: return ["f"]
        case .size: return ["fs"]
        case .color: return ["cf"]
        case .highlight: return ["highlight"]
        case .clear: return []
        }
    }

    /// Коды команды для куска с шрифтом `font`. `nil` — новый шрифт или цвет некуда записать.
    private static func characterWords(_ change: CharChange, font: RTFFont?, tables: inout FormatTables, model: RTFDocumentModel) -> String? {
        switch change {
        case .bold(let on): return on ? "\\b" : "\\b0"
        case .italic(let on): return on ? "\\i" : "\\i0"
        case .underline(let on): return on ? "\\ul" : "\\ulnone"
        case .strike(let on): return on ? "\\strike" : "\\strike0\\striked0"
        case .font(let name):
            guard let number = tables.fontNumber(name: name, like: font) else { return nil }
            return "\\f\(number)"
        case .size(let halfPoints): return "\\fs\(min(max(halfPoints, 2), 3_276))"
        case .color(let color):
            guard let color else { return "\\cf0" }
            guard let index = tables.colorIndex(color) else { return nil }
            return "\\cf\(index)"
        case .highlight(let color):
            guard let color else { return "\\highlight0" }
            guard let index = tables.colorIndex(color) else { return nil }
            return "\\highlight\(index)"
        case .clear:
            // `\plain` ставит шрифт `\deff`; если у него другая кодировка `\'hh` — тот же шрифт с кодировкой куска.
            let defaultFont = model.font(nil)
            if FormatTables.encoding(of: defaultFont, model: model) == FormatTables.encoding(of: font, model: model) || defaultFont == nil {
                return "\\plain"
            }
            guard let number = tables.fontNumber(name: defaultFont?.name ?? "Times New Roman", like: font) else { return nil }
            return "\\plain\\f\(number)"
        }
    }

    /// Замена кода `token` (без его пробела-разделителя) на `word`. Если новое слово кончается буквой, а за старым
    /// без разделителя идёт буква, цифра или минус — нужен пробел, иначе слово слилось бы с текстом.
    static func replacement(_ token: RTFToken, with word: String, source: NSString, order: Int = 1) -> FormatEdit {
        var text = word
        if !token.hasDelimiter, token.wordEnd < source.length, let last = word.utf16.last, RTFLexer.isLetter(last) {
            let next = source.character(at: token.wordEnd)
            if RTFLexer.isLetter(next) || RTFLexer.isDigit(next) || next == 0x2D || next == 0x20 { text += " " }
        }
        return FormatEdit(range: token.wordRange, string: text, order: order)
    }

    // MARK: - Абзацы

    /// Правки свойств абзацев `paragraphs` истории `story`.
    static func paragraph(_ change: ParaChange, paragraphs: [Int], story ref: DocStoryRef = .body, source: NSString,
                          model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard let story = model.story(ref) else { return .failure(FormatFailure(reason: "Нет такого колонтитула")) }
        let groups = RTFGroupIndex(source)
        var plan = FormatPlan(story: ref, paraChange: change)
        plan.paraTargets = Set(paragraphs.filter { $0 >= 0 && $0 < story.paragraphs.count })
        guard !plan.paraTargets.isEmpty else { return .failure(FormatFailure(reason: "Нет абзаца")) }
        var lastFailure = FormatFailure(reason: "Нечего менять")
        // Сначала — как пишет Word (замена своего кода, код после `\pard`), не прошло — код прямо перед концом абзаца.
        for conventional in [true, false] {
            plan.edits = paragraphEdits(change, targets: plan.paraTargets, story: story, ref: ref, source: source, groups: groups,
                                        conventional: conventional)
            if plan.edits.isEmpty { return .success(plan) }
            if let problem = FormatCheck.verify(plan, source: source, model: model) {
                lastFailure = FormatFailure(reason: problem)
                continue
            }
            return .success(plan)
        }
        return .failure(lastFailure)
    }

    /// Код каждого меняющегося поля и возврат прежнего значения после конца абзаца — на каждом уровне групп между
    /// местом кода и концом абзаца, чтобы следующие абзацы, которые наследовали свойства, остались как были.
    static func paragraphEdits(_ change: ParaChange, targets: Set<Int>, story: RTFStory, ref: DocStoryRef, source: NSString,
                               groups: RTFGroupIndex, conventional: Bool = true) -> [FormatEdit] {
        var edits: [FormatEdit] = []
        for index in targets.sorted() {
            let paragraph = story.paragraphs[index]
            let end = endLocation(paragraph, story: ref, groups: groups)
            let endGroup = groups.innermost(containing: end)
            for (field, value) in change.settings where ParaChange.value(field, of: paragraph.props) != value {
                let word = ParaChange.token(field, value)
                var level = endGroup
                var original = ParaChange.token(field, ParaChange.value(field, of: paragraph.props))
                if conventional, let range = paragraph.propTokens[field.rawValue],
                   contains(groups.innermost(containing: range.location), endGroup, groups: groups) {
                    // Свой код абзаца — замена; вернуть — ровно его текст (`\qd`, `\li0`…).
                    let token = RTFLexer.controlToken(source, at: range.location)
                    edits.append(replacement(token, with: word, source: source))
                    level = groups.innermost(containing: range.location)
                    original = source.substring(with: token.wordRange)
                } else if conventional, paragraph.propTokens[field.rawValue] == nil, let pard = paragraph.pard,
                          contains(groups.innermost(containing: pard.location), endGroup, groups: groups) {
                    // После `\pard` своего кода нет — значит, до конца абзаца там значение по умолчанию.
                    edits.append(FormatEdit(range: NSRange(location: NSMaxRange(pard), length: 0), string: word + " ", order: 1))
                    level = groups.innermost(containing: pard.location)
                    original = ParaChange.token(field, ParaChange.value(field, of: RTFParaProps()))
                } else {
                    edits.append(FormatEdit(range: NSRange(location: end, length: 0), string: word + " ", order: 1))
                }
                edits += restores(original, after: paragraph, from: endGroup, upTo: level, source: source, groups: groups)
            }
        }
        return edits
    }

    /// `outer` — та же группа, что `inner`, или её предок.
    private static func contains(_ outer: Int?, _ inner: Int?, groups: RTFGroupIndex) -> Bool {
        var group = inner
        while let current = group {
            if current == outer { return true }
            group = groups.parents[current] >= 0 ? groups.parents[current] : nil
        }
        return outer == nil
    }

    /// Прежнее значение после конца абзаца: сразу за его кодом конца, затем за `}` каждой группы до уровня, где стоит
    /// изменённый код. Только там, где за этим местом ещё что-то наследует свойства (не `\pard` и не `}`).
    private static func restores(_ original: String, after paragraph: RTFParagraph, from endGroup: Int?, upTo level: Int?,
                                 source: NSString, groups: RTFGroupIndex) -> [FormatEdit] {
        guard paragraph.end != .storyEnd else { return [] }
        var result: [FormatEdit] = []
        var position = NSMaxRange(paragraph.endRange)
        var group = endGroup
        let walksUp = contains(level, endGroup, groups: groups)
        while true {
            if inherits(at: position, source: source) {
                result.append(FormatEdit(range: NSRange(location: position, length: 0), string: original + " ", order: 1))
            }
            guard walksUp, let current = group, current != level, groups.parents[current] >= 0 else { break }
            position = groups.closes[current] + 1
            group = groups.parents[current]
        }
        return result
    }

    /// Наследует ли что-то свойства абзаца с этого места: дальше не `\pard`, не `}` и не конец файла.
    private static func inherits(at position: Int, source: NSString) -> Bool {
        var i = position
        while i < source.length, [0x0D, 0x0A].contains(source.character(at: i)) { i += 1 }
        guard i < source.length else { return false }
        switch source.character(at: i) {
        case 0x7D: return false
        case 0x5C: return RTFLexer.controlToken(source, at: i).name != "pard"
        default: return true
        }
    }

    /// Место перед кодом конца абзаца. У последнего абзаца основного текста без `\par` — перед `}` документа.
    static func endLocation(_ paragraph: RTFParagraph, story: DocStoryRef, groups: RTFGroupIndex) -> Int {
        if paragraph.end == .storyEnd, story == .body, let root = groups.root {
            return min(paragraph.endRange.location, groups.closes[root])
        }
        return paragraph.endRange.location
    }

    // MARK: - Очистить формат

    /// «Очистить формат»: символы выделения — шрифт и размер документа по умолчанию, абзацы — без отступов и интервалов.
    static func clear(span: NSRange, paragraphs: [Int], story ref: DocStoryRef = .body, source: NSString,
                      model: RTFDocumentModel) -> Result<FormatPlan, FormatFailure> {
        guard let story = model.story(ref) else { return .failure(FormatFailure(reason: "Нет такого колонтитула")) }
        let groups = RTFGroupIndex(source)
        var base: FormatPlan
        switch characterPlan(.clear, span: span, story: story, ref: ref, source: source, model: model, groups: groups, inGroup: false) {
        case .success(let chars): base = chars
        case .failure: base = FormatPlan(story: ref)
        }
        base.paraChange = ParaChange.clear
        base.paraTargets = Set(paragraphs.filter { $0 >= 0 && $0 < story.paragraphs.count })
        var lastFailure = FormatFailure(reason: "Нечего менять")
        for conventional in [true, false] {
            var plan = base
            plan.edits += paragraphEdits(.clear, targets: plan.paraTargets, story: story, ref: ref, source: source, groups: groups,
                                         conventional: conventional)
            guard !plan.edits.isEmpty else { return .success(plan) }
            if let problem = FormatCheck.verify(plan, source: source, model: model) {
                lastFailure = FormatFailure(reason: problem)
                continue
            }
            return .success(plan)
        }
        return .failure(lastFailure)
    }
}

private extension String {
    /// Есть ли подстрока после первых `offset` символов (второй код в `\strike0\striked0`).
    func contains(_ other: String, after offset: Int) -> Bool {
        guard count > offset else { return false }
        return dropFirst(offset).contains(other)
    }
}

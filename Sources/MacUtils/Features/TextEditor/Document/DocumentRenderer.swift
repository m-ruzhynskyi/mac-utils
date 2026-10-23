import AppKit

extension NSAttributedString.Key {
    /// Свойства символа документа для панели форматирования (`DocCharInfo`).
    static let docChar = NSAttributedString.Key("MacUtilsDocChar")
    /// Свойства абзаца документа для панели и линейки (`DocParaInfo`).
    static let docPara = NSAttributedString.Key("MacUtilsDocPara")
    /// Служебный абзац «\f\n» перед таблицей, которая начинается с новой страницы: высоты у него нет.
    static let docBreakLine = NSAttributedString.Key("MacUtilsDocBreakLine")
}

/// Свойства символа в показанном тексте: что в файле (`fontName` — исходное имя) и чем показано.
final class DocCharInfo: NSObject {
    let props: RTFCharProps
    let fontName: String
    let displayFont: String

    init(props: RTFCharProps, fontName: String, displayFont: String) {
        self.props = props
        self.fontName = fontName
        self.displayFont = displayFont
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? DocCharInfo else { return false }
        return other.props == props && other.fontName == fontName && other.displayFont == displayFont
    }

    override var hash: Int { props.hashValue ^ fontName.hashValue }
}

/// Свойства абзаца в показанном тексте.
final class DocParaInfo: NSObject {
    let props: RTFParaProps

    init(props: RTFParaProps) { self.props = props }

    override func isEqual(_ object: Any?) -> Bool { (object as? DocParaInfo)?.props == props }
    override var hash: Int { props.hashValue }
}

/// Показанный документ: карта всех единиц и где в показанном тексте каждый абзац модели.
/// Выступ текста в поля страницы слева и справа, в пунктах.
struct DocOutdent: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
}

struct DocRendering {
    var map = DocSourceMap()
    /// Показанный диапазон каждого абзаца модели вместе с его концом; у пропущенных (объединённая ячейка) — пустой.
    var paragraphRanges: [NSRange] = []
    /// Начало каждого раздела в показанном тексте.
    var sectionStarts: [Int] = [0]
    /// Выступ текста каждого раздела в поля страницы (таблицы шире полосы текста, отрицательные отступы), в пунктах:
    /// рамка текста страницы шире полосы на столько же.
    var sectionOutdents: [DocOutdent] = []
    fileprivate var keys: [DocRenderer.ParagraphKey] = []

    var length: Int { map.count }

    /// Номер абзаца модели по показанной единице.
    func paragraph(atUnit unit: Int) -> Int? {
        var low = 0, high = paragraphRanges.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(paragraphRanges[mid]) <= unit { low = mid + 1 } else { high = mid }
        }
        guard low < paragraphRanges.count else { return paragraphRanges.isEmpty ? nil : paragraphRanges.count - 1 }
        return low
    }

    /// Раздел по показанной единице.
    func section(atUnit unit: Int) -> Int {
        var section = 0
        for (index, start) in sectionStarts.enumerated() where start <= unit { section = index }
        return section
    }
}

/// Что заменить в показанном тексте после правки: старый диапазон → новый кусок.
struct DocRenderPatch {
    var range: NSRange
    var string: NSAttributedString
}

/// Модель → `NSAttributedString` для TextKit 1: шрифты (с заменой отсутствующих), размеры, Ж/К/Ч, цвет, маркер,
/// абзацы, таблицы (`NSTextTable`), границы абзацев, рисунки и заглушки. Бумага всегда белая, «авто» — чёрный.
@MainActor
final class DocRenderer {
    /// Показывать скрытый текст (¶ включены): с точечным подчёркиванием.
    var showsHidden = false
    /// Ширина текста страницы — для рисунков и заглушек.
    var contentWidth: CGFloat = 481
    private var fonts: [FontKey: NSFont] = [:]
    private var tables: [TableKey: NSTextTable] = [:]
    private var blocks: [BlockKey: NSTextTableBlock] = [:]
    private var borderBlocks: [BorderKey: NSTextBlock] = [:]
    private var styles: [StyleKey: NSParagraphStyle] = [:]
    private var attachments: [Int: NSTextAttachment] = [:]
    /// Нажата кнопка заглушки («Показать в коде», «Открыть в Word») у символа с этим номером.
    var placeholderAction: ((DocPlaceholderCell.Action, Int) -> Void)?

    // MARK: - Ключи

    private struct FontKey: Hashable {
        var family: String
        var size: CGFloat
        var bold: Bool
        var italic: Bool
    }

    fileprivate struct TableKey: Hashable {
        var ordinal: Int
        var signature: Int
        /// Отступ таблицы от левого края рамки рисования (`\trleft` плюс выступ колонтитула в поле), твипы.
        var offset = 0
    }

    private struct BlockKey: Hashable {
        var table: TableKey
        var row: Int
        var column: Int
        var rowSpan: Int
        var columnSpan: Int
        var cell: RTFCellDef
        var marginLeft: Int
        var marginRight: Int
        var height: Int
        var start: Int
        var width: Int
        var padLeft: Int
        var padRight: Int
        var padTop: Int
        var padBottom: Int
    }

    private struct StyleKey: Hashable {
        var props: RTFParaProps
        var block: BlockKey?
        var defaultTab: Int
        var frame: StoryFrame
    }

    private struct BorderKey: Hashable {
        var props: RTFParaProps
        var frame: StoryFrame
    }

    /// Рамка рисования истории относительно полосы текста, твипы: выступ в поля слева и справа и ширина полосы.
    fileprivate struct StoryFrame: Hashable {
        var left = 0
        var right = 0
        var width = 0
    }

    /// Ячейка таблицы для показа: где в сетке, сколько занимает, пропускается ли (продолжение объединения).
    fileprivate struct CellPlace: Hashable {
        var table: TableKey
        var row: Int
        var column: Int
        var rowSpan: Int
        var columnSpan: Int
        /// Левый край ячейки от левого края таблицы и её ширина, твипы.
        var start: Int
        var width: Int
        var skip: Bool
        var def: RTFCellDef
        /// Поля ячейки по RTF, твипы (`RTFRow.margins`): от них отступы абзацев и табуляции.
        var marginLeft: Int
        var marginRight: Int
        var height: Int
        var columns: Int
        var tableWidth: Int
        /// Поля ячейки для показа, твипы: поля по RTF, уменьшенные на отрицательные отступы её абзацев (в Word абзац ячейки
        /// с `\li` < 0 заходит в поле ячейки; у `NSTextBlock` поле одно на ячейку).
        var padLeft: Int
        var padRight: Int
        var padTop = 0
        var padBottom = 0
    }

    fileprivate struct RunKey: Equatable {
        var length: Int
        var props: RTFCharProps
        var kind: Int
        var object: Int
    }

    fileprivate struct ParagraphKey: Equatable {
        var text: String
        var runs: [RunKey]
        var props: RTFParaProps
        var place: CellPlace?
        var breakBefore: UInt8
        var end: UInt8
        var endProps: RTFCharProps
        /// Интервалы до и после с учётом соседей (`\contextualspace`).
        var spacing: [Int]
        var font: [String]
        var frame = StoryFrame()
    }

    // MARK: - Основной текст

    /// Показать модель. С `previous` перерисовываются только изменившиеся абзацы (заплатка), карта — целиком.
    func render(_ model: RTFDocumentModel, previous: DocRendering?) -> (DocRendering, DocRenderPatch) {
        let story = Self.aligningRows(model.body) { table in
            model.sections[safe: Self.section(of: table, in: model.body)].map { Int((DocPageView.bodyRect($0.props).width * 20).rounded()) }
        }
        let frames = bodyFrames(model, story: story)
        let places = cellPlaces(story) { table, left in
            frames[safe: Self.section(of: table, in: story)].map { $0.left + left } ?? 0
        }
        var rendering = DocRendering()
        rendering.sectionOutdents = frames.map { DocOutdent(left: CGFloat($0.left) / 20, right: CGFloat($0.right) / 20) }
        rendering.map.reserve(previous?.map.count ?? 4_096)
        rendering.paragraphRanges.reserveCapacity(story.paragraphs.count)
        rendering.keys.reserveCapacity(story.paragraphs.count)
        rendering.sectionStarts = Array(repeating: 0, count: model.sections.count)
        var plans: [ParagraphPlan] = []
        plans.reserveCapacity(story.paragraphs.count)
        for (index, paragraph) in story.paragraphs.enumerated() {
            let place = paragraph.cell.flatMap { places[$0] }
            var plan = self.plan(paragraph, index: index, story: story, model: model, place: place)
            plan.key.frame = frames[safe: paragraph.section] ?? StoryFrame()
            if paragraph.section < rendering.sectionStarts.count, model.sections[paragraph.section].firstParagraph == index {
                rendering.sectionStarts[paragraph.section] = rendering.map.count
            }
            let start = rendering.map.count
            for piece in plan.pieces {
                for range in piece.ranges { rendering.map.append(range, kind: piece.kind) }
            }
            rendering.paragraphRanges.append(NSRange(location: start, length: rendering.map.count - start))
            rendering.keys.append(plan.key)
            plans.append(plan)
        }
        // Изменившиеся абзацы: общее начало и общий конец по ключам.
        let old = previous?.keys ?? []
        var prefix = 0
        while prefix < min(old.count, plans.count), old[prefix] == plans[prefix].key { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, plans.count) - prefix, old[old.count - 1 - suffix] == plans[plans.count - 1 - suffix].key { suffix += 1 }
        let oldRanges = previous?.paragraphRanges ?? []
        let oldStart = prefix < oldRanges.count ? oldRanges[prefix].location : (previous?.length ?? 0)
        let oldEnd = old.count - suffix > prefix ? NSMaxRange(oldRanges[old.count - suffix - 1]) : oldStart
        let string = NSMutableAttributedString()
        for index in prefix..<(plans.count - suffix) {
            string.append(attributed(plans[index], paragraph: story.paragraphs[index], model: model, frame: plans[index].key.frame))
        }
        return (rendering, DocRenderPatch(range: NSRange(location: oldStart, length: oldEnd - oldStart), string: string))
    }

    /// Колонтитул (или другая история) целиком; `field` — текст вычисляемого поля (номер страницы).
    func renderStory(_ story: RTFStory, model: RTFDocumentModel, field: (RTFFieldKind) -> String?) -> (NSAttributedString, DocSourceMap) {
        let rendered = renderMargins(story, model: model, field: field)
        return (rendered.string, rendered.map)
    }

    /// Колонтитул: текст, карта и насколько он выходит в поля страницы. Абзацы колонтитулов Word часто с отрицательными
    /// отступами (заходят в поле); показ сдвигает отступы на этот выступ, а рамку рисования расширяет на столько же.
    struct StoryRendering {
        var string: NSAttributedString
        var map: DocSourceMap
        /// Выступ влево и вправо за поля текста, в пунктах.
        var outdentLeft: CGFloat
        var outdentRight: CGFloat
    }

    /// `textWidth` — ширина текста страницы раздела: таблица, правый `\cellx` которой дальше неё, выходит в правое поле
    /// (как в Word), а не сжимается в ширину текста.
    func renderMargins(_ story: RTFStory, model: RTFDocumentModel, textWidth: CGFloat? = nil,
                       field: (RTFFieldKind) -> String?) -> StoryRendering {
        // Выступ в поля: абзацы вне таблиц с отрицательными отступами и таблицы за полями текста (`\trleft` < 0,
        // `\cellx` за правым полем). Отступы абзацев ячеек — от ячейки, не от поля.
        let width = Int(((textWidth ?? contentWidth) * 20).rounded())
        let story = Self.aligningRows(story) { _ in width }
        let frame = Self.frame(free: story.paragraphs.filter { $0.cell == nil }, edges: Self.tableEdges(story).map { ($0.left, $0.right) },
                               width: width)
        let places = cellPlaces(story) { _, left in frame.left + left }
        var map = DocSourceMap()
        let string = NSMutableAttributedString()
        for (index, paragraph) in story.paragraphs.enumerated() {
            var plan = self.plan(paragraph, index: index, story: story, model: model, place: paragraph.cell.flatMap { places[$0] },
                                 sectionBreaks: false)
            // Вычисляемые поля — свой текст (номер страницы), весь — на кусок исходника поля.
            for (offset, piece) in plan.pieces.enumerated() where piece.kind == .field {
                guard let run = piece.run, case .field(let kind) = paragraph.runs[run].kind, let value = field(kind) else { continue }
                let whole = NSRange(location: piece.ranges.first?.location ?? 0,
                                    length: (piece.ranges.last.map(NSMaxRange) ?? 0) - (piece.ranges.first?.location ?? 0))
                plan.pieces[offset].units = Array(value.utf16)
                plan.pieces[offset].ranges = Array(repeating: whole, count: value.utf16.count)
            }
            for piece in plan.pieces {
                for range in piece.ranges { map.append(range, kind: piece.kind) }
            }
            string.append(attributed(plan, paragraph: paragraph, model: model, frame: frame))
        }
        return StoryRendering(string: string, map: map, outdentLeft: CGFloat(frame.left) / 20, outdentRight: CGFloat(frame.right) / 20)
    }

    /// Выступ в поля: абзацы вне таблиц с отрицательными отступами и таблицы за полосой текста (`\trleft` < 0,
    /// `\cellx` за правым полем); `limit` — абзацы не дальше полей страницы. Отступы абзацев ячеек — от ячейки, не от поля.
    private static func frame(free: [RTFParagraph], edges: [(left: Int, right: Int)], width: Int,
                              limit: (left: Int, right: Int) = (.max, .max)) -> StoryFrame {
        // Абзацы — не дальше края листа (`limit`), таблицы — как в Word, и за край листа (лишнее страница обрезает):
        // иначе `NSTextTable` сдвинет или сожмёт таблицу.
        let left = max(0, min(-(free.map { min($0.props.left, $0.props.left + $0.props.firstLine) }.min() ?? 0), limit.left),
                       -(edges.map(\.left).min() ?? 0))
        // Справа — на пункт больше: `NSTextTable` ставит таблицу на полпункта правее края рамки.
        let right = max(0, min(-(free.map(\.props.right).min() ?? 0), limit.right),
                        edges.isEmpty ? 0 : (edges.map(\.right).max() ?? 0) + 20 - width)
        return StoryFrame(left: left, right: right, width: width)
    }

    /// Рамка основного текста каждого раздела: выступ его таблиц и абзацев в поля, не дальше края листа.
    private func bodyFrames(_ model: RTFDocumentModel, story: RTFStory) -> [StoryFrame] {
        var free = Array(repeating: [RTFParagraph](), count: model.sections.count)
        for paragraph in story.paragraphs where paragraph.cell == nil && paragraph.section < free.count { free[paragraph.section].append(paragraph) }
        var edges = Array(repeating: [(left: Int, right: Int)](), count: model.sections.count)
        for edge in Self.tableEdges(story) {
            let section = Self.section(of: edge.table, in: story)
            if section < edges.count { edges[section].append((edge.left, edge.right)) }
        }
        return model.sections.enumerated().map { index, section in
            let props = section.props
            return Self.frame(free: free[index], edges: edges[index], width: Int((DocPageView.bodyRect(props).width * 20).rounded()),
                              limit: (props.marginLeft, props.marginRight))
        }
    }

    /// Раздел таблицы — по её первому абзацу.
    private static func section(of table: Int, in story: RTFStory) -> Int {
        guard let first = story.tables[safe: table]?.rows.first?.paragraphs.first?.first else { return 0 }
        return story.paragraphs[safe: first]?.section ?? 0
    }

    // MARK: - План абзаца

    private struct Piece {
        var units: [UInt16]
        var ranges: [NSRange]
        var kind: DocSourceMap.Kind
        var run: Int?
    }

    private struct ParagraphPlan {
        var pieces: [Piece]
        var key: ParagraphKey
        var place: CellPlace?
        var spacing: (before: Int, after: Int)?
        /// Сколько первых кусков — разрыв перед абзацем («\f»).
        var breakUnits = 0
    }

    private func plan(_ paragraph: RTFParagraph, index: Int, story: RTFStory, model: RTFDocumentModel, place: CellPlace?,
                      sectionBreaks: Bool = true) -> ParagraphPlan {
        var pieces: [Piece] = []
        var breakBefore: UInt8 = 0
        if place?.skip == true {
            return ParagraphPlan(pieces: [], key: ParagraphKey(text: "", runs: [], props: paragraph.props, place: place, breakBefore: 0, end: 0,
                                                              endProps: paragraph.endProps, spacing: [], font: []), place: place)
        }
        // Новая страница раздела и разрыв перед абзацем (`\pagebb`) — «\f»: TextKit переносит текст в следующий контейнер.
        // Внутри таблицы «\f» не переносит — таблица с первой ячейкой на новой странице получает перед собой
        // отдельный абзац «\f\n» нулевой высоты (`docBreakLine`), как Word переносит такую строку.
        let tableStart = place != nil && paragraph.cell?.row == 0 && paragraph.cell?.cell == 0
            && (index == 0 || story.paragraphs[index - 1].cell != paragraph.cell)
        if sectionBreaks, place == nil || tableStart, index > 0 {
            let section = paragraph.section
            if section > 0, section < model.sections.count, model.sections[section].firstParagraph == index, model.sections[section].props.newPage {
                pieces.append(Piece(units: [0x0C], ranges: [NSRange(location: paragraph.regionStart, length: 0)], kind: .sectionBreak))
                breakBefore = 1
            } else if paragraph.props.pageBreakBefore {
                let token = paragraph.propTokens["pagebb"]
                pieces.append(Piece(units: [0x0C], ranges: [token ?? NSRange(location: paragraph.regionStart, length: 0)],
                                    kind: token == nil ? .sectionBreak : .pageBreak))
                breakBefore = 2
            }
            if breakBefore > 0, place != nil {
                pieces.append(Piece(units: [0x0A], ranges: [NSRange(location: paragraph.regionStart, length: 0)], kind: .sectionBreak))
                breakBefore += 2
            }
        }
        var runKeys: [RunKey] = []
        var text = ""
        var fontNames: [String] = []
        for (number, run) in paragraph.runs.enumerated() {
            // Скрытый текст (`\v`) — только при ¶.
            if run.props.hidden, !showsHidden, run.isEditableText { continue }
            let units = Array(run.text.utf16)
            var kind: DocSourceMap.Kind
            var object = 0
            switch run.kind {
            case .text: kind = run.props.hidden ? .hidden : .text
            case .tab: kind = .tab
            case .lineBreak: kind = .lineBreak
            case .pageBreak:
                // Разрыв страницы внутри ячейки таблицы TextKit не переносит — показываем только вне таблиц.
                if place != nil { continue }
                kind = .pageBreak
            case .field: kind = .field
            case .listText: kind = .listText
            case .picture:
                kind = .object
                object = run.picture.map { $0.data.hashValue ^ $0.width &* 31 ^ $0.height } ?? 0
            case .placeholder(let placeholder):
                kind = .object
                object = placeholder.hashValue
            }
            if let floating = run.floating { object ^= floating.hashValue &* 7 }
            pieces.append(Piece(units: units, ranges: run.map, kind: kind, run: number))
            runKeys.append(RunKey(length: units.count, props: run.props, kind: Int(kind.rawValue), object: object))
            text += run.text
            fontNames.append(model.font(run.props.font)?.name ?? "")
        }
        var end: UInt8 = 0
        // Абзац, скрытый целиком (`\v` и на тексте, и на знаке `\par`), Word не показывает вовсе — даже пустой строкой.
        let hiddenWhole = !showsHidden && place == nil && paragraph.end == .paragraph && paragraph.endProps.hidden && pieces.isEmpty
            && paragraph.runs.contains { $0.props.hidden }
        switch paragraph.end {
        case .paragraph where hiddenWhole:
            break
        case .paragraph:
            pieces.append(Piece(units: [0x0A], ranges: [paragraph.endRange], kind: .paragraphEnd))
            end = 1
        case .cell:
            pieces.append(Piece(units: [0x0A], ranges: [paragraph.endRange], kind: .cellEnd))
            end = 2
        case .section:
            pieces.append(Piece(units: [0x0A], ranges: [paragraph.endRange], kind: .sectionEnd))
            end = 3
        case .storyEnd:
            // Без кода конца — только в ячейке (таблице нужен конец абзаца).
            if place != nil {
                pieces.append(Piece(units: [0x0A], ranges: [paragraph.endRange], kind: .storyEnd))
                end = 4
            }
        }
        let spacing = Self.spacing(story, index: index)
        let key = ParagraphKey(text: text, runs: runKeys, props: paragraph.props, place: place, breakBefore: breakBefore, end: end,
                               endProps: paragraph.endProps, spacing: [spacing.before, spacing.after],
                               font: fontNames + [model.font(paragraph.endProps.font)?.name ?? ""])
        return ParagraphPlan(pieces: pieces, key: key, place: place, spacing: spacing, breakUnits: breakBefore > 0 ? 1 : 0)
    }

    /// Интервалы до и после абзаца, как их ставит Word: при `\contextualspace` между абзацами одного стиля их нет.
    private static func spacing(_ story: RTFStory, index: Int) -> (before: Int, after: Int) {
        let props = story.paragraphs[index].props
        guard props.contextualSpace else { return (props.spaceBefore, props.spaceAfter) }
        let previous = index > 0 ? story.paragraphs[index - 1].props : nil
        let next = index + 1 < story.paragraphs.count ? story.paragraphs[index + 1].props : nil
        return (previous?.style == props.style ? 0 : props.spaceBefore, next?.style == props.style ? 0 : props.spaceAfter)
    }

    // MARK: - Атрибуты

    /// `frame` — рамка рисования: абзацы вне таблиц сдвигаются на выступ в поля вместе с табуляциями.
    private func attributed(_ plan: ParagraphPlan, paragraph: RTFParagraph, model: RTFDocumentModel, frame: StoryFrame) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var shown = Self.shown(paragraph.props, place: plan.place, frame: frame, defaultTab: model.defaultTab)
        if let spacing = plan.spacing { (shown.spaceBefore, shown.spaceAfter) = spacing }
        let style = paragraphStyle(shown, place: plan.place, model: model, frame: frame)
        let paraInfo = DocParaInfo(props: paragraph.props)
        // Разрыв — от первого прогона; знак конца абзаца — свои свойства (`\par`/`\cell` в их окружении): как в Word,
        // от его шрифта высота пустого абзаца и последней строки. Скрытый знак — от последнего прогона.
        let firstRun = paragraph.runs.first { !$0.props.hidden || showsHidden }
        let lastRun = paragraph.runs.last { !$0.props.hidden || showsHidden }
        let endProps = paragraph.endProps.hidden && !showsHidden ? lastRun?.props : paragraph.endProps
        // Служебный абзац разрыва перед таблицей — свой стиль, без ячейки.
        let breakPieces = plan.place != nil && plan.key.breakBefore > 2 ? 2 : 0
        for (number, piece) in plan.pieces.enumerated() {
            if number < breakPieces {
                var attributes = characterAttributes(firstRun?.props ?? defaultProps(model), model: model)
                // Высота почти нулевая уже для TextKit: «\f» не должен не поместиться внизу полной страницы
                // (иначе он уходит на следующую и оставляет пустую страницу).
                attributes[.paragraphStyle] = Self.breakStyle
                attributes[.font] = font(family: "Times New Roman", size: 1, bold: false, italic: false)
                attributes[.docPara] = paraInfo
                attributes[.docBreakLine] = true
                result.append(NSAttributedString(string: String(utf16CodeUnits: piece.units, count: piece.units.count), attributes: attributes))
                continue
            }
            let run = piece.run.map { paragraph.runs[$0] }
            let props = run?.props ?? (piece.kind == .sectionBreak || piece.kind == .pageBreak ? firstRun?.props : endProps ?? lastRun?.props)
                ?? defaultProps(model)
            var attributes = characterAttributes(props, model: model, hidden: piece.kind == .hidden)
            attributes[.paragraphStyle] = style
            attributes[.docPara] = paraInfo
            if number < plan.breakUnits {
                // «\f» перед абзацем — строка без высоты: внизу полной страницы она не уходит на следующую.
                attributes[.font] = font(family: "Times New Roman", size: 1, bold: false, italic: false)
                attributes[.docBreakLine] = true
            }
            if let run, piece.kind == .object {
                attributes[.attachment] = attachment(for: run)
            }
            let string = String(utf16CodeUnits: piece.units, count: piece.units.count)
            if (props.caps || props.smallCaps), piece.kind == .text || piece.kind == .hidden || piece.kind == .field {
                result.append(capitals(string, props: props, attributes: attributes, model: model))
            } else {
                result.append(NSAttributedString(string: string, attributes: attributes))
            }
        }
        return result
    }

    /// Все прописные (`\caps`) и капитель (`\scaps`: строчные — прописными на 80 % кегля, как в Word). Буква меняется,
    /// только если её прописная — одна единица UTF-16 (карта «единица ↔ исходник» не сдвигается).
    private func capitals(_ string: String, props: RTFCharProps, attributes: [NSAttributedString.Key: Any],
                          model: RTFDocumentModel) -> NSAttributedString {
        var small = attributes
        if props.smallCaps, let font = attributes[.font] as? NSFont {
            let entry = model.font(props.font)
            let family = FontSubstitution.display(for: entry?.name ?? "Times New Roman", family: entry?.family ?? .roman, panose: entry?.panose)
            small[.font] = self.font(family: family, size: (font.pointSize * 0.8 * 2).rounded() / 2, bold: props.bold, italic: props.italic)
        }
        let result = NSMutableAttributedString()
        for unit in string.utf16 {
            let character = String(utf16CodeUnits: [unit], count: 1)
            let upper = character.uppercased()
            let changed = upper != character && upper.utf16.count == 1
            result.append(NSAttributedString(string: changed ? upper : character,
                                             attributes: changed && props.smallCaps && !props.caps ? small : attributes))
        }
        return result
    }

    /// Отступы и табуляции абзаца для показа. В ячейке — от её поля для показа (`padLeft`) вместо её поля по RTF
    /// (табуляции ячейки в Word — от её текста); вне таблицы — со сдвигом на выступ в поле (у абзаца с рамкой вместо
    /// сдвига — поле блока). Шаг табуляции по умолчанию `NSParagraphStyle` отсчитывает от края рамки, Word — от поля:
    /// при сдвиге позиции по умолчанию становятся явными. В `.docPara` остаются исходные — их правят линейка и команды.
    private static func shown(_ props: RTFParaProps, place: CellPlace?, frame: StoryFrame, defaultTab: Int) -> RTFParaProps {
        var shown = props
        let left: Int, right: Int, width: Int
        if let place {
            (left, right, width) = (place.marginLeft - place.padLeft, place.marginRight - place.padRight,
                                    place.width - place.marginLeft - place.marginRight)
        } else if hasBlock(props) {
            return props
        } else {
            (left, right, width) = (frame.left, frame.right, frame.width)
        }
        guard left != 0 || right != 0 else { return props }
        shown.left += left
        shown.right += right
        var tabs = props.tabs
        let interval = max(defaultTab, 1)
        var position = ((tabs.filter { $0.kind != .bar }.map(\.position).max() ?? 0) / interval + 1) * interval
        while position <= width {
            tabs.append(RTFTabStop(position: position))
            position += interval
        }
        shown.tabs = tabs.map { tab in
            var tab = tab
            tab.position += left
            return tab
        }
        return shown
    }

    /// У абзаца своя рамка или заливка (`NSTextBlock`).
    private static func hasBlock(_ props: RTFParaProps) -> Bool { props.hasBorders || props.shading > 0 }

    func defaultProps(_ model: RTFDocumentModel) -> RTFCharProps {
        var props = RTFCharProps()
        props.font = model.defaultFont
        return props
    }

    /// Атрибуты символа: шрифт (заменой, если его нет на Mac), цвет, маркер, подчёркивание, зачёркивание, положение.
    func characterAttributes(_ props: RTFCharProps, model: RTFDocumentModel, hidden: Bool = false) -> [NSAttributedString.Key: Any] {
        let fontEntry = model.font(props.font)
        let name = fontEntry?.name ?? "Times New Roman"
        let family = FontSubstitution.display(for: name, family: fontEntry?.family ?? .roman, panose: fontEntry?.panose)
        var size = CGFloat(props.halfPoints) / 2
        if props.vertical != .normal { size *= 0.65 }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(family: family, size: size, bold: props.bold, italic: props.italic),
            .foregroundColor: color(props.color, model: model) ?? NSColor.black,
            .docChar: DocCharInfo(props: props, fontName: name, displayFont: family),
        ]
        let highlight = props.highlight > 0 ? props.highlight : props.background
        if highlight > 0, let fill = color(highlight, model: model) { attributes[.backgroundColor] = fill }
        switch props.underline {
        case .none: break
        case .single, .words: attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | (props.underline == .words ? NSUnderlineStyle.byWord.rawValue : 0)
        case .double: attributes[.underlineStyle] = NSUnderlineStyle.double.rawValue
        case .dotted: attributes[.underlineStyle] = NSUnderlineStyle([.single, .patternDot]).rawValue
        case .dashed: attributes[.underlineStyle] = NSUnderlineStyle([.single, .patternDash]).rawValue
        case .thick: attributes[.underlineStyle] = NSUnderlineStyle.thick.rawValue
        case .wave: attributes[.underlineStyle] = NSUnderlineStyle([.single, .patternDashDot]).rawValue
        }
        if props.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        switch props.vertical {
        case .normal: break
        case .superscript: attributes[.baselineOffset] = CGFloat(props.halfPoints) / 2 * 0.35
        case .subscript: attributes[.baselineOffset] = -CGFloat(props.halfPoints) / 2 * 0.15
        }
        if hidden {
            // Скрытый текст при ¶ — серый с точечным подчёркиванием, как в Word.
            attributes[.foregroundColor] = NSColor(white: 0.45, alpha: 1)
            attributes[.underlineStyle] = NSUnderlineStyle([.single, .patternDot]).rawValue
            attributes[.underlineColor] = NSColor(srgbRed: 0.27, green: 0.45, blue: 0.85, alpha: 1)
        }
        return attributes
    }

    func color(_ index: Int, model: RTFDocumentModel) -> NSColor? {
        guard let color = model.color(index) else { return nil }
        return NSColor(srgbRed: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255, blue: CGFloat(color.blue) / 255, alpha: 1)
    }

    func font(family: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let key = FontKey(family: family, size: size, bold: bold, italic: italic)
        if let font = fonts[key] { return font }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let manager = NSFontManager.shared
        var font = manager.font(withFamily: family, traits: traits, weight: 5, size: size)
            ?? manager.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont(name: family, size: size)
            ?? NSFont.systemFont(ofSize: size)
        // Нет начертания у семейства — достраиваем.
        if bold, !manager.traits(of: font).contains(.boldFontMask) { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if italic, !manager.traits(of: font).contains(.italicFontMask) { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        fonts[key] = font
        return font
    }

    // MARK: - Абзац

    private func paragraphStyle(_ props: RTFParaProps, place: CellPlace?, model: RTFDocumentModel, frame: StoryFrame) -> NSParagraphStyle {
        // Не `let blockKey = place.map { blockKey($0) }`: имя затеняло бы метод в собственном инициализаторе —
        // новый компилятор (CI) это не принимает.
        var cellKey: BlockKey?
        if let place { cellKey = self.blockKey(place) }
        // Рамка важна только абзацу с блоком (поля блока); остальным — уже в отступах.
        let key = StyleKey(props: props, block: cellKey, defaultTab: model.defaultTab, frame: place == nil && Self.hasBlock(props) ? frame : StoryFrame())
        if let style = styles[key] { return style }
        let style = NSMutableParagraphStyle()
        switch props.alignment {
        case .left: style.alignment = .left
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        case .justify: style.alignment = .justified
        }
        // В блоке абзаца с рамкой строка не начинается левее него (так она и ложилась: левее края TextKit её не ставит).
        let floor = place == nil && Self.hasBlock(props) ? 0 : Int.min
        style.headIndent = CGFloat(max(floor, props.left)) / 20
        style.firstLineHeadIndent = CGFloat(max(floor, props.left + props.firstLine)) / 20
        style.tailIndent = props.right > 0 ? -CGFloat(props.right) / 20 : 0
        style.paragraphSpacingBefore = CGFloat(props.spaceBefore) / 20
        style.paragraphSpacing = CGFloat(props.spaceAfter) / 20
        if props.lineSpacing > 0 {
            if props.lineMultiple {
                style.lineHeightMultiple = CGFloat(props.lineSpacing) / 240
            } else {
                style.minimumLineHeight = CGFloat(props.lineSpacing) / 20
            }
        } else if props.lineSpacing < 0 {
            style.minimumLineHeight = CGFloat(-props.lineSpacing) / 20
            style.maximumLineHeight = CGFloat(-props.lineSpacing) / 20
        }
        style.defaultTabInterval = CGFloat(max(model.defaultTab, 1)) / 20
        var tabStops = props.tabs.filter { $0.kind != .bar }.map { tab in
            let alignment: NSTextAlignment
            switch tab.kind {
            case .left, .bar: alignment = .left
            case .center: alignment = .center
            case .right, .decimal: alignment = .right
            }
            return NSTextTab(textAlignment: alignment, location: CGFloat(tab.position) / 20)
        }
        // Выступ первой строки (`\fi` < 0): у Word левый отступ абзаца — ещё и позиция табуляции («1.→текст»).
        if props.firstLine < 0, !props.tabs.contains(where: { $0.position == props.left }) {
            tabStops.append(NSTextTab(textAlignment: .left, location: CGFloat(props.left) / 20))
            tabStops.sort { $0.location < $1.location }
        }
        style.tabStops = tabStops
        if let place, let block = tableBlock(place, model: model) {
            style.textBlocks = [block]
        } else if Self.hasBlock(props) {
            style.textBlocks = [borderBlock(props, model: model, frame: key.frame)]
        }
        styles[key] = style
        return style
    }

    private func borderBlock(_ props: RTFParaProps, model: RTFDocumentModel, frame: StoryFrame) -> NSTextBlock {
        let key = BorderKey(props: props, frame: frame)
        if let block = borderBlocks[key] { return block }
        let block = NSTextBlock()
        // Только сверху и снизу: `NSTextBlock` со слоем слева или справа (поле, рамка, отступ), разорванный между
        // страницами, зацикливает typesetter (зависание 1.9.6), а на место строк такие слои и не влияли.
        for (edge, border) in [(NSRectEdge.minY, props.borderTop), (.maxY, props.borderBottom)] {
            guard border.isVisible else { continue }
            block.setWidth(max(0.5, CGFloat(border.width) / 20), type: .absoluteValueType, for: .border, edge: edge)
            block.setBorderColor(color(border.color, model: model) ?? .black, for: edge)
            block.setWidth(1, type: .absoluteValueType, for: .padding, edge: edge)
        }
        if props.shading > 0 { block.backgroundColor = color(props.shading, model: model) }
        borderBlocks[key] = block
        return block
    }

    // MARK: - Таблицы

    /// Строки `\trqc`/`\trqr` — по центру или вправо полосы текста (ширина по номеру таблицы, твипы), как в Word:
    /// `\trleft` у них не учитывается, сдвигаются левый край и все `\cellx` строки.
    private static func aligningRows(_ story: RTFStory, width: (Int) -> Int?) -> RTFStory {
        guard story.tables.contains(where: { $0.rows.contains { $0.alignment != .left } }) else { return story }
        var story = story
        for table in story.tables.indices {
            guard story.tables[table].rows.contains(where: { $0.alignment != .left }), let width = width(table) else { continue }
            for index in story.tables[table].rows.indices {
                var row = story.tables[table].rows[index]
                guard row.alignment != .left else { continue }
                let right = row.cells.reduce(row.left) { max($0, $1.right) }
                let left = row.alignment == .center ? (width - (right - row.left)) / 2 : width - (right - row.left)
                let shift = left - row.left
                row.left += shift
                for cell in row.cells.indices { row.cells[cell].right += shift }
                story.tables[table].rows[index] = row
            }
        }
        return story
    }

    /// Левый и правый край каждой таблицы истории от поля текста (`\trleft`, наибольший `\cellx`), твипы.
    private static func tableEdges(_ story: RTFStory) -> [(table: Int, left: Int, right: Int)] {
        story.tables.enumerated().compactMap { index, table in
            var left: Int?, right: Int?
            for row in table.rows {
                left = min(left ?? row.left, row.left)
                var edge = row.left
                for cell in row.cells { edge = max(cell.right, edge) }
                right = max(right ?? edge, edge)
            }
            guard let left, let right else { return nil }
            return (index, left, right)
        }
    }

    /// Место каждой ячейки в сетке таблицы: столбцы — все границы `\cellx` всех строк, объединение по вертикали.
    /// `offset` — отступ таблицы от края рамки по номеру таблицы и её левому краю `\trleft`.
    private func cellPlaces(_ story: RTFStory, offset: (Int, Int) -> Int) -> [RTFCellRef: CellPlace] {
        var places: [RTFCellRef: CellPlace] = [:]
        for (ordinal, table) in story.tables.enumerated() {
            var hasher = Hasher()
            var bounds = Set<Int>()
            for row in table.rows {
                hasher.combine(row.left)
                hasher.combine(row.gap)
                hasher.combine([row.padLeft, row.padLeftUnit, row.padRight, row.padRightUnit])
                hasher.combine(row.height)
                hasher.combine(row.cells)
                var left = row.left
                bounds.insert(left)
                for cell in row.cells {
                    bounds.insert(max(cell.right, left))
                    left = max(cell.right, left)
                }
            }
            let grid = bounds.sorted()
            let tableKey = TableKey(ordinal: ordinal, signature: hasher.finalize(), offset: max(0, offset(ordinal, grid.first ?? 0)))
            let columns = max(1, grid.count - 1)
            let tableWidth = (grid.last ?? 0) - (grid.first ?? 0)
            for (rowIndex, row) in table.rows.enumerated() {
                var left = row.left
                var cellIndex = 0
                while cellIndex < row.cells.count {
                    let cell = row.cells[cellIndex]
                    var right = max(cell.right, left)
                    var span = 1
                    // Объединение по горизонтали: продолжения (`\clmrg`) присоединяются к первой.
                    while cell.horizontalMergeFirst, cellIndex + span < row.cells.count, row.cells[cellIndex + span].horizontalMerged {
                        right = max(row.cells[cellIndex + span].right, right)
                        span += 1
                    }
                    let start = grid.firstIndex(of: left) ?? 0
                    let end = grid.firstIndex(of: right) ?? min(grid.count - 1, start + 1)
                    var rowSpan = 1
                    if cell.verticalMergeFirst {
                        var next = rowIndex + 1
                        while next < table.rows.count,
                              let below = Self.cell(in: table.rows[next], left: left, right: right), below.verticalMerged {
                            rowSpan += 1
                            next += 1
                        }
                    }
                    // Поле ячейки уменьшается на самый отрицательный отступ её абзацев (не меньше нуля).
                    let margins = row.margins(cell)
                    let paragraphs = (row.paragraphs[safe: cellIndex] ?? []).compactMap { story.paragraphs[safe: $0]?.props }
                    let indentLeft = paragraphs.map { min($0.left, $0.left + $0.firstLine) }.min() ?? 0
                    let indentRight = paragraphs.map(\.right).min() ?? 0
                    let place = CellPlace(table: tableKey, row: rowIndex, column: start, rowSpan: rowSpan, columnSpan: max(1, end - start),
                                          start: left - (grid.first ?? 0), width: right - left, skip: cell.verticalMerged || cell.horizontalMerged,
                                          def: cell, marginLeft: margins.left, marginRight: margins.right, height: row.height, columns: columns, tableWidth: tableWidth,
                                          padLeft: max(0, margins.left + min(0, indentLeft)),
                                          padRight: max(0, margins.right + min(0, indentRight)),
                                          padTop: row.padTop, padBottom: row.padBottom)
                    for offset in 0..<span {
                        var placed = place
                        if offset > 0 { placed.skip = true }
                        places[RTFCellRef(table: ordinal, row: rowIndex, cell: cellIndex + offset)] = placed
                    }
                    left = right
                    cellIndex += span
                }
            }
        }
        return places
    }

    private static func cell(in row: RTFRow, left: Int, right: Int) -> RTFCellDef? {
        var edge = row.left
        for cell in row.cells {
            if edge == left, cell.right == right { return cell }
            edge = max(cell.right, edge)
        }
        return nil
    }

    private func blockKey(_ place: CellPlace) -> BlockKey {
        BlockKey(table: place.table, row: place.row, column: place.column, rowSpan: place.rowSpan, columnSpan: place.columnSpan,
                 cell: place.def, marginLeft: place.marginLeft,
                 marginRight: place.marginRight, height: place.height, start: place.start, width: place.width, padLeft: place.padLeft,
                 padRight: place.padRight, padTop: place.padTop, padBottom: place.padBottom)
    }

    private func tableBlock(_ place: CellPlace, model: RTFDocumentModel) -> NSTextTableBlock? {
        guard !place.skip else { return nil }
        let key = blockKey(place)
        if let block = blocks[key] { return block }
        let table: NSTextTable
        if let cached = tables[place.table] {
            table = cached
        } else {
            table = NSTextTable()
            table.numberOfColumns = place.columns
            table.layoutAlgorithm = .fixedLayoutAlgorithm
            table.collapsesBorders = true
            table.hidesEmptyCells = false
            // Ширина таблицы у `NSTextTable` — вместе с отступом слева (полем блока). Всё в целых пунктах: дробные ширины
            // и поля `NSTextTable` округляет внутрь, и текст ячейки становится уже, чем в Word (до 2 pt).
            let offset = Self.points(place.table.offset)
            table.setContentWidth(Self.points(max(place.tableWidth, 20)) + offset, type: .absoluteValueType)
            if offset > 0 { table.setWidth(offset, type: .absoluteValueType, for: .margin, edge: .minX) }
            tables[place.table] = table
        }
        let block = DocCellBlock(table: table, startingRow: place.row, rowSpan: place.rowSpan,
                                 startingColumn: place.column, columnSpan: place.columnSpan)
        // Края ячейки — целые от левого края таблицы (без накопления ошибки). Поля тоже целые: слева — до ближайшего
        // к точному началу текста (Word: `\trleft` + края + поле), справа — правее точного конца (не уже Word). Всю таблицу
        // `NSTextTable` ставит на полпункта правее рамки — это учтено.
        let offset = Self.points(place.table.offset), cellLeft = offset + Self.points(place.start)
        let cellRight = offset + Self.points(place.start + place.width), width = cellRight - cellLeft
        let textLeft = (CGFloat(place.table.offset + place.start + place.padLeft) / 20 - 0.5).rounded()
        let textRight = (CGFloat(place.table.offset + place.start + place.width - place.padRight) / 20 - 0.5).rounded(.up)
        let padLeft = max(0, textLeft - cellLeft), padRight = max(0, cellRight - textRight)
        block.setWidth(padLeft, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(padRight, type: .absoluteValueType, for: .padding, edge: .maxX)
        // Сверху и снизу — поля строки `\trpaddt`/`\trpaddb` (у Word по умолчанию 0: текст у самой линии сетки).
        block.setWidth(CGFloat(place.padTop) / 20, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(CGFloat(place.padBottom) / 20, type: .absoluteValueType, for: .padding, edge: .maxY)
        let cell = place.def
        for (edge, border) in [(NSRectEdge.minY, cell.borderTop), (.maxY, cell.borderBottom), (.minX, cell.borderLeft), (.maxX, cell.borderRight)] {
            guard border.isVisible else { continue }
            block.lines.append(DocCellBlock.Line(edge: edge, width: max(0.5, CGFloat(border.width) / 20),
                                                 color: color(border.color, model: model) ?? .black))
        }
        if cell.shading > 0 { block.backgroundColor = color(cell.shading, model: model) }
        block.setContentWidth(max(4, width - padLeft - padRight), type: .absoluteValueType)
        if place.height != 0 {
            block.setValue(CGFloat(abs(place.height)) / 20, type: .absoluteValueType, for: .minimumHeight)
        }
        // `\trrh` < 0 — «точно»: у Word строка не растёт, лишний текст ячейки обрезается.
        if place.height < 0, place.rowSpan == 1 {
            block.setValue(CGFloat(-place.height) / 20, type: .absoluteValueType, for: .maximumHeight)
        }
        switch cell.verticalAlign {
        case .top: block.verticalAlignment = .topAlignment
        case .center: block.verticalAlignment = .middleAlignment
        case .bottom: block.verticalAlignment = .bottomAlignment
        }
        blocks[key] = block
        return block
    }

    /// Стиль служебного абзаца разрыва перед таблицей.
    private static let breakStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0.01
        style.maximumLineHeight = 0.01
        return style
    }()

    /// Твипы → целые пункты (вниз: таблица не шире своей рамки, иначе `NSTextTable` сожмёт все столбцы).
    private static func points(_ twips: Int) -> CGFloat { floor(CGFloat(twips) / 20) }

    // MARK: - Рисунки и заглушки

    private func attachment(for run: RTFRun) -> NSTextAttachment {
        // Фигура без обтекания: в тексте — опора нулевой ширины, сама рисуется поверх страницы (`DocFloatingLayer`).
        if let floating = run.floating {
            let image = run.picture.flatMap { NSImage(data: $0.data) }
            let key = floating.hashValue ^ (run.picture?.data.hashValue ?? 0) &* 31
            if let cached = attachments[key] { return cached }
            let attachment = NSTextAttachment()
            attachment.attachmentCell = DocFloatingCell(shape: floating, image: image)
            attachments[key] = attachment
            return attachment
        }
        let key: Int
        if let picture = run.picture {
            key = picture.data.hashValue ^ picture.width &* 31 ^ picture.height
        } else if case .placeholder(let placeholder) = run.kind {
            key = placeholder.hashValue ^ Int(contentWidth)
        } else {
            key = 0
        }
        if let cached = attachments[key] { return cached }
        let attachment = NSTextAttachment()
        if let picture = run.picture, let image = NSImage(data: picture.data) {
            var size = CGSize(width: CGFloat(max(picture.width, 20)) / 20, height: CGFloat(max(picture.height, 20)) / 20)
            if size.width > contentWidth {
                size = CGSize(width: contentWidth, height: size.height * contentWidth / size.width)
            }
            image.size = size
            attachment.image = image
            attachment.bounds = CGRect(origin: .zero, size: size)
        } else if case .placeholder(let placeholder) = run.kind {
            let cell = DocPlaceholderCell(placeholder: placeholder, width: min(contentWidth, 520))
            cell.onAction = { [weak self] action, character in self?.placeholderAction?(action, character) }
            attachment.attachmentCell = cell
        }
        attachments[key] = attachment
        return attachment
    }
}

/// Ячейка таблицы, чьи рамки рисуются по её краю (как в Word — по линии сетки), а не внутри: рамка `NSTextBlock`
/// занимает место в ширине столбца, и текст ячейки становится уже, чем в Word.
final class DocCellBlock: NSTextTableBlock {
    struct Line {
        var edge: NSRectEdge
        var width: CGFloat
        var color: NSColor
    }

    var lines: [Line] = []

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?, characterRange charRange: NSRange,
                                 layoutManager: NSLayoutManager) {
        // До SDK macOS 27 `controlView` у `NSTextBlock` не опциональный (CI собирает старым Xcode): туда — развёрнутый.
        if let controlView {
            super.drawBackground(withFrame: frameRect, in: controlView, characterRange: charRange, layoutManager: layoutManager)
        } else {
            #if compiler(>=6.4)
            super.drawBackground(withFrame: frameRect, in: nil, characterRange: charRange, layoutManager: layoutManager)
            #endif
        }
        for line in lines {
            let half = line.width / 2
            let rect: NSRect
            switch line.edge {
            case .minX: rect = NSRect(x: frameRect.minX - half, y: frameRect.minY - half, width: line.width, height: frameRect.height + line.width)
            case .maxX: rect = NSRect(x: frameRect.maxX - half, y: frameRect.minY - half, width: line.width, height: frameRect.height + line.width)
            case .minY: rect = NSRect(x: frameRect.minX - half, y: frameRect.minY - half, width: frameRect.width + line.width, height: line.width)
            default: rect = NSRect(x: frameRect.minX - half, y: frameRect.maxY - half, width: frameRect.width + line.width, height: line.width)
            }
            line.color.setFill()
            rect.fill()
        }
    }
}

import AppKit

extension NSAttributedString.Key {
    /// Свойства символа документа для панели форматирования (`DocCharInfo`).
    static let docChar = NSAttributedString.Key("MacUtilsDocChar")
    /// Свойства абзаца документа для панели и линейки (`DocParaInfo`).
    static let docPara = NSAttributedString.Key("MacUtilsDocPara")
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
struct DocRendering {
    var map = DocSourceMap()
    /// Показанный диапазон каждого абзаца модели вместе с его концом; у пропущенных (объединённая ячейка) — пустой.
    var paragraphRanges: [NSRange] = []
    /// Начало каждого раздела в показанном тексте.
    var sectionStarts: [Int] = [0]
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
    private var borderBlocks: [RTFParaProps: NSTextBlock] = [:]
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
    }

    private struct BlockKey: Hashable {
        var table: TableKey
        var row: Int
        var column: Int
        var rowSpan: Int
        var columnSpan: Int
        var cell: RTFCellDef
        var gap: Int
        var height: Int
        var width: Int
    }

    private struct StyleKey: Hashable {
        var props: RTFParaProps
        var block: BlockKey?
        var defaultTab: Int
    }

    /// Ячейка таблицы для показа: где в сетке, сколько занимает, пропускается ли (продолжение объединения).
    fileprivate struct CellPlace: Hashable {
        var table: TableKey
        var row: Int
        var column: Int
        var rowSpan: Int
        var columnSpan: Int
        var width: Int
        var skip: Bool
        var def: RTFCellDef
        var gap: Int
        var height: Int
        var columns: Int
        var tableWidth: Int
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
        var font: [String]
    }

    // MARK: - Основной текст

    /// Показать модель. С `previous` перерисовываются только изменившиеся абзацы (заплатка), карта — целиком.
    func render(_ model: RTFDocumentModel, previous: DocRendering?) -> (DocRendering, DocRenderPatch) {
        let story = model.body
        let places = cellPlaces(story)
        var rendering = DocRendering()
        rendering.map.reserve(previous?.map.count ?? 4_096)
        rendering.paragraphRanges.reserveCapacity(story.paragraphs.count)
        rendering.keys.reserveCapacity(story.paragraphs.count)
        rendering.sectionStarts = Array(repeating: 0, count: model.sections.count)
        var plans: [ParagraphPlan] = []
        plans.reserveCapacity(story.paragraphs.count)
        for (index, paragraph) in story.paragraphs.enumerated() {
            let place = paragraph.cell.flatMap { places[$0] }
            let plan = self.plan(paragraph, index: index, model: model, place: place)
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
            string.append(attributed(plans[index], paragraph: story.paragraphs[index], model: model))
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

    func renderMargins(_ story: RTFStory, model: RTFDocumentModel, field: (RTFFieldKind) -> String?) -> StoryRendering {
        let shiftLeft = max(0, -(story.paragraphs.map { min($0.props.left, $0.props.left + $0.props.firstLine) }.min() ?? 0))
        let shiftRight = max(0, -(story.paragraphs.map(\.props.right).min() ?? 0))
        let places = cellPlaces(story)
        var map = DocSourceMap()
        let string = NSMutableAttributedString()
        for (index, original) in story.paragraphs.enumerated() {
            var paragraph = original
            paragraph.props.left += shiftLeft
            paragraph.props.right += shiftRight
            var plan = self.plan(paragraph, index: index, model: model, place: paragraph.cell.flatMap { places[$0] }, sectionBreaks: false)
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
            string.append(attributed(plan, paragraph: paragraph, model: model))
        }
        return StoryRendering(string: string, map: map, outdentLeft: CGFloat(shiftLeft) / 20, outdentRight: CGFloat(shiftRight) / 20)
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
    }

    private func plan(_ paragraph: RTFParagraph, index: Int, model: RTFDocumentModel, place: CellPlace?,
                      sectionBreaks: Bool = true) -> ParagraphPlan {
        var pieces: [Piece] = []
        var breakBefore: UInt8 = 0
        if place?.skip == true {
            return ParagraphPlan(pieces: [], key: ParagraphKey(text: "", runs: [], props: paragraph.props, place: place, breakBefore: 0, end: 0,
                                                              font: []), place: place)
        }
        // Новая страница раздела и разрыв перед абзацем (`\pagebb`) — «\f»: TextKit переносит текст в следующий контейнер.
        if sectionBreaks, place == nil, index > 0 {
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
            pieces.append(Piece(units: units, ranges: run.map, kind: kind, run: number))
            runKeys.append(RunKey(length: units.count, props: run.props, kind: Int(kind.rawValue), object: object))
            text += run.text
            fontNames.append(model.font(run.props.font)?.name ?? "")
        }
        var end: UInt8 = 0
        switch paragraph.end {
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
        let key = ParagraphKey(text: text, runs: runKeys, props: paragraph.props, place: place, breakBefore: breakBefore, end: end,
                               font: fontNames)
        return ParagraphPlan(pieces: pieces, key: key, place: place)
    }

    // MARK: - Атрибуты

    private func attributed(_ plan: ParagraphPlan, paragraph: RTFParagraph, model: RTFDocumentModel) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let style = paragraphStyle(paragraph.props, place: plan.place, model: model)
        let paraInfo = DocParaInfo(props: paragraph.props)
        // Атрибуты конца абзаца и разрыва — от ближайшего прогона (у пустого абзаца — по умолчанию).
        let firstRun = paragraph.runs.first { !$0.props.hidden || showsHidden }
        let lastRun = paragraph.runs.last { !$0.props.hidden || showsHidden }
        for piece in plan.pieces {
            let run = piece.run.map { paragraph.runs[$0] }
            let props = run?.props ?? (piece.kind == .sectionBreak || piece.kind == .pageBreak ? firstRun?.props : lastRun?.props)
                ?? defaultProps(model)
            var attributes = characterAttributes(props, model: model, hidden: piece.kind == .hidden)
            attributes[.paragraphStyle] = style
            attributes[.docPara] = paraInfo
            if let run, piece.kind == .object {
                attributes[.attachment] = attachment(for: run)
            }
            let string = String(utf16CodeUnits: piece.units, count: piece.units.count)
            result.append(NSAttributedString(string: string, attributes: attributes))
        }
        return result
    }

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

    private func paragraphStyle(_ props: RTFParaProps, place: CellPlace?, model: RTFDocumentModel) -> NSParagraphStyle {
        // Не `let blockKey = place.map { blockKey($0) }`: имя затеняло бы метод в собственном инициализаторе —
        // новый компилятор (CI) это не принимает.
        var cellKey: BlockKey?
        if let place { cellKey = self.blockKey(place) }
        let key = StyleKey(props: props, block: cellKey, defaultTab: model.defaultTab)
        if let style = styles[key] { return style }
        let style = NSMutableParagraphStyle()
        switch props.alignment {
        case .left: style.alignment = .left
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        case .justify: style.alignment = .justified
        }
        style.headIndent = CGFloat(props.left) / 20
        style.firstLineHeadIndent = CGFloat(props.left + props.firstLine) / 20
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
        style.tabStops = props.tabs.filter { $0.kind != .bar }.map { tab in
            let alignment: NSTextAlignment
            switch tab.kind {
            case .left, .bar: alignment = .left
            case .center: alignment = .center
            case .right, .decimal: alignment = .right
            }
            return NSTextTab(textAlignment: alignment, location: CGFloat(tab.position) / 20)
        }
        if let place, let block = tableBlock(place, model: model) {
            style.textBlocks = [block]
        } else if props.hasBorders || props.shading > 0 {
            style.textBlocks = [borderBlock(props, model: model)]
        }
        styles[key] = style
        return style
    }

    private func borderBlock(_ props: RTFParaProps, model: RTFDocumentModel) -> NSTextBlock {
        if let block = borderBlocks[props] { return block }
        let block = NSTextBlock()
        for (edge, border) in [(NSRectEdge.minY, props.borderTop), (.maxY, props.borderBottom), (.minX, props.borderLeft), (.maxX, props.borderRight)] {
            guard border.isVisible else { continue }
            block.setWidth(max(0.5, CGFloat(border.width) / 20), type: .absoluteValueType, for: .border, edge: edge)
            block.setBorderColor(color(border.color, model: model) ?? .black, for: edge)
            block.setWidth(1, type: .absoluteValueType, for: .padding, edge: edge)
        }
        if props.shading > 0 { block.backgroundColor = color(props.shading, model: model) }
        borderBlocks[props] = block
        return block
    }

    // MARK: - Таблицы

    /// Место каждой ячейки в сетке таблицы: столбцы — все границы `\cellx` всех строк, объединение по вертикали.
    private func cellPlaces(_ story: RTFStory) -> [RTFCellRef: CellPlace] {
        var places: [RTFCellRef: CellPlace] = [:]
        for (ordinal, table) in story.tables.enumerated() {
            var hasher = Hasher()
            var bounds = Set<Int>()
            for row in table.rows {
                hasher.combine(row.left)
                hasher.combine(row.gap)
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
            let tableKey = TableKey(ordinal: ordinal, signature: hasher.finalize())
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
                    let place = CellPlace(table: tableKey, row: rowIndex, column: start, rowSpan: rowSpan, columnSpan: max(1, end - start),
                                          width: right - left, skip: cell.verticalMerged || cell.horizontalMerged, def: cell, gap: row.gap,
                                          height: row.height, columns: columns, tableWidth: tableWidth)
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
                 cell: place.def, gap: place.gap, height: place.height, width: place.width)
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
            table.setContentWidth(CGFloat(max(place.tableWidth, 20)) / 20, type: .absoluteValueType)
            tables[place.table] = table
        }
        let block = NSTextTableBlock(table: table, startingRow: place.row, rowSpan: place.rowSpan,
                                     startingColumn: place.column, columnSpan: place.columnSpan)
        let padding = CGFloat(max(place.gap, 0)) / 20
        block.setWidth(padding, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(padding, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(1, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(1, type: .absoluteValueType, for: .padding, edge: .maxY)
        let cell = place.def
        for (edge, border) in [(NSRectEdge.minY, cell.borderTop), (.maxY, cell.borderBottom), (.minX, cell.borderLeft), (.maxX, cell.borderRight)] {
            guard border.isVisible else { continue }
            block.setWidth(max(0.5, CGFloat(border.width) / 20), type: .absoluteValueType, for: .border, edge: edge)
            block.setBorderColor(color(border.color, model: model) ?? .black, for: edge)
        }
        if cell.shading > 0 { block.backgroundColor = color(cell.shading, model: model) }
        block.setContentWidth(max(4, CGFloat(place.width) / 20 - 2 * padding), type: .absoluteValueType)
        if place.height != 0 {
            block.setValue(CGFloat(abs(place.height)) / 20, type: .absoluteValueType, for: .minimumHeight)
        }
        switch cell.verticalAlign {
        case .top: block.verticalAlignment = .topAlignment
        case .center: block.verticalAlignment = .middleAlignment
        case .bottom: block.verticalAlignment = .bottomAlignment
        }
        blocks[key] = block
        return block
    }

    // MARK: - Рисунки и заглушки

    private func attachment(for run: RTFRun) -> NSTextAttachment {
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

import Foundation
import MUCore
import MUDesign

/// Разбор RTF в `RTFDocumentModel` с картой «видимый символ ↔ диапазон исходника». Тот же подход, что у
/// `RTFDollarScanner`: группы, управляющие слова с числом и одним пробелом-разделителем, `\'hh` по кодовой странице
/// шрифта или документа, `\uN` с заменителями `\ucN`, назначения `{\*\…}`. Исходник не меняется и не копируется
/// в строки по символу — 1,9 МБ разбираются за десятки миллисекунд.
package enum RTFReader {
    package static func read(_ text: NSString, fallback: TextEncoding = .windows1252) -> RTFDocumentModel {
        let length = text.length
        var units = [UInt16](repeating: 0, count: length)
        if length > 0 {
            units.withUnsafeMutableBufferPointer { text.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) }
        }
        return units.withUnsafeBufferPointer { buffer in
            let parser = RTFParser(buffer, fallback: fallback)
            parser.run()
            var model = parser.model
            model.lists = DocListReader.read(text, table: parser.listTable, overrides: parser.listOverrideTable, codePage: model.codePage)
            return model
        }
    }

    package static func read(_ text: String) -> RTFDocumentModel { read(text as NSString) }

    /// Кодировка `\'hh` для шрифта: `\cpgN`, иначе по `\fcharsetN`, иначе кодовая страница документа.
    package static func encoding(charset: Int, codePage: Int?, document: TextEncoding) -> TextEncoding {
        if let codePage, let encoding = TextEncoding(codePage: codePage), encoding.group != .unicode { return encoding }
        switch charset {
        case 204: return .windows1251
        case 238: return .windows1250
        case 0: return document
        default: return document
        }
    }
}

/// Разбор одного исходника. Живёт только внутри `RTFReader.read` (держит указатель на буфер).
private final class RTFParser {
    package typealias Key = RTFDollarScanner.WordKey

    private let u: UnsafeBufferPointer<UInt16>
    private let count: Int
    private var i = 0
    package private(set) var model = RTFDocumentModel()
    /// Группы `{\*\listtable …}` и `{\*\listoverridetable …}` — разбираются отдельно (`DocListReader`).
    package private(set) var listTable: NSRange?
    package private(set) var listOverrideTable: NSRange?

    // MARK: Состояние групп

    private enum Destination: Equatable {
        case text, fontTable, fontEntry, colorTable, fieldInstruction, picture, shape, shapeInstruction
        case shapeProperty, shapeName, shapeValue, drawing, upr, panose
    }

    private enum BorderTarget: Equatable {
        case none, paraTop, paraBottom, paraLeft, paraRight, paraBox
        case cellTop, cellBottom, cellLeft, cellRight
        case rowTop, rowBottom, rowLeft, rowRight, rowInsideH, rowInsideV
    }

    private struct Group {
        package var char = RTFCharProps()
        package var charVersion = 0
        package var para = RTFParaProps()
        package var uc = 1
        package var destination = Destination.text
        package var fresh = true
        package var ignorable = false
        package var id = 0
        package var start = 0
        package var story = 0
        package var border = BorderTarget.none
        package var tabKind = RTFTabStop.Kind.left
        package var tabLeader = false
        package var listText = false
        package var field: Int?
        package var fieldResult = false
        /// `{\*\nesttableprops …}` — определение строки вложенной таблицы.
        package var nestProps = false
    }

    private var stack: [Group] = []
    private var nextGroupID = 1
    private var nextCharVersion = 1

    // MARK: Истории (основной текст и колонтитулы)

    private struct RunKey: Equatable {
        package var version: Int
        package var group: Int
        package var kind: Int
        package var uc: Int
        package var field: Int?
    }

    private struct Story {
        package var paragraphs: [RTFParagraph] = []
        package var current = RTFParagraph()
        package var units: [[UInt16]] = []
        package var lastKey: RunKey?
        package var tables: [RTFTable] = []
        package var rowCells: [[Int]] = []
        package var cellParagraphs: [Int] = []
        /// То же для строки вложенной таблицы (`\nestcell`, `\nestrow`).
        package var nestedRowCells: [[Int]] = []
        package var nestedCellParagraphs: [Int] = []
        package var pard: (range: NSRange, group: Int)?
        package var tokens: [String: (range: NSRange, group: Int)] = [:]
        package var range = NSRange(location: 0, length: 0)
        package var headerKind: RTFHeaderKind?
        package var section = 0
    }

    private var stories: [Story] = [Story()]

    // MARK: Документ, разделы, таблицы

    private var documentPage = RTFSectionProps()
    private var currentSection = 0
    /// Первый код основного текста раздела (`\pard`, `\trowd`, текст…) — сюда вставляются новые колонтитулы.
    private var sectionContentStart: [Int: Int] = [:]
    /// Начало текста текущего раздела уже отмечено (проверка на каждый символ — без словаря).
    private var contentNoted = false
    private var lastHeaderEnd: [Int: Int] = [:]
    private var row = RTFRow()
    /// Строка внешней таблицы, пока разбирается определение вложенной (`\nesttableprops`).
    private var savedRows: [(row: RTFRow, cell: RTFCellDef, borders: RowBorders)] = []
    private var cellInProgress = RTFCellDef()
    private typealias RowBorders = (top: RTFBorder?, bottom: RTFBorder?, left: RTFBorder?, right: RTFBorder?, insideH: RTFBorder?,
                                    insideV: RTFBorder?)
    private var rowBorders: RowBorders = (nil, nil, nil, nil, nil, nil)

    // MARK: Назначения: шрифты, цвета, рисунки, фигуры, поля

    private var fontEntry: RTFFont?
    private var fontName: [UInt16] = []
    private var panose: [UInt16] = []
    private var colorParts: (red: Int?, green: Int?, blue: Int?) = (nil, nil, nil)
    private var pictureFormat: String?
    private var pictureHex: [UInt8] = []
    private var pictureNibble: UInt8?
    private var pictureSize = (w: 0, h: 0, goalW: 0, goalH: 0, scaleX: 100, scaleY: 100)
    private var shapeType: Int?
    private var shapeBox = (left: 0, right: 0, top: 0, bottom: 0)
    private var shapePropName: [UInt16] = []
    private var shapePropValue: [UInt16] = []
    private var shapePicture: RTFPicture?
    /// Обтекание (`\shpwr`), опора и свойства `{\sp{\sn …}{\sv …}}` текущей фигуры.
    private var shapeWrap = 0
    private var shapeFloat = RTFFloat()
    private var shapeProps: [String: String] = [:]
    private var drawingType = "Объект"
    private var drawingSize = (w: 0, h: 0)
    private var fieldInstructions: [Int: [UInt16]] = [:]
    private var byteTables: [TextEncoding: [UInt16]] = [:]
    private let fallback: TextEncoding

    package init(_ buffer: UnsafeBufferPointer<UInt16>, fallback: TextEncoding) {
        u = buffer
        count = buffer.count
        self.fallback = fallback
    }

    // MARK: - Проход

    package func run() {
        model.isRTF = Self.startsWithRTF(u)
        model.codePage = fallback.group == .unicode ? .windows1252 : fallback
        var root = Group()
        root.char.halfPoints = 24
        stack = [root]
        stories[0].range = NSRange(location: 0, length: count)
        while i < count {
            let unit = u[i]
            switch unit {
            case 0x7B: openGroup()
            case 0x7D: closeGroup()
            case 0x5C: controlSequence()
            case 0x0D, 0x0A:
                i += 1
            default:
                plainText()
            }
        }
        // Незакрытые группы (битый файл) — закрываем в конце.
        while stack.count > 1 { finishGroup(end: count) }
        finishStory(0, end: count, props: top.para)
        finishSections()
        model.body = buildStory(stories[0])
        if model.defaultFont == nil { model.defaultFont = model.fonts.keys.min() }
    }

    private static func startsWithRTF(_ u: UnsafeBufferPointer<UInt16>) -> Bool {
        var k = 0
        while k < u.count, [0x20, 0x09, 0x0D, 0x0A, 0xFEFF].contains(u[k]) { k += 1 }
        let prefix: [UInt16] = [0x7B, 0x5C, 0x72, 0x74, 0x66]  // {\rtf
        return k + prefix.count <= u.count && (0..<prefix.count).allSatisfy { u[k + $0] == prefix[$0] }
    }

    /// Верх стека без копирования состояния (в нём массивы — копия на каждый символ стоила бы сотни миллисекунд).
    private var top: Group {
        _read { yield stack[stack.count - 1] }
        _modify { yield &stack[stack.count - 1] }
    }

    private func openGroup() {
        var group = top
        group.fresh = true
        group.ignorable = false
        group.id = nextGroupID
        nextGroupID += 1
        group.start = i
        group.border = .none
        stack.append(group)
        i += 1
        // Вложенные группы внутри рисунка, фигуры, объекта рисования и `\upr` не показываются (кроме разобранных ниже).
        switch group.destination {
        case .picture, .drawing:
            skipGroup()
        default:
            break
        }
    }

    private func closeGroup() {
        let end = i + 1
        i += 1
        guard stack.count > 1 else { return }
        finishGroup(end: end)
    }

    /// Группа закрылась: дела назначения (шрифт, цвет, рисунок, фигура, колонтитул, поле) и возврат состояния.
    private func finishGroup(end: Int) {
        let group = stack.removeLast()
        let range = NSRange(location: group.start, length: end - group.start)
        switch group.destination {
        case .fontEntry:
            if top.destination != .fontEntry { finishFont() }
        case .fontTable:
            if top.destination != .fontTable {
                finishFont()
                model.fontTable = range
            }
        case .colorTable:
            if top.destination != .colorTable { model.colorTable = range }
        case .picture:
            if top.destination != .picture { finishPicture(range, group: group) }
        case .shape:
            if top.destination != .shape {
                let width = max(0, shapeBox.right - shapeBox.left), height = max(0, shapeBox.bottom - shapeBox.top)
                let floating = floatingShape(width: width, height: height)
                if var picture = shapePicture {
                    if width > 0, height > 0 { (picture.width, picture.height) = (width, height) }
                    emitObject(.picture, range: range, group: group, picture: picture, floating: floating)
                } else {
                    var placeholder = RTFPlaceholder(kind: .shape(shapeType))
                    placeholder.width = width
                    placeholder.height = height
                    emitObject(.placeholder(placeholder), range: range, group: group, floating: floating)
                }
                shapePicture = nil
            }
        case .shapeProperty:
            if top.destination != .shapeProperty {
                let name = String(utf16CodeUnits: shapePropName, count: shapePropName.count)
                let value = String(utf16CodeUnits: shapePropValue, count: shapePropValue.count)
                let key = name.trimmingCharacters(in: .whitespaces)
                if key == "shapeType" { shapeType = Int(value.trimmingCharacters(in: .whitespaces)) }
                shapeProps[key] = value.trimmingCharacters(in: .whitespaces)
            }
        case .drawing:
            if top.destination != .drawing {
                var placeholder = RTFPlaceholder(kind: .drawing(drawingType))
                placeholder.width = drawingSize.w
                placeholder.height = drawingSize.h
                emitObject(.placeholder(placeholder), range: range, group: group)
            }
        case .panose:
            if top.destination != .panose { fontEntry?.panose = String(utf16CodeUnits: panose, count: panose.count) }
        default:
            break
        }
        if let kind = stories[group.story].headerKind, group.story != top.story {
            finishStory(group.story, end: range.location + range.length - 1, props: group.para)
            stories[group.story].range = range
            attachHeader(kind, story: group.story, range: range)
            lastHeaderEnd[stories[group.story].section] = NSMaxRange(range)
        }
        if group.nestProps, !top.nestProps, let saved = savedRows.popLast() {
            (row, cellInProgress, rowBorders) = saved
        }
        if group.listText, !top.listText, group.destination == .text, top.story == group.story {
            stories[group.story].current.listTextGroup = range
        }
        if let field = group.field, top.field != field, field < model.fields.count {
            model.fields[field].group = range
        }
    }

    // MARK: - Управляющие последовательности

    private func controlSequence() {
        let start = i
        guard i + 1 < count else { i += 1; return }
        let next = u[i + 1]
        if isLetter(next) {
            controlWord(start: start)
            return
        }
        i += 2
        let symbol = NSRange(location: start, length: 2)
        switch next {
        case 0x27:  // \'hh
            guard i + 1 < count, let high = hex(u[i]), let low = hex(u[i + 1]) else { return }
            i += 2
            let byte = Int(high * 16 + low)
            byteText(byte, range: NSRange(location: start, length: 4))
        case 0x2A:  // \*
            top.ignorable = true
            return
        case 0x5C, 0x7B, 0x7D:
            text(next, range: symbol)
        case 0x7E: text(0x00A0, range: symbol)       // \~
        case 0x5F: text(0x2011, range: symbol)       // \_
        case 0x2D: text(0x00AD, range: symbol)       // \- мягкий перенос
        case 0x0D, 0x0A:                               // \ + перевод строки = \par
            if next == 0x0D, i < count, u[i] == 0x0A { i += 1 }
            paragraphEnd(.paragraph, range: NSRange(location: start, length: i - start))
        default:
            break
        }
        top.fresh = false
    }

    private func controlWord(start: Int) {
        var end = i + 1
        var key = Key()
        while end < count, isLetter(u[end]) {
            key.append(u[end])
            end += 1
        }
        var number: Int?
        if end < count, u[end] == 0x2D || isDigit(u[end]) {
            let negative = u[end] == 0x2D
            var digits = negative ? end + 1 : end
            let first = digits
            var value = 0
            while digits < count, isDigit(u[digits]) {
                value = value &* 10 &+ Int(u[digits] - 0x30)
                digits += 1
            }
            if digits > first {
                number = negative ? -value : value
                end = digits
            }
        }
        if end < count, u[end] == 0x20 { end += 1 }
        i = end
        let range = NSRange(location: start, length: end - start)
        let word = RTFWord.byKey[key]
        if top.fresh {
            top.fresh = false
            if destination(word, key: key, range: range) { return }
            if top.ignorable {
                // `{\*\неизвестное…}` — назначение, которое можно не понимать.
                skipGroup()
                return
            }
        }
        guard let word else { return }
        handle(word, number, range: range)
    }

    /// Первое слово группы — назначение. `true` — разобрано (или группа пропущена).
    private func destination(_ word: RTFWord?, key: Key, range: NSRange) -> Bool {
        if key == Self.nestTablePropsKey {
            // Строка вложенной таблицы: её `\trowd … \cellx … \nestrow` — своё состояние строки, внешнее вернётся на `}`.
            top.nestProps = true
            savedRows.append((row, cellInProgress, rowBorders))
            return true
        }
        if key == Self.listTableKey || key == Self.listOverrideTableKey {
            let start = top.start
            skipGroup()
            let group = NSRange(location: start, length: i - start)
            if key == Self.listTableKey { listTable = group } else { listOverrideTable = group }
            return true
        }
        if RTFWord.skippedDestinations.contains(key) {
            skipGroup()
            return true
        }
        guard let word else { return false }
        switch top.destination {
        case .shape:
            switch word {
            case .shpinst: top.destination = .shapeInstruction
            default: skipGroup()
            }
            return true
        case .shapeInstruction:
            if word == .sp {
                top.destination = .shapeProperty
                shapePropName = []
                shapePropValue = []
                return true
            }
            if [.shpleft, .shpright, .shptop, .shpbottom].contains(word) { return false }
            skipGroup()
            return true
        case .shapeProperty:
            switch word {
            case .sn: top.destination = .shapeName
            case .sv: top.destination = .shapeValue
            default: skipGroup()
            }
            return true
        case .shapeName, .shapeValue:
            // Рисунок рамки (`{\sp{\sn pib}{\sv {\pict…}}}`) — его и показываем вместо заглушки.
            if top.destination == .shapeValue, word == .pict {
                top.destination = .picture
                resetPicture()
                return true
            }
            skipGroup()
            return true
        case .upr:
            if word == .ud { top.destination = .text } else { skipGroup() }
            return true
        case .fontTable, .fontEntry:
            if word == .panose {
                top.destination = .panose
                panose = []
                return true
            }
            if word == .falt {
                skipGroup()
                return true
            }
            if word == .f, top.destination == .fontTable {
                top.destination = .fontEntry
                return false
            }
            return false
        default:
            break
        }
        switch word {
        case .fonttbl:
            top.destination = .fontTable
        case .colortbl:
            top.destination = .colorTable
            model.colors = []
            colorParts = (nil, nil, nil)
        case .header, .headerl, .headerr, .headerf, .footer, .footerl, .footerr, .footerf:
            guard let kind = RTFHeaderKind(rawValue: word.rawValue) else { return false }
            var story = Story()
            story.headerKind = kind
            story.section = currentSection
            story.current.regionStart = range.location + range.length
            stories.append(story)
            top.story = stories.count - 1
            top.destination = .text
            top.field = nil
            top.fieldResult = false
            top.listText = false
        case .field:
            model.fields.append(RTFField(kind: .other(""), instruction: "", group: NSRange(location: top.start, length: 0)))
            top.field = model.fields.count - 1
            top.fieldResult = false
        case .fldinst:
            top.destination = .fieldInstruction
        case .fldrslt:
            top.fieldResult = true
            if let field = top.field, field < model.fields.count {
                let instruction = fieldInstructions[field].map { String(utf16CodeUnits: $0, count: $0.count) } ?? ""
                model.fields[field].instruction = instruction
                model.fields[field].kind = RTFFieldKind.parse(instruction)
            }
        case .pict:
            top.destination = .picture
            resetPicture()
        case .shppict:
            break
        case .shp:
            top.destination = .shape
            shapeType = nil
            shapeBox = (0, 0, 0, 0)
            shapePicture = nil
            shapeWrap = 0
            shapeFloat = RTFFloat()
            shapeProps = [:]
        case .object:
            let groupStart = top.start
            let group = top
            skipGroup()
            emitObject(.placeholder(RTFPlaceholder(kind: .object)), range: NSRange(location: groupStart, length: i - groupStart), group: group)
        case .do_:
            top.destination = .drawing
            drawingType = "Объект"
            drawingSize = (0, 0)
        case .pntext, .listtext:
            top.listText = true
        case .upr:
            top.destination = .upr
        case .shpinst, .shprslt, .sp, .sn, .sv, .ud, .panose, .falt:
            skipGroup()
        default:
            return false
        }
        return true
    }

    private static let listTableKey = Key("listtable"), listOverrideTableKey = Key("listoverridetable")
    private static let nestTablePropsKey = Key("nesttableprops")

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func handle(_ word: RTFWord, _ number: Int?, range: NSRange) {
        let destination = top.destination
        switch destination {
        case .fontTable, .fontEntry:
            fontWord(word, number)
            return
        case .colorTable:
            switch word {
            case .red: colorParts.red = number ?? 0
            case .green: colorParts.green = number ?? 0
            case .blue: colorParts.blue = number ?? 0
            default: break
            }
            return
        case .picture:
            pictureWord(word, number)
            return
        case .shapeInstruction:
            switch word {
            case .shpleft: shapeBox.left = number ?? 0
            case .shpright: shapeBox.right = number ?? 0
            case .shptop: shapeBox.top = number ?? 0
            case .shpbottom: shapeBox.bottom = number ?? 0
            case .shpwr: shapeWrap = number ?? 0
            case .shpfblwtxt: shapeFloat.behind = (number ?? 0) != 0
            case .shpbxpage: shapeFloat.horizontal = .page
            case .shpbxmargin: shapeFloat.horizontal = .margin
            case .shpbxcolumn: shapeFloat.horizontal = .column
            case .shpbypage: shapeFloat.vertical = .page
            case .shpbymargin: shapeFloat.vertical = .margin
            case .shpbypara: shapeFloat.vertical = .paragraph
            default: break
            }
            return
        case .drawing:
            switch word {
            case .dpline: drawingType = "Линия"
            case .dprect: drawingType = "Прямоугольник"
            case .dpellipse: drawingType = "Эллипс"
            case .dptxbx: drawingType = "Надпись"
            case .dppolyline, .dppolygon: drawingType = "Ломаная"
            case .dparc: drawingType = "Дуга"
            case .dpcallout: drawingType = "Выноска"
            case .dpgroup: drawingType = "Группа объектов"
            case .dpxsize: drawingSize.w = abs(number ?? 0)
            case .dpysize: drawingSize.h = abs(number ?? 0)
            default: break
            }
            return
        case .shape, .shapeProperty, .upr, .panose:
            return
        case .shapeName, .shapeValue, .fieldInstruction:
            if word == .u, let number { collect(UInt16(truncatingIfNeeded: number < 0 ? number + 65_536 : number)); skipReplacements() }
            return
        case .text:
            break
        }
        // Свойства документа и раздела — только в основном тексте: Word пишет `\sectd` и внутри колонтитулов,
        // и там он не должен сбрасывать `\titlepg` раздела.
        if top.story != 0, Self.sectionWords.contains(word) { return }

        switch word {
        // Документ.
        case .ansicpg:
            if let number, let encoding = TextEncoding(codePage: number), encoding.group != .unicode { model.codePage = encoding }
        case .deff: model.defaultFont = number ?? 0
        case .deftab: if let number, number > 0 { model.defaultTab = number }
        case .paperw: setPage(\.pageWidth, number)
        case .paperh: setPage(\.pageHeight, number)
        case .margl: setPage(\.marginLeft, number)
        case .margr: setPage(\.marginRight, number)
        case .margt: setPage(\.marginTop, number)
        case .margb: setPage(\.marginBottom, number)
        case .landscape:
            documentPage.landscape = true
            model.sections[currentSection].props.landscape = true
        case .facingp:
            model.facingPages = true
            model.facingPagesRange = range
        // Раздел.
        case .sectd:
            // `\sectd` — свойства раздела по умолчанию (страница документа, без особой первой страницы).
            model.sections[currentSection].props = documentPage
            model.sections[currentSection].props.titlePage = false
            model.sections[currentSection].sectd = range
            notePropsInsertion(range.location)
        case .sect:
            noteContent(range.location)
            paragraphEnd(.section, range: range)
            newSection()
        case .pgwsxn: model.sections[currentSection].props.pageWidth = number ?? 11906
        case .pghsxn: model.sections[currentSection].props.pageHeight = number ?? 16838
        case .marglsxn: model.sections[currentSection].props.marginLeft = number ?? 1134
        case .margrsxn: model.sections[currentSection].props.marginRight = number ?? 1134
        case .margtsxn: model.sections[currentSection].props.marginTop = number ?? 1134
        case .margbsxn: model.sections[currentSection].props.marginBottom = number ?? 1134
        case .lndscpsxn: model.sections[currentSection].props.landscape = true
        case .titlepg: model.sections[currentSection].props.titlePage = true
        case .headery: model.sections[currentSection].props.headerY = number ?? 720
        case .footery: model.sections[currentSection].props.footerY = number ?? 720
        case .sbknone: model.sections[currentSection].props.newPage = false
        case .sbkpage, .sbkodd, .sbkeven: model.sections[currentSection].props.newPage = true
        case .sbkcol: model.sections[currentSection].props.newPage = false
        // Абзац.
        case .pard:
            noteContent(range.location)
            top.para = RTFParaProps()
            top.tabKind = .left
            top.tabLeader = false
            stories[top.story].pard = (range, top.id)
            stories[top.story].tokens = [:]
        case .par:
            noteContent(range.location)
            paragraphEnd(.paragraph, range: range)
        case .ql, .qc, .qr, .qj, .qd:
            top.para.alignment = word == .qc ? .center : word == .qr ? .right : (word == .qj || word == .qd) ? .justify : .left
            token("align", range)
        case .li, .lin:
            top.para.left = number ?? 0
            token(word.rawValue, range)
        case .ri, .rin:
            top.para.right = number ?? 0
            token(word.rawValue, range)
        case .fi:
            top.para.firstLine = number ?? 0
            token("fi", range)
        case .sb:
            top.para.spaceBefore = number ?? 0
            token("sb", range)
        case .sa:
            top.para.spaceAfter = number ?? 0
            token("sa", range)
        case .sl:
            top.para.lineSpacing = number ?? 0
            token("sl", range)
        case .slmult:
            top.para.lineMultiple = (number ?? 1) != 0
            token("slmult", range)
        case .tqr: top.tabKind = .right
        case .tqc: top.tabKind = .center
        case .tqdec: top.tabKind = .decimal
        case .tldot, .tlhyph, .tlul, .tlth, .tleq, .tlmdot: top.tabLeader = true
        case .tx, .tb:
            top.para.tabs.append(RTFTabStop(position: number ?? 0, kind: word == .tb ? .bar : top.tabKind, leader: top.tabLeader))
            top.tabKind = .left
            top.tabLeader = false
        case .intbl:
            noteContent(range.location)
            top.para.inTable = true
        case .keepn:
            top.para.keepNext = (number ?? 1) != 0
            token("keepn", range)
        case .keep:
            top.para.keepTogether = (number ?? 1) != 0
            token("keep", range)
        case .widctlpar: top.para.widowControl = true
        case .nowidctlpar: top.para.widowControl = false
        case .posx, .posxl, .posxi: top.para.frame.isSet = true; top.para.frame.x = .left
        case .posxc: top.para.frame.isSet = true; top.para.frame.x = .center
        case .posxr, .posxo: top.para.frame.isSet = true; top.para.frame.x = .right
        case .posy: top.para.frame.isSet = true; top.para.frame.y = number ?? 0
        case .posyt, .posyc, .posyb, .posyil, .posyin, .posyout: top.para.frame.isSet = true; top.para.frame.y = 1
        case .pvpara: top.para.frame.isSet = true; top.para.frame.fromParagraph = true
        case .pvmrg, .pvpg: top.para.frame.isSet = true; top.para.frame.fromParagraph = false
        case .phmrg, .phpg, .phcol, .absw, .absh: top.para.frame.isSet = true
        case .pagebb:
            top.para.pageBreakBefore = (number ?? 1) != 0
            token("pagebb", range)
        case .s: top.para.style = number
        case .contextualspace: top.para.contextualSpace = (number ?? 1) != 0
        case .sbauto: top.para.spaceBeforeAuto = (number ?? 1) != 0
        case .saauto: top.para.spaceAfterAuto = (number ?? 1) != 0
        case .ls:
            top.para.list = number ?? 0
            token("ls", range)
        case .ilvl:
            top.para.listLevel = number ?? 0
            token("ilvl", range)
        case .cbpat: top.para.shading = number ?? 0
        case .brdrt: top.border = .paraTop; top.para.borderTop = RTFBorder()
        case .brdrb: top.border = .paraBottom; top.para.borderBottom = RTFBorder()
        case .brdrl: top.border = .paraLeft; top.para.borderLeft = RTFBorder()
        case .brdrr: top.border = .paraRight; top.para.borderRight = RTFBorder()
        case .box: top.border = .paraBox; setBox(RTFBorder())
        case .brdrw, .brdrcf, .brdrs, .brdrth, .brdrdb, .brdrdot, .brdrdash, .brdrnone, .brdrnil, .brdrsh:
            borderWord(word, number)
        // Символ.
        case .plain:
            var props = RTFCharProps()
            props.font = model.defaultFont
            setChar(props)
        case .f: updateChar { $0.font = number ?? 0 }
        case .fs: updateChar { $0.halfPoints = max(1, number ?? 24) }
        case .b: updateChar { $0.bold = (number ?? 1) != 0 }
        case .i: updateChar { $0.italic = (number ?? 1) != 0 }
        case .ul, .ulw: updateChar { $0.underline = (number ?? 1) != 0 ? (word == .ulw ? .words : .single) : .none }
        case .uldb: updateChar { $0.underline = (number ?? 1) != 0 ? .double : .none }
        case .uld: updateChar { $0.underline = (number ?? 1) != 0 ? .dotted : .none }
        case .uldash, .uldashd, .uldashdd, .ulthdash: updateChar { $0.underline = (number ?? 1) != 0 ? .dashed : .none }
        case .ulth, .ulthd: updateChar { $0.underline = (number ?? 1) != 0 ? .thick : .none }
        case .ulwave, .ulhwave, .ululdbwave: updateChar { $0.underline = (number ?? 1) != 0 ? .wave : .none }
        case .ulnone: updateChar { $0.underline = .none }
        case .strike, .striked: updateChar { $0.strike = (number ?? 1) != 0 }
        case .cf: updateChar { $0.color = max(0, number ?? 0) }
        case .cb, .chcbpat: updateChar { $0.background = max(0, number ?? 0) }
        case .chshdng: updateChar { $0.backgroundPercent = min(10_000, max(0, number ?? 0)) }
        case .chcfpat: updateChar { $0.backgroundPattern = max(0, number ?? 0) }
        case .highlight: updateChar { $0.highlight = max(0, number ?? 0) }
        case .v: updateChar { $0.hidden = (number ?? 1) != 0 }
        case .super_: updateChar { $0.vertical = .superscript }
        case .sub: updateChar { $0.vertical = .subscript }
        case .nosupersub: updateChar { $0.vertical = .normal }
        case .up: updateChar { $0.vertical = (number ?? 6) != 0 ? .superscript : .normal }
        case .dn: updateChar { $0.vertical = (number ?? 6) != 0 ? .subscript : .normal }
        case .caps: updateChar { $0.caps = (number ?? 1) != 0 }
        case .scaps: updateChar { $0.smallCaps = (number ?? 1) != 0 }
        case .kerning: updateChar { $0.kerning = max(0, number ?? 0) }
        case .expnd: updateChar { $0.expand = (number ?? 0) * 5 }
        case .expndtw: updateChar { $0.expand = number ?? 0 }
        // Особые символы.
        case .uc: top.uc = max(0, number ?? 1)
        case .u:
            guard let number else { return }
            let unit = UInt16(truncatingIfNeeded: number < 0 ? number + 65_536 : number)
            let end = replacementsEnd(from: i, count: top.uc)
            i = end
            text(unit, range: NSRange(location: range.location, length: end - range.location))
        case .bin:
            if let number, number > 0 { i = min(count, i + number) }
        case .tab: special(.tab, unit: 0x09, range: range)
        case .line: special(.lineBreak, unit: 0x2028, range: range)
        case .page: special(.pageBreak, unit: 0x0C, range: range)
        case .cell, .nestcell:
            noteContent(range.location)
            paragraphEnd(word == .cell ? .cell : .nestedCell, range: range)
        case .row:
            noteContent(range.location)
            finishRow(range)
        case .nestrow:
            finishNestedRow(range)
        case .itap:
            top.para.nesting = number ?? 1
        case .emdash: text(0x2014, range: range)
        case .endash: text(0x2013, range: range)
        case .lquote: text(0x2018, range: range)
        case .rquote: text(0x2019, range: range)
        case .ldblquote: text(0x201C, range: range)
        case .rdblquote: text(0x201D, range: range)
        case .bullet: text(0x2022, range: range)
        case .emspace: text(0x2003, range: range)
        case .enspace: text(0x2002, range: range)
        case .qmspace: text(0x2005, range: range)
        case .zwj: text(0x200D, range: range)
        case .zwnj: text(0x200C, range: range)
        case .chpgn:
            emit(0x23, nil, range: range, kind: .field(.page), field: nil)
        // Таблица.
        case .trowd:
            noteContent(range.location)
            row = RTFRow()
            cellInProgress = RTFCellDef()
            rowBorders = (nil, nil, nil, nil, nil, nil)
        case .cellx:
            cellInProgress.right = number ?? 0
            row.cells.append(cellInProgress)
            cellInProgress = RTFCellDef()
        case .clvmgf: cellInProgress.verticalMergeFirst = true
        case .clvmrg: cellInProgress.verticalMerged = true
        case .clmgf: cellInProgress.horizontalMergeFirst = true
        case .clmrg: cellInProgress.horizontalMerged = true
        case .clcbpat: cellInProgress.shading = number ?? 0
        case .clshdng: cellInProgress.shadingPercent = min(10_000, max(0, number ?? 0))
        case .clcfpat: cellInProgress.shadingPattern = number ?? 0
        case .clvertalt: cellInProgress.verticalAlign = .top
        case .clvertalc: cellInProgress.verticalAlign = .center
        case .clvertalb: cellInProgress.verticalAlign = .bottom
        case .clbrdrt: top.border = .cellTop; cellInProgress.borderTop = RTFBorder()
        case .clbrdrb: top.border = .cellBottom; cellInProgress.borderBottom = RTFBorder()
        case .clbrdrl: top.border = .cellLeft; cellInProgress.borderLeft = RTFBorder()
        case .clbrdrr: top.border = .cellRight; cellInProgress.borderRight = RTFBorder()
        case .trbrdrt: top.border = .rowTop; rowBorders.top = RTFBorder()
        case .trbrdrb: top.border = .rowBottom; rowBorders.bottom = RTFBorder()
        case .trbrdrl: top.border = .rowLeft; rowBorders.left = RTFBorder()
        case .trbrdrr: top.border = .rowRight; rowBorders.right = RTFBorder()
        case .trbrdrh: top.border = .rowInsideH; rowBorders.insideH = RTFBorder()
        case .trbrdrv: top.border = .rowInsideV; rowBorders.insideV = RTFBorder()
        case .trgaph: row.gap = number ?? 108
        case .trleft: row.left = number ?? 0
        case .trql: row.alignment = .left
        case .trqc: row.alignment = .center
        case .trqr: row.alignment = .right
        case .trpaddl: row.padLeft = number ?? 0
        case .trpaddr: row.padRight = number ?? 0
        case .trpaddfl: row.padLeftUnit = number ?? 0
        case .trpaddfr: row.padRightUnit = number ?? 0
        case .clpadt: cellInProgress.padLeft = number ?? 0
        case .clpadr: cellInProgress.padRight = number ?? 0
        case .clpadft: cellInProgress.padLeftUnit = number ?? 0
        case .clpadfr: cellInProgress.padRightUnit = number ?? 0
        case .trrh: row.height = number ?? 0
        case .trpaddt: row.padTop = max(0, number ?? 0)
        case .trpaddb: row.padBottom = max(0, number ?? 0)
        case .trhdr: row.header = true
        default:
            break
        }
    }

    private static let sectionWords: Set<RTFWord> = [
        .ansicpg, .deff, .deftab, .paperw, .paperh, .margl, .margr, .margt, .margb, .landscape, .facingp, .sectd, .sect,
        .pgwsxn, .pghsxn, .marglsxn, .margrsxn, .margtsxn, .margbsxn, .lndscpsxn, .titlepg, .headery, .footery,
        .sbknone, .sbkpage, .sbkodd, .sbkeven, .sbkcol,
    ]

    // MARK: - Текст

    private func plainText() {
        let start = i
        let unit = u[i]
        i += 1
        switch top.destination {
        case .fontTable, .fontEntry:
            if unit == 0x3B { finishFont() } else { fontName.append(unit) }
            return
        case .colorTable:
            if unit == 0x3B {
                if let red = colorParts.red, let green = colorParts.green, let blue = colorParts.blue {
                    model.colors.append(RTFColor(red: red, green: green, blue: blue))
                } else {
                    model.colors.append(nil)
                }
                colorParts = (nil, nil, nil)
            }
            return
        case .picture:
            pictureByte(unit)
            return
        case .panose:
            panose.append(unit)
            return
        case .shapeName, .shapeValue, .fieldInstruction:
            collect(unit)
            return
        case .shape, .shapeInstruction, .shapeProperty, .drawing, .upr:
            return
        case .text:
            break
        }
        if unit == 0x09 {
            special(.tab, unit: 0x09, range: NSRange(location: start, length: 1))
            return
        }
        guard unit >= 0x20 else { return }
        // Суррогатная пара — один символ из двух единиц.
        if (0xD800...0xDBFF).contains(unit), i < count, (0xDC00...0xDFFF).contains(u[i]) {
            let low = u[i]
            i += 1
            text(unit, low, range: NSRange(location: start, length: 2))
            return
        }
        text(unit, range: NSRange(location: start, length: 1))
    }

    /// `\'hh`: байт в кодировке шрифта или документа.
    private func byteText(_ byte: Int, range: NSRange) {
        switch top.destination {
        case .fontTable, .fontEntry: fontName.append(decode(byte))
        case .shapeName, .shapeValue, .fieldInstruction: collect(decode(byte))
        case .text: text(decode(byte), range: range)
        default: break
        }
    }

    private func decode(_ byte: Int) -> UInt16 {
        let encoding = currentEncoding()
        if byteTables[encoding] == nil { byteTables[encoding] = SingleByteTable.table(for: encoding)?.decodeTable ?? [] }
        let table = byteTables[encoding]!
        return byte < table.count ? table[byte] : UInt16(byte)
    }

    private func currentEncoding() -> TextEncoding {
        guard let number = top.char.font ?? model.defaultFont, let font = model.fonts[number] else { return model.codePage }
        return RTFReader.encoding(charset: font.charset, codePage: font.codePage, document: model.codePage)
    }

    private func collect(_ unit: UInt16) {
        switch top.destination {
        case .shapeName: shapePropName.append(unit)
        case .shapeValue: shapePropValue.append(unit)
        case .fieldInstruction:
            if let field = top.field { fieldInstructions[field, default: []].append(unit) }
        default: break
        }
    }

    /// Видимый символ (одна единица UTF-16 или пара суррогатов) в текущей истории. Без массивов — это на каждый символ.
    private func text(_ unit: UInt16, _ low: UInt16? = nil, range: NSRange) {
        switch top.destination {
        case .text: break
        case .fontTable, .fontEntry:
            fontName.append(unit)
            if let low { fontName.append(low) }
            return
        case .shapeName, .shapeValue, .fieldInstruction:
            collect(unit)
            if let low { collect(low) }
            return
        default: return
        }
        var kind = RTFRun.Kind.text
        if top.listText { kind = .listText }
        if top.fieldResult, let field = top.field, field < model.fields.count, model.fields[field].kind.isComputed {
            kind = .field(model.fields[field].kind)
        }
        emit(unit, low, range: range, kind: kind, field: top.fieldResult ? top.field : nil)
    }

    private func special(_ kind: RTFRun.Kind, unit: UInt16, range: NSRange) {
        guard top.destination == .text else { return }
        // Табуляция в номере списка (`{\listtext ·\tab}`) — часть номера, а не текста абзаца.
        emit(unit, nil, range: range, kind: top.listText ? .listText : kind, field: top.fieldResult ? top.field : nil)
    }

    private func emit(_ unit: UInt16, _ low: UInt16?, range: NSRange, kind: RTFRun.Kind, field: Int?) {
        noteContent(range.location)
        let story = top.story
        let key = RunKey(version: top.charVersion, group: top.id, kind: Self.kindTag(kind), uc: top.uc, field: field)
        if stories[story].lastKey == key, !stories[story].current.runs.isEmpty {
            let last = stories[story].current.runs.count - 1
            stories[story].units[last].append(unit)
            stories[story].current.runs[last].map.append(range)
            if let low {
                // Пара суррогатов — обе единицы с одним диапазоном.
                stories[story].units[last].append(low)
                stories[story].current.runs[last].map.append(range)
            }
            return
        }
        var run = RTFRun(kind: kind, text: "", props: top.char, map: low == nil ? [range] : [range, range], group: top.id, uc: top.uc)
        run.field = field
        stories[story].current.runs.append(run)
        stories[story].units.append(low.map { [unit, $0] } ?? [unit])
        stories[story].lastKey = key
    }

    /// Фигура без обтекания (`\shpwr3`), которую рисуем сами: рамка, опора и вид из свойств; иначе `nil` (заглушка в тексте).
    private func floatingShape(width: Int, height: Int) -> RTFFloat? {
        guard shapeWrap == 3 else { return nil }
        var shape = shapeFloat
        let type = shapePicture != nil ? 75 : (shapeType ?? 1)
        guard RTFFloat.drawnTypes.contains(type), type != 75 || shapePicture != nil else { return nil }
        func number(_ key: String) -> Int? { shapeProps[key].flatMap { Int($0) } }
        func flag(_ key: String, _ value: Bool) -> Bool { number(key).map { $0 != 0 } ?? value }
        shape.shapeType = type
        (shape.left, shape.top, shape.width, shape.height) = (shapeBox.left, shapeBox.top, width, height)
        // Новые свойства опоры (`posrelh`, `posrelv`) главнее старых `\shpbx*`/`\shpby*` (их Word пишет с `…ignore`).
        switch number("posrelh") {
        case 0: shape.horizontal = .margin
        case 1: shape.horizontal = .page
        case 2, 3: shape.horizontal = .column
        default: break
        }
        switch number("posrelv") {
        case 0: shape.vertical = .margin
        case 1: shape.vertical = .page
        case 2, 3: shape.vertical = .paragraph
        default: break
        }
        shape.layoutInCell = flag("fLayoutInCell", true)
        shape.behind = flag("fBehindDocument", shape.behind)
        shape.filled = flag("fFilled", type != 75 && type != 20 && type != 32)
        shape.fillColor = number("fillColor") ?? 0xFFFFFF
        shape.line = flag("fLine", type != 75)
        shape.lineColor = number("lineColor") ?? 0
        shape.lineWidth = number("lineWidth") ?? 9_525
        shape.flipH = flag("fFlipH", false)
        shape.flipV = flag("fFlipV", false)
        return shape
    }

    /// Рисунок или заглушка — отдельный прогон из одного символа U+FFFC на всю группу.
    private func emitObject(_ kind: RTFRun.Kind, range: NSRange, group: Group, picture: RTFPicture? = nil, floating: RTFFloat? = nil) {
        // Группа уже снята со стека: показываем, только если вокруг — текст (а не, например, значение свойства фигуры).
        guard top.destination == .text else { return }
        let story = top.story
        noteContent(range.location)
        var run = RTFRun(kind: kind, text: "", props: group.char, map: [range], group: group.id, uc: group.uc)
        run.picture = picture
        run.objectGroup = range
        run.floating = floating
        stories[story].current.runs.append(run)
        stories[story].units.append([0xFFFC])
        stories[story].lastKey = nil
    }

    private static func kindTag(_ kind: RTFRun.Kind) -> Int {
        switch kind {
        case .text: return 0
        case .tab: return 1
        case .lineBreak: return 2
        case .pageBreak: return 3
        case .field: return 4
        case .listText: return 5
        case .picture: return 6
        case .placeholder: return 7
        }
    }

    // MARK: - Абзацы

    private func token(_ name: String, _ range: NSRange) {
        guard top.destination == .text else { return }
        stories[top.story].tokens[name] = (range, top.id)
        noteContent(range.location)
    }

    private func paragraphEnd(_ end: RTFParagraphEnd, range: NSRange) {
        guard top.destination == .text else { return }
        let story = top.story
        closeParagraph(story, end: end, range: range, props: top.para)
    }

    private func closeParagraph(_ index: Int, end: RTFParagraphEnd, range: NSRange, props: RTFParaProps) {
        // История вынимается из массива, чтобы её массивы не копировались при дописывании (иначе — квадрат по абзацам).
        var story = stories[index]
        stories[index] = Story()
        var paragraph = story.current
        for run in paragraph.runs.indices {
            let units = story.units[run]
            paragraph.runs[run].text = String(utf16CodeUnits: units, count: units.count)
        }
        paragraph.props = props
        paragraph.endProps = top.char
        paragraph.endUC = top.uc
        paragraph.end = end
        paragraph.endRange = range
        let open = Set(stack.map(\.id))
        if let pard = story.pard, open.contains(pard.group) { paragraph.pard = pard.range }
        for (name, entry) in story.tokens where open.contains(entry.group) { paragraph.propTokens[name] = entry.range }
        paragraph.section = index == 0 ? currentSection : story.section
        let number = story.paragraphs.count
        story.paragraphs.append(paragraph)
        if props.inTable {
            story.cellParagraphs.append(number)
            if end == .cell {
                story.rowCells.append(story.cellParagraphs)
                story.cellParagraphs = []
            }
            if props.nesting >= 2 || end == .nestedCell {
                story.nestedCellParagraphs.append(number)
                if end == .nestedCell {
                    story.nestedRowCells.append(story.nestedCellParagraphs)
                    story.nestedCellParagraphs = []
                }
            }
        }
        story.current = RTFParagraph()
        story.current.regionStart = range.location + range.length
        story.units = []
        story.lastKey = nil
        story.pard = nil
        story.tokens = [:]
        stories[index] = story
    }

    /// Конец истории: незакрытый абзац с текстом (или вовсе без абзацев) закрывается без кода конца.
    private func finishStory(_ index: Int, end: Int, props: RTFParaProps) {
        let story = stories[index]
        guard !story.current.runs.isEmpty || story.paragraphs.isEmpty else { return }
        closeParagraph(index, end: .storyEnd, range: NSRange(location: end, length: 0), props: props)
    }

    // MARK: - Таблицы

    private func finishRow(_ range: NSRange) { finishRow(range, nested: false) }

    /// Конец строки вложенной таблицы (`\nestrow` в `{\*\nesttableprops}`).
    private func finishNestedRow(_ range: NSRange) { finishRow(range, nested: true) }

    /// Строка таблицы. Вложенная таблица — своя запись в `tables` (`nested`); её абзацы на конце внешней строки получают
    /// `outerCell`, а сама таблица — `parent`.
    private func finishRow(_ range: NSRange, nested: Bool) {
        let story = top.story
        guard top.destination == .text else { return }
        var cells = nested ? stories[story].nestedRowCells : stories[story].rowCells
        let pending = nested ? stories[story].nestedCellParagraphs : stories[story].cellParagraphs
        if !pending.isEmpty { cells.append(pending) }
        if nested {
            stories[story].nestedRowCells = []
            stories[story].nestedCellParagraphs = []
        } else {
            stories[story].rowCells = []
            stories[story].cellParagraphs = []
            stories[story].nestedRowCells = []
            stories[story].nestedCellParagraphs = []
        }
        guard !cells.isEmpty else { return }
        var finished = row
        finished.endRange = range
        finished.paragraphs = cells
        // Границы строки — запасные для краёв ячеек, у которых своих нет.
        for (index, _) in finished.cells.enumerated() {
            var cell = finished.cells[index]
            if cell.borderTop == RTFBorder(), let border = rowBorders.top ?? rowBorders.insideH { cell.borderTop = border }
            if cell.borderBottom == RTFBorder(), let border = rowBorders.bottom ?? rowBorders.insideH { cell.borderBottom = border }
            let first = index == 0, last = index == finished.cells.count - 1
            if cell.borderLeft == RTFBorder(), let border = first ? rowBorders.left : (rowBorders.insideV ?? rowBorders.left) { cell.borderLeft = border }
            if cell.borderRight == RTFBorder(), let border = last ? rowBorders.right : (rowBorders.insideV ?? rowBorders.right) {
                cell.borderRight = border
            }
            finished.cells[index] = cell
        }
        let firstParagraph = cells.first?.first ?? 0
        let tableIndex: Int
        if let last = stories[story].tables.lastIndex(where: { $0.nested == nested }),
           let lastParagraph = stories[story].tables[last].rows.last?.paragraphs.last?.last, lastParagraph + 1 == firstParagraph {
            stories[story].tables[last].rows.append(finished)
            tableIndex = last
        } else {
            stories[story].tables.append(RTFTable(rows: [finished], nested: nested))
            tableIndex = stories[story].tables.count - 1
        }
        let rowIndex = stories[story].tables[tableIndex].rows.count - 1
        for (cellIndex, paragraphs) in cells.enumerated() {
            let ref = RTFCellRef(table: tableIndex, row: rowIndex, cell: cellIndex)
            for paragraph in paragraphs where paragraph < stories[story].paragraphs.count {
                if !nested, let inner = stories[story].paragraphs[paragraph].cell, stories[story].tables[safe: inner.table]?.nested == true {
                    stories[story].paragraphs[paragraph].outerCell = ref
                    stories[story].tables[inner.table].parent = ref
                } else {
                    stories[story].paragraphs[paragraph].cell = ref
                }
            }
        }
    }

    // MARK: - Разделы и колонтитулы

    private func setPage(_ path: WritableKeyPath<RTFSectionProps, Int>, _ number: Int?) {
        guard let number else { return }
        documentPage[keyPath: path] = number
        model.sections[currentSection][keyPath: (\RTFSection.props).appending(path: path)] = number
    }

    private func newSection() {
        var section = RTFSection()
        section.props = model.sections[currentSection].props
        section.props.titlePage = false
        section.firstParagraph = stories[0].paragraphs.count
        model.sections.append(section)
        currentSection += 1
        contentNoted = false
    }

    /// Первый код основного текста раздела — новые колонтитулы встают перед ним.
    private func noteContent(_ location: Int) {
        guard !contentNoted, top.story == 0, top.destination == .text else { return }
        contentNoted = true
        sectionContentStart[currentSection] = location
        if currentSection == 0, model.documentPropsInsertion == 0 { model.documentPropsInsertion = location }
    }

    private func notePropsInsertion(_ location: Int) {
        if currentSection == 0, model.documentPropsInsertion == 0 { model.documentPropsInsertion = location }
    }

    private func attachHeader(_ kind: RTFHeaderKind, story index: Int, range: NSRange) {
        let section = stories[index].section
        guard section < model.sections.count else { return }
        model.sections[section].headers[kind] = RTFHeader(kind: kind, story: buildStory(stories[index]), group: range)
    }

    /// Новый колонтитул раздела встаёт после последнего существующего, а без них — перед первым кодом текста раздела.
    private func finishSections() {
        for index in model.sections.indices {
            model.sections[index].headerInsertion = lastHeaderEnd[index] ?? sectionContentStart[index] ?? count
        }
        if model.documentPropsInsertion == 0 { model.documentPropsInsertion = sectionContentStart[0] ?? count }
    }

    private func buildStory(_ story: Story) -> RTFStory {
        RTFStory(paragraphs: story.paragraphs, tables: story.tables, range: story.range)
    }

    // MARK: - Шрифты, цвета, рисунки

    private func fontWord(_ word: RTFWord, _ number: Int?) {
        switch word {
        case .f:
            finishFont()
            fontEntry = RTFFont(number: number ?? 0, name: "")
        case .fnil, .froman, .fswiss, .fmodern, .fscript, .fdecor, .ftech, .fbidi:
            if word != .fbidi { fontEntry?.family = RTFFont.Family(rawValue: word.rawValue) ?? .nil_ }
        case .fcharset: fontEntry?.charset = number ?? 0
        case .cpg: fontEntry?.codePage = number
        case .u:
            if let number { fontName.append(UInt16(truncatingIfNeeded: number < 0 ? number + 65_536 : number)) }
            skipReplacements()
        default: break
        }
    }

    private func finishFont() {
        guard var font = fontEntry else { fontName = []; return }
        let name = String(utf16CodeUnits: fontName, count: fontName.count).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty || font.name.isEmpty { font.name = name }
        if model.fonts[font.number] == nil || !name.isEmpty { model.fonts[font.number] = font }
        fontEntry = nil
        fontName = []
    }

    private func pictureWord(_ word: RTFWord, _ number: Int?) {
        switch word {
        case .pngblip: pictureFormat = "PNG"
        case .jpegblip: pictureFormat = "JPEG"
        case .wmetafile: pictureFormat = "WMF"
        case .emfblip: pictureFormat = "EMF"
        case .macpict: pictureFormat = "PICT"
        case .dibitmap, .wbitmap: pictureFormat = "BMP"
        case .pmmetafile: pictureFormat = "OS/2"
        case .picw: pictureSize.w = number ?? 0
        case .pich: pictureSize.h = number ?? 0
        case .picwgoal: pictureSize.goalW = number ?? 0
        case .pichgoal: pictureSize.goalH = number ?? 0
        case .picscalex: pictureSize.scaleX = number ?? 100
        case .picscaley: pictureSize.scaleY = number ?? 100
        case .bin:
            if let number, number > 0 { i = min(count, i + number) }
        default: break
        }
    }

    private func pictureByte(_ unit: UInt16) {
        guard pictureFormat == "PNG" || pictureFormat == "JPEG", let value = hex(unit) else { return }
        if let high = pictureNibble {
            pictureHex.append(high << 4 | UInt8(value))
            pictureNibble = nil
        } else {
            pictureNibble = UInt8(value)
        }
    }

    private func resetPicture() {
        pictureFormat = nil
        pictureHex = []
        pictureNibble = nil
        pictureSize = (0, 0, 0, 0, 100, 100)
    }

    private func finishPicture(_ range: NSRange, group: Group) {
        let format = pictureFormat ?? "без формата"
        var width = pictureSize.goalW > 0 ? pictureSize.goalW : pictureSize.w * 15
        var height = pictureSize.goalH > 0 ? pictureSize.goalH : pictureSize.h * 15
        width = width * max(1, pictureSize.scaleX) / 100
        height = height * max(1, pictureSize.scaleY) / 100
        if (format == "PNG" || format == "JPEG"), !pictureHex.isEmpty {
            let picture = RTFPicture(format: format == "PNG" ? .png : .jpeg, data: Data(pictureHex), width: width, height: height)
            // Рисунок фигуры — показывается на месте фигуры, когда она закроется.
            if top.destination == .shapeValue {
                shapePicture = picture
                pictureHex = []
                return
            }
            emitObject(.picture, range: range, group: group, picture: picture)
        } else {
            var placeholder = RTFPlaceholder(kind: .picture(format))
            placeholder.width = width
            placeholder.height = height
            emitObject(.placeholder(placeholder), range: range, group: group)
        }
        pictureHex = []
    }

    // MARK: - Границы

    private func borderWord(_ word: RTFWord, _ number: Int?) {
        func apply(_ change: (inout RTFBorder) -> Void) {
            switch top.border {
            case .none: return
            case .paraTop: change(&top.para.borderTop)
            case .paraBottom: change(&top.para.borderBottom)
            case .paraLeft: change(&top.para.borderLeft)
            case .paraRight: change(&top.para.borderRight)
            case .paraBox:
                change(&top.para.borderTop)
                change(&top.para.borderBottom)
                change(&top.para.borderLeft)
                change(&top.para.borderRight)
            case .cellTop: change(&cellInProgress.borderTop)
            case .cellBottom: change(&cellInProgress.borderBottom)
            case .cellLeft: change(&cellInProgress.borderLeft)
            case .cellRight: change(&cellInProgress.borderRight)
            case .rowTop: update(&rowBorders.top, change)
            case .rowBottom: update(&rowBorders.bottom, change)
            case .rowLeft: update(&rowBorders.left, change)
            case .rowRight: update(&rowBorders.right, change)
            case .rowInsideH: update(&rowBorders.insideH, change)
            case .rowInsideV: update(&rowBorders.insideV, change)
            }
        }
        func update(_ border: inout RTFBorder?, _ body: (inout RTFBorder) -> Void) {
            var value = border ?? RTFBorder()
            body(&value)
            border = value
        }
        apply { border in
            switch word {
            case .brdrw: border.width = max(0, number ?? 0)
            case .brdrcf: border.color = max(0, number ?? 0)
            case .brdrs, .brdrsh:
                border.style = .single
                if border.width == 0 { border.width = 10 }
            case .brdrth:
                border.style = .single
                border.width = max(border.width, 20)
            case .brdrdb:
                border.style = .double
                if border.width == 0 { border.width = 10 }
            case .brdrdot:
                border.style = .dotted
                if border.width == 0 { border.width = 10 }
            case .brdrdash:
                border.style = .dashed
                if border.width == 0 { border.width = 10 }
            case .brdrnone, .brdrnil: border.none = true
            default: break
            }
        }
    }

    private func setBox(_ border: RTFBorder) {
        top.para.borderTop = border
        top.para.borderBottom = border
        top.para.borderLeft = border
        top.para.borderRight = border
    }

    // MARK: - Свойства символа

    private func updateChar(_ change: (inout RTFCharProps) -> Void) {
        var props = top.char
        change(&props)
        setChar(props)
    }

    private func setChar(_ props: RTFCharProps) {
        guard props != top.char else { return }
        top.char = props
        top.charVersion = nextCharVersion
        nextCharVersion += 1
    }

    // MARK: - Пропуск

    /// Пропустить остаток текущей группы до её `}` (и снять её со стека).
    private func skipGroup() {
        var depth = 1
        while i < count {
            let unit = u[i]
            if unit == 0x5C {
                // `\bin N` — N байтов как есть, внутри могут быть скобки.
                if i + 3 < count, u[i + 1] == 0x62, u[i + 2] == 0x69, u[i + 3] == 0x6E {
                    var k = i + 4
                    var value = 0
                    var digits = false
                    while k < count, isDigit(u[k]) {
                        value = value &* 10 &+ Int(u[k] - 0x30)
                        k += 1
                        digits = true
                    }
                    if digits {
                        if k < count, u[k] == 0x20 { k += 1 }
                        i = min(count, k + value)
                        continue
                    }
                }
                i += 2
                continue
            }
            if unit == 0x7B {
                depth += 1
            } else if unit == 0x7D {
                depth -= 1
                if depth == 0 {
                    i += 1
                    finishGroup(end: i)
                    return
                }
            }
            i += 1
        }
    }

    /// После `\uN`: пропустить `uc` заменителей (символ, `\'hh` или управляющее слово — каждый за один).
    private func replacementsEnd(from position: Int, count replacements: Int) -> Int {
        var end = position
        var left = replacements
        while left > 0, end < count {
            let unit = u[end]
            if unit == 0x7B || unit == 0x7D { break }
            if unit == 0x5C {
                guard end + 1 < count else { break }
                if u[end + 1] == 0x27, end + 3 < count, hex(u[end + 2]) != nil, hex(u[end + 3]) != nil {
                    end += 4
                } else {
                    break
                }
            } else if unit == 0x0D || unit == 0x0A {
                end += 1
                continue
            } else {
                end += 1
            }
            left -= 1
        }
        return end
    }

    private func skipReplacements() {
        i = replacementsEnd(from: i, count: top.uc)
    }

    // MARK: - Символы

    private func isLetter(_ unit: UInt16) -> Bool { (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit) }
    private func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }
    private func hex(_ unit: UInt16) -> Int? {
        switch unit {
        case 0x30...0x39: return Int(unit - 0x30)
        case 0x61...0x66: return Int(unit - 0x61 + 10)
        case 0x41...0x46: return Int(unit - 0x41 + 10)
        default: return nil
        }
    }
}

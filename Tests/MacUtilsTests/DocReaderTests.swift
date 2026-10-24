import AppKit
import XCTest
@testable import MacUtils
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot

/// `RTFReader`: видимый текст, карта «символ ↔ исходник», свойства, структура (таблицы, разделы, колонтитулы, поля,
/// рисунки). Документы — выдуманные, в стиле Word.
final class DocReaderTests: XCTestCase {
    /// Видимый текст истории как у эталонного читателя тестировщика: `\par` — «\n», `\cell` — «\u{7}», без `\v`,
    /// номеров списков, рисунков и разрывов.
    static func visibleText(_ story: RTFStory) -> String {
        var out = ""
        for paragraph in story.paragraphs {
            for run in paragraph.runs where !run.props.hidden {
                switch run.kind {
                case .text, .tab, .lineBreak, .field: out += run.text
                default: break
                }
            }
            switch paragraph.end {
            case .paragraph: out += "\n"
            case .cell: out += "\u{7}"
            case .section, .storyEnd: break
            }
        }
        return out
    }

    // MARK: - Свои документы

    /// Обратный путь: место исходника → видимый символ; кусок исходника → показанные символы внутри него.
    func testSourceMapBothWays() throws {
        let source = Self.letter as NSString
        let model = RTFReader.read(source)
        var map = DocSourceMap()
        var text = ""
        for paragraph in model.body.paragraphs {
            for run in paragraph.runs {
                for range in run.map { map.append(range, kind: .text) }
                text += run.text
            }
            map.append(paragraph.endRange, kind: .paragraphEnd)
            text += "\n"
        }
        XCTAssertEqual(map.count, (text as NSString).length)
        for unit in 0..<map.count {
            let range = map.range(at: unit)
            XCTAssertEqual(map.unit(forSource: range.location), unit, "начало куска → сам символ")
            if range.length > 1 { XCTAssertEqual(map.unit(forSource: range.location + range.length - 1), unit, "середина `\\'hh` → тот же символ") }
        }
        // Место между кодами — ближайший следующий символ.
        let codes = source.range(of: "{\\rtlch\\insrsid99 an }")
        let a = map.unit(forSource: codes.location)
        XCTAssertEqual((text as NSString).substring(with: NSRange(location: a, length: 2)), "an")
        // Видимые символы внутри куска исходника «Iv}{\rtlch\insrsid99 an» — четыре буквы одним отрезком.
        let piece = NSRange(location: source.range(of: "Iv}").location, length: NSMaxRange(source.range(of: " an }")) - 2 - source.range(of: "Iv}").location)
        XCTAssertEqual(map.units(inside: piece).map { (text as NSString).substring(with: $0) }, ["Ivan"])
        XCTAssertEqual(map.sourceRange(ofUnits: NSRange(location: a, length: 2)), NSRange(location: source.range(of: "an }").location, length: 2))
        XCTAssertEqual(map.sourceLocation(beforeUnit: map.count), NSMaxRange(map.range(at: map.count - 1)))
    }

    /// Word-подобный документ в cp1251: `\'hh`, `\uN` с `\uc1` и `\uc2`, `\~`, `\emdash`, слово, разорванное группами.
    static let letter = #"""
    {\rtf1\ansi\ansicpg1251\uc1\deff0\deftab708{\fonttbl{\f0\froman\fcharset204\fprq2 Times New Roman;}{\f1\fswiss\fcharset204\fprq2{\*\panose 020b0604020202020204}Arial;}{\f2\fswiss\fcharset0 Calibri;}}
    {\colortbl;\red0\green0\blue0;\red192\green0\blue0;\red255\green255\blue0;}
    {\stylesheet{\ql \li0\ri0\widctlpar Normal;}}{\info{\title $SECRET}}
    \paperw11906\paperh16838\margl1701\margr850\margt1134\margb1134
    \pard\plain \ltrpar\qc \li0\ri0\sb120\sa240\sl276\slmult1 {\b\fs32 \'c7\'e0\'ea\'eb\'fe\'f7\'e5\'ed\'e8\'e5}\par
    \pard\plain \ltrpar\ql \li567\ri0\fi-284 {\f1\fs20 Iv}{\rtlch\insrsid99 an }{\i Pe}{\ul trov}\~\emdash\~{\strike x}{\cf2 red}{\highlight3 mark}\par
    \pard\plain \qr {\u1071\'3f\uc2\u1103\'3f\'3f end}\par
    }
    """#

    func testTextMapAndCodePages() throws {
        let source = Self.letter as NSString
        let model = RTFReader.read(source)
        XCTAssertTrue(model.isRTF)
        XCTAssertEqual(model.codePage, .windows1251)
        XCTAssertEqual(Self.visibleText(model.body), "Заключение\nIvan Petrov\u{00A0}\u{2014}\u{00A0}xredmark\nЯя end\n")
        XCTAssertEqual(model.fonts[1]?.name, "Arial")
        XCTAssertEqual(model.fonts[1]?.family, .swiss)
        XCTAssertEqual(model.fonts[1]?.charset, 204)
        XCTAssertEqual(model.fonts[1]?.panose, "020b0604020202020204")
        XCTAssertEqual(model.colors.count, 4)
        XCTAssertNil(model.colors[0], "первая запись — «авто»")
        XCTAssertEqual(model.colors[2], RTFColor(red: 192, green: 0, blue: 0))
        XCTAssertEqual(model.defaultTab, 708)
        XCTAssertEqual(model.sections[0].props.marginLeft, 1701)
        XCTAssertEqual(source.substring(with: try XCTUnwrap(model.fontTable)).prefix(9), "{\\fonttbl")
        XCTAssertEqual(source.substring(with: try XCTUnwrap(model.colorTable)).suffix(2), ";}")

        // Карта: `\'c7` — 4 знака, «Iv» — сами символы, `\u1071\'3f` — вместе с заменителем, `\uc2` — с двумя.
        let title = model.body.paragraphs[0].runs[0]
        XCTAssertEqual(title.map[0], source.range(of: #"\'c7"#))
        let name = model.body.paragraphs[1].runs
        XCTAssertEqual(name[0].text, "Iv")
        XCTAssertEqual(name[0].map[0], NSRange(location: source.range(of: "Iv}").location, length: 1))
        XCTAssertNotEqual(name[0].group, name[1].group, "кусок каждой группы — свой прогон")
        let last = model.body.paragraphs[2].runs
        XCTAssertEqual(last.map(\.uc), [1, 2], "\\uc меняет прогон: при вводе нужно знать число заменителей")
        let map = last.flatMap(\.map)
        XCTAssertEqual(map[0], source.range(of: #"\u1071\'3f"#))
        XCTAssertEqual(map[1], source.range(of: #"\u1103\'3f\'3f"#), "\\uc2 — два заменителя")
        Self.checkMap(model.body, source: source, file: "letter")
    }

    func testCharacterAndParagraphProps() throws {
        let source = Self.letter as NSString
        let model = RTFReader.read(source)
        let title = model.body.paragraphs[0]
        XCTAssertEqual(title.props.alignment, .center)
        XCTAssertEqual(title.props.spaceBefore, 120)
        XCTAssertEqual(title.props.spaceAfter, 240)
        XCTAssertEqual(title.props.lineSpacing, 276)
        XCTAssertTrue(title.props.lineMultiple)
        XCTAssertTrue(title.runs[0].props.bold)
        XCTAssertEqual(title.runs[0].props.halfPoints, 32)
        XCTAssertEqual(title.runs[0].props.font, 0, "\\plain — шрифт по умолчанию")
        let body = model.body.paragraphs[1]
        XCTAssertEqual(body.props.left, 567)
        XCTAssertEqual(body.props.firstLine, -284)
        let runs = Dictionary(body.runs.map { ($0.text, $0.props) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(runs["Iv"]?.font, 1)
        XCTAssertEqual(runs["Iv"]?.halfPoints, 20)
        XCTAssertEqual(runs["Pe"]?.italic, true)
        XCTAssertEqual(runs["trov"]?.underline, .single)
        XCTAssertEqual(runs["x"]?.strike, true)
        XCTAssertEqual(runs["red"]?.color, 2)
        XCTAssertEqual(runs["mark"]?.highlight, 3)
        XCTAssertEqual(model.body.paragraphs[2].props.alignment, .right)

        // Коды свойств абзаца — в его области, действующие на его конце.
        XCTAssertEqual(source.substring(with: try XCTUnwrap(title.pard)), "\\pard")
        XCTAssertEqual(source.substring(with: try XCTUnwrap(title.propTokens["align"])), "\\qc ")
        XCTAssertEqual(source.substring(with: try XCTUnwrap(title.propTokens["sl"])), "\\sl276")
        XCTAssertEqual(source.substring(with: try XCTUnwrap(body.propTokens["fi"])), "\\fi-284 ")
        XCTAssertEqual(source.substring(with: title.endRange), "\\par")
        XCTAssertEqual(body.regionStart, NSMaxRange(title.endRange))
        XCTAssertEqual(body.end, .paragraph)
    }

    static let table = #"""
    {\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}}{\colortbl;\red0\green0\blue0;\red221\green226\blue238;}
    \pard\plain Before\par
    \trowd\trgaph108\trleft-108\trhdr\clbrdrt\brdrs\brdrw10 \clbrdrl\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \clbrdrr\brdrs\brdrw10 \clcbpat2\clvmgf\cellx2000\clbrdrt\brdrs\brdrw15\brdrcf1 \cellx5000
    \pard\plain\intbl {A1\cell}{B1\par B1b\cell}\row
    \trowd\trgaph108\trleft-108\clvmrg\cellx2000\cellx5000
    \pard\plain\intbl {\cell}{B2\cell}\row
    \pard\plain After\par
    }
    """#

    func testTable() throws {
        let source = Self.table as NSString
        let model = RTFReader.read(source)
        XCTAssertEqual(Self.visibleText(model.body), "Before\nA1\u{7}B1\nB1b\u{7}\u{7}B2\u{7}After\n")
        let table = try XCTUnwrap(model.body.tables.first)
        XCTAssertEqual(model.body.tables.count, 1)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.rows[0].paragraphs, [[1], [2, 3]])
        XCTAssertTrue(table.rows[0].header)
        XCTAssertEqual(table.rows[0].left, -108)
        XCTAssertEqual(table.rows[0].cells.map(\.right), [2000, 5000])
        XCTAssertEqual(table.rows[0].cells[0].shading, 2)
        XCTAssertTrue(table.rows[0].cells[0].verticalMergeFirst)
        XCTAssertEqual(table.rows[0].cells[0].borderLeft.width, 10)
        XCTAssertEqual(table.rows[0].cells[1].borderTop.width, 15)
        XCTAssertEqual(table.rows[0].cells[1].borderTop.color, 1)
        XCTAssertTrue(table.rows[1].cells[0].verticalMerged)
        XCTAssertEqual(source.substring(with: table.rows[1].endRange), "\\row")
        XCTAssertEqual(model.body.paragraphs[2].cell, RTFCellRef(table: 0, row: 0, cell: 1))
        XCTAssertEqual(model.body.paragraphs[2].end, .paragraph, "абзац внутри ячейки")
        XCTAssertEqual(model.body.paragraphs[3].end, .cell)
        XCTAssertNil(model.body.paragraphs[6].cell, "после таблицы — обычный абзац")
    }

    static let headers = #"""
    {\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}\paperw11906\paperh16838\facingp
    \sectd\titlepg\headery500{\headerf\pard\plain\qc First\par}{\headerr\pard\plain Odd {\field{\*\fldinst {PAGE }}{\fldrslt {7}}} of {\field{\*\fldinst NUMPAGES}{\fldrslt 9}}\par}{\headerl\pard Even\par}
    \pard\plain Body {\field{\*\fldinst HYPERLINK "http://x"}{\fldrslt link}} {\v secret}tail\par
    \sect\sectd\lndscpsxn\pgwsxn16838\pghsxn11906\sbknone
    \pard\plain Landscape\par
    }
    """#

    func testHeadersFieldsSections() throws {
        let source = Self.headers as NSString
        let model = RTFReader.read(source)
        XCTAssertTrue(model.facingPages)
        XCTAssertEqual(source.substring(with: try XCTUnwrap(model.facingPagesRange)), "\\facingp")
        XCTAssertEqual(model.sections.count, 2)
        let first = model.sections[0]
        XCTAssertTrue(first.props.titlePage)
        XCTAssertEqual(first.props.headerY, 500)
        XCTAssertEqual(Set(first.headers.keys), [.headerFirst, .headerRight, .headerLeft])
        let odd = try XCTUnwrap(first.headers[.headerRight])
        XCTAssertEqual(Self.visibleText(odd.story), "Odd 7 of 9\n")
        XCTAssertTrue(source.substring(with: odd.group).hasPrefix("{\\headerr"))
        XCTAssertEqual(first.headers[.headerFirst]?.story.paragraphs.first?.props.alignment, .center)
        // Новый колонтитул — после последнего существующего.
        XCTAssertEqual(first.headerInsertion, NSMaxRange(try XCTUnwrap(first.headers[.headerLeft]).group))
        XCTAssertNotNil(first.sectd)

        let fieldRuns = odd.story.paragraphs[0].runs.filter { if case .field = $0.kind { return true }; return false }
        XCTAssertEqual(fieldRuns.map(\.text), ["7", "9"])
        XCTAssertEqual(fieldRuns.first?.kind, .field(.page))
        XCTAssertEqual(model.fields.map(\.kind), [.page, .numPages, .other("HYPERLINK")])
        for field in model.fields { XCTAssertTrue(source.substring(with: field.group).hasPrefix("{\\field")) }
        XCTAssertTrue(source.substring(with: model.fields[0].group).hasSuffix("}}}"))

        XCTAssertEqual(Self.visibleText(model.body), "Body link tail\nLandscape\n")
        let body = model.body.paragraphs[0].runs
        XCTAssertEqual(body.first { $0.props.hidden }?.text, "secret")
        XCTAssertEqual(body.first { $0.text == "link" }?.kind, .text, "результат HYPERLINK правится")
        XCTAssertEqual(body.first { $0.text == "link" }?.field, 2)
        let second = model.sections[1]
        XCTAssertEqual(second.props.pageWidth, 16838)
        XCTAssertTrue(second.props.landscape)
        XCTAssertFalse(second.props.newPage)
        XCTAssertFalse(second.props.titlePage, "\\sectd сбрасывает особую первую страницу")
        // `\par` перед `\sect` — пустой абзац с концом раздела, как в Word.
        XCTAssertEqual(model.body.paragraphs[1].end, .section)
        XCTAssertEqual(model.body.paragraphs[1].section, 0)
        XCTAssertEqual(second.firstParagraph, 2)
        XCTAssertEqual(model.body.paragraphs[2].section, 1)
    }

    static let objects = #"""
    {\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}
    \pard\plain Pic {\*\shppict{\pict\pngblip\picw1\pich1\picwgoal1440\pichgoal720 PNGHEX}}{\nonshppict{\pict\wmetafile8\picw100\pich100 0100090000}}\par
    \pard {\pict\wmetafile8\picwgoal2268\pichgoal1701 010009000003}\par
    \pard {\shp{\*\shpinst\shpleft0\shpright3515\shptop0\shpbottom1191{\sp{\sn shapeType}{\sv 1}}{\sp{\sn fFilled}{\sv 0}}{\shptxt Hidden shape text}}{\shprslt {\*\do\dobxcolumn\dprect\dpx0\dpy0\dpxsize100\dpysize100}}}\par
    \pard {\*\do\dobxcolumn\dpline\dpx0\dpy0\dpxsize567\dpysize0}\par
    \pard {\object\objemb{\*\objclass Excel.Sheet}{\*\objdata 0102}{\result {Result text}}}\par
    }
    """#.replacingOccurrences(of: "PNGHEX", with: "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da636460f85f0f0002870180eb47ba920000000049454e44ae426082")

    func testPicturesAndPlaceholders() throws {
        let source = Self.objects as NSString
        let model = RTFReader.read(source)
        XCTAssertEqual(Self.visibleText(model.body), "Pic \n\n\n\n\n")
        let picture = try XCTUnwrap(model.body.paragraphs[0].runs.last?.picture)
        XCTAssertEqual(picture.format, .png)
        XCTAssertEqual(picture.width, 1440)
        XCTAssertEqual(picture.height, 720)
        XCTAssertNotNil(NSImage(data: picture.data), "данные PNG целы")
        XCTAssertEqual(model.body.paragraphs[0].runs.count, 2, "\\nonshppict не показывается")
        func placeholder(_ paragraph: Int) -> RTFPlaceholder? {
            if case .placeholder(let placeholder) = model.body.paragraphs[paragraph].runs.first?.kind { return placeholder }
            return nil
        }
        XCTAssertEqual(placeholder(1), RTFPlaceholder(kind: .picture("WMF"), width: 2268, height: 1701))
        XCTAssertEqual(placeholder(2), RTFPlaceholder(kind: .shape(1), width: 3515, height: 1191))
        XCTAssertEqual(placeholder(3), RTFPlaceholder(kind: .drawing("Линия"), width: 567, height: 0))
        XCTAssertEqual(placeholder(4)?.kind, .object)
        XCTAssertEqual(placeholder(2)?.subtitle, "Прямоугольник · 6,2 × 2,1 см")
        for paragraph in 1...4 {
            let run = try XCTUnwrap(model.body.paragraphs[paragraph].runs.first)
            let group = source.substring(with: try XCTUnwrap(run.objectGroup))
            XCTAssertTrue(group.hasPrefix("{") && group.hasSuffix("}"), "заглушка — вся группа")
            XCTAssertEqual(run.map, [run.objectGroup!])
        }
    }

    // MARK: - Сверка с Cocoa

    /// Видимый текст против `NSAttributedString(rtf:)` (только для сверки, показываем своим разбором).
    static func cocoaText(_ source: String) -> String? {
        guard let data = source.data(using: .ascii) ?? source.data(using: .windowsCP1252) else { return nil }
        return (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string
    }

    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{7}", with: "\n").replacingOccurrences(of: "\u{2028}", with: "\n")
            .trimmingCharacters(in: .newlines)
    }

    func testMatchesCocoaVisibleText() throws {
        for (name, source) in [("letter", Self.letter), ("table", Self.table)] {
            let cocoa = try XCTUnwrap(Self.cocoaText(source), name)
            // Пустая объединённая ячейка у Cocoa не даёт строки — сравниваем без пустых строк.
            func lines(_ text: String) -> [String] { Self.normalized(text).split(separator: "\n").map(String.init) }
            XCTAssertEqual(lines(Self.visibleText(RTFReader.read(source).body)), lines(cocoa), name)
        }
    }

    func testTesterFixturesMatchCocoa() throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: Self.testerFolder.path) else {
            throw XCTSkip("Нет фикстур тестировщика Tests/Fixtures/DocView")
        }
        var compared = 0
        for name in names.sorted() where name.hasSuffix(".rtf") || name.hasSuffix(".frm") {
            let data = try Data(contentsOf: Self.testerFolder.appendingPathComponent(name))
            let document = EditorDocument(data: data)
            let model = RTFReader.read(document.decodedText as NSString, fallback: document.encoding)
            // Колонтитулы и скрытый текст Cocoa показывает иначе (теряет и раскрывает) — такие файлы не сравниваем.
            let hasHeaders = model.sections.contains { !$0.headers.isEmpty }
            let hasHidden = model.body.paragraphs.flatMap(\.runs).contains { $0.props.hidden }
            let hasLists = model.body.paragraphs.flatMap(\.runs).contains { $0.kind == .listText }
            guard !hasHeaders, !hasHidden, !hasLists,
                  let cocoa = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                      documentAttributes: nil) else { continue }
            let mine = Self.normalized(Self.visibleText(model.body))
            let theirs = Self.normalized(cocoa.string.replacingOccurrences(of: "\u{FFFC}", with: ""))
            XCTAssertEqual(mine.filter { !$0.isWhitespace }, theirs.filter { !$0.isWhitespace }, name)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 5)
    }

    // MARK: - Скорость

    /// Word-подобный документ нужного размера: кириллица `\'hh`, группы rsid, `$`, таблица каждые 12 абзацев.
    static func bigDocument(bytes: Int) -> String {
        var out = #"{\rtf1\adeflang1025\ansi\ansicpg1251\uc1\adeff0\deff0\stshfdbch0\stshfloch0\stshfhich0\stshfbi0\deflang1049\deflangfe1049"#
        out += #"{\fonttbl{\f0\fbidi \froman\fcharset204\fprq2{\*\panose 02020603050405020304}Times New Roman;}{\f1\fbidi \fswiss\fcharset204\fprq2 Arial;}}"#
        out += #"{\colortbl;\red0\green0\blue0;\red0\green0\blue255;}{\stylesheet{\ql \li0\ri0\widctlpar Normal;}}"# + "\r\n"
        out += #"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134"# + "\r\n"
        let pard = #"\pard\plain \ltrpar\ql \li0\ri0\sa160\sl259\slmult1\widctlpar\wrapdefault\aspalpha\aspnum\faauto\adjustright\rin0\lin0\itap0 \rtlch\fcs1 \af0\afs24\alang1025 \ltrch\fcs0 \fs24\lang1049\langfe1049\cgrid\langnp1049\langfenp1049 "#
        let word = #"\'c4\'e5\'ec\'ee\'ed\'f1\'f2\'f0\'e0\'f6\'e8\'ff"#
        var paragraph = 0
        while out.utf16.count < bytes {
            paragraph += 1
            if paragraph % 12 == 0 {
                out += #"\trowd \irow0\ltrrow\trgaph108\trleft-108\trbrdrt\brdrs\brdrw10 \trbrdrl\brdrs\brdrw10 \trbrdrb\brdrs\brdrw10 \trbrdrr\brdrs\brdrw10 \clbrdrt\brdrs\brdrw10 \cellx3000\clbrdrt\brdrs\brdrw10 \cellx6000\clbrdrt\brdrs\brdrw10 \cellx9000"# + "\r\n"
                for cell in 0..<3 {
                    out += pard + #"\intbl {\rtlch\fcs1 \af0 \ltrch\fcs0 \insrsid4548749 "# + word + " \(cell)}{\\cell }"
                }
                out += #"{\trowd \irow0\ltrrow\trgaph108\trleft-108\cellx3000\cellx6000\cellx9000\row }"# + "\r\n"
                continue
            }
            out += pard + #"{\rtlch\fcs1 \af0 \ltrch\fcs0 \f1\insrsid4548749 "# + word + " " + word + " " + word + #" }{\rtlch\fcs1 \af0 \ltrch\fcs0 \b\insrsid9 $"# + "\(paragraph)" + "}"
            out += #"{\rtlch\fcs1 \af0 \ltrch\fcs0 \insrsid4548749  "# + word + #" demo text for the page.}\par"# + "\r\n"
        }
        return out + "}"
    }

    func testReadTwoMegabytes() {
        let source = Self.bigDocument(bytes: 1_900_000) as NSString
        var model = RTFDocumentModel()
        let time = TextEditorPerformanceTests.measure { model = RTFReader.read(source) }
        XCTAssertGreaterThan(model.body.paragraphs.count, 3_000)
        XCTAssertGreaterThan(model.body.tables.count, 200)
        print(String(format: "[doc-perf] %@ разбор RTF 1,9 МБ: %.0f мс, абзацев %d", TextEditorPerformanceTests.build, time, model.body.paragraphs.count))
        XCTAssertLessThan(time, TextEditorPerformanceTests.limit(150))
    }

    // MARK: - Фикстуры тестировщика (если лежат рядом; в репозиторий они не входят)

    static let testerFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/DocView", isDirectory: true)

    func testTesterFixturesVisibleText() throws {
        let manifestURL = Self.testerFolder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = manifest["files"] as? [String: [String: Any]] else {
            throw XCTSkip("Нет фикстур тестировщика Tests/Fixtures/DocView")
        }
        for (name, facts) in files.sorted(by: { $0.key < $1.key }) {
            let bytes = try Data(contentsOf: Self.testerFolder.appendingPathComponent(name))
            let document = EditorDocument(data: bytes)
            let model = RTFReader.read(document.decodedText as NSString, fallback: document.encoding)
            XCTAssertTrue(model.isRTF, name)
            XCTAssertEqual(Self.visibleText(model.body), facts["visible_body"] as? String, name)
            // Колонтитулы: «header:all» → текст.
            var headers: [String: String] = [:]
            for section in model.sections {
                for (kind, header) in section.headers {
                    let page: String
                    switch kind.page {
                    case .all: page = "all"
                    case .even: page = "even"
                    case .odd: page = "odd"
                    case .first: page = "first"
                    }
                    headers[(kind.isHeader ? "header:" : "footer:") + page] = Self.visibleText(header.story)
                }
            }
            XCTAssertEqual(headers, facts["headers"] as? [String: String] ?? [:], name)
            XCTAssertEqual(model.body.tables.flatMap { $0.rows.map(\.paragraphs.count) }, facts["table_rows_cells"] as? [Int] ?? [], name)
            // Разделов на один больше, чем слов `\sect` (в манифесте `sections` считает и `\sectd`).
            let sectWords = try NSRegularExpression(pattern: #"\\sect(?![a-z])"#)
                .numberOfMatches(in: document.decodedText, range: NSRange(location: 0, length: (document.decodedText as NSString).length))
            XCTAssertEqual(model.sections.count - 1, sectWords, name)
            XCTAssertEqual(model.sections.contains { $0.props.titlePage }, facts["titlepg"] as? Bool, name)
            XCTAssertEqual(model.facingPages, facts["facingp"] as? Bool, name)
            let hidden = model.body.paragraphs.flatMap(\.runs).filter { $0.props.hidden && $0.kind == .text }.map { ($0.text as NSString).length }
            XCTAssertEqual(hidden.reduce(0, +), facts["hidden_chars"] as? Int, name)
            let runs = model.body.paragraphs.flatMap(\.runs)
            let pictures = facts["pictures"] as? [String: Int] ?? [:]
            XCTAssertEqual(runs.filter { $0.picture?.format == .png }.count, pictures["png"], name)
            XCTAssertEqual(runs.filter { if case .placeholder(let p) = $0.kind, case .picture("WMF") = p.kind { return true }; return false }.count,
                           pictures["wmf"], name)
            XCTAssertEqual(runs.filter { if case .placeholder(let p) = $0.kind, case .shape = p.kind { return true }; return false }.count,
                           pictures["shapes"], name)
            Self.checkMap(model.body, source: document.decodedText as NSString, file: name)
        }
    }

    /// Каждая видимая единица ведёт в свой кусок исходника: обычный символ — он сам, `\'hh` — 4 знака, `\uN` — со
    /// заменителями, переводы строк исходника не видны.
    static func checkMap(_ story: RTFStory, source: NSString, file: String) {
        var previousEnd = 0
        for paragraph in story.paragraphs {
            for run in paragraph.runs {
                let units = run.text as NSString
                XCTAssertEqual(run.map.count, units.length, "\(file): карта на каждую единицу")
                for (index, range) in run.map.enumerated() {
                    XCTAssertGreaterThanOrEqual(range.location, previousEnd, "\(file): карта идёт по порядку исходника")
                    guard NSMaxRange(range) <= source.length else { return XCTFail("\(file): диапазон за концом") }
                    let piece = source.substring(with: range)
                    switch run.kind {
                    case .picture, .placeholder:
                        XCTAssertTrue(piece.hasPrefix("{") && piece.hasSuffix("}"), "\(file): объект — вся группа")
                    default:
                        XCTAssertFalse(piece.contains("\n") || piece.contains("\r"), "\(file): перевод строки исходника — не символ")
                        if !piece.hasPrefix("\\") {
                            XCTAssertEqual(piece, units.substring(with: NSRange(location: index, length: 1)), "\(file): обычный символ — сам себя")
                        } else if piece.hasPrefix("\\'") {
                            XCTAssertEqual(range.length, 4, "\(file): \\'hh — 4 знака")
                        }
                    }
                    previousEnd = range.location
                }
            }
        }
    }
}

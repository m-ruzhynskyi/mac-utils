import AppKit
import XCTest
@testable import MacUtils

/// Форматирование в режиме «Документ» (D-4): точечные правки свойств символов и абзацев. Главное правило — байты вне
/// правок не меняются, а всё, кроме цели, читается как раньше. Документы выдуманные, в стиле Word.
final class DocFormatTests: XCTestCase {
    // MARK: - Помощники

    /// Применить план: проверить правила (1)–(4) плана § 6 и вернуть новый исходник.
    @discardableResult
    func applyChecked(_ plan: FormatPlan, to source: String, family: Set<String>? = nil, wholeGroups: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let text = source as NSString
        let merged = try XCTUnwrap(FormatCheck.merged(plan.edits), "правки пересекаются", file: file, line: line)
        // (1) Байты вне правок: заменяются только управляющие слова, вставляются только группы и коды — текста нет.
        for edit in merged {
            let old = text.substring(with: edit.range)
            if edit.range.length > 0, wholeGroups {
                // Колонтитул целиком: вырезается ровно одна группа `{…}` или один код.
                let cut = text.substring(with: edit.range)
                XCTAssertTrue(cut.hasPrefix("{\\") && cut.hasSuffix("}") || cut.hasPrefix("\\"), "вырезано не то", file: file, line: line)
            } else if edit.range.length > 0 {
                let token = RTFLexer.controlToken(text, at: edit.range.location)
                XCTAssertEqual(token.wordRange, edit.range, "замена — ровно одно слово: \(old)", file: file, line: line)
                if let family { XCTAssertTrue(family.contains(token.name), "заменено чужое слово \(old)", file: file, line: line) }
            }
            XCTAssertTrue(Self.onlyCodes(edit.string), "во вставке есть текст: \(edit.string)", file: file, line: line)
        }
        let result = try XCTUnwrap(FormatCheck.apply(plan.edits, to: text), file: file, line: line) as String
        Self.assertUntouched(original: source, result: result, edits: merged, file: file, line: line)
        // (2) Скобки.
        XCTAssertEqual(DollarMarks.unbalancedBraces(in: result as NSString), DollarMarks.unbalancedBraces(in: text), file: file, line: line)
        // (3) Наш разбор и Cocoa открывают файл; модель — как ожидалось (у колонтитулов это проверил сам генератор).
        if !wholeGroups {
            XCTAssertNil(FormatCheck.compare(old: RTFReader.read(text), new: RTFReader.read(result as NSString), plan: plan), file: file, line: line)
        }
        XCTAssertTrue(RTFReader.read(result as NSString).isRTF, file: file, line: line)
        XCTAssertNotNil(try? NSAttributedString(data: Data(result.utf8), options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                documentAttributes: nil), "Cocoa не открыла", file: file, line: line)
        return result
    }

    /// Вставка — только скобки, управляющие слова, их числа и пробелы-разделители (имя шрифта в `\fonttbl` — отдельно).
    static func onlyCodes(_ string: String) -> Bool {
        if string.hasPrefix("{\\f"), string.contains(";}") { return true }
        if string.contains("\\red") { return true }
        let text = string as NSString
        for token in RTFLexer.tokens(text, in: NSRange(location: 0, length: text.length)) {
            switch token.kind {
            case .open, .close, .word: continue
            default: return false
            }
        }
        return true
    }

    /// Независимая проверка «байты вне правок те же»: исходник, разрезанный по правкам, — по порядку в результате.
    static func assertUntouched(original: String, result: String, edits: [FormatEdit], file: StaticString = #filePath, line: UInt = #line) {
        let source = original as NSString, out = result as NSString
        var cursor = 0, offset = 0
        for edit in edits {
            let keep = NSRange(location: cursor, length: edit.range.location - cursor)
            XCTAssertEqual(out.substring(with: NSRange(location: keep.location + offset, length: keep.length)), source.substring(with: keep),
                           "байты до правки в \(edit.range.location) изменились", file: file, line: line)
            offset += (edit.string as NSString).length - edit.range.length
            cursor = NSMaxRange(edit.range)
        }
        XCTAssertEqual(out.substring(from: cursor + offset), source.substring(from: cursor), "хвост изменился", file: file, line: line)
    }

    func span(of text: String, in source: String) -> NSRange {
        (source as NSString).range(of: text)
    }

    /// Свойства видимых символов основного текста по порядку (без скрытых).
    func chars(_ source: String) -> [(Character, RTFCharProps)] {
        let model = RTFReader.read(source)
        var out: [(Character, RTFCharProps)] = []
        for paragraph in model.body.paragraphs {
            for run in paragraph.runs where run.kind == .text { for char in run.text { out.append((char, run.props)) } }
        }
        return out
    }

    func props(of text: String, in source: String) -> [RTFCharProps] {
        let all = chars(source)
        let joined = String(all.map(\.0))
        guard let range = joined.range(of: text) else { return [] }
        let start = joined.distance(from: joined.startIndex, to: range.lowerBound)
        return all[start..<(start + text.count)].map(\.1)
    }

    static let letter = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}{\f1\fswiss\fcharset204 Arial;}}"#
        + #"{\colortbl;\red0\green0\blue0;\red192\green0\blue0;}"# + "\r\n"
        + #"\pard\plain \qj\li720\lin720\sa120 {\rtlch\fcs1 \ltrch\fcs0 \f1\fs24\insrsid1 Hello world}{\b\insrsid2  bold}\par"# + "\r\n"
        + #"plain line \'cf\'f0\'e8\'e2\'e5\'f2\par"# + "\r\n"
        + #"\pard \qc {\f1 Centered}{\*\bkmkstart x}{\*\bkmkend x} tail\par"# + "\r\n"
        + #"\pard {\striked1 Double}\par"# + "\r\n"
        + "}"

    // MARK: - Символы

    func testBoldPartOfRunWrapsInGroup() throws {
        let source = Self.letter
        let plan = try FormatEdits.character(.bold(true), span: span(of: "world", in: source), source: source as NSString,
                                             model: RTFReader.read(source)).get()
        let result = try applyChecked(plan, to: source)
        XCTAssertTrue(result.contains("Hello {\\b world}"), result)
        XCTAssertEqual(props(of: "world", in: result).map(\.bold), Array(repeating: true, count: 5))
        XCTAssertEqual(props(of: "Hello ", in: result).map(\.bold), Array(repeating: false, count: 6))
    }

    func testWholeGroupGetsCodeInsideGroup() throws {
        let source = Self.letter
        // Вся группа «Hello world» — код в начале группы, без новой группы.
        let plan = try FormatEdits.character(.italic(true), span: span(of: "Hello world", in: source), source: source as NSString,
                                             model: RTFReader.read(source)).get()
        let result = try applyChecked(plan, to: source)
        XCTAssertTrue(result.contains("\\insrsid1 \\i Hello world}"), result)
        // Снять полужирный у « bold»: `\b` в начале группы → `\b0`.
        let off = try FormatEdits.character(.bold(false), span: span(of: " bold", in: result), source: result as NSString,
                                            model: RTFReader.read(result)).get()
        let cleared = try applyChecked(off, to: result, family: ["b"])
        XCTAssertTrue(cleared.contains("{\\b0\\insrsid2  bold}"), cleared)
        XCTAssertEqual(props(of: "bold", in: cleared).map(\.bold), [false, false, false, false])
    }

    func testCyrillicFontGetsSameCharset() throws {
        let source = Self.letter
        let plan = try FormatEdits.character(.font("Calibri"), span: span(of: #"\'cf\'f0\'e8\'e2\'e5\'f2"#, in: source), source: source as NSString,
                                             model: RTFReader.read(source)).get()
        let result = try applyChecked(plan, to: source)
        // Новый шрифт — в конце таблицы, с кодировкой кириллицы; номера прежних не изменились.
        XCTAssertTrue(result.contains(#"{\f1\fswiss\fcharset204 Arial;}{\f2\fswiss\fcharset204\fprq2 Calibri;}}"#), result)
        let model = RTFReader.read(result)
        XCTAssertEqual(model.fonts[2]?.name, "Calibri")
        XCTAssertEqual(props(of: "Привет", in: result).map(\.font), Array(repeating: 2, count: 6))
        // Тот же шрифт ещё раз — та же запись.
        let again = try FormatEdits.character(.font("Calibri"), span: span(of: "plain line", in: result), source: result as NSString, model: model).get()
        XCTAssertTrue(again.addedFonts.isEmpty)
        try applyChecked(again, to: result)
    }

    func testSizeColorHighlight() throws {
        var source = Self.letter
        let model = RTFReader.read(source)
        let size = try FormatEdits.character(.size(21), span: span(of: "Hello", in: source), source: source as NSString, model: model).get()
        source = try applyChecked(size, to: source)
        XCTAssertEqual(props(of: "Hello", in: source).map(\.halfPoints), Array(repeating: 21, count: 5))
        // Цвет, которого нет, дописывается в конец `\colortbl`; тот, что есть, берётся по номеру.
        let blue = RTFColor(red: 0, green: 0, blue: 255)
        let color = try FormatEdits.character(.color(blue), span: span(of: "tail", in: source), source: source as NSString,
                                              model: RTFReader.read(source)).get()
        XCTAssertEqual(color.addedColors, [blue])
        source = try applyChecked(color, to: source)
        XCTAssertTrue(source.contains(#"\red192\green0\blue0;\red0\green0\blue255;}"#))
        XCTAssertEqual(props(of: "tail", in: source).map(\.color), Array(repeating: 3, count: 4))
        let red = try FormatEdits.character(.highlight(RTFColor(red: 192, green: 0, blue: 0)), span: span(of: "plain line", in: source),
                                            source: source as NSString, model: RTFReader.read(source)).get()
        XCTAssertTrue(red.addedColors.isEmpty)
        source = try applyChecked(red, to: source)
        XCTAssertEqual(props(of: "plain line", in: source).map(\.highlight), Array(repeating: 2, count: 10))
        let auto = try FormatEdits.character(.color(nil), span: span(of: "tail", in: source), source: source as NSString,
                                             model: RTFReader.read(source)).get()
        source = try applyChecked(auto, to: source)
        XCTAssertEqual(props(of: "tail", in: source).map(\.color), Array(repeating: 0, count: 4))
    }

    func testStrikeOffClearsDoubleStrike() throws {
        let source = Self.letter
        let plan = try FormatEdits.character(.strike(false), span: span(of: "Double", in: source), source: source as NSString,
                                             model: RTFReader.read(source)).get()
        let result = try applyChecked(plan, to: source)
        XCTAssertTrue(result.contains("\\strike0\\striked0"), result)
        XCTAssertEqual(props(of: "Double", in: result).map(\.strike), Array(repeating: false, count: 6))
    }

    func testSelectionAcrossParagraphsAndGroups() throws {
        let source = Self.letter
        let start = span(of: "world", in: source).location
        let end = NSMaxRange(span(of: "Centered", in: source))
        let plan = try FormatEdits.character(.underline(true), span: NSRange(location: start, length: end - start), source: source as NSString,
                                             model: RTFReader.read(source)).get()
        let result = try applyChecked(plan, to: source)
        let all = chars(result)
        let text = String(all.map(\.0))
        let from = text.distance(from: text.startIndex, to: text.range(of: "world")!.lowerBound)
        let to = text.distance(from: text.startIndex, to: text.range(of: "Centered")!.upperBound)
        for (index, (_, props)) in all.enumerated() {
            XCTAssertEqual(props.underline != .none, (from..<to).contains(index), "символ \(index)")
        }
    }

    func testClearFormatting() throws {
        let source = Self.letter
        let model = RTFReader.read(source)
        let paragraphs = [0]
        let plan = try FormatEdits.clear(span: span(of: "Hello world}{\\b\\insrsid2  bold", in: source), paragraphs: paragraphs,
                                         source: source as NSString, model: model).get()
        let result = try applyChecked(plan, to: source)
        let fresh = RTFReader.read(result)
        XCTAssertEqual(fresh.body.paragraphs[0].props.alignment, .left)
        XCTAssertEqual(fresh.body.paragraphs[0].props.left, 0)
        XCTAssertEqual(fresh.body.paragraphs[0].props.spaceAfter, 0)
        for props in props(of: "Hello world bold", in: result) {
            XCTAssertFalse(props.bold)
            XCTAssertEqual(props.halfPoints, 24)
            XCTAssertEqual(fresh.font(props.font)?.name, "Times New Roman")
        }
        // Второй абзац наследовал отступ первого — у него он остался.
        XCTAssertEqual(fresh.body.paragraphs[1].props, model.body.paragraphs[1].props)
    }

    // MARK: - Абзацы

    func testAlignmentReplacesOwnCodeAndRestoresFollowing() throws {
        let source = Self.letter
        let model = RTFReader.read(source)
        // У первого абзаца свой `\qj` — замена; второй его наследовал — сразу за `\par` первого прежний `\qj`.
        let plan = try FormatEdits.paragraph(ParaChange(alignment: .right), paragraphs: [0], source: source as NSString, model: model).get()
        let result = try applyChecked(plan, to: source, family: ["qj"])
        let fresh = RTFReader.read(result)
        XCTAssertEqual(fresh.body.paragraphs.map(\.props.alignment), [.right, .justify, .center, .left])
        XCTAssertTrue(result.contains(#"\qr\li720"#), result)
        XCTAssertTrue(result.contains(#"bold}\par\qj "#), result)
    }

    func testParagraphWithoutPardGetsCodeBeforeEnd() throws {
        let source = Self.letter
        let model = RTFReader.read(source)
        let plan = try FormatEdits.paragraph(ParaChange(alignment: .center, left: 0, spaceAfter: 240), paragraphs: [1],
                                             source: source as NSString, model: model).get()
        let result = try applyChecked(plan, to: source)
        let fresh = RTFReader.read(result)
        XCTAssertEqual(fresh.body.paragraphs[1].props.alignment, .center)
        XCTAssertEqual(fresh.body.paragraphs[1].props.left, 0)
        XCTAssertEqual(fresh.body.paragraphs[1].props.spaceAfter, 240)
        XCTAssertEqual(fresh.body.paragraphs[0].props, model.body.paragraphs[0].props)
        XCTAssertEqual(fresh.body.paragraphs[2].props, model.body.paragraphs[2].props)
    }

    func testIndentsAndSpacingAfterPard() throws {
        let source = Self.letter
        let model = RTFReader.read(source)
        let plan = try FormatEdits.paragraph(ParaChange(left: 1440, right: 360, firstLine: -360, spaceBefore: 240, lineSpacing: (360, true)),
                                             paragraphs: [2, 3], source: source as NSString, model: model).get()
        let result = try applyChecked(plan, to: source)
        let fresh = RTFReader.read(result)
        for index in [2, 3] {
            let props = fresh.body.paragraphs[index].props
            XCTAssertEqual([props.left, props.right, props.firstLine, props.spaceBefore, props.lineSpacing], [1440, 360, -360, 240, 360])
            XCTAssertTrue(props.lineMultiple)
        }
        XCTAssertTrue(result.contains(#"\pard \li1440 \lin1440 \ri360 \rin360 \fi-360 \sb240 \sl360 \slmult1 \qc"#), result)
    }

    func testNothingToChangeHasNoEdits() throws {
        let source = Self.letter
        let plan = try FormatEdits.paragraph(ParaChange(alignment: .center), paragraphs: [2], source: source as NSString,
                                             model: RTFReader.read(source)).get()
        XCTAssertTrue(plan.edits.isEmpty)
    }

    // MARK: - Колонтитулы и демо-документ

    func testFormatInsideHeaderStory() throws {
        let source = DocDemo.expertReport
        let model = RTFReader.read(source)
        let header = try XCTUnwrap(model.sections[0].headers[.headerRight])
        let text = DocDemo.rtf("ООО")
        let range = (source as NSString).range(of: text, options: [], range: header.group)
        let plan = try FormatEdits.character(.bold(true), span: range, story: .header(section: 0, kind: .headerRight),
                                             source: source as NSString, model: model).get()
        let result = try applyChecked(plan, to: source)
        let fresh = RTFReader.read(result)
        let run = try XCTUnwrap(fresh.sections[0].headers[.headerRight]?.story.paragraphs[0].runs.first)
        XCTAssertTrue(run.text.hasPrefix("ООО"))
        XCTAssertTrue(run.props.bold)
        XCTAssertFalse(fresh.sections[0].headers[.headerRight]!.story.paragraphs[0].runs.last!.props.bold)
        let alignment = try FormatEdits.paragraph(ParaChange(alignment: .center), paragraphs: [0], story: .header(section: 0, kind: .headerRight),
                                                  source: result as NSString, model: fresh).get()
        let centered = try applyChecked(alignment, to: result)
        XCTAssertEqual(RTFReader.read(centered).sections[0].headers[.headerRight]?.story.paragraphs[0].props.alignment, .center)
    }

    /// Правило § 6: случайные команды (seed) на демо-документах — каждая либо проходит все проверки, либо честно
    /// отказывается; ни одна не портит файл.
    func testRandomFormattingKeepsEverythingElse() throws {
        var generator = SeededGenerator(seed: 20_261_020)
        for document in [DocDemo.expertReport, Self.letter] {
            var source = document
            var applied = 0, refused = 0
            for _ in 0..<120 {
                let model = RTFReader.read(source)
                let text = source as NSString
                let units = model.body.paragraphs.flatMap { $0.runs.filter { FormatEdits.isTarget($0.kind) }.flatMap(\.map) }.filter { $0.length > 0 }
                guard units.count > 2 else { break }
                let a = Int.random(in: 0..<units.count, using: &generator)
                let b = min(units.count - 1, a + Int.random(in: 0..<40, using: &generator))
                let span = NSRange(location: units[a].location, length: NSMaxRange(units[b]) - units[a].location)
                let result: Result<FormatPlan, FormatFailure>
                switch Int.random(in: 0..<10, using: &generator) {
                case 0: result = FormatEdits.character(.bold(Bool.random(using: &generator)), span: span, source: text, model: model)
                case 1: result = FormatEdits.character(.italic(Bool.random(using: &generator)), span: span, source: text, model: model)
                case 2: result = FormatEdits.character(.underline(Bool.random(using: &generator)), span: span, source: text, model: model)
                case 3: result = FormatEdits.character(.size([16, 21, 24, 28, 48].randomElement(using: &generator)!), span: span, source: text, model: model)
                case 4: result = FormatEdits.character(.font(["Arial", "Calibri", "Times New Roman", "Consolas"].randomElement(using: &generator)!),
                                                       span: span, source: text, model: model)
                case 5: result = FormatEdits.character(.color([nil, RTFColor(red: 192, green: 0, blue: 0), RTFColor(red: 0, green: 112, blue: 192)]
                                                       .randomElement(using: &generator)!), span: span, source: text, model: model)
                case 6: result = FormatEdits.character(.strike(Bool.random(using: &generator)), span: span, source: text, model: model)
                case 7:
                    let paragraph = Int.random(in: 0..<model.body.paragraphs.count, using: &generator)
                    result = FormatEdits.paragraph(ParaChange(alignment: RTFAlignment.allCases.randomElement(using: &generator)!), paragraphs: [paragraph],
                                                   source: text, model: model)
                case 8:
                    let paragraph = Int.random(in: 0..<model.body.paragraphs.count, using: &generator)
                    result = FormatEdits.paragraph(ParaChange(left: [0, 360, 720].randomElement(using: &generator)!,
                                                              spaceAfter: [0, 120].randomElement(using: &generator)!),
                                                   paragraphs: [paragraph, paragraph + 1], source: text, model: model)
                default:
                    let paragraph = Int.random(in: 0..<model.body.paragraphs.count, using: &generator)
                    result = FormatEdits.clear(span: span, paragraphs: [paragraph], source: text, model: model)
                }
                switch result {
                case .success(let plan):
                    source = try applyChecked(plan, to: source)
                    applied += 1
                case .failure:
                    refused += 1
                }
            }
            XCTAssertGreaterThan(applied, 100, "отказов слишком много: \(refused)")
        }
    }

    // MARK: - Настоящие файлы (только по MU_REAL_FRM_DIR, в журнал — только числа)

    /// Случайные команды форматирования и колонтитулов на копиях: каждая либо проходит все проверки, либо отказывается.
    /// Колонтитул добавить и удалить — файл байт в байт как был.
    func testRealFilesFormatting() throws {
        var generator = SeededGenerator(seed: 1_020)
        var files = 0, applied = 0, refused = 0, roundTrips = 0, slowest = 0.0
        var reasons: [String: Int] = [:]
        for url in try DocRealFilesTests.copies() {
            let document = EditorDocument(data: try Data(contentsOf: url))
            var source = document.decodedText
            guard RTFReader.read(source as NSString, fallback: document.encoding).isRTF else { continue }
            files += 1
            for step in 0..<20 {
                let text = source as NSString
                let model = RTFReader.read(text, fallback: document.encoding)
                let units = model.body.paragraphs.flatMap { $0.runs.filter { FormatEdits.isTarget($0.kind) }.flatMap(\.map) }.filter { $0.length > 0 }
                guard units.count > 2 else { break }
                let a = Int.random(in: 0..<units.count, using: &generator)
                let b = min(units.count - 1, a + Int.random(in: 0..<60, using: &generator))
                let span = NSRange(location: units[a].location, length: NSMaxRange(units[b]) - units[a].location)
                let paragraph = Int.random(in: 0..<model.body.paragraphs.count, using: &generator)
                var result: Result<FormatPlan, FormatFailure>!
                let time = TextEditorPerformanceTests.measure {
                    switch step % 6 {
                    case 0: result = FormatEdits.character(.bold(true), span: span, source: text, model: model)
                    case 1: result = FormatEdits.character(.font("Calibri"), span: span, source: text, model: model)
                    case 2: result = FormatEdits.character(.size(22), span: span, source: text, model: model)
                    case 3: result = FormatEdits.character(.color(RTFColor(red: 0, green: 112, blue: 192)), span: span, source: text, model: model)
                    case 4: result = FormatEdits.paragraph(ParaChange(alignment: .center, left: 360), paragraphs: [paragraph], source: text, model: model)
                    default: result = FormatEdits.clear(span: span, paragraphs: [paragraph], source: text, model: model)
                    }
                }
                slowest = max(slowest, time)
                switch result! {
                case .success(let plan):
                    source = try applyChecked(plan, to: source)
                    applied += 1
                case .failure(let failure):
                    refused += 1
                    reasons[failure.reason, default: 0] += 1
                }
            }
            // Нижний колонтитул: добавить и удалить — исходник как был.
            let model = RTFReader.read(source as NSString, fallback: document.encoding)
            let kind = RTFHeaderKind.footerFirst
            if model.sections[0].headers[kind] == nil,
               case .success(let add) = DocHeaderFooterEdits.add([kind], section: 0, source: source as NSString, model: model) {
                let added = try applyChecked(add, to: source, wholeGroups: true)
                let fresh = RTFReader.read(added as NSString, fallback: document.encoding)
                if case .success(let remove) = DocHeaderFooterEdits.remove(kind, section: 0, source: added as NSString, model: fresh),
                   try applyChecked(remove, to: added, wholeGroups: true) == source {
                    roundTrips += 1
                }
            }
        }
        print("[real-frm] формат: файлов \(files), команд выполнено \(applied), отказов \(refused), колонтитул туда-обратно \(roundTrips), "
              + "самая долгая команда \(Int(slowest)) мс (debug)")
        for (reason, count) in reasons.sorted(by: { $0.value > $1.value }) { print("[real-frm] отказ: \(reason) — \(count)") }
    }
}

import AppKit
import XCTest
@testable import MacUtils

/// E-4: индексы, капитель, все прописные, скрытый; «не отрывать», «не разрывать», «с новой страницы»; разрыв страницы;
/// «Обновить поля». Каждая команда — без потерь: `DocSaveGuard`, отмена байт в байт, вне цели модель та же
/// (`FormatCheck`). Фикстура — `Tests/Fixtures/DocE4` (выдуманный текст, `make_e4.py`).
@MainActor
final class DocE4Tests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/DocE4", isDirectory: true)

    static func fixture() throws -> String {
        EditorDocument(data: try Data(contentsOf: folder.appendingPathComponent("01-form-e4.rtf"))).decodedText
    }

    static func shown(_ source: String) -> (String, DocRendering) {
        let (rendering, patch) = DocRenderer().render(RTFReader.read(source as NSString), previous: nil)
        return (patch.string.string, rendering)
    }

    /// Применить план команды формата и проверить без потерь.
    func applying(_ result: Result<FormatPlan, FormatFailure>, to source: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let plan: FormatPlan
        switch result {
        case .success(let success): plan = success
        case .failure(let failure):
            XCTFail("команда отказала: \(failure.reason)", file: file, line: line)
            throw failure
        }
        let edits = try XCTUnwrap(FormatCheck.merged(plan.edits), file: file, line: line).map { DocEdit(range: $0.range, text: $0.string) }
        return check(source, edits: edits, file: file, line: line)
    }

    func check(_ source: String, edits: [DocEdit], file: StaticString = #filePath, line: UInt = #line) -> String {
        let outcome = DocListsTests.Outcome(source: DocListText.applied(edits, to: source as NSString) as String, edits: edits, caret: 0)
        for problem in DocListsTests.violations(source, outcome, synced: false) { XCTFail(problem, file: file, line: line) }
        return outcome.source
    }

    /// Кусок исходника показанного текста `text` (или его единиц `offset`…`offset + length`).
    static func span(_ source: String, of text: String, offset: Int = 0, length: Int? = nil) -> NSRange {
        let (shown, rendering) = Self.shown(source)
        let found = (shown as NSString).range(of: text)
        return rendering.map.sourceRange(ofUnits: NSRange(location: found.location + offset, length: length ?? found.length))
    }

    static func runs(_ source: String, containing text: String) -> [RTFRun] {
        RTFReader.read(source as NSString).body.paragraphs.flatMap(\.runs).filter { $0.kind == .text && $0.text.contains(text) }
    }

    // MARK: - Символы

    func testSuperscriptSubscriptSmallCapsCapsHidden() throws {
        var source = try Self.fixture()
        let model = { RTFReader.read(source as NSString) }
        // «участка» — надстрочным, затем обычным; подстрочный; капитель; все прописные; скрытый и обратно.
        source = try applying(FormatEdits.character(.vertical(.superscript), span: Self.span(source, of: "участка"), source: source as NSString,
                                                    model: model()), to: source)
        XCTAssertEqual(Self.runs(source, containing: "участка").first?.props.vertical, .superscript)
        source = try applying(FormatEdits.character(.vertical(.normal), span: Self.span(source, of: "участка"), source: source as NSString,
                                                    model: model()), to: source)
        XCTAssertEqual(Self.runs(source, containing: "участка").first?.props.vertical, .normal)
        // Уже надстрочная «2» — обычной: код `\super` в начале её группы меняется на `\nosupersub`.
        source = try applying(FormatEdits.character(.vertical(.normal), span: Self.span(source, of: "м2", offset: 1, length: 1),
                                                    source: source as NSString, model: model()), to: source)
        XCTAssertTrue(source.contains("{\\nosupersub 2}"), "замена кода в начале группы")
        source = try applying(FormatEdits.character(.vertical(.subscript), span: Self.span(source, of: "счётчику"), source: source as NSString,
                                                    model: model()), to: source)
        XCTAssertEqual(Self.runs(source, containing: "счётчику").first?.props.vertical, .subscript)
        source = try applying(FormatEdits.character(.smallCaps(true), span: Self.span(source, of: "Второй"), source: source as NSString,
                                                    model: model()), to: source)
        XCTAssertEqual(Self.runs(source, containing: "Второй").first?.props.smallCaps, true)
        // Капитель на странице — прописными.
        source = try applying(FormatEdits.character(.smallCaps(false), span: Self.span(source, of: "СВЕДЕНИЯ"), source: source as NSString,
                                                    model: model()), to: source)
        XCTAssertEqual(Self.runs(source, containing: "Сведения").first?.props.smallCaps, false)
        source = try applying(FormatEdits.character(.caps(true), span: Self.span(source, of: "Последний"), source: source as NSString,
                                                    model: model()), to: source)
        XCTAssertEqual(Self.runs(source, containing: "Последний").first?.props.caps, true)
        XCTAssertTrue(Self.shown(source).0.contains("ПОСЛЕДНИЙ"), "все прописные — на странице прописными")
        source = try applying(FormatEdits.character(.hidden(true), span: Self.span(source, of: "формы"), source: source as NSString,
                                                    model: model()), to: source)
        XCTAssertFalse(Self.shown(source).0.contains("формы."), "скрытый текст без ¶ не виден")
        XCTAssertEqual(Self.runs(source, containing: "формы").first?.props.hidden, true)
    }

    func testFormatStateShowsNewProps() throws {
        let source = try Self.fixture()
        let (rendering, patch) = DocRenderer().render(RTFReader.read(source as NSString), previous: nil)
        _ = rendering
        let shown = patch.string.string as NSString
        let two = shown.range(of: "м2").location + 1
        XCTAssertEqual(DocFormatter.state(in: patch.string, selection: NSRange(location: two, length: 1)).vertical, .superscript)
        let caps = shown.range(of: "СВЕДЕНИЯ")
        XCTAssertTrue(DocFormatter.state(in: patch.string, selection: caps).smallCaps)
    }

    // MARK: - Абзац

    func testParagraphFlagsOnAndOff() throws {
        var source = try Self.fixture()
        let model = { RTFReader.read(source as NSString) }
        let paragraph = { (text: String) -> Int in
            try XCTUnwrap(model().body.paragraphs.firstIndex { $0.plainText.contains(text) })
        }
        // Включить у абзаца со своим `\pard` — код сразу после него.
        let last = try paragraph("Последний")
        source = try applying(FormatEdits.flag(.keepNext, on: true, paragraphs: [last], source: source as NSString, model: model()), to: source)
        XCTAssertTrue(model().body.paragraphs[last].props.keepNext)
        source = try applying(FormatEdits.flag(.pageBreakBefore, on: true, paragraphs: [last], source: source as NSString, model: model()), to: source)
        XCTAssertTrue(model().body.paragraphs[last].props.pageBreakBefore)
        XCTAssertEqual(Self.shown(source).0.components(separatedBy: "\u{0C}").count - 1, 2, "ещё один разрыв перед абзацем")
        // Снять — свой код вырезается.
        let title = try paragraph("ЗАЯВЛЕНИЕ")
        let before = source
        source = try applying(FormatEdits.flag(.keepNext, on: false, paragraphs: [title], source: source as NSString, model: model()), to: source)
        XCTAssertFalse(model().body.paragraphs[title].props.keepNext)
        XCTAssertEqual((before as NSString).length - (source as NSString).length, ("\\keepn " as NSString).length)
        let keep = try paragraph("не разрывается")
        source = try applying(FormatEdits.flag(.keepTogether, on: false, paragraphs: [keep], source: source as NSString, model: model()), to: source)
        XCTAssertFalse(model().body.paragraphs[keep].props.keepTogether)
        let appendix = try paragraph("Приложение")
        source = try applying(FormatEdits.flag(.pageBreakBefore, on: false, paragraphs: [appendix], source: source as NSString, model: model()), to: source)
        XCTAssertFalse(model().body.paragraphs[appendix].props.pageBreakBefore)
        // Абзац без своего `\pard` наследует свойства соседа: флаг первого перешёл бы и ко второму, а снять его у второго
        // без `\pard` нечем (`\keep0` RTF не определяет) — отказ, исходник не меняется.
        let first = try paragraph("Площадь")
        guard case .failure(let failure) = FormatEdits.flag(.keepTogether, on: true, paragraphs: [first], source: source as NSString,
                                                            model: model()) else { return XCTFail("флаг ушёл бы к наследнику") }
        XCTAssertEqual(failure.reason, "Изменились свойства другого абзаца")
        // У обоих сразу — можно: код у первого, второй его наследует.
        source = try applying(FormatEdits.flag(.keepTogether, on: true, paragraphs: [first, first + 1], source: source as NSString, model: model()),
                              to: source)
        XCTAssertTrue(model().body.paragraphs[first].props.keepTogether && model().body.paragraphs[first + 1].props.keepTogether)
    }

    // MARK: - Разрыв страницы

    func testInsertPageBreak() throws {
        let source = try Self.fixture()
        let model = RTFReader.read(source as NSString)
        let (shown, rendering) = Self.shown(source)
        let at = (shown as NSString).range(of: "Второй").location
        let result = DocTextEditor.replace(NSRange(location: at, length: 0), with: "\u{0C}", model: model, map: rendering.map, source: source as NSString)
        XCTAssertNil(result.refusal)
        XCTAssertTrue(result.edits.contains { $0.text.contains("\\page ") })
        let after = check(source, edits: result.edits)
        let paragraph = try XCTUnwrap(RTFReader.read(after as NSString).body.paragraphs.first { $0.plainText.contains("Второй") })
        XCTAssertEqual(paragraph.runs.first?.kind, .pageBreak)
        XCTAssertTrue(Self.shown(after).0.contains("\u{0C}Второй"))
        // В ячейке — отказ.
        let cell = (shown as NSString).range(of: "Иванова").location
        let refused = DocTextEditor.replace(NSRange(location: cell, length: 0), with: "\u{0C}", model: model, map: rendering.map, source: source as NSString)
        XCTAssertNotNil(refused.refusal)
        XCTAssertTrue(refused.edits.isEmpty)
    }

    // MARK: - Поля

    func testUpdateFields() throws {
        let source = try Self.fixture()
        let model = RTFReader.read(source as NSString)
        let values = DocFieldUpdate.Values(page: { _ in 2 }, total: 3, sectionPages: { _ in 3 })
        let result = DocFieldUpdate.edits(model: model, source: source as NSString, values: values)
        XCTAssertEqual(result.fields, 4, "PAGE и NUMPAGES в колонтитуле и в тексте")
        XCTAssertEqual(result.updated, 3, "PAGE колонтитула — на каждой странице свой, не трогается")
        let after = check(source, edits: result.edits)
        XCTAssertTrue(after.contains(#"{\fldrslt {\f0 7}}"#), "PAGE колонтитула как был")
        XCTAssertTrue(after.contains(#"{\fldrslt {\f0 3}}"#), "NUMPAGES колонтитула")
        XCTAssertTrue(after.contains(#"{\fldrslt {3}}"#) && after.contains(#"{\fldrslt {2}}"#), "поля в тексте")
        // Второй раз — нечего менять.
        XCTAssertTrue(DocFieldUpdate.edits(model: RTFReader.read(after as NSString), source: after as NSString, values: values).edits.isEmpty)
        // Двузначное число и результат из двух прогонов: число — в первый, текст второго вырезается.
        let split = source.replacingOccurrences(of: #"{\fldrslt {5}}"#, with: #"{\fldrslt {5}{\b 1}}"#)
        let edits = DocFieldUpdate.edits(model: RTFReader.read(split as NSString), source: split as NSString,
                                         values: DocFieldUpdate.Values(page: { _ in 2 }, total: 12, sectionPages: { _ in 12 })).edits
        let updated = check(split, edits: edits)
        XCTAssertTrue(updated.contains(#"{\fldrslt {12}{\b }}"#), updated)
    }

    // MARK: - Случайные команды

    /// Случайная команда E-4 на месте `units` показанного текста; `nil` — команда отказала (это не ошибка).
    static func randomCommand(_ source: String, random: inout SeededRandom, encoding: TextEncoding = .windows1252,
                              renderer: DocRenderer, previous: inout DocRendering?) -> [DocEdit]? {
        let model = RTFReader.read(source as NSString, fallback: encoding)
        let (rendering, _) = renderer.render(model, previous: previous)
        previous = rendering
        let count = rendering.map.count
        guard count > 2 else { return nil }
        let location = random.next(count - 1)
        let length = 1 + random.next(min(12, count - location))
        let units = NSRange(location: location, length: length)
        let span = rendering.map.sourceRange(ofUnits: units)
        let paragraphs = Array(Set([rendering.paragraph(atUnit: location), rendering.paragraph(atUnit: location + length - 1)].compactMap { $0 })).sorted()
        let changes: [CharChange] = [.vertical(.superscript), .vertical(.subscript), .vertical(.normal), .smallCaps(true), .smallCaps(false),
                                     .caps(true), .caps(false), .hidden(true), .hidden(false)]
        let choice = random.next(changes.count + 4)
        let plan: Result<FormatPlan, FormatFailure>
        if choice < changes.count {
            plan = FormatEdits.character(changes[choice], span: span, source: source as NSString, model: model)
        } else if choice < changes.count + 3 {
            let flag = DocParaFlag.allCases[choice - changes.count]
            let on = !(paragraphs.allSatisfy { model.body.paragraphs[safe: $0].map { flag.value($0.props) } ?? false })
            plan = FormatEdits.flag(flag, on: on, paragraphs: paragraphs, source: source as NSString, model: model)
        } else {
            let result = DocTextEditor.replace(NSRange(location: location, length: 0), with: "\u{0C}", model: model, map: rendering.map,
                                               source: source as NSString)
            return result.refusal == nil && !result.edits.isEmpty ? result.edits : nil
        }
        guard case .success(let success) = plan, let merged = FormatCheck.merged(success.edits), !merged.isEmpty else { return nil }
        return merged.map { DocEdit(range: $0.range, text: $0.string) }
    }

    func testRandomCommandsLossless() throws {
        var random = SeededRandom(seed: 4_404)
        var applied = 0, refused = 0
        let sources = [try Self.fixture()] + (try DocListsTests.fixtures.map { try DocListsTests.fixture($0) })
        for original in sources {
            var source = original
            var previous: DocRendering?
            let renderer = DocRenderer()
            for _ in 0..<250 {
                guard let edits = Self.randomCommand(source, random: &random, renderer: renderer, previous: &previous) else {
                    refused += 1
                    continue
                }
                source = check(source, edits: edits)
                applied += 1
            }
        }
        print("[e4] случайные команды на фикстурах: применено \(applied), отказ или нечего менять \(refused)")
        XCTAssertGreaterThan(applied, 300)
    }

    /// На копиях форм (`MU_REAL_FRM_DIR`): по 100 случайных команд на каждой, без потерь. Только числа.
    func testRandomCommandsOnCopies() throws {
        var random = SeededRandom(seed: 4_405)
        var files = 0, applied = 0, refused = 0, violations = 0
        for url in try DocRealFilesTests.copies() {
            let document = EditorDocument(data: try Data(contentsOf: url))
            guard RTFReader.read(document.decodedText as NSString, fallback: document.encoding).isRTF else { continue }
            files += 1
            var source = document.decodedText
            let renderer = DocRenderer()
            var previous: DocRendering?
            for _ in 0..<100 {
                guard let edits = Self.randomCommand(source, random: &random, encoding: document.encoding, renderer: renderer, previous: &previous) else {
                    refused += 1
                    continue
                }
                let outcome = DocListsTests.Outcome(source: DocListText.applied(edits, to: source as NSString) as String, edits: edits, caret: 0)
                let before = EditorDocument(data: (try? document.data(for: source)) ?? Data())
                violations += DocListsTests.violations(source, outcome, synced: false, document: before).isEmpty ? 0 : 1
                source = outcome.source
                applied += 1
            }
        }
        print("[e4-real] копий \(files), применено \(applied), отказ или нечего менять \(refused), нарушений \(violations)")
        XCTAssertEqual(violations, 0)
    }
}

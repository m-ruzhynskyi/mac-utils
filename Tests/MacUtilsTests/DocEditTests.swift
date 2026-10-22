import AppKit
import XCTest
@testable import MacUtils

/// Правка текста в «Документе» (D-3): каждая команда — точечные правки исходника. Проверки «без потерь»:
/// правки только в окне затронутых абзацев, скобок не хуже, наш разбор и Cocoa открывают, видимый текст ожидаемый,
/// обратная правка возвращает байты.
@MainActor
final class DocEditTests: XCTestCase {
    /// Исходник и его показ; `edit` применяет правку и проверяет её.
    @MainActor
    struct Harness {
        var source: String
        let renderer = DocRenderer()

        var model: RTFDocumentModel { RTFReader.read(source as NSString) }

        func display() -> (String, DocSourceMap) {
            let (rendering, patch) = renderer.render(model, previous: nil)
            return (patch.string.string, rendering.map)
        }

        /// Применить правку к показанным единицам; вернуть результат (правки уже применены к `source`).
        @discardableResult
        mutating func edit(_ units: NSRange, _ text: String, check: Bool = true, file: StaticString = #filePath,
                           line: UInt = #line) -> DocTextEditor.Result {
            let before = source as NSString
            let model = self.model
            let (shown, map) = display()
            let result = DocTextEditor.replace(units, with: text, model: model, map: map, source: before)
            guard result.refusal == nil, !result.edits.isEmpty else { return result }
            let after = NSMutableString(string: source)
            var undo: [(NSRange, String)] = []
            var shift = 0
            for edit in result.edits.sorted(by: { $0.range.location < $1.range.location }) {
                let location = edit.range.location + shift
                undo.append((NSRange(location: location, length: (edit.text as NSString).length), before.substring(with: edit.range)))
                after.replaceCharacters(in: NSRange(location: location, length: edit.range.length), with: edit.text)
                shift += (edit.text as NSString).length - edit.range.length
            }
            source = after as String
            guard check else { return result }
            DocEditTests.checkLossless(before: before, after: after, edits: result.edits, model: model, map: map, units: units, file: file, line: line)
            // Видимый текст: старый без удалённых единиц, набранное — на месте ввода. Номера списков (`listText`) не
            // сравниваются — их пересчитывает нумерация (↩ в пункте даёт номер новому); регистр — тоже (капитель `\caps`).
            var expected = Array((shown as NSString).utf16Units())
            var numbers = (0..<expected.count).map { map.kind(at: $0) == .listText }
            let removedBefore = result.deletedUnits.filter { $0 < result.insertionUnit }.count
            for unit in result.deletedUnits.sorted(by: >) {
                expected.remove(at: unit)
                numbers.remove(at: unit)
            }
            let typed = Array(DocEditTests.shownForm(text).utf16)
            let at = min(expected.count, max(0, result.insertionUnit - removedBefore))
            expected.insert(contentsOf: typed, at: at)
            numbers.insert(contentsOf: Array(repeating: false, count: typed.count), at: at)
            let (now, newMap) = display()
            let nowUnits = Array((now as NSString).utf16Units())
            let nowNumbers = (0..<nowUnits.count).map { newMap.kind(at: $0) == .listText }
            // Разрывы «\f» сравниваем отдельно: ↩ в абзаце с `\pagebb` даёт разрыв и новому абзацу (свойства переходят, как в Word).
            func plain(_ units: ArraySlice<UInt16>, _ skip: ArraySlice<Bool>) -> [UInt16] {
                zip(units, skip).filter { !$1 && $0 != 0x0C }.map(\.0)
            }
            let expectedText = String(utf16CodeUnits: plain(expected[...], numbers[...]), count: plain(expected[...], numbers[...]).count)
            let nowText = String(utf16CodeUnits: plain(nowUnits[...], nowNumbers[...]), count: plain(nowUnits[...], nowNumbers[...]).count)
            XCTAssertEqual(nowText.lowercased(), expectedText.lowercased(), "видимый текст после правки", file: file, line: line)
            // Курсор — сразу после набранного (без разрывов «\f» и номеров списков).
            let caret = newMap.firstUnit(atOrAfter: result.caretSource)
            let expectedCaret = min(expected.count, at + typed.count)
            XCTAssertEqual(plain(nowUnits.prefix(caret), nowNumbers.prefix(caret)).count,
                           plain(expected.prefix(expectedCaret), numbers.prefix(expectedCaret)).count, "курсор", file: file, line: line)
            // Отмена (обратная правка) — байт в байт.
            let restored = NSMutableString(string: source)
            for (range, text) in undo.reversed() { restored.replaceCharacters(in: range, with: text) }
            XCTAssertEqual(restored as String, before as String, "отмена — байт в байт", file: file, line: line)
            return result
        }
    }

    /// Как набранное выглядит на странице (переводы строк — абзацы).
    static func shownForm(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n").replacingOccurrences(of: "\u{0B}", with: "\u{2028}")
            .filter { !($0.asciiValue.map { $0 < 0x20 && $0 != 0x0A && $0 != 0x09 } ?? false) }
    }

    /// Правки — только в окне затронутых абзацев (± соседний при склейке); скобок не хуже; разбор и Cocoa открывают.
    static func checkLossless(before: NSString, after: NSString, edits: [DocEdit], model: RTFDocumentModel, map: DocSourceMap,
                              units: NSRange, file: StaticString, line: UInt) {
        let paragraphs = model.body.paragraphs
        let firstSource = map.sourceLocation(beforeUnit: units.location)
        let lastSource = map.sourceLocation(beforeUnit: NSMaxRange(units))
        let first = paragraphs.firstIndex { NSMaxRange($0.endRange) >= firstSource } ?? 0
        let last = min(paragraphs.count - 1, (paragraphs.firstIndex { NSMaxRange($0.endRange) >= lastSource } ?? paragraphs.count - 1) + 1)
        // Окно: от начала области первого затронутого абзаца до конца следующего за последним (склейка).
        let start = paragraphs.isEmpty ? 0 : min(paragraphs[first].regionStart, firstSource)
        let end = paragraphs.isEmpty ? before.length : max(NSMaxRange(paragraphs[last].endRange), lastSource)
        let window = NSRange(location: start, length: end - start)
        let fields = model.fields.map(\.group)
        for edit in edits {
            let inside = NSIntersectionRange(edit.range, window) == edit.range
                || (edit.range.length == 0 && edit.range.location >= window.location && edit.range.location <= NSMaxRange(window))
                || fields.contains { NSIntersectionRange(edit.range, $0) == edit.range || $0 == edit.range }
            XCTAssertTrue(inside, "правка \(edit.range) вне окна абзацев \(window)", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(DollarMarks.unbalancedBraces(in: after), DollarMarks.unbalancedBraces(in: before), "скобки", file: file, line: line)
        let reread = RTFReader.read(after)
        XCTAssertTrue(reread.isRTF, file: file, line: line)
        if let original = before.data(using: String.Encoding.ascii.rawValue), (try? NSAttributedString(data: original, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)) != nil,
           let data = after.data(using: String.Encoding.ascii.rawValue) {
            XCTAssertNotNil(try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
                            "Cocoa открывает", file: file, line: line)
        }
    }

    private func units(_ harness: Harness, of text: String) -> NSRange {
        (harness.display().0 as NSString).range(of: text)
    }

    // MARK: - Ввод и кодовые страницы

    func testTypingCyrillicByCodePage() throws {
        // cp1251 (`\ansicpg1251`, шрифт `\fcharset204`) — `\'hh`, как пишет Word.
        var cyr = Harness(source: DocReaderTests.letter)
        let at = units(cyr, of: "Заключение")
        cyr.edit(NSRange(location: NSMaxRange(at), length: 0), " Привет")
        XCTAssertTrue(cyr.source.contains(#" \'cf\'f0\'e8\'e2\'e5\'f2"#), "кириллица в cp1251 — \\'hh")
        // Символа нет в cp1251 — `\uN` с заменителем.
        cyr.edit(NSRange(location: NSMaxRange(units(cyr, of: "Привет")), length: 0), "ő")
        XCTAssertTrue(cyr.source.contains("\\" + "u337" + #"\'3f"#))
        // cp1252 (`\ansicpg1252`) — кириллица `\uN\'3f`.
        var latin = Harness(source: DocReaderTests.table)
        latin.edit(NSRange(location: NSMaxRange(units(latin, of: "Before")), length: 0), "Я")
        XCTAssertTrue(latin.source.contains("\\" + "u1071" + #"\'3f"#))
        // Служебные знаки экранируются, табуляция и разрыв строки — коды.
        latin.edit(NSRange(location: 0, length: 0), "{x}\\\t")
        XCTAssertTrue(latin.source.contains(#"\{x\}\\\tab "#))
    }

    func testTypingInheritsFormattingOfPreviousCharacter() throws {
        var harness = Harness(source: DocReaderTests.letter)
        let pe = units(harness, of: "Pe")
        harness.edit(NSRange(location: NSMaxRange(pe), length: 0), "X")
        XCTAssertTrue(harness.source.contains(#"{\i PeX}"#), "после «Pe» — в той же группе (курсив)")
        let model = harness.model
        let run = model.body.paragraphs[1].runs.first { $0.text.contains("PeX") }
        XCTAssertEqual(run?.props.italic, true)
    }

    func testDeleteInsideRunsKeepsCodes() throws {
        var harness = Harness(source: DocReaderTests.letter)
        // «Ivan» разорван группами: `{\f1\fs20 Iv}{\rtlch\insrsid99 an }` — удаляем «va».
        let iv = units(harness, of: "Ivan")
        let result = harness.edit(NSRange(location: iv.location + 1, length: 2), "")
        XCTAssertEqual(result.edits.count, 2)
        XCTAssertTrue(harness.source.contains(#"{\f1\fs20 I}{\rtlch\insrsid99 n }"#), "коды и группы на месте")
    }

    func testEnterAndShiftEnter() throws {
        var harness = Harness(source: DocReaderTests.letter)
        harness.edit(NSRange(location: NSMaxRange(units(harness, of: "Iv")), length: 0), "\n")
        XCTAssertTrue(harness.source.contains(#"Iv\par }"#))
        XCTAssertEqual(harness.model.body.paragraphs[1].props.left, 567, "новый абзац — со свойствами текущего")
        XCTAssertEqual(harness.model.body.paragraphs[2].props.left, 567)
        harness.edit(NSRange(location: NSMaxRange(units(harness, of: "Pe")), length: 0), "\u{2028}")
        XCTAssertTrue(harness.source.contains(#"Pe\line }"#))
    }

    // MARK: - Абзацы и таблицы

    func testDeletingParagraphMarkKeepsFirstParagraphProps() throws {
        var harness = Harness(source: DocReaderTests.letter)
        let (shown, map) = harness.display()
        // Конец первого абзаца (по центру) — склеиваем со вторым (слева, отступ 567).
        let end = (shown as NSString).range(of: "\n").location
        XCTAssertEqual(map.kind(at: end), .paragraphEnd)
        harness.edit(NSRange(location: end, length: 1), "")
        let model = harness.model
        XCTAssertEqual(model.body.paragraphs.count, 2)
        XCTAssertEqual(model.body.paragraphs[0].props.alignment, .center, "свойства — первого абзаца")
        XCTAssertEqual(model.body.paragraphs[0].props.left, 0)
        XCTAssertTrue(model.body.paragraphs[0].plainText.hasPrefix("ЗаключениеIv"))
    }

    func testTableCellsStay() throws {
        var harness = Harness(source: DocReaderTests.table)
        // Выделение от «fore» до середины первой ячейки: конец абзаца перед таблицей и сами ячейки остаются.
        let shown = harness.display().0 as NSString
        let from = shown.range(of: "fore").location
        let to = NSMaxRange(shown.range(of: "B1b"))
        let result = harness.edit(NSRange(location: from, length: to - from), "")
        XCTAssertFalse(result.edits.isEmpty)
        let model = harness.model
        XCTAssertEqual(model.body.tables.first?.rows.count, 2, "строки таблицы целы")
        XCTAssertEqual(model.body.tables.first?.rows.first?.paragraphs.count, 2, "ячейки целы")
        XCTAssertTrue(DocReaderTests.visibleText(model.body).hasPrefix("Be\n\u{7}\u{7}"), "текст ячеек стёрт, абзацы ячейки — склеены внутри неё")
        // Только конец ячейки — не удаляется, как в Word: без правок и без подсказки «в коде».
        let cellEnd = (harness.display().0 as NSString).range(of: "\n", options: [], range: NSRange(location: 3, length: 5)).location
        let refused = DocTextEditor.replace(NSRange(location: cellEnd, length: 1), with: "", model: model, map: harness.display().1,
                                            source: harness.source as NSString)
        XCTAssertNil(refused.refusal)
        XCTAssertTrue(refused.edits.isEmpty)
    }

    func testEnterInsideTableCell() throws {
        var harness = Harness(source: DocReaderTests.table)
        harness.edit(NSRange(location: NSMaxRange(units(harness, of: "A1")), length: 0), "\n")
        let model = harness.model
        XCTAssertEqual(model.body.tables.first?.rows.first?.paragraphs.first?.count, 2, "\\par внутри ячейки — второй абзац ячейки")
    }

    // MARK: - Поля и разделители

    static let fieldDoc = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}\pard\plain Page {\field{\*\fldinst PAGE}{\fldrslt 7}} end {\cf2x5} and {\b\'e9}\par}"#

    func testComputedFieldIsAtomic() throws {
        var harness = Harness(source: Self.fieldDoc)
        let seven = units(harness, of: "7")
        let result = harness.edit(NSRange(location: seven.location, length: 0), "Z")
        XCTAssertTrue(harness.source.contains(#"{\fldrslt 7}}Z end"#) || harness.source.contains(#"Page Z{\field"#), "вне поля")
        XCTAssertNil(result.refusal)
        // Выделение через поле — поле удаляется целиком.
        let shown = harness.display().0 as NSString
        let span = shown.range(of: "Z7 ")
        harness.edit(span, "")
        XCTAssertFalse(harness.source.contains("fldinst"), "поле удалено целиком")
    }

    func testControlWordDelimiters() throws {
        var harness = Harness(source: Self.fieldDoc)
        // `{\cf2x5}`: после удаления «x» иначе вышло бы `\cf25`.
        let x = units(harness, of: "x5")
        harness.edit(NSRange(location: x.location, length: 1), "")
        XCTAssertTrue(harness.source.contains(#"{\cf2 5}"#))
        XCTAssertEqual(harness.model.body.paragraphs[0].runs.first { $0.text == "5" }?.props.color, 2)
        // Ввод в начало абзаца перед `\'e9` после `\b` без разделителя: «old» не должно стать словом `\bold`.
        var bold = Harness(source: #"{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}\pard\plain {\b\'e9}\par}"#)
        bold.edit(NSRange(location: 0, length: 0), "old")
        XCTAssertTrue(bold.source.contains(#"{\b old\'e9}"#))
        XCTAssertEqual(bold.model.body.paragraphs[0].runs.first?.text, "oldé")
        XCTAssertEqual(bold.model.body.paragraphs[0].runs.first?.props.bold, true, "свойства — первого символа абзаца")
    }

    func testObjectsAreNotDeleted() throws {
        var harness = Harness(source: DocReaderTests.objects)
        let (shown, map) = harness.display()
        let object = (shown as NSString).range(of: "\u{FFFC}")
        XCTAssertEqual(map.kind(at: object.location), .object)
        let result = DocTextEditor.replace(object, with: "", model: harness.model, map: map, source: harness.source as NSString)
        XCTAssertNotNil(result.refusal, "рисунок не удаляется — «Изменить в коде»")
        // Выделение с рисунком: удаляется текст, рисунок остаётся.
        harness.edit(NSRange(location: 0, length: object.location + 1), "")
        XCTAssertTrue(harness.source.contains("pngblip"))
    }

    // MARK: - Случайные правки

    /// 300 случайных вставок и удалений (семя) на каждом демо-документе — проверки «без потерь» на каждом шаге.
    func testRandomEditsStayLossless() throws {
        let documents = [DocReaderTests.letter, DocReaderTests.table, DocReaderTests.headers, DocReaderTests.objects, Self.fieldDoc,
                         DocDemo.expertReport]
        let pieces = ["a", "Я", "1", " ", "\n", "\t", "ő", "{", "}", "\\", "\u{2028}", "", "", "Демо текст", "—"]
        var random = SeededRandom(seed: 20_261_020)
        for (number, document) in documents.enumerated() {
            var harness = Harness(source: document)
            for step in 0..<300 {
                let count = harness.display().1.count
                guard count > 0 else { break }
                let location = random.next(count + 1)
                let length = random.next(4) == 0 ? random.next(min(12, count - min(location, count)) + 1) : 0
                let text = pieces[random.next(pieces.count)]
                let range = NSRange(location: location, length: min(length, count - min(location, count)))
                harness.edit(range, text, file: #filePath, line: #line)
                if step % 100 == 99 { XCTAssertTrue(RTFReader.read(harness.source).isRTF, "документ \(number), шаг \(step)") }
            }
        }
    }

    // MARK: - Фикстуры тестировщика (если есть)

    func testTesterFixturesRandomEdits() throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: DocReaderTests.testerFolder.path) else {
            throw XCTSkip("Нет фикстур тестировщика Tests/Fixtures/DocView")
        }
        var random = SeededRandom(seed: 7)
        var checked = 0
        for name in names.sorted() where name.hasSuffix(".rtf") || name.hasSuffix(".frm") {
            let data = try Data(contentsOf: DocReaderTests.testerFolder.appendingPathComponent(name))
            guard let text = EditorDocument(data: data).decodedText as String?, text.utf16.count < 40_000 else { continue }
            var harness = Harness(source: text)
            for _ in 0..<60 {
                let count = harness.display().1.count
                let location = random.next(count + 1)
                let length = random.next(3) == 0 ? random.next(min(8, count - min(location, count)) + 1) : 0
                harness.edit(NSRange(location: location, length: length), ["x", "Ж", "\n", "", " "][random.next(5)])
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10)
    }
}

/// Повторяемые случайные числа (семя).
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

    mutating func next(_ bound: Int) -> Int {
        guard bound > 1 else { return 0 }
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}

extension NSString {
    func utf16Units() -> [UInt16] {
        var units = [UInt16](repeating: 0, count: length)
        if length > 0 { units.withUnsafeMutableBufferPointer { getCharacters($0.baseAddress!, range: NSRange(location: 0, length: length)) } }
        return units
    }
}

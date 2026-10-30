import AppKit
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUTextEditor

/// Списки в «Документе» (E-2): номера по `\listtable`/`\listoverridetable`/`\ls`/`\ilvl`, как у Word, и правка пунктов
/// без потерь. Фикстуры — `Tests/Fixtures/DocLists` (выдуманный текст, структура — как у форм; `make_lists.py`).
@MainActor
final class DocListsTests: XCTestCase {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/DocLists", isDirectory: true)

    static func fixture(_ name: String) throws -> String {
        EditorDocument(data: try Data(contentsOf: folder.appendingPathComponent(name))).decodedText
    }

    static let fixtures = ["01-word-numbered.rtf", "02-generated-no-listtext.rtf", "03-table-roman.rtf"]

    /// Номера пунктов по порядку абзацев.
    static func numbers(_ source: String) -> [String] {
        let model = RTFReader.read(source as NSString)
        let labels = DocListNumbers.labels(model.body, lists: model.lists)
        return labels.keys.sorted().compactMap { labels[$0]?.number }
    }

    /// Видимый текст абзаца без номера (для поиска пункта).
    static func paragraph(_ source: String, containing text: String) -> Int? {
        RTFReader.read(source as NSString).body.paragraphs.firstIndex { $0.runs.filter { $0.kind == .text }.map(\.text).joined().contains(text) }
    }

    // MARK: - Разбор

    func testReadsListTableAndOverrides() throws {
        let model = RTFReader.read(try Self.fixture("02-generated-no-listtext.rtf") as NSString)
        XCTAssertEqual(model.lists.lists.count, 2)
        XCTAssertEqual(model.lists.overrides.count, 4)
        let multi = try XCTUnwrap(model.lists.lists[201])
        XCTAssertEqual(multi.levels.count, 9)
        XCTAssertEqual(multi.levels[1].text, [0, 0x2E, 1, 0x2E], "шаблон «%1.%2.»")
        XCTAssertEqual(multi.levels[1].placeholders, [0: 0, 2: 1])
        XCTAssertEqual(multi.levels[1].left, 792)
        XCTAssertEqual(multi.levels[1].firstLine, -432)
        XCTAssertEqual(multi.levels[2].format, 4)
        let bullet = try XCTUnwrap(model.lists.lists[202]?.levels.first)
        XCTAssertEqual(bullet.format, 23)
        XCTAssertEqual(bullet.text, [0xF0B7], "маркер `\\u-3913 ?` — без заменителя")
        XCTAssertEqual(bullet.char.font, 2)
        XCTAssertEqual(model.lists.overrides[4]?.listID, 201)
        XCTAssertEqual(model.lists.overrides[4]?.starts, [0: 7])
        let paragraph = try XCTUnwrap(Self.paragraph(try Self.fixture("02-generated-no-listtext.rtf"), containing: "две фотографии"))
        XCTAssertEqual(model.body.paragraphs[paragraph].props.list, 2)
        XCTAssertEqual(model.body.paragraphs[paragraph].props.listLevel, 0)
    }

    func testFormats() {
        XCTAssertEqual(DocListNumbers.formatted(14, format: 1), "XIV")
        XCTAssertEqual(DocListNumbers.formatted(9, format: 2), "ix")
        XCTAssertEqual(DocListNumbers.formatted(28, format: 3), "BB", "после z — двойные буквы, как в Word")
        XCTAssertEqual(DocListNumbers.formatted(3, format: 4), "c")
        XCTAssertEqual(DocListNumbers.formatted(7, format: 22), "07")
        XCTAssertEqual(DocListNumbers.formatted(5, format: 255), "")
        XCTAssertEqual(DocListNumbers.formatted(5, format: 0), "5")
    }

    // MARK: - Номера

    func testNumbersLikeWord() throws {
        XCTAssertEqual(Self.numbers(try Self.fixture("01-word-numbered.rtf")), ["1.", "1.1.", "1.2.", "a)", "b)", "2.", "2.1."])
        // Два `\ls` одного списка продолжают нумерацию; `\listoverridestartat` начинает уровень с 7; маркер Symbol — «•».
        XCTAssertEqual(Self.numbers(try Self.fixture("02-generated-no-listtext.rtf")), ["1.", "2.", "\u{2022}", "\u{2022}", "3.", "7."])
        // В ячейках таблицы счёт общий с текстом; римские.
        XCTAssertEqual(Self.numbers(try Self.fixture("03-table-roman.rtf")), ["1.", "2.", "3.", "I.", "II."])
    }

    func testListTextIsNotShownComputedNumberIs() throws {
        // Готовый номер в файле нарочно неверный: Word его не читает — и мы показываем посчитанный.
        let source = try Self.fixture("01-word-numbered.rtf").replacingOccurrences(of: #"\f0\fs24 2.\tab}"#, with: #"\f0\fs24 9.\tab}"#)
        let renderer = DocRenderer()
        let (rendering, patch) = renderer.render(RTFReader.read(source as NSString), previous: nil)
        let shown = patch.string.string
        XCTAssertTrue(shown.contains("2.\t\u{041A}онтакты"), "посчитанный номер и табуляция перед текстом")
        XCTAssertFalse(shown.contains("9."), "готовый \\listtext не показан")
        XCTAssertTrue(shown.contains("1.1.\t"))
        let at = (shown as NSString).range(of: "2.\t\u{041A}")
        XCTAssertEqual(rendering.map.kind(at: at.location), .listText)
        XCTAssertEqual(rendering.map.kind(at: at.location + 2), .listText, "табуляция после номера — часть номера")
        XCTAssertEqual(rendering.map.kind(at: at.location + 3), .text)
        // Номер — без маркера Symbol (знак Юникода) и с табуляцией на отступе.
        let bullets = renderer.render(RTFReader.read(try Self.fixture("02-generated-no-listtext.rtf") as NSString), previous: nil).1.string
        XCTAssertTrue(bullets.string.contains("\u{2022}\t"))
        let index = (bullets.string as NSString).range(of: "\u{2022}\t").location
        let style = try XCTUnwrap(bullets.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertTrue(style.tabStops.contains { abs($0.location - 36) < 0.01 }, "табуляция на отступе 720 твипов")
        XCTAssertEqual(style.headIndent, 36, accuracy: 0.01)
        XCTAssertEqual(style.firstLineHeadIndent, 18, accuracy: 0.01)
    }

    func testRenumberPatchesFollowingParagraphs() throws {
        // После правки перерисовываются и абзацы ниже, чей номер изменился (ключ абзаца — с номером).
        var source = try Self.fixture("02-generated-no-listtext.rtf")
        let renderer = DocRenderer()
        let (first, _) = renderer.render(RTFReader.read(source as NSString), previous: nil)
        let result = try XCTUnwrap(Self.perform(source, at: "Приложите", offset: 0, text: "\n"))
        source = result.source
        let (_, patch) = renderer.render(RTFReader.read(source as NSString), previous: first)
        XCTAssertTrue(patch.string.string.contains("4.\t\u{041F}ередайте"), "номер ниже правки — новый")
    }

    // MARK: - Правка

    /// Как `DocumentController.perform(replacing:with:)`: команда списка или обычная правка и готовые номера.
    struct Outcome: Sendable {
        var source: String
        var edits: [DocEdit]
        var caret: Int
    }

    static func perform(_ source: String, units: NSRange, text: String, backtab: Bool = false,
                        encoding: TextEncoding = .windows1252) -> Outcome? {
        let original = source as NSString
        let model = RTFReader.read(original, fallback: encoding)
        let (rendering, _) = DocRenderer().render(model, previous: nil)
        var edits: [DocEdit]
        var caret: Int
        if backtab {
            guard let list = DocListEdit.backtab(units, model: model, rendering: rendering, source: original), list.refusal == nil else { return nil }
            (edits, caret) = (list.edits, list.caretSource)
        } else if let list = DocListEdit.intercept(units, text: text, model: model, rendering: rendering, source: original) {
            guard list.refusal == nil else { return nil }
            (edits, caret) = (list.edits, list.caretSource)
        } else {
            let result = DocTextEditor.replace(units, with: text, model: model, map: rendering.map, source: original)
            guard result.refusal == nil else { return nil }
            (edits, caret) = (result.edits, result.caretSource)
            if units.length > 0 || text.contains(where: \.isNewline) {
                (edits, caret) = DocListText.synced(edits, caret: caret, model: model, source: original)
            }
        }
        guard !edits.isEmpty else { return nil }
        return Outcome(source: DocListText.applied(edits, to: original) as String, edits: edits, caret: caret)
    }

    /// Правка у видимого текста `anchor` (+ `offset` единиц от его начала); `before` — курсор за номером пункта.
    static func perform(_ source: String, at anchor: String, offset: Int, text: String, length: Int = 0, backtab: Bool = false) -> Outcome? {
        let (_, patch) = DocRenderer().render(RTFReader.read(source as NSString), previous: nil)
        let found = (patch.string.string as NSString).range(of: anchor)
        guard found.location != NSNotFound else { return nil }
        return perform(source, units: NSRange(location: found.location + offset, length: length), text: text, backtab: backtab)
    }

    /// Без потерь: `DocSaveGuard` (байты вне правок, скобки, разбор, Cocoa), отмена — байт в байт; в файле, где готовые
    /// номера совпадали с посчитанными, они совпадают и после правки.
    func checkLossless(_ before: String, _ outcome: Outcome, synced: Bool, file: StaticString = #filePath, line: UInt = #line) {
        for problem in Self.violations(before, outcome, synced: synced) { XCTFail(problem, file: file, line: line) }
    }

    /// Что нарушила правка (пусто — ничего). `encoding` — кодировка файла (у копий форм — своя).
    nonisolated static func violations(_ before: String, _ outcome: Outcome, synced: Bool, document: EditorDocument? = nil) -> [String] {
        var problems: [String] = []
        let document = document ?? EditorDocument(data: before.data(using: .windowsCP1251) ?? Data())
        var journal = DocSourceJournal(length: (before as NSString).length)
        var undo: [(NSRange, String)] = []
        for edit in outcome.edits.sorted(by: { $0.range.location > $1.range.location }) {
            let length = (edit.text as NSString).length
            journal.record(edited: NSRange(location: edit.range.location, length: length), delta: length - edit.range.length)
        }
        var shift = 0
        for edit in outcome.edits.sorted(by: { $0.range.location < $1.range.location }) {
            undo.append((NSRange(location: edit.range.location + shift, length: (edit.text as NSString).length),
                         (before as NSString).substring(with: edit.range)))
            shift += (edit.text as NSString).length - edit.range.length
        }
        let report = DocSaveGuard.check(document: document, text: outcome.source as NSString, journal: journal)
        if !report.passed { problems.append("DocSaveGuard: " + report.problem) }
        let restored = NSMutableString(string: outcome.source)
        for (range, text) in undo.reversed() { restored.replaceCharacters(in: range, with: text) }
        if restored as String != before { problems.append("отмена — не байт в байт") }
        if synced, staleListTexts(outcome.source) != 0 { problems.append("готовые номера разошлись с посчитанными") }
        return problems
    }

    /// Пункты, у которых готовый `{\listtext}` расходится с посчитанным номером.
    nonisolated static func staleListTexts(_ source: String) -> Int {
        let model = RTFReader.read(source as NSString)
        let labels = DocListNumbers.labels(model.body, lists: model.lists)
        return labels.filter { index, label in
            let paragraph = model.body.paragraphs[index]
            guard paragraph.listTextGroup != nil else { return false }
            return DocListText.segment(paragraph)?.text != label.number
        }.count
    }

    func testReturnInItemMakesNextItemAndRewritesListText() throws {
        let source = try Self.fixture("01-word-numbered.rtf")
        // ↩ внутри «Дата рождения»: «рождения» — новый пункт 1.3., у него своя копия {\listtext} с номером «1.3.».
        let outcome = try XCTUnwrap(Self.perform(source, at: "Дата рождения", offset: 5, text: "\n"))
        checkLossless(source, outcome, synced: true)
        XCTAssertEqual(Self.numbers(outcome.source), ["1.", "1.1.", "1.2.", "1.3.", "a)", "b)", "2.", "2.1."])
        XCTAssertEqual(outcome.edits.count, 1, "номера ниже не изменились — их байты не тронуты")
        XCTAssertTrue(outcome.edits[0].text.hasPrefix("\\par {\\listtext"), outcome.edits[0].text)
        XCTAssertTrue(outcome.edits[0].text.contains("1.3.\\tab}"))
        // Курсор — в начале нового пункта, за номером.
        let model = RTFReader.read(outcome.source as NSString)
        let (rendering, patch) = DocRenderer().render(model, previous: nil)
        let caret = rendering.caretUnit(atSource: outcome.caret)
        XCTAssertTrue((patch.string.string as NSString).substring(from: caret).hasPrefix("\u{0440}ождения"))
    }

    func testReturnAtItemStartShiftsNumbersBelow() throws {
        let source = try Self.fixture("01-word-numbered.rtf")
        let outcome = try XCTUnwrap(Self.perform(source, at: "Общие сведения", offset: 0, text: "\n"))
        checkLossless(source, outcome, synced: true)
        XCTAssertEqual(Self.numbers(outcome.source), ["1.", "2.", "2.1.", "2.2.", "a)", "b)", "3.", "3.1."])
    }

    func testReturnInEmptyItemOutdentsThenLeavesList() throws {
        let source = try Self.fixture("01-word-numbered.rtf")
        // ↩ в конце «Телефон для связи» — новый пустой пункт 2.2.; ↩ в нём — уровень выше (3.); ещё ↩ — без номера.
        let step1 = try XCTUnwrap(Self.perform(source, at: "Телефон для связи", offset: 17, text: "\n"))
        checkLossless(source, step1, synced: true)
        XCTAssertEqual(Self.numbers(step1.source).suffix(2), ["2.1.", "2.2."])
        let (rendering, _) = DocRenderer().render(RTFReader.read(step1.source as NSString), previous: nil)
        let empty = rendering.caretUnit(atSource: step1.caret)
        let step2 = try XCTUnwrap(Self.perform(step1.source, units: NSRange(location: empty, length: 0), text: "\n"))
        checkLossless(step1.source, step2, synced: true)
        XCTAssertEqual(Self.numbers(step2.source).suffix(2), ["2.1.", "3."])
        let model2 = RTFReader.read(step2.source as NSString)
        let index = try XCTUnwrap(DocListNumbers.labels(model2.body, lists: model2.lists).keys.max())
        XCTAssertEqual(model2.body.paragraphs[index].props.left, 360, "отступ нового уровня")
        XCTAssertEqual(model2.body.paragraphs[index].props.firstLine, -360)
        let (rendering2, _) = DocRenderer().render(model2, previous: nil)
        let step3 = try XCTUnwrap(Self.perform(step2.source, units: NSRange(location: rendering2.caretUnit(atSource: step2.caret), length: 0), text: "\n"))
        checkLossless(step2.source, step3, synced: true)
        XCTAssertEqual(Self.numbers(step3.source).count, 7, "пустой абзац больше не пункт")
        let model3 = RTFReader.read(step3.source as NSString)
        XCTAssertEqual(model3.body.paragraphs[index].props.list, 0)
        XCTAssertNil(model3.body.paragraphs[index].listTextGroup, "готовый номер вырезан")
        XCTAssertEqual(model3.body.paragraphs[index].props.left, 0)
        XCTAssertEqual(model3.body.paragraphs[index].props.firstLine, 0)
        XCTAssertTrue(step3.source.contains(#"\ls0"#))
    }

    func testTabAndBacktabChangeLevel() throws {
        let source = try Self.fixture("01-word-numbered.rtf")
        // Tab в начале «Контакты» (2.) — уровень ниже: 1.3., «Телефон» — 1.4.; оба готовых номера переписаны.
        let tab = try XCTUnwrap(Self.perform(source, at: "Контакты", offset: 0, text: "\t"))
        checkLossless(source, tab, synced: true)
        XCTAssertEqual(Self.numbers(tab.source), ["1.", "1.1.", "1.2.", "a)", "b)", "1.3.", "1.4."])
        let model = RTFReader.read(tab.source as NSString)
        let index = try XCTUnwrap(Self.paragraph(tab.source, containing: "Контакты"))
        XCTAssertEqual(model.body.paragraphs[index].props.listLevel, 1)
        XCTAssertEqual(model.body.paragraphs[index].props.left, 792, "отступ уровня 2")
        XCTAssertEqual(model.body.paragraphs[index].props.firstLine, -432)
        // Tab не в начале пункта — обычная табуляция.
        let inside = try XCTUnwrap(Self.perform(source, at: "Контакты", offset: 3, text: "\t"))
        XCTAssertTrue(inside.edits.contains { $0.text.contains("\\tab") })
        XCTAssertEqual(Self.numbers(inside.source), Self.numbers(source))
        // ⇧Tab на «Телефон для связи» (2.1.) — уровень выше: 3.
        let back = try XCTUnwrap(Self.perform(source, at: "Телефон", offset: 0, text: "", backtab: true))
        checkLossless(source, back, synced: true)
        XCTAssertEqual(Self.numbers(back.source).last, "3.")
        // ⇧Tab на первом уровне — нечего повышать.
        XCTAssertNil(Self.perform(source, at: "Общие", offset: 0, text: "", backtab: true))
        // Несколько пунктов одного уровня выделением.
        let (_, patch) = DocRenderer().render(RTFReader.read(source as NSString), previous: nil)
        let shown = patch.string.string as NSString
        let from = shown.range(of: "Фамилия").location, to = NSMaxRange(shown.range(of: "Дата рождения"))
        let both = try XCTUnwrap(Self.perform(source, units: NSRange(location: from, length: to - from), text: "\t"))
        checkLossless(source, both, synced: true)
        XCTAssertEqual(Self.numbers(both.source), ["1.", "a)", "b)", "c)", "d)", "2.", "2.1."])
    }

    func testBackspaceAfterNumberRemovesIt() throws {
        let source = try Self.fixture("02-generated-no-listtext.rtf")
        let (_, patch) = DocRenderer().render(RTFReader.read(source as NSString), previous: nil)
        let at = (patch.string.string as NSString).range(of: "Приложите").location
        // ⌫ удаляет единицу перед курсором — табуляцию номера.
        let outcome = try XCTUnwrap(Self.perform(source, units: NSRange(location: at - 1, length: 1), text: ""))
        checkLossless(source, outcome, synced: false)
        XCTAssertEqual(Self.numbers(outcome.source), ["1.", "\u{2022}", "\u{2022}", "2.", "7."], "ниже — на номер меньше")
        let model = RTFReader.read(outcome.source as NSString)
        let index = try XCTUnwrap(Self.paragraph(outcome.source, containing: "Приложите"))
        XCTAssertEqual(model.body.paragraphs[index].props.list, 0)
        XCTAssertEqual(model.body.paragraphs[index].props.firstLine, 0, "без выступа: текст остаётся на отступе")
        XCTAssertEqual(model.body.paragraphs[index].props.left, 360)
    }

    func testMergeDropsSecondListText() throws {
        let source = try Self.fixture("01-word-numbered.rtf")
        let (_, patch) = DocRenderer().render(RTFReader.read(source as NSString), previous: nil)
        let shown = patch.string.string as NSString
        // Delete в конце «год» — склейка с «Контакты»: его {\listtext} и свойства уходят.
        let end = NSMaxRange(shown.range(of: "\u{0433}\u{043E}\u{0434}\n")) - 1
        let outcome = try XCTUnwrap(Self.perform(source, units: NSRange(location: end, length: 1), text: ""))
        checkLossless(source, outcome, synced: true)
        XCTAssertEqual(Self.numbers(outcome.source), ["1.", "1.1.", "1.2.", "a)", "b)", "1.3."])
        XCTAssertFalse(outcome.source.contains("\\fs24 2.\\tab}"), "готовый номер «2.» вырезан")
    }

    func testCaretSkipsNumber() {
        var map = DocSourceMap()
        map.append(NSRange(location: 0, length: 5), kind: .paragraphEnd)
        for _ in 0..<3 { map.append(NSRange(location: 5, length: 0), kind: .listText) }
        map.append(NSRange(location: 20, length: 1), kind: .text)
        XCTAssertEqual(DocListEdit.caretOutsideNumber(NSRange(location: 2, length: 0), from: NSRange(location: 0, length: 0), map: map)?.location, 4)
        XCTAssertEqual(DocListEdit.caretOutsideNumber(NSRange(location: 3, length: 0), from: NSRange(location: 4, length: 0), map: map)?.location, 0,
                       "назад — в конец прошлого абзаца")
        XCTAssertNil(DocListEdit.caretOutsideNumber(NSRange(location: 4, length: 0), from: NSRange(location: 0, length: 0), map: map))
    }

    // MARK: - Случайные правки

    func testRandomEditsKeepFixturesLossless() throws {
        var random = SeededRandom(seed: 2_202)
        var applied = 0
        for name in Self.fixtures {
            let original = try Self.fixture(name)
            let synced = Self.staleListTexts(original) == 0 && original.contains("listtext")
            var source = original
            for _ in 0..<120 {
                let (rendering, _) = DocRenderer().render(RTFReader.read(source as NSString), previous: nil)
                let count = rendering.map.count
                let location = random.next(count + 1)
                let length = random.next(4) == 0 ? random.next(min(6, count - min(location, count)) + 1) : 0
                let operation = random.next(6)
                let text = ["\n", "\t", "", "x", "Ж", ""][operation]
                guard let outcome = Self.perform(source, units: NSRange(location: location, length: length), text: text, backtab: operation == 5)
                else { continue }
                checkLossless(source, outcome, synced: synced)
                source = outcome.source
                applied += 1
            }
        }
        print("[lists] случайные правки на фикстурах: применено \(applied) из \(Self.fixtures.count * 120)")
        XCTAssertGreaterThan(applied, 150)
    }
}

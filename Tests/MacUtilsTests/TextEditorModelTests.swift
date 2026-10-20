import XCTest
@testable import MacUtils

/// Модели редактора без окон: документ и правила сохранения, индекс строк при правках, поиск, команды строк,
/// сессия, поколения скана `$`.
final class EditorDocumentTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: TextEditorAcceptanceTests.folder.appendingPathComponent(name))
    }

    /// Все 17 фикстур: «открыл → сохранил» через модель документа — те же байты (BOM, смешанные EOL, нет EOL в конце),
    /// и так же после правки, отменённой обратно (текст сравнивается побуквенно, байты кодируются заново).
    func testOpenSaveWithoutEditsKeepsBytes() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: TextEditorAcceptanceTests.folder.path).filter { $0.hasSuffix(".frm") }
        XCTAssertEqual(names.count, 17)
        for name in names {
            let data = try fixture(name)
            let document = EditorDocument(data: data)
            XCTAssertEqual(try document.data(for: document.decodedText), data, name)
            XCTAssertFalse(document.isConverted, name)
            let roundTrip = String((document.decodedText + "x").dropLast())
            XCTAssertEqual(try document.data(for: roundTrip), data, "\(name): тот же текст другим объектом")
            XCTAssertEqual(document.encoding.encode(document.decodedText), data, "\(name): и перекодирование даёт те же байты")
        }
    }

    func testSaveAfterEditUsesSameEncoding() throws {
        let data = try fixture("13-cp1251-cyrillic.frm")
        let document = EditorDocument(data: data)
        XCTAssertEqual(document.encoding, .windows1251)
        XCTAssertEqual(document.reason, .rtfCodePage(1251))
        let edited = document.decodedText.replacingOccurrences(of: "Київ", with: "Львів")
        let saved = try document.data(for: edited)
        XCTAssertEqual(TextEncoding.windows1251.decode(saved), edited)
    }

    func testMixedLineEndingsAreNotNormalizedOnSave() throws {
        let data = try fixture("07-empty-values.frm")
        let document = EditorDocument(data: data)
        XCTAssertEqual(LineEndingMode.of(document.decodedText, default: .lf), .mixed)
        // Правка в середине — переводы строк вокруг остаются как были.
        let edited = (document.decodedText as NSString).replacingCharacters(in: NSRange(location: 10, length: 0), with: "x")
        let saved = try document.data(for: edited)
        XCTAssertEqual(LineEnding.count(in: TextEncoding.windows1252.decode(saved)!), LineEnding.count(in: document.decodedText))
    }

    func testConvertWarnsAboutMissingCharactersAndLossyOnConsent() throws {
        var document = EditorDocument(data: try fixture("13-cp1251-cyrillic.frm"))
        document.encoding = .windows1252
        XCTAssertTrue(document.isConverted)
        XCTAssertThrowsError(try document.data(for: document.decodedText)) { error in
            guard case .unrepresentable(let characters) = error as? EditorDocument.SaveError else { return XCTFail("\(error)") }
            XCTAssertTrue(characters.contains("И"))
        }
        let lossy = try document.data(for: document.decodedText, lossy: true)
        XCTAssertTrue(TextEncoding.windows1252.decode(lossy)!.contains("??????"), "Иванов → ??????")
        // UTF-8 с BOM: текст тот же, байты начинаются с EF BB BF.
        var bom = EditorDocument(data: try fixture("12b-utf8-nobom.frm"))
        bom.encoding = .utf8BOM
        let saved = try bom.data(for: bom.decodedText)
        XCTAssertEqual(Array(saved.prefix(3)), [0xEF, 0xBB, 0xBF])
        XCTAssertEqual(TextEncoding.utf8BOM.decode(saved), bom.decodedText)
    }

    func testReinterpretFromOriginalBytes() throws {
        let data = try fixture("13-cp1251-cyrillic.frm")
        var document = EditorDocument(data: data)
        let cyrillic = document.decodedText
        document.reinterpret(as: .windows1252)
        XCTAssertTrue(document.decodedText.contains("Èâàíîâ"), "те же байты в 1252 — мусор")
        XCTAssertEqual(document.reason, .manual)
        XCTAssertEqual(try document.data(for: document.decodedText), data, "без правок — исходные байты")
        document.reinterpret(as: .windows1251)
        XCTAssertEqual(document.decodedText, cyrillic, "вернули 1251 — текст как исходный")
        // Неверный UTF-8: знак замены и отметка, байты на диске те же.
        var high = EditorDocument(data: try fixture("11-cp1252-high-bytes.frm"))
        high.reinterpret(as: .utf8)
        XCTAssertTrue(high.lossyDecode)
        XCTAssertTrue(high.decodedText.contains("\u{FFFD}"))
        XCTAssertEqual(try high.data(for: high.decodedText), try fixture("11-cp1252-high-bytes.frm"))
    }

    func testNewDocumentAndLanguageDetection() {
        let document = EditorDocument(newWith: .utf8)
        XCTAssertEqual(document.title, "Без имени")
        XCTAssertEqual(try document.data(for: "abc"), Data("abc".utf8))
        XCTAssertEqual(EditorLanguage.detect(url: URL(fileURLWithPath: "/a/b.frm"), head: Data()), .rtf)
        XCTAssertEqual(EditorLanguage.detect(url: URL(fileURLWithPath: "/a/b.json"), head: Data()), .json)
        XCTAssertEqual(EditorLanguage.detect(url: URL(fileURLWithPath: "/a/b.html"), head: Data()), .xml)
        XCTAssertEqual(EditorLanguage.detect(url: URL(fileURLWithPath: "/a/b.txt"), head: Data("{\\rtf1 x".utf8)), .rtf)
        XCTAssertEqual(EditorLanguage.detect(url: nil, head: Data("<?xml version".utf8)), .xml)
        XCTAssertEqual(EditorLanguage.detect(url: URL(fileURLWithPath: "/a/b.txt"), head: Data("hello".utf8)), .plain)
    }

    @MainActor
    func testWriteKeepsPermissionsOfExistingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editor-write-\(UUID().uuidString).frm")
        defer { try? FileManager.default.removeItem(at: url) }
        try EditorWindowController.writeFile(Data("a".utf8), to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try EditorWindowController.writeFile(Data("b\r\n".utf8), to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("b\r\n".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testFileStampNoticesExternalChange() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("editor-stamp-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("one".utf8).write(to: url)
        let document = try EditorDocument.open(url)
        XCTAssertFalse(document.isChangedOnDisk)
        try Data("one two".utf8).write(to: url)
        XCTAssertTrue(document.isChangedOnDisk)
    }
}

final class LineIndexUpdateTests: XCTestCase {
    /// Случайные правки (с CR, LF, CRLF и их склейкой) — индекс совпадает с построенным заново.
    func testRandomEditsMatchRebuild() {
        var generator = SystemRandomNumberGenerator()
        let pieces = ["a", "bc", "\r", "\n", "\r\n", "x\ry", "\n\r", "", "$v1 "]
        for _ in 0..<300 {
            let text = NSMutableString(string: (0..<Int.random(in: 0...12, using: &generator)).map { _ in pieces.randomElement()! }.joined())
            var index = LineIndex(text)
            for _ in 0..<20 {
                let location = Int.random(in: 0...text.length, using: &generator)
                let length = Int.random(in: 0...min(3, text.length - location), using: &generator)
                let insert = (0..<Int.random(in: 0...3, using: &generator)).map { _ in pieces.randomElement()! }.joined()
                let before = text.copy() as! String
                text.replaceCharacters(in: NSRange(location: location, length: length), with: insert)
                let inserted = (insert as NSString).length
                index.update(text, editedRange: NSRange(location: location, length: inserted), delta: inserted - length)
                XCTAssertEqual(index.starts, LineIndex(text).starts,
                               "\(before.debugDescription) → \((text as String).debugDescription)")
            }
        }
    }

    func testHueByValue() {
        XCTAssertNil(DollarMarks.hue(of: ""))
        XCTAssertEqual(DollarMarks.hue(of: "CLIENT"), DollarMarks.hue(of: "CLIENT"), "одинаковые значения — один оттенок")
        let hues = Set(["A", "B", "C", "D", "E", "F", "G", "INV_NO", "DATE", "TOTAL"].compactMap { DollarMarks.hue(of: $0 as NSString) })
        XCTAssertGreaterThan(hues.count, 2, "разные значения расходятся по оттенкам")
        XCTAssertTrue(hues.allSatisfy { (0..<6).contains($0) })
    }
}

final class TextSearchTests: XCTestCase {
    private let crlf = "Line one $one\r\nLine two $two\r\nLinefeed four $four\r\n$five line\r\n" as NSString

    private func found(_ query: String, _ options: SearchOptions = SearchOptions(), in text: NSString? = nil) throws -> [String] {
        let text = text ?? crlf
        return try TextSearch.find(query, in: text, options: options).ranges.map { text.substring(with: $0) }
    }

    func testCaseWholeWordRegex() throws {
        XCTAssertEqual(try found("line").count, 4)
        XCTAssertEqual(try found("line", SearchOptions(caseSensitive: true)), ["line"])
        XCTAssertEqual(try found("Line", SearchOptions(caseSensitive: true, wholeWord: true)), ["Line", "Line"], "не Linefeed")
        XCTAssertEqual(try found(#"\$[a-z]+"#, SearchOptions(regex: true)), ["$one", "$two", "$four", "$five"])
        XCTAssertEqual(try found("$two", SearchOptions(wholeWord: true)), ["$two"], "края слова — без букв и цифр")
        XCTAssertThrowsError(try found("(", SearchOptions(regex: true)))
        XCTAssertEqual(try found(""), [])
    }

    func testInSelectionAndLimit() throws {
        let scope = NSRange(location: 15, length: 30)
        let ranges = try TextSearch.find("$", in: crlf, options: SearchOptions(inSelection: true), scope: scope).ranges
        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue(ranges.allSatisfy { NSLocationInRange($0.location, scope) })
        let many = String(repeating: "a", count: TextSearch.limit + 5) as NSString
        let result = try TextSearch.find("a", in: many, options: SearchOptions())
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.ranges.count, TextSearch.limit)
    }

    func testEmptyRegexMatchesDoNotLoop() throws {
        let text = "ab\ncd\n" as NSString
        let starts = try TextSearch.find("^", in: text, options: SearchOptions(regex: true)).ranges
        XCTAssertEqual(starts.map(\.location), [0, 3], "после последнего перевода строки `^` не совпадает (ICU)")
        let words = try TextSearch.find(#"\b"#, in: text, options: SearchOptions(regex: true)).ranges
        XCTAssertEqual(words.count, 4)
        // «Далее» по пустым совпадениям идёт вперёд, а не стоит на месте.
        var selection = NSRange(location: 0, length: 0)
        var visited: [Int] = []
        for _ in 0..<4 {
            guard let next = TextSearch.next(in: starts, after: selection, backwards: false) else { break }
            visited.append(starts[next.index].location)
            selection = starts[next.index]
        }
        XCTAssertEqual(visited, [3, 0, 3, 0])
    }

    func testReplacementsWithGroups() throws {
        let plan = try TextSearch.replacements(#"\$(\w+)"#, template: "<$1>", in: crlf, options: SearchOptions(regex: true))
        XCTAssertEqual(plan.strings, ["<one>", "<two>", "<four>", "<five>"])
        let literal = try TextSearch.replacements("$", template: "$1", in: crlf, options: SearchOptions())
        XCTAssertEqual(literal.strings.count, 4)
        XCTAssertTrue(literal.strings.allSatisfy { $0 == "$1" }, "без regex шаблон — как есть")
        let single = try TextSearch.replacement(for: plan.ranges[1], #"\$(\w+)"#, template: "[$1]", in: crlf, options: SearchOptions(regex: true))
        XCTAssertEqual(single, "[two]")
    }

    func testNextWrapsAndParsesLocation() {
        let ranges = [NSRange(location: 2, length: 1), NSRange(location: 8, length: 1)]
        XCTAssertEqual(TextSearch.next(in: ranges, after: NSRange(location: 9, length: 0), backwards: false)?.index, 0)
        XCTAssertEqual(TextSearch.next(in: ranges, after: NSRange(location: 9, length: 0), backwards: false)?.wrapped, true)
        XCTAssertEqual(TextSearch.next(in: ranges, after: NSRange(location: 2, length: 1), backwards: true)?.index, 1)
        XCTAssertNil(TextSearch.next(in: [], after: NSRange(location: 0, length: 0), backwards: false))
        XCTAssertEqual(TextSearch.parseLocation("4")?.line, 4)
        XCTAssertEqual(TextSearch.parseLocation(" 15:26 ")?.column, 26)
        XCTAssertNil(TextSearch.parseLocation("abc"))
        XCTAssertNil(TextSearch.parseLocation(""))
        XCTAssertNil(TextSearch.parseLocation("1:x"))
        XCTAssertEqual(TextSearch.parseLocation("0")?.line, 0, "0 — разбирается, переход ограничит его первой строкой")
    }
}

final class LineCommandsTests: XCTestCase {
    private let sample = "  beta  \nalpha\ngamma\nalpha\nBeta" as NSString

    private func apply(_ edit: LineEdit?, to text: NSString) -> String {
        guard let edit else { return text as String }
        let result = NSMutableString(string: text)
        for index in edit.ranges.indices.sorted(by: { edit.ranges[$0].location > edit.ranges[$1].location }) {
            result.replaceCharacters(in: edit.ranges[index], with: edit.strings[index])
        }
        return result as String
    }

    func testDuplicateDeleteKeepLastLineWithoutBreak() {
        XCTAssertEqual(apply(LineCommands.duplicate(sample, NSRange(location: 10, length: 0), lineBreak: "\n"), to: sample),
                       "  beta  \nalpha\nalpha\ngamma\nalpha\nBeta")
        XCTAssertEqual(apply(LineCommands.duplicate(sample, NSRange(location: sample.length, length: 0), lineBreak: "\n"), to: sample),
                       "  beta  \nalpha\ngamma\nalpha\nBeta\nBeta", "последняя строка без перевода")
        XCTAssertEqual(apply(LineCommands.delete(sample, NSRange(location: 10, length: 0), lineBreak: "\n"), to: sample),
                       "  beta  \ngamma\nalpha\nBeta")
        XCTAssertEqual(apply(LineCommands.delete(sample, NSRange(location: sample.length, length: 0), lineBreak: "\n"), to: sample),
                       "  beta  \nalpha\ngamma\nalpha", "у последней строки уходит перевод перед ней")
        let crlf = "a\r\nb\r\nc" as NSString
        XCTAssertEqual(apply(LineCommands.duplicate(crlf, NSRange(location: 3, length: 0), lineBreak: "\r\n"), to: crlf), "a\r\nb\r\nb\r\nc")
        XCTAssertEqual(apply(LineCommands.delete(crlf, NSRange(location: 6, length: 0), lineBreak: "\r\n"), to: crlf), "a\r\nb")
    }

    func testMoveLines() {
        let up = LineCommands.move(sample, NSRange(location: sample.length - 1, length: 0), up: true)
        XCTAssertEqual(apply(up, to: sample), "  beta  \nalpha\ngamma\nBeta\nalpha", "последняя строка уходит вверх, без перевода — теперь alpha")
        XCTAssertNil(LineCommands.move(sample, NSRange(location: 0, length: 0), up: true), "на краю — ничего")
        XCTAssertNil(LineCommands.move(sample, NSRange(location: sample.length, length: 0), up: false))
        let down = LineCommands.move(sample, NSRange(location: 1, length: 0), up: false)
        XCTAssertEqual(apply(down, to: sample), "alpha\n  beta  \ngamma\nalpha\nBeta")
        XCTAssertEqual(down?.selection.location, 7, "курсор едет вместе со строкой")
        let crlf = "a\r\nb\r\nc" as NSString
        XCTAssertEqual(apply(LineCommands.move(crlf, NSRange(location: 6, length: 0), up: true), to: crlf), "a\r\nc\r\nb")
    }

    func testTrailingWhitespaceAndCase() {
        XCTAssertEqual(apply(LineCommands.trimTrailingWhitespace(sample, NSRange(location: 0, length: 0), lineBreak: "\n"), to: sample),
                       "  beta\nalpha\ngamma\nalpha\nBeta", "начальные пробелы остаются")
        XCTAssertNil(LineCommands.trimTrailingWhitespace("a\nb" as NSString, NSRange(location: 0, length: 0), lineBreak: "\n"))
        let text = "привет мир. straße ok" as NSString
        XCTAssertEqual(apply(LineCommands.changeCase(text, NSRange(location: 0, length: text.length), .upper), to: text), "ПРИВЕТ МИР. STRASSE OK")
        XCTAssertEqual(apply(LineCommands.changeCase(text, NSRange(location: 2, length: 0), .upper), to: text), "ПРИВЕТ мир. straße ok",
                       "без выделения — слово под курсором")
        XCTAssertEqual(LineCommands.sentenceCase("hELLO. wORLD! ok"), "Hello. World! Ok")
    }
}

@MainActor
final class EditorSessionTests: XCTestCase {
    private var folder: URL!
    private var saved: URL!

    override func setUp() {
        super.setUp()
        saved = EditorSession.folder
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("editor-session-\(UUID().uuidString)", isDirectory: true)
        EditorSession.folder = folder
        UserDefaults.standard.set(true, forKey: Pref.editorRestoreSession)
        UserDefaults.standard.set(true, forKey: Pref.editorAutosaveDrafts)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        EditorSession.folder = saved
        super.tearDown()
    }

    func testRoundTripWithDraftsAndMissingFile() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("named.frm")
        try Data("{\\rtf1 $A $B}".utf8).write(to: file)
        let gone = folder.appendingPathComponent("gone.txt")
        try Data("old".utf8).write(to: gone)

        let workspace = EditorWorkspace()
        let named = EditorTab(document: try EditorDocument.open(file))
        workspace.add(named)
        let untitled = workspace.newDocument()
        untitled.textView.insertText("demo $x", replacementRange: NSRange(location: 0, length: 0))
        let missing = EditorTab(document: try EditorDocument.open(gone))
        missing.textView.insertText("new ", replacementRange: NSRange(location: 0, length: 0))
        workspace.add(missing)
        workspace.selectedID = untitled.id
        EditorSession.save(workspace)
        try FileManager.default.removeItem(at: gone)

        let restored = EditorWorkspace()
        EditorSession.restore(into: restored)
        XCTAssertEqual(restored.tabs.count, 3)
        XCTAssertEqual(restored.current?.id, untitled.id, "активная вкладка прежняя")
        XCTAssertEqual(restored.tabs[0].text as String, "{\\rtf1 $A $B}")
        XCTAssertFalse(restored.tabs[0].isDirty)
        XCTAssertEqual(restored.tabs[1].text as String, "demo $x")
        XCTAssertTrue(restored.tabs[1].isDirty)
        XCTAssertEqual(restored.tabs[2].text as String, "new old")
        XCTAssertTrue(restored.tabs[2].fileMissing, "файл удалён — вкладка с черновиком и пометкой")
        XCTAssertTrue(restored.tabs[2].isDirty)
    }

    func testBrokenSessionIsSetAside() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: EditorSession.sessionURL)
        let workspace = EditorWorkspace()
        EditorSession.restore(into: workspace)
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EditorSession.sessionURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: EditorSession.sessionURL.appendingPathExtension("broken").path))
    }

    /// Автосохранение: через 2 с после правки черновик на диске (после `kill -9` теряется не больше 2 с ввода).
    func testAutosaveAfterTwoSeconds() throws {
        let workspace = EditorWorkspace()
        workspace.onChange = { EditorSession.scheduleSave(workspace) }
        let tab = workspace.newDocument()
        tab.textView.insertText("demo $x", replacementRange: NSRange(location: 0, length: 0))
        tab.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertNil(tab.draftID)
        RunLoop.main.run(until: Date().addingTimeInterval(EditorSession.autosaveDelay + 0.5))
        let draft = try XCTUnwrap(tab.draftID)
        XCTAssertEqual(try String(contentsOf: EditorSession.draftURL(draft), encoding: .utf8), "demo $x")
        let state = try XCTUnwrap(EditorSession.load())
        XCTAssertEqual(state.tabs.first?.draftID, draft)
        // Сохранили или закрыли без сохранения — черновик удаляется.
        EditorSession.discardDraft(of: tab)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EditorSession.draftURL(draft).path))
    }

    func testClosePlan() {
        XCTAssertEqual(EditorWindowController.closePlan(dirtyCount: 0, autosaveDrafts: false), .close)
        XCTAssertEqual(EditorWindowController.closePlan(dirtyCount: 0, autosaveDrafts: true), .close)
        XCTAssertEqual(EditorWindowController.closePlan(dirtyCount: 2, autosaveDrafts: true), .keepInDrafts, "выход без вопроса — правки в черновиках")
        XCTAssertEqual(EditorWindowController.closePlan(dirtyCount: 1, autosaveDrafts: false), .ask)
    }

    func testRecentFiles() {
        let key = Pref.editorRecent
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }
        EditorRecent.clear()
        for i in 0..<20 { EditorRecent.add(URL(fileURLWithPath: "/tmp/r\(i).txt")) }
        EditorRecent.add(URL(fileURLWithPath: "/tmp/r5.txt"))
        XCTAssertEqual(EditorRecent.paths.count, EditorRecent.limit)
        XCTAssertEqual(EditorRecent.paths.first, "/tmp/r5.txt", "последний — первым, без дублей")
        XCTAssertEqual(EditorRecent.paths.filter { $0 == "/tmp/r5.txt" }.count, 1)
        EditorRecent.clear()
        XCTAssertTrue(EditorRecent.paths.isEmpty)
    }
}

@MainActor
final class DollarPanelModelTests: XCTestCase {
    /// Быстрый набор: применяется только последний результат; скан ждёт паузы (часы ручные).
    func testDebounceAndGenerations() {
        let model = DollarPanelModel()
        var scheduled: [(TimeInterval, () -> Void)] = []
        model.schedule = { delay, block in
            scheduled.append((delay, block))
            return DispatchWorkItem {}
        }
        var jobs: [@Sendable () -> Void] = []
        model.background = { jobs.append($0) }
        var text: NSString = "$a"
        model.textChanged { text }
        text = "$a $b"
        model.textChanged { text }
        XCTAssertEqual(scheduled.count, 2)
        XCTAssertEqual(scheduled[0].0, DollarPanelModel.debounce)
        scheduled[0].1()
        XCTAssertTrue(jobs.isEmpty, "устаревшее поколение не сканируется")
        scheduled[1].1()
        XCTAssertEqual(jobs.count, 1)
        // Устаревший результат отбрасывается.
        model.apply(DollarPanelModel.scan("$old"), generation: model.currentGeneration - 1)
        XCTAssertTrue(model.entries.isEmpty)
        model.apply(DollarPanelModel.scan(text), generation: model.currentGeneration)
        XCTAssertEqual(model.entries.map(\.value), ["a", "b"])
        XCTAssertEqual(model.entries.map(\.line), [1, 1])
        XCTAssertEqual(model.entries(in: NSRange(location: 3, length: 2)).map(\.value), ["b"])
    }
}

@MainActor
final class EditorWorkspaceTests: XCTestCase {
    private func tab(_ path: String?) -> EditorTab {
        var document = EditorDocument(newWith: .utf8)
        document.url = path.map { URL(fileURLWithPath: $0) }
        return EditorTab(document: document)
    }

    func testTabsOrderSwitchingAndTitles() {
        let workspace = EditorWorkspace()
        let a = tab("/tmp/one/form.frm"), b = tab("/tmp/two/form.frm"), c = tab("/tmp/notes.txt")
        for item in [a, b, c] { workspace.add(item) }
        XCTAssertEqual(workspace.current?.id, c.id)
        XCTAssertEqual(workspace.displayTitle(a), "form.frm — one", "одноимённые различаются папкой")
        XCTAssertEqual(workspace.displayTitle(c), "notes.txt")
        workspace.select(offset: 1)
        XCTAssertEqual(workspace.current?.id, a.id, "по кругу")
        workspace.select(offset: -1)
        XCTAssertEqual(workspace.current?.id, c.id)
        workspace.move(c.id, to: a.id)
        XCTAssertEqual(workspace.tabs.map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(workspace.tab(for: URL(fileURLWithPath: "/tmp/two/../two/form.frm"))?.id, b.id, "тот же файл — та же вкладка")
        workspace.remove(c)
        XCTAssertEqual(workspace.current?.id, a.id, "после закрытия — соседняя")
    }

    func testUntitledNames() {
        let workspace = EditorWorkspace()
        let first = workspace.newDocument(), second = workspace.newDocument()
        XCTAssertEqual(first.title, "Без имени 1")
        XCTAssertEqual(second.title, "Без имени 2")
        workspace.remove(first)
        XCTAssertEqual(workspace.newDocument().title, "Без имени 1")
        XCTAssertEqual(second.textView.lineBreak, EditorPrefs.newLineEnding.string)
    }
}

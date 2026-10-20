import AppKit
import XCTest
@testable import MacUtils

/// Этап 2.7: поиск и замена по папке (на копии фикстур во временной папке) и несколько курсоров.
final class FolderSearchTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("editor-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let fixtures = TextEditorAcceptanceTests.folder
        for name in try FileManager.default.contentsOfDirectory(atPath: fixtures.path) where name.hasSuffix(".frm") {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        try Data([0x24, 0x00, 0x01, 0x02]).write(to: folder.appendingPathComponent("binary.frm"))       // NUL — двоичный
        try Data("$hidden".utf8).write(to: folder.appendingPathComponent(".hidden.frm"))
        try Data("deep $nested\n".utf8).write(to: folder.appendingPathComponent("sub/nested.frm"))
        try Data("$skip".utf8).write(to: folder.appendingPathComponent("notes.md"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testMaskPatterns() {
        XCTAssertEqual(FolderSearch.patterns("*.frm; *.TXT,*.rtf"), ["*.frm", "*.txt", "*.rtf"])
        XCTAssertTrue(FolderSearch.matches("Form.FRM", patterns: ["*.frm"]))
        XCTAssertFalse(FolderSearch.matches("form.frm.bak", patterns: ["*.frm"]))
        XCTAssertTrue(FolderSearch.matches("anything", patterns: []), "пустая маска — все файлы")
    }

    /// CHECKLIST 7.13–7.14: «$» по всем фикстурам, в 03-zero нет; двоичный пропущен; скрытые и не по маске — нет;
    /// вложенные папки — да; кириллица из cp1251 читается.
    func testSearchFixturesFolder() throws {
        let summary = try FolderSearch.search("$", options: SearchOptions(), in: folder, mask: "*.frm")
        let names = Set(summary.files.map(\.url.lastPathComponent))
        XCTAssertEqual(summary.skippedBinary, 1)
        XCTAssertFalse(names.contains("03-zero-dollars.frm"))
        XCTAssertFalse(names.contains(".hidden.frm"))
        XCTAssertFalse(names.contains("notes.md"))
        XCTAssertTrue(names.contains("nested.frm"))
        XCTAssertEqual(names.count, 17, "16 фикстур со знаками + вложенный")
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: TextEditorAcceptanceTests.folder.appendingPathComponent("expected.json"))) as! [String: Any]
        let counts = (expected["files"] as! [String: [String: Any]]).mapValues { $0["dollar_count"] as! Int }
        for file in summary.files where counts[file.url.lastPathComponent] != nil {
            XCTAssertEqual(file.matches.count, counts[file.url.lastPathComponent], file.url.lastPathComponent)
        }
        let first = try XCTUnwrap(summary.files.first { $0.url.lastPathComponent == "02-four-dollars.frm" }?.matches.first)
        XCTAssertEqual(first.line, 2)
        XCTAssertTrue(first.preview.contains("$A1"))

        let kyiv = try FolderSearch.search("Київ", options: SearchOptions(), in: folder, mask: "*.frm")
        XCTAssertEqual(kyiv.files.map(\.url.lastPathComponent), ["13-cp1251-cyrillic.frm"])
        XCTAssertEqual(kyiv.files.first?.encoding, .windows1251)

        let regex = try FolderSearch.search(#"\$v?[a-z]+\d{2}k"#, options: SearchOptions(regex: true), in: folder, mask: "*.frm")
        XCTAssertEqual(regex.files.first?.url.lastPathComponent, "08-long-line.frm")
        XCTAssertThrowsError(try FolderSearch.search("(", options: SearchOptions(regex: true), in: folder, mask: "*"))
    }

    func testCancelledSearchStops() {
        XCTAssertThrowsError(try FolderSearch.search("$", options: SearchOptions(), in: folder, mask: "*", isCancelled: { true })) {
            XCTAssertEqual($0 as? TextSearch.Failure, .cancelled)
        }
    }

    /// Замена в файле — в той же кодировке, с теми же переводами строк и BOM; символа нет в кодировке — ошибка.
    func testReplacementKeepsEncodingAndLineBreaks() throws {
        let cp1251 = try Data(contentsOf: folder.appendingPathComponent("13-cp1251-cyrillic.frm"))
        let plan = try XCTUnwrap(FolderSearch.replacement(in: cp1251, query: "Київ", template: "Львів", options: SearchOptions()))
        XCTAssertEqual(plan.count, 1)
        let text = try XCTUnwrap(TextEncoding.windows1251.decode(plan.data))
        XCTAssertTrue(text.contains("$Львів"))
        XCTAssertEqual(LineEnding.count(in: text), LineEnding.count(in: TextEncoding.windows1251.decode(cp1251)!))
        XCTAssertThrowsError(try FolderSearch.replacement(in: cp1251, query: "Київ", template: "東京", options: SearchOptions()))
        let bom = try Data(contentsOf: folder.appendingPathComponent("12-utf8-bom.frm"))
        let bomPlan = try XCTUnwrap(FolderSearch.replacement(in: bom, query: "$", template: "%", options: SearchOptions()))
        XCTAssertEqual(Array(bomPlan.data.prefix(3)), [0xEF, 0xBB, 0xBF], "BOM на месте")
        XCTAssertNil(try FolderSearch.replacement(in: bom, query: "нет такого", template: "x", options: SearchOptions()))
    }

    @MainActor
    func testModelSearchesAndReplacesSkippingOpenEdits() throws {
        let model = FolderSearchModel()
        let savedPath = UserDefaults.standard.object(forKey: Pref.editorFolderSearchPath)
        let savedMask = UserDefaults.standard.object(forKey: Pref.editorFolderSearchMask)
        defer {
            UserDefaults.standard.set(savedPath, forKey: Pref.editorFolderSearchPath)
            UserDefaults.standard.set(savedMask, forKey: Pref.editorFolderSearchMask)
        }
        model.folder = folder
        model.mask = "0*.frm"
        model.query = "$"
        model.start()
        let deadline = Date().addingTimeInterval(10)
        while model.running, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(summary.files.count, 9, "01, 02, 04, 04b, 05, 06, 07, 08, 09 — 03 без знаков")
        let open = folder.appendingPathComponent("02-four-dollars.frm")
        model.dirtyOpenFiles = { [open.standardizedFileURL.resolvingSymlinksInPath().path] }
        var reloaded: [URL] = []
        model.reloadOpenFiles = { reloaded = $0 }
        let before = try Data(contentsOf: open)
        model.replacement = "€"
        model.replaceAll()
        while model.running, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(try Data(contentsOf: open), before, "открытый с правками не тронут")
        XCTAssertEqual(reloaded.count, 8)
        let first = try XCTUnwrap(TextEncoding.windows1252.decode(Data(contentsOf: folder.appendingPathComponent("01-three-dollars.frm"))))
        XCTAssertTrue(first.contains("€FIRST"), "€ записан в Windows-1252")
        XCTAssertTrue(model.note?.contains("не тронуты открытые с правками: 1") ?? false, model.note ?? "")
    }
}

@MainActor
final class EditorMultiCaretTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        window?.contentView = nil
        window?.close()
        super.tearDown()
    }

    private func tab(_ text: String) -> EditorTab {
        let tab = EditorTab(document: EditorDocument(data: Data(text.utf8)))
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 300), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tab.container.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        window.contentView = tab.container
        window.orderBack(nil)
        tab.container.layoutSubtreeIfNeeded()
        return tab
    }

    /// CHECKLIST 11.10: курсоры строкой ниже (⌃⇧↓) в том же столбце, ввод во всех, ← → двигают все, Esc — снова один.
    func testAddCaretsBelowTypeMoveAndCollapse() {
        let tab = tab("one\ntwo\nx\nfour\n")
        tab.textView.setSelectedRange(NSRange(location: 2, length: 0))   // on|e
        tab.textView.addCaret(lineOffset: 1)
        tab.textView.addCaret(lineOffset: 1)                              // короткая строка «x» — в её конец
        XCTAssertEqual(tab.textView.editTargets.map(\.location), [2, 6, 9])
        XCTAssertEqual(tab.caret.cursors, 3)
        tab.textView.insertText("_", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tab.text as String, "on_e\ntw_o\nx_\nfour\n")
        tab.textView.moveLeft(nil)
        XCTAssertEqual(tab.textView.editTargets.map(\.location), [2, 7, 11])
        tab.textView.moveRight(nil)
        tab.textView.moveRight(nil)
        tab.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tab.text as String, "on_e!\ntw_o!\nx_\n!four\n", "в конце строки «x_» курсор переходит на следующую")
        tab.textView.cancelOperation(nil)
        XCTAssertEqual(tab.caret.cursors, 1)
        XCTAssertEqual(tab.caret.line, 1, "остаётся первый курсор")
        tab.textView.setSelectedRange(NSRange(location: 14, length: 0))   // строка «!four»
        tab.textView.addCaret(lineOffset: -1)
        XCTAssertEqual(tab.caret.cursors, 2, "курсор выше")
    }

    func testAddCaretAtEdgesBeeps() {
        let tab = tab("a\nb")
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        tab.textView.addCaret(lineOffset: -1)
        XCTAssertEqual(tab.caret.cursors, 1, "выше первой строки — некуда")
        tab.textView.setSelectedRange(NSRange(location: 3, length: 0))
        tab.textView.addCaret(lineOffset: 1)
        XCTAssertEqual(tab.caret.cursors, 1, "ниже последней строки без перевода — некуда")
    }
}

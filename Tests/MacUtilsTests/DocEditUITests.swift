import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUAudio

/// Правка в окне «Документа»: набор и удаление в странице, общая отмена с «Кодом», метод ввода, запись с проверками
/// без потерь и лист `d10`, скорость ввода.
@MainActor
final class DocEditUITests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!
    private var folder: URL!
    private var savedGuard: ((DocSaveGuard.Report, EditorTab, @escaping (Bool) -> Void) -> Void)!
    private var guardShown: [DocSaveGuard.Report] = []

    override func setUpWithError() throws {
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.set(false, forKey: Pref.editorInvisibles)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("doc-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedGuard = EditorWindowController.shared.saveGuardPrompt
        guardShown = []
        EditorWindowController.shared.saveGuardPrompt = { [weak self] report, _, done in
            self?.guardShown.append(report)
            done(false)
        }
    }

    override func tearDown() {
        EditorWindowController.shared.saveGuardPrompt = savedGuard
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Вкладка из файла на диске, сразу в «Документе», в окне вне экрана.
    private func open(_ source: Data, name: String = "form.frm") throws -> (EditorTab, DocumentController, URL) {
        let url = folder.appendingPathComponent(name)
        try source.write(to: url)
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: try EditorDocument.open(url))
        tab.restoreMode(nil)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        windows.append(window)
        settle()
        return (tab, try XCTUnwrap(tab.documentController), url)
    }

    private func page(_ document: DocumentController) throws -> DocTextView { try XCTUnwrap(document.textViews.first) }

    // MARK: - Набор и отмена

    func testTypingInPageEditsSourceAndSharesUndo() throws {
        let (tab, document, _) = try open(Data(DocDemo.expertReport.utf8))
        let original = tab.text as String
        let view = try page(document)
        let city = (document.storage.string as NSString).range(of: "Демоград")
        view.setSelectedRange(NSRange(location: NSMaxRange(city), length: 0))
        view.insertText("ск", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(document.storage.string.contains("Демоградск"), "на странице — набранное")
        XCTAssertTrue((tab.text as String).contains(DocDemo.rtf("Демоградск")), "в исходнике — \\'hh cp1251")
        XCTAssertEqual(view.selectedRange(), NSRange(location: NSMaxRange(city) + 2, length: 0), "курсор после набранного")
        XCTAssertTrue(tab.isDirty)
        XCTAssertTrue(tab.editedInDocument)
        // Отмена — общая с «Кодом»: отменяем в «Коде», байт в байт.
        tab.setMode(.code)
        settle()
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original)
        tab.undo.redo()
        tab.setMode(.document)
        settle()
        XCTAssertTrue(document.storage.string.contains("Демоградск"))
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original, "и в «Документе»")
        XCTAssertFalse(document.storage.string.contains("Демоградск"))
    }

    /// Набор подряд — один шаг отмены (как в Word); пауза или переход курсора — новый шаг.
    func testTypingBurstIsOneUndoStep() throws {
        let (tab, document, _) = try open(Data(DocDemo.expertReport.utf8))
        let original = tab.text as String
        let view = try page(document)
        let city = (document.storage.string as NSString).range(of: "Демоград")
        view.setSelectedRange(NSRange(location: NSMaxRange(city), length: 0))
        for letter in ["с", "к", "и", "й"] { view.insertText(letter, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        XCTAssertTrue(document.storage.string.contains("Демоградский"))
        XCTAssertTrue((tab.text as String).contains(DocDemo.rtf("Демоградский")))
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original, "одна отмена — весь набор")
        tab.undo.redo()
        XCTAssertTrue((tab.text as String).contains(DocDemo.rtf("Демоградский")))
        // Курсор в другом месте — новый шаг.
        let start = (document.storage.string as NSString).range(of: "Эксперт").location
        settle()
        view.setSelectedRange(NSRange(location: start, length: 0))
        view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        tab.undo.undo()
        XCTAssertTrue((tab.text as String).contains(DocDemo.rtf("Демоградский")), "отменён только «!»")
    }

    func testBackspaceAtParagraphStartMergesParagraphs() throws {
        let (tab, document, _) = try open(Data(DocDemo.expertReport.utf8))
        let view = try page(document)
        let start = (document.storage.string as NSString).range(of: "по результатам").location
        view.setSelectedRange(NSRange(location: start, length: 0))
        view.deleteBackward(nil)
        XCTAssertTrue(document.storage.string.contains("$17-204по результатам"), "абзацы склеены")
        XCTAssertEqual(view.selectedRange().location, start - 1)
        let model = RTFReader.read(tab.text)
        XCTAssertEqual(model.body.paragraphs.first?.props.alignment, .center)
        // Удаление конца ячейки — нельзя: подсказка, текст не тронут.
        let before = tab.text as String
        let cell = (document.storage.string as NSString).range(of: "Показатель").location
        view.setSelectedRange(NSRange(location: cell, length: 0))
        view.deleteBackward(nil)
        XCTAssertEqual(tab.text as String, before, "через границу ячейки NSTextView не удаляет")
        XCTAssertFalse(document.perform(replacing: NSRange(location: cell - 1, length: 1), with: ""))
        XCTAssertEqual(tab.text as String, before)
        XCTAssertNotNil(document.notice, "подсказка «Изменить в коде»")
    }

    func testInputMethodCommitsOnce() throws {
        let (tab, document, _) = try open(Data(DocDemo.expertReport.utf8))
        let view = try page(document)
        let city = (document.storage.string as NSString).range(of: "Демоград")
        view.setSelectedRange(NSRange(location: NSMaxRange(city), length: 0))
        let before = tab.text as String
        view.setMarkedText("к", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tab.text as String, before, "набираемое — только на экране")
        view.setMarkedText("ку", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("ку", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue((tab.text as String).contains(DocDemo.rtf("Демоградку")))
        XCTAssertTrue(document.storage.string.contains("Демоградку"))
        XCTAssertFalse(document.storage.string.contains("Демоградкуку"), "один раз")
    }

    // MARK: - Запись

    func testSaveAfterDocumentEditKeepsBytesOutsideEdit() throws {
        let source = DocDemo.expertReport
        let (tab, document, url) = try open(Data(source.utf8))
        let view = try page(document)
        let word = (document.storage.string as NSString).range(of: "Демоград")
        view.setSelectedRange(word)
        view.insertText("Город", replacementRange: NSRange(location: NSNotFound, length: 0))
        var saved: Bool?
        EditorWindowController.shared.save(tab) { saved = $0 }
        XCTAssertEqual(saved, true)
        XCTAssertTrue(guardShown.isEmpty)
        let written = try String(contentsOf: url, encoding: .ascii)
        let removed = (source as NSString).range(of: DocDemo.rtf("Демоград"))
        let replaced = (written as NSString).range(of: DocDemo.rtf("Город"))
        XCTAssertEqual(removed.location, replaced.location)
        XCTAssertEqual((written as NSString).substring(to: removed.location), (source as NSString).substring(to: removed.location), "байты до правки те же")
        XCTAssertEqual((written as NSString).substring(from: NSMaxRange(replaced)), (source as NSString).substring(from: NSMaxRange(removed)),
                       "байты после правки те же")
        XCTAssertFalse(tab.editedInDocument)
        XCTAssertFalse(tab.isDirty)
    }

    /// Байты файла не переживают перекодировку (неверный UTF-8): проверка не пускает запись, оригинал цел.
    func testGuardRefusesLossyFileAndKeepsOriginal() throws {
        var bytes = Data(DocDemo.expertReport.utf8)
        bytes.insert(contentsOf: [0xFF, 0xFE, 0x80], at: bytes.count - 4)
        let (tab, document, url) = try open(bytes, name: "broken.rtf")
        tab.document.reinterpret(as: .utf8)
        tab.load(tab.document.decodedText, resetUndo: true)
        settle()
        XCTAssertTrue(tab.document.lossyDecode)
        let view = try page(document)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        var saved: Bool?
        EditorWindowController.shared.save(tab) { saved = $0 }
        XCTAssertEqual(saved, false, "запись не пошла")
        XCTAssertEqual(guardShown.count, 1, "лист «Не удалось сохранить без потерь»")
        XCTAssertFalse(guardShown[0].bytesOutsideEdits)
        XCTAssertNotNil(guardShown[0].data, "копию сохранить можно")
        XCTAssertEqual(try Data(contentsOf: url), bytes, "оригинал не тронут")
    }

    func testGuardRefusesBrokenBraces() throws {
        let source = DocDemo.expertReport
        let (tab, document, url) = try open(Data(source.utf8))
        let view = try page(document)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("A", replacementRange: NSRange(location: NSNotFound, length: 0))
        // В «Коде» потом сломали скобку — запись правок «Документа» с этим не пройдёт.
        tab.textView.replace([NSRange(location: tab.storage.length - 1, length: 1)], with: [""], actionName: "x")
        var saved: Bool?
        EditorWindowController.shared.save(tab) { saved = $0 }
        XCTAssertEqual(saved, false)
        XCTAssertEqual(guardShown.first?.braces, false)
        XCTAssertNotNil(guardShown.first?.problemRange)
        XCTAssertEqual(try String(contentsOf: url, encoding: .ascii), source)
    }

    // MARK: - Черновик из сессии (ревью, п. 1)

    /// Вкладка с черновиком (файл на диске + правка в `{\info}`) — правка в «Документе» сохраняется с проверками.
    private func openDraft(_ draft: String, file: String) throws -> (EditorTab, DocumentController, URL) {
        let url = folder.appendingPathComponent("draft.frm")
        try Data(file.utf8).write(to: url)
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: try EditorDocument.open(url), text: draft)
        tab.restoreMode(nil)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        windows.append(window)
        settle()
        return (tab, try XCTUnwrap(tab.documentController), url)
    }

    func testDraftThenDocumentEditSaves() throws {
        let file = DocDemo.expertReport
        let draft = file.replacingOccurrences(of: #"{\info{\title Demo}}"#, with: #"{\info{\title Demo draft}}"#)
        XCTAssertNotEqual(draft, file)
        let (tab, document, url) = try openDraft(draft, file: file)
        XCTAssertTrue(tab.isDirty)
        let view = try page(document)
        let city = (document.storage.string as NSString).range(of: "Демоград")
        view.setSelectedRange(NSRange(location: NSMaxRange(city), length: 0))
        view.insertText("ск", replacementRange: NSRange(location: NSNotFound, length: 0))
        let report = DocSaveGuard.check(document: tab.document, text: tab.text, journal: tab.journal)
        XCTAssertTrue(report.passed, report.problem)
        var saved: Bool?
        EditorWindowController.shared.save(tab) { saved = $0 }
        XCTAssertEqual(saved, true)
        XCTAssertTrue(guardShown.isEmpty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .ascii),
                       draft.replacingOccurrences(of: DocDemo.rtf("Демоград"), with: DocDemo.rtf("Демоградск")), "на диске — черновик с правкой")
    }

    /// Черновик, испорченный вне правок «Документа» (потеряна скобка), — запись отклоняется, файл цел.
    func testBrokenDraftIsRefused() throws {
        let file = DocDemo.expertReport
        let draft = file.replacingOccurrences(of: #"{\info{\title Demo}}"#, with: #"{\info{\title Demo}"#)
        let (tab, document, url) = try openDraft(draft, file: file)
        let view = try page(document)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        var saved: Bool?
        EditorWindowController.shared.save(tab) { saved = $0 }
        XCTAssertEqual(saved, false)
        XCTAssertEqual(guardShown.first?.braces, false)
        XCTAssertEqual(try String(contentsOf: url, encoding: .ascii), file, "файл на диске цел")
    }

    /// Признак «правили в Документе» переживает черновик в сессии: проверки при записи не теряются.
    func testEditedInDocumentSurvivesSession() throws {
        let saved = EditorSession.folder
        EditorSession.folder = folder.appendingPathComponent("session", isDirectory: true)
        defer { EditorSession.folder = saved }
        UserDefaults.standard.set(true, forKey: Pref.editorAutosaveDrafts)
        UserDefaults.standard.set(true, forKey: Pref.editorRestoreSession)
        let (tab, document, _) = try open(Data(DocDemo.expertReport.utf8))
        let view = try page(document)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.insertText("Z", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(tab.editedInDocument)
        let workspace = EditorWorkspace()
        workspace.add(tab)
        EditorSession.save(workspace)
        let state = try XCTUnwrap(EditorSession.load())
        XCTAssertEqual(state.tabs.first?.editedInDocument, true)
        let restored = try XCTUnwrap(EditorSession.makeTab(state.tabs[0], workspace: EditorWorkspace()))
        XCTAssertTrue(restored.editedInDocument)
        XCTAssertTrue(DocSaveGuard.check(document: restored.document, text: restored.text, journal: restored.journal).passed)
    }

    func testJournalTracksCleanSegments() {
        var journal = DocSourceJournal(length: 100)
        journal.record(edited: NSRange(location: 10, length: 3), delta: 3)          // вставка 3 в 10
        XCTAssertEqual(journal.segments, [.init(original: 0, current: 0, length: 10), .init(original: 10, current: 13, length: 90)])
        journal.record(edited: NSRange(location: 20, length: 0), delta: -5)         // удаление 20..25
        XCTAssertEqual(journal.segments, [.init(original: 0, current: 0, length: 10), .init(original: 10, current: 13, length: 7),
                                          .init(original: 22, current: 20, length: 78)])
        journal.record(edited: NSRange(location: 0, length: 1), delta: 0)           // замена первого
        XCTAssertEqual(journal.segments.first, .init(original: 1, current: 1, length: 9))
    }

    // MARK: - Скорость

    /// Ввод символа в 10-страничном документе: правка исходника, разбор, заплатка показа и раскладка — < 16 мс (release).
    func testTypingSpeedInTenPages() throws {
        let source = DocReaderTests.bigDocument(bytes: 190_000)
        let (_, document, _) = try open(Data(source.utf8), name: "ten.rtf")
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
        settle(0.5)
        XCTAssertGreaterThanOrEqual(document.pageCount, 10)
        let view = try page(document)
        let middle = document.storage.length / 2
        var times: [Double] = [], edits: [Double] = [], layouts: [Double] = []
        for step in 0..<20 {
            view.setSelectedRange(NSRange(location: middle + step, length: 0))
            let edit = TextEditorPerformanceTests.measure { view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0)) }
            let layout = TextEditorPerformanceTests.measure {
                document.layoutManager.ensureLayout(forCharacterRange: NSRange(location: middle, length: 200))
            }
            edits.append(edit)
            layouts.append(layout)
            times.append(edit + layout)
            settle(0.02)
        }
        let median = times.sorted()[times.count / 2]
        print(String(format: "[doc-perf] %@ ввод: правка+показ медиана %.1f (мин %.1f) мс, раскладка медиана %.1f (мин %.1f) мс",
                     TextEditorPerformanceTests.build, edits.sorted()[10], edits.min() ?? 0, layouts.sorted()[10], layouts.min() ?? 0))
        // Из чего складывается: разбор, ключи и заплатка рендера (без раскладки).
        let text = (try XCTUnwrap(document.tab)).text
        var model = RTFDocumentModel()
        let parse = TextEditorPerformanceTests.measure { model = RTFReader.read(text) }
        let renderer = DocRenderer()
        let (full, _) = renderer.render(model, previous: nil)
        let render = TextEditorPerformanceTests.measure { _ = renderer.render(model, previous: full) }
        print(String(format: "[doc-perf] %@ из них: разбор %.1f мс, рендер без изменений %.1f мс", TextEditorPerformanceTests.build, parse, render))
        print(String(format: "[doc-perf] %@ ввод символа, 10 страниц (%d стр.): медиана %.1f мс, макс. %.1f мс", TextEditorPerformanceTests.build,
                     document.pageCount, median, times.max() ?? 0))
        XCTAssertLessThan(median, TextEditorPerformanceTests.limit(16))
    }
}

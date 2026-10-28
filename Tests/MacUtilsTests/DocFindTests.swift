import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Поиск и замена в «Документе» (S2): по видимому тексту, подсветка на страницах, переход между страницами, «Заменить» и «Заменить все» —
/// точечные правки, один шаг отмены; кириллица в `\'hh`, слово через границу групп. Демо — выдуманный текст.
@MainActor
final class DocFindTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!
    private var folder: URL!
    private var savedGuard: ((DocSaveGuard.Report, EditorTab, @escaping (Bool) -> Void) -> Void)!
    private var guardShown: [DocSaveGuard.Report] = []

    override func setUpWithError() throws {
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("doc-find-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedGuard = EditorWindowController.shared.saveGuardPrompt
        guardShown = []
        EditorWindowController.shared.saveGuardPrompt = { [weak self] report, _, done in self?.guardShown.append(report); done(false) }
    }

    override func tearDown() {
        EditorWindowController.shared.saveGuardPrompt = savedGuard
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func open(_ source: Data, name: String = "find.rtf") throws -> (EditorWorkspace, EditorTab, DocumentController) {
        let url = folder.appendingPathComponent(name)
        try source.write(to: url)
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: try EditorDocument.open(url))
        tab.restoreMode(.document)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        windows.append(window)
        settle()
        return (workspace, tab, try XCTUnwrap(tab.documentController))
    }

    /// «Кот» целиком, «ко{\b т}» через границу групп с другим начертанием, «Скот» (внутри слова) и кириллица в cp1251.
    private static let cats: String = {
        let rtf = DocDemo.rtf
        var s = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}\sectd"# + "\r\n"
        s += #"\pard\plain\f0\fs24 "# + rtf("Кот сидит у окна. ") + #"ко{\b т}"# + rtf(" спит. Скот пасётся.") + #"\par"# + "\r\n"
        s += #"\pard\plain\f0\fs24 "# + rtf("КОТ и кот, и «кот».") + #"\par}"#
        return s
    }()

    private func start(_ workspace: EditorWorkspace, query: String) {
        workspace.findMode = false
        workspace.search.query = query
        workspace.search.refresh()
    }

    func testSearchesVisibleTextNotCodes() throws {
        let (workspace, tab, document) = try open(Data(Self.cats.utf8))
        XCTAssertEqual(tab.mode, .document)
        start(workspace, query: "кот")
        let shown = document.storage.string as NSString
        let expected = shown.components(separatedBy: "кот").count - 1 + shown.components(separatedBy: "КОТ").count - 1 + shown.components(separatedBy: "Кот").count - 1
        XCTAssertEqual(workspace.search.count, 6, "Кот, ко|т через границу групп, Скот, КОТ, кот, «кот»; expected≥\(expected)")
        XCTAssertEqual(document.findMatches.count, 6)
        for range in document.findMatches { XCTAssertEqual(shown.substring(with: range).lowercased(), "кот") }
        // Коды RTF не ищутся.
        start(workspace, query: "fonttbl")
        XCTAssertEqual(workspace.search.count, 0)
        start(workspace, query: "\\'ea")
        XCTAssertEqual(workspace.search.count, 0, "\\'hh — не текст")
        // Целое слово: «Скот» не считается.
        workspace.search.options.wholeWord = true
        start(workspace, query: "кот")
        XCTAssertEqual(workspace.search.count, 5)
        XCTAssertEqual(tab.mode, .document, "поиск не переключает в «Код»")
    }

    func testHighlightOnPagesAndNavigation() throws {
        let (workspace, _, document) = try open(Data(Self.cats.utf8))
        start(workspace, query: "кот")
        let first = document.findMatches[0]
        XCTAssertNotNil(document.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: first.location, effectiveRange: nil), "подсветка на странице")
        let before = document.storage.string
        workspace.search.next()
        XCTAssertEqual(document.textViews.first?.selectedRange(), document.findMatches[workspace.search.current ?? 0])
        let color = document.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: document.findMatches[workspace.search.current ?? 0].location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, DocumentController.findCurrentColor, "текущее — другим цветом")
        XCTAssertEqual(document.storage.string, before, "подсветка не меняет текст")
        workspace.search.clear()
        XCTAssertNil(document.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: first.location, effectiveRange: nil), "закрыли поиск — подсветки нет")
    }

    func testNextMovesAcrossPages() throws {
        let long = (1...140).map { #"\pard\plain\f0\fs24 Line \#($0)\par"# + ($0 == 130 ? #" \pard\plain\f0\fs24 needle\par"# : "") }.joined(separator: "\n")
        let source = #"{\rtf1\ansi\deff0{\fonttbl{\f0\froman Times New Roman;}}\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134\sectd"# + "\n" + long + "}"
        let (workspace, _, document) = try open(Data(source.utf8))
        XCTAssertGreaterThan(document.pageCount, 2)
        start(workspace, query: "needle")
        XCTAssertEqual(workspace.search.count, 1)
        document.textViews.first?.setSelectedRange(NSRange(location: 0, length: 0))
        workspace.search.next()
        settle(0.2)
        XCTAssertGreaterThan(document.currentPage, 1, "переход на страницу с совпадением")
        XCTAssertEqual(document.textViews.compactMap { $0.selectedRange().length > 0 ? $0.selectedRange() : nil }.first, document.findMatches[0])
    }

    func testReplaceOneIsPointEdit() throws {
        let (workspace, tab, document) = try open(Data(Self.cats.utf8))
        let original = tab.text as String
        start(workspace, query: "кот")
        workspace.search.replacement = "пёс"
        document.textViews.first?.setSelectedRange(document.findMatches[0])
        workspace.search.replaceOne()
        XCTAssertTrue(document.storage.string.hasPrefix("пёс сидит"), document.storage.string)
        XCTAssertEqual(document.storage.string.components(separatedBy: "пёс").count - 1, 1, "заменено одно")
        let source = tab.text as String
        XCTAssertTrue(source.contains(DocDemo.rtf("пёс")), "в файле — \\'hh cp1251")
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original, "одна отмена — байт в байт")
    }

    func testReplaceAllIsOneUndoStepAndKeepsOtherBytes() throws {
        let (workspace, tab, document) = try open(Data(Self.cats.utf8))
        let original = tab.text as String
        start(workspace, query: "кот")
        workspace.search.options.wholeWord = true
        start(workspace, query: "кот")
        XCTAssertEqual(workspace.search.count, 5)
        workspace.search.replacement = "пёс"
        workspace.search.replaceAll()
        settle(0.2)
        XCTAssertEqual(workspace.search.note, "Заменено: 5")
        let shown = document.storage.string
        XCTAssertEqual(shown.components(separatedBy: "пёс").count - 1, 5)
        XCTAssertTrue(shown.contains("Скот"), "слово «Скот» не тронуто")
        XCTAssertFalse(shown.lowercased().contains(" кот "))
        // Слово через границу групп заменено, формат первого куска сохранён.
        XCTAssertTrue(shown.contains("пёс спит"), shown)
        var saved: Bool?
        EditorWindowController.shared.save(tab) { saved = $0 }
        XCTAssertEqual(saved, true, guardShown.first?.problem ?? "")
        // Отмена одним шагом: после записи история цела — вернёт исходный текст.
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original, "«Заменить все» — один шаг отмены")
        XCTAssertFalse(tab.undo.canUndo && (tab.text as String) != original)
    }

    func testReplaceAllRegexAndSkipsProtected() throws {
        let (workspace, tab, document) = try open(Data(DocDemo.expertReport.utf8))
        let original = tab.text as String
        workspace.findMode = true
        workspace.search.options.regex = true
        workspace.search.query = "(\\d+),(\\d+)"
        workspace.search.refresh()
        settle(0.6)  // регулярное выражение ищется в фоне
        XCTAssertGreaterThan(workspace.search.count, 0)
        workspace.search.replacement = "$1.$2"
        workspace.search.replaceAll()
        settle(0.6)
        XCTAssertFalse(document.storage.string.contains("7,4"), document.storage.string)
        XCTAssertTrue(document.storage.string.contains("7.4"))
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original)
    }

    /// Копии настоящих форм (`MU_WORD_REF_DIR`): самое частое слово из 4+ букв → другое слово; запись проходит проверки, отмена — один шаг. Только числа.
    func testReplaceAllOnRealFormCopies() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else { throw XCTSkip("MU_WORD_REF_DIR") }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("rtf")
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".rtf") }.sorted()
        let limit = Int(ProcessInfo.processInfo.environment["MU_FIND_FORMS"] ?? "") ?? 15
        var forms = 0, replaced = 0, skipped = 0, failures = 0
        for (index, file) in names.enumerated() where index % max(1, names.count / limit) == 0 && forms < limit {
            guard let data = try? Data(contentsOf: base.appendingPathComponent(file)), data.count < 300_000 else { continue }
            guardShown = []
            let (workspace, tab, document) = try open(data, name: file)
            let words = (document.storage.string as NSString).components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 }
            var counts: [String: Int] = [:]
            for w in words { counts[w, default: 0] += 1 }
            guard let word = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { continue }
            forms += 1
            let original = tab.text as String
            workspace.findMode = true
            workspace.search.options.caseSensitive = true
            workspace.search.options.wholeWord = true
            workspace.search.query = word
            workspace.search.refresh()
            let found = workspace.search.count
            workspace.search.replacement = "Тест"
            workspace.search.replaceAll()
            let note = workspace.search.note ?? ""
            let done = Int(note.dropFirst("Заменено: ".count).prefix { $0.isNumber }) ?? 0
            replaced += done
            if note.contains("пропущено") { skipped += found - done }
            var saved: Bool?
            EditorWindowController.shared.save(tab) { saved = $0 }
            if saved != true || !guardShown.isEmpty { failures += 1; XCTFail("\(file): запись не прошла проверку") }
            tab.undo.undo()
            if tab.text as String != original { failures += 1; XCTFail("\(file): отмена не вернула файл") }
            for window in windows { window.contentView = nil; window.close() }
            windows = []
        }
        print("S2-AUDIT forms=\(forms) replaced=\(replaced) skipped=\(skipped) failures=\(failures)")
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(forms, 0)
    }
}

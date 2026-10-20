import AppKit
import SwiftUI
import XCTest
@testable import MacUtils

/// Этап 2.5: невидимые символы, парные скобки, regex в фоне и пункты ревью (UTF-16 без BOM, проверка значения,
/// путь вкладки без черновика в сессии).
@MainActor
final class TextEditorViewTests: XCTestCase {
    private var defaults: EditorDefaultsSnapshot!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        _ = NSApplication.shared
        DSFonts.registerAll()
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func hosted(_ tab: EditorTab) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 700, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        tab.container.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        window.contentView = tab.container
        window.orderBack(nil)
        windows.append(window)
        tab.container.layoutSubtreeIfNeeded()
        tab.container.displayIfNeeded()
    }

    // MARK: - Невидимые символы

    /// Неопределённый байт 0x81 (Windows-1252) — в тексте U+0081: без «Невидимых» — нулевой ширины, с ними — бейдж ‹81›.
    func testUndefinedByteGetsBadgeWidthOnlyWithInvisibles() throws {
        let data = Data([0x61, 0x81, 0x62, 0x0D, 0x0A, 0x09, 0x20, 0x63])
        let document = EditorDocument(data: data)
        XCTAssertEqual(document.encoding, .windows1252)
        let tab = EditorTab(document: document)
        hosted(tab)
        let layout = try XCTUnwrap(tab.textView.layoutManager as? EditorLayoutManager)
        func advance(at index: Int) -> CGFloat {
            layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: tab.storage.length))
            let next = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: index + 1)).x
            return next - layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: index)).x
        }
        XCTAssertEqual(advance(at: 1), 0, accuracy: 0.5, "без «Невидимых» байт не виден")
        tab.showsInvisibles = true
        XCTAssertGreaterThan(advance(at: 1), 15, "бейдж ‹81› занимает место")
        XCTAssertEqual(EditorLayoutManager.badge(0x81), "‹81›")
        XCTAssertEqual(EditorLayoutManager.badge(0x9D), "‹9D›")
        tab.container.needsDisplay = true
        tab.container.displayIfNeeded()   // рисование ·, →, ¤¶ и бейджа не падает
        tab.showsInvisibles = false
        XCTAssertEqual(advance(at: 1), 0, accuracy: 0.5)
        XCTAssertEqual(tab.text as String, "a\u{81}b\r\n\t c", "текст и байты не меняются")
        XCTAssertEqual(try tab.document.data(for: tab.text as String), data)
    }

    // MARK: - Парные скобки

    func testBracketMatching() {
        let text = #"{\rtf1 {\b x} \{ (a[b]c) }"# as NSString
        XCTAssertEqual(BracketMatcher.match(in: text, caret: 0), .pair(0, text.length - 1), "курсор перед `{`")
        XCTAssertEqual(BracketMatcher.match(in: text, caret: 8), .pair(7, 12), "курсор после `{` — пара её `}`")
        XCTAssertEqual(BracketMatcher.match(in: text, caret: 13), .pair(12, 7), "после `}`")
        XCTAssertNil(BracketMatcher.match(in: text, caret: 16), "`\\{` в RTF — не скобка")
        XCTAssertTrue(BracketMatcher.isEscaped(text, 15))
        let paren = text.range(of: "(").location
        XCTAssertEqual(BracketMatcher.match(in: text, caret: paren), .pair(paren, text.range(of: ")").location))
        XCTAssertEqual(BracketMatcher.match(in: "x { y" as NSString, caret: 2), .unmatched(2))
        XCTAssertNil(BracketMatcher.match(in: "abc" as NSString, caret: 1))
        XCTAssertNil(BracketMatcher.match(in: "" as NSString, caret: 0))
    }

    func testBracketHighlightFollowsCaret() throws {
        let tab = EditorTab(document: EditorDocument(data: Data("{\\b x} y".utf8)))
        hosted(tab)
        let layout = try XCTUnwrap(tab.textView.layoutManager)
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNotNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 5, effectiveRange: nil), "пара `}` подсвечена")
        tab.textView.setSelectedRange(NSRange(location: 7, length: 0))
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 5, effectiveRange: nil), "курсор ушёл — подсветка снята")
        tab.matchesBrackets = false
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNil(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 5, effectiveRange: nil), "выключено в «Виде»")
    }

    // MARK: - Regex в фоне

    /// Выражение с катастрофическим перебором не держит главный поток; новый запрос прерывает прежний поиск.
    func testCatastrophicRegexRunsInBackgroundAndIsCancelled() throws {
        let text = String(repeating: "a", count: 40) + "!"
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: Data(text.utf8)))
        workspace.add(tab)
        workspace.findMode = false
        let search = workspace.search
        search.options = SearchOptions(regex: true)
        search.query = "(a+)+$"
        let started = Date()
        search.refresh()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2, "поиск ушёл в фон")
        XCTAssertTrue(search.searching)
        XCTAssertEqual(search.counter, "Ищу…")
        search.query = "a{3}"
        search.refresh()
        let deadline = Date().addingTimeInterval(5)
        while search.searching, Date() < deadline { settle(0.02) }
        XCTAssertFalse(search.searching, "новый запрос прервал долгий перебор")
        XCTAssertEqual(search.count, 13)
        XCTAssertNil(search.error)
    }

    func testCancellationStopsMatching() {
        let cancel = TextSearch.Cancellation()
        cancel.cancel()
        XCTAssertThrowsError(try TextSearch.find("(a+)+$", in: String(repeating: "a", count: 40) + "!" as NSString,
                                                 options: SearchOptions(regex: true), isCancelled: { cancel.isCancelled })) {
            XCTAssertEqual($0 as? TextSearch.Failure, .cancelled)
        }
        XCTAssertTrue(TextSearch.Cancellation(timeout: -1).isCancelled, "предел по времени")
    }

    // MARK: - Пункты ревью

    /// UTF-16 без BOM («Открыть заново в UTF-16») сохраняется без BOM; «Преобразовать в UTF-16» — с BOM.
    func testUTF16WithoutBOMStaysWithoutBOM() throws {
        let bytes = Data([0x41, 0x00, 0x42, 0x00])            // «AB» в UTF-16 LE без BOM
        var document = EditorDocument(data: bytes)
        document.reinterpret(as: .utf16LE)
        XCTAssertEqual(document.decodedText, "AB")
        XCTAssertFalse(document.utf16BOM)
        XCTAssertEqual(try document.data(for: "ABC"), Data([0x41, 0x00, 0x42, 0x00, 0x43, 0x00]))
        var withBOM = EditorDocument(data: Data([0xFF, 0xFE, 0x41, 0x00]))
        XCTAssertEqual(withBOM.encoding, .utf16LE)
        XCTAssertTrue(withBOM.utf16BOM)
        XCTAssertEqual(try withBOM.data(for: "AB"), Data([0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00]))
        withBOM.reinterpret(as: .utf16BE)
        XCTAssertFalse(withBOM.utf16BOM, "FF FE — не BOM для BE")
        XCTAssertEqual(TextEncoding.utf16BE.encode("A", utf16BOM: true), Data([0xFE, 0xFF, 0x00, 0x41]))
    }

    func testValueCheckBeforeRemoval() {
        let text = "a $AB c $D" as NSString
        XCTAssertTrue(DollarMarks.isValue(NSRange(location: 3, length: 2), in: text))
        XCTAssertTrue(DollarMarks.isValue(NSRange(location: 9, length: 1), in: text), "до конца текста")
        XCTAssertFalse(DollarMarks.isValue(NSRange(location: 3, length: 1), in: text), "после диапазона значение продолжается")
        XCTAssertFalse(DollarMarks.isValue(NSRange(location: 3, length: 4), in: text), "внутри завершитель")
        XCTAssertFalse(DollarMarks.isValue(NSRange(location: 4, length: 1), in: text), "перед диапазоном не `$`")
    }

    /// Одиночное «Убрать значение» по устаревшей строке списка (текст сдвинулся, а `$` оказался на том же месте)
    /// не удаляет чужие символы: проверка значения и пересчёт.
    func testSingleRemovalWithStaleEntryDoesNothing() throws {
        let tab = EditorTab(document: EditorDocument(data: Data("x $AB c".utf8)))
        hosted(tab)
        let deadline = Date().addingTimeInterval(3)
        while tab.dollars.entries.count != 1, Date() < deadline { settle(0.02) }
        let stale = try XCTUnwrap(tab.dollars.entries.first)
        // Сдвиг: `$` на прежнем месте, но значение теперь короче.
        tab.storage.replaceCharacters(in: NSRange(location: 3, length: 2), with: "Z c")
        XCTAssertEqual(tab.text as String, "x $Z c c")
        XCTAssertEqual(tab.removeValues([stale]), 0)
        XCTAssertEqual(tab.text as String, "x $Z c c", "чужие символы не удалены")
        XCTAssertTrue(tab.dollars.isCurrent, "список пересчитан сразу")
        XCTAssertEqual(tab.dollars.entries.first?.value, "Z")
    }

    /// Без черновиков вкладка, по которой ответили «Не сохранять», всё равно вернётся (файл с диска, без правок).
    func testDirtyTabWithoutDraftsKeepsPathInSession() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("editor-nodraft-\(UUID().uuidString)", isDirectory: true)
        let saved = EditorSession.folder
        EditorSession.folder = folder
        defer { EditorSession.folder = saved; try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.txt")
        try Data("disk".utf8).write(to: file)
        UserDefaults.standard.set(true, forKey: Pref.editorRestoreSession)
        UserDefaults.standard.set(false, forKey: Pref.editorAutosaveDrafts)
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: try EditorDocument.open(file))
        tab.textView.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))
        workspace.add(tab)
        XCTAssertTrue(tab.isDirty)
        EditorSession.save(workspace)
        let restored = EditorWorkspace()
        EditorSession.restore(into: restored)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertEqual(restored.tabs.first?.text as String?, "disk")
        XCTAssertFalse(restored.tabs.first?.isDirty ?? true)
    }

    /// Снимок «Невидимых символов» и парных скобок для сверки глазами (только с `MU_EDITOR_SNAPSHOTS`).
    func testInvisiblesSnapshot() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_EDITOR_SNAPSHOTS"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_EDITOR_SNAPSHOTS=<папка>")
        }
        var data = Data("{\\rtf1\\ansicpg1252 {\\b Total:}\t$SUM \\par\r\nByte ".utf8)
        data.append(0x81)
        data.append(contentsOf: Array(" and ".utf8))
        data.append(0x9D)
        data.append(contentsOf: Array(" here\r\nLF only\nCR only\r}".utf8))
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: data, url: URL(fileURLWithPath: "/tmp/invisibles.frm")))
        workspace.add(tab)
        workspace.showsInvisibles = true
        workspace.dollarPanelVisible = false
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 260), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: EditorRootView(workspace: workspace))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 260)
        window.contentView = host
        window.orderBack(nil)
        windows.append(window)
        settle(0.4)
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        settle(0.3)
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 520, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("editor-f-invisibles-dark.png"))
    }
}

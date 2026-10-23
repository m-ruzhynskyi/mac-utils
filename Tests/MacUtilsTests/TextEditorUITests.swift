import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign

/// Настоящее окно редактора офскрин: правка через `EditorTextView` (один шаг отмены), «Убрать значения» на фикстурах,
/// строка состояния. С `MU_EDITOR_SNAPSHOTS=<папка>` — ещё и PNG 2x для сверки с макетами (`.audit/text-editor-design/`).
@MainActor
final class TextEditorUITests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        _ = NSApplication.shared
        DSFonts.registerAll()
        UserDefaults.standard.set(true, forKey: Pref.editorSkipFirst)
        UserDefaults.standard.set(3, forKey: Pref.editorSkipCount)
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    /// Регулярное выражение ищется в фоне — ждём результата.
    private func waitSearch(_ search: EditorSearch) {
        let deadline = Date().addingTimeInterval(5)
        while search.searching, Date() < deadline { settle(0.02) }
    }

    /// Демо-форма счёта (как на макетах): первые три `$` — служебные в `\info`.
    static let demo = [
        #"{\rtf1\adeflang1025\ansi\ansicpg1252\uc1\adeff0\deff0\stshfdbch0\stshfloch0\stshfhich0\deflang1033"#,
        #"{\fonttbl{\f0\froman\fcharset0 Times New Roman;}{\f1\fswiss\fcharset0 Arial;}}"#,
        #"{\colortbl;\red0\green0\blue0;\red31\green111\blue219;}"#,
        #"{\info{\title $FORM_TITLE}{\author $AUTHOR}{\version $REV}}"#,
        #"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134"#,
        #"\pard\plain\qc\f1\fs28\b INVOICE\b0\par"#,
        #"\pard\plain\f1\fs20 No. $INV_NO dated $DATE\par"#,
        #"\par"#,
        #"{\b Bill to:}\tab $CLIENT_NAME\par"#,
        #"\tab $CLIENT_ADDR\par"#,
        #"\tab VAT ID $CLIENT_VAT\par"#,
        #"\par"#,
        #"\trowd\cellx4500\cellx6000\cellx7500\cellx9000"#,
        #"{\b Item}\cell{\b Qty}\cell{\b Price}\cell{\b Sum}\cell\row"#,
        #"$ITEM_1\cell $QTY_1\cell $PRICE_1 \'80\cell $SUM_1\cell\row"#,
        #"$ITEM_2\cell $QTY_2\cell $PRICE_2 \'80\cell $SUM_2\cell\row"#,
        #"\pard\par"#,
        #"\qr Subtotal: $SUBTOTAL \'80\par"#,
        #"VAT 20%: $VAT \'80\par"#,
        #"{\b Total: $TOTAL \'80}\par"#,
        #"\pard\par"#,
        #"Payment due within $DAYS days. Merci beaucoup \'97 $COMPANY\par"#,
        #"\pard\qr $SIGNATURE\par"#,
        #"}"#,
    ].joined(separator: "\r\n")

    private func host(_ workspace: EditorWorkspace, size: NSSize = NSSize(width: 800, height: 540), dark: Bool = false) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = NSHostingView(rootView: EditorRootView(workspace: workspace).environment(\.controlActiveState, .key))
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderBack(nil)
        windows.append(window)
        settle()
        return window
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func tab(_ text: String, url: URL? = URL(fileURLWithPath: "/tmp/invoice_demo.frm")) -> (EditorWorkspace, EditorTab) {
        let workspace = EditorWorkspace()
        var document = EditorDocument(data: TextEncoding.windows1252.encode(text)!, url: url)
        document.language = .rtf
        let tab = EditorTab(document: document)
        workspace.add(tab)
        return (workspace, tab)
    }

    /// Ждём фоновый скан `$` (debounce и очередь).
    private func waitForScan(_ tab: EditorTab, count: Int, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while tab.dollars.entries.count != count, Date() < deadline { settle(0.05) }
        XCTAssertEqual(tab.dollars.entries.count, count, file: file, line: line)
    }

    // MARK: - «Убрать значения» на фикстурах: текст как в expected.json, один шаг отмены

    func testRemoveValuesOnFixturesIsOneUndoStep() throws {
        let folder = TextEditorAcceptanceTests.folder
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("expected.json"))) as! [String: Any]
        let files = expected["files"] as! [String: [String: Any]]
        for name in ["02-four-dollars.frm", "05-double-dollar.frm", "11-cp1252-high-bytes.frm", "13-cp1251-cyrillic.frm", "07-empty-values.frm"] {
            let info = try XCTUnwrap(files[name])
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            let workspace = EditorWorkspace()
            let tab = EditorTab(document: EditorDocument(data: data, url: folder.appendingPathComponent(name)))
            // expected.json описывает правило исходника; правило по видимому тексту RTF — TextEditorRTFValueTests.
                workspace.add(tab)
            _ = host(workspace)
            waitForScan(tab, count: info["dollar_count"] as! Int)
            let original = tab.text as String

            for (skipOn, key) in [(true, "strip_skip3_text"), (false, "strip_all_text")] {
                UserDefaults.standard.set(skipOn, forKey: Pref.editorSkipFirst)
                settle(0.05)
                XCTAssertEqual(tab.dollars.skip, skipOn ? 3 : nil, name)
                tab.removeValues(Array(tab.dollars.split.active))
                XCTAssertEqual(tab.text as String, info[key] as? String, "\(name): \(key)")
                if tab.text as String != original {
                    XCTAssertTrue(tab.isDirty, name)
                    XCTAssertTrue(tab.undo.canUndo, name)
                    tab.undo.undo()
                    XCTAssertEqual(tab.text as String, original, "\(name): одна отмена возвращает всё")
                    XCTAssertFalse(tab.isDirty, "\(name): после отмены — как сохранённый")
                    tab.undo.redo()
                    XCTAssertEqual(tab.text as String, info[key] as? String, "\(name): повтор")
                    tab.undo.undo()
                }
                waitForScan(tab, count: info["dollar_count"] as! Int)
            }
            // Сохранение без правок — исходные байты.
            XCTAssertEqual(try tab.document.data(for: tab.text as String), data, name)
        }
        UserDefaults.standard.set(true, forKey: Pref.editorSkipFirst)
    }

    func testRemoveSingleValueAndSkippedToo() throws {
        let (workspace, tab) = tab(Self.demo)
        _ = host(workspace)
        waitForScan(tab, count: 22)
        // Значение — до конца строки или следующего `$`: у первого пропущенного это `FORM_TITLE}{\author `.
        let skipped = try XCTUnwrap(tab.dollars.split.skipped.first)
        XCTAssertEqual(skipped.value, #"FORM_TITLE}{\author"#)
        XCTAssertEqual(tab.removeValues([skipped]), 1)
        XCTAssertTrue((tab.text as String).contains(#"{\info{\title $$AUTHOR}"#))
        XCTAssertNil(tab.dollars.unbalancedAfterRemoval, "убраны `}` и `{` — баланс тот же")
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, Self.demo)
    }

    /// 08-long-line: клик по `deep20k` прокручивает к нему по горизонтали; пустой файл — «Знаков $ нет».
    func testRevealInLongLineAndEmptyPanel() throws {
        let url = TextEditorAcceptanceTests.folder.appendingPathComponent("08-long-line.frm")
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: try EditorDocument.open(url))
        workspace.add(tab)
        _ = host(workspace)
        waitForScan(tab, count: 4)
        let deep = try XCTUnwrap(tab.dollars.entries.first { $0.value.hasPrefix("deep20k") })
        XCTAssertEqual(tab.scrollView.contentView.bounds.minX, 0)
        tab.dollars.selected = deep.id
        tab.reveal(deep.mark.whole)
        settle(0.2)
        XCTAssertEqual(tab.textView.selectedRange(), deep.mark.whole)
        XCTAssertGreaterThan(tab.scrollView.contentView.bounds.minX, 1_000, "прокрутка вбок к 20-тысячному символу")

        let empty = EditorTab(document: try EditorDocument.open(TextEditorAcceptanceTests.folder.appendingPathComponent("03-zero-dollars.frm")))
        workspace.add(empty)
        settle(0.3)
        XCTAssertTrue(empty.dollars.entries.isEmpty)
        XCTAssertFalse(empty.dollars.scanning)
        XCTAssertEqual(empty.dollars.removableCount, 0)
    }

    /// Панель с 4 184 знаками (файл 10 МБ): список ленивый — показ и смена выбора не тормозят.
    func testPanelWithThousandsOfMarks() {
        let big = TextEditorPerformanceTests.bigFile()
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: big.data, url: URL(fileURLWithPath: "/tmp/big.frm")))
        workspace.add(tab)
        let window = host(workspace, size: NSSize(width: 1000, height: 700))
        // Скан 10 МБ в фоне: под нагрузкой (полный прогон) — дольше; не дождались — проверка, а не падение процесса.
        waitForScan(tab, count: big.dollars, timeout: 30)
        guard tab.dollars.entries.count == big.dollars else { return }
        let select = TextEditorPerformanceTests.measure {
            tab.dollars.selected = tab.dollars.entries[big.dollars / 2].id
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        print(String(format: "[editor-perf] %@ панель с %d знаками: смена выбора и перерисовка %.0f мс", TextEditorPerformanceTests.build, big.dollars, select))
        XCTAssertLessThan(select, TextEditorPerformanceTests.limit(300))
    }

    // MARK: - Поиск и замена (09-crlf)

    func testFindReplaceInEditor() throws {
        let url = TextEditorAcceptanceTests.folder.appendingPathComponent("09-crlf.frm")
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: try EditorDocument.open(url))
        workspace.add(tab)
        _ = host(workspace)
        let search = workspace.search
        workspace.findMode = true
        search.query = "two"
        search.refresh()
        XCTAssertEqual(search.counter, "1 из 2", "«Line two» и «$two» (в CHECKLIST 7.1 указано одно)")
        search.query = "Line"
        search.options.wholeWord = true
        search.options.caseSensitive = true
        search.refresh()
        XCTAssertEqual(search.count, 3)
        search.options = SearchOptions(regex: true)
        search.query = "("
        search.refresh()
        waitSearch(search)
        XCTAssertNotNil(search.error, "ошибка выражения — в поле, без падения")
        // Замена по группам — один шаг отмены.
        let original = tab.text as String
        search.query = #"\$(\w+)"#
        search.replacement = "<$1>"
        search.refresh()
        waitSearch(search)
        settle(0.05)
        search.replaceAll()
        waitSearch(search)
        XCTAssertFalse((tab.text as String).contains("$"))
        XCTAssertTrue((tab.text as String).contains("<one>"))
        XCTAssertEqual(search.note, "Заменено: 4")
        settle(0.05)
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original)
        // «В выделении»: строки 2–3.
        let lines = LineIndex(tab.text)
        tab.textView.setSelectedRange(NSRange(location: lines.starts[1], length: lines.starts[3] - lines.starts[1]))
        search.options = SearchOptions(inSelection: true)
        search.query = "$"
        search.refresh()
        XCTAssertEqual(search.count, 2)
        // «Далее» по кругу и пустой запрос.
        search.options = SearchOptions()
        tab.textView.setSelectedRange(NSRange(location: tab.storage.length, length: 0))
        search.next()
        XCTAssertTrue(search.wrapped)
        search.query = ""
        search.refresh()
        XCTAssertTrue(tab.matches.isEmpty)
        XCTAssertEqual(search.counter, "")
        // Перейти к строке: вне диапазона — к последней.
        tab.goTo(line: 4)
        XCTAssertEqual(tab.caret.line, 4)
        tab.goTo(line: 999, column: 999)
        XCTAssertEqual(tab.caret.line, tab.lineCount)
        tab.goTo(line: 0)
        XCTAssertEqual(tab.caret.line, 1)
    }

    func testFindDollarInTenMegabytes() throws {
        let big = TextEditorPerformanceTests.bigFile()
        let text = try XCTUnwrap(TextEncoding.windows1252.decode(big.data)) as NSString
        var result = TextSearch.Result(ranges: [], truncated: false)
        let time = TextEditorPerformanceTests.measure { result = (try? TextSearch.find("$", in: text, options: SearchOptions())) ?? result }
        XCTAssertEqual(result.ranges.count, big.dollars)
        print(String(format: "[editor-perf] %@ поиск $ в 10 МБ: %.0f мс (%d)", TextEditorPerformanceTests.build, time, result.ranges.count))
        XCTAssertLessThan(time, TextEditorPerformanceTests.limit(300))
    }

    // MARK: - Строка состояния, перевод строки, режим замены

    func testCaretLineEndingAndOverwrite() {
        let (workspace, tab) = tab("Line one\r\nLine two\r\n")
        _ = host(workspace)
        tab.textView.setSelectedRange(NSRange(location: 10, length: 0))
        XCTAssertEqual(tab.caret.line, 2)
        XCTAssertEqual(tab.caret.column, 1)
        tab.textView.setSelectedRange(NSRange(location: 0, length: 14))
        XCTAssertEqual(tab.caret.selected, 14)
        XCTAssertEqual(tab.caret.selectedLines, 2)
        XCTAssertEqual(tab.lineEnding, .single(.crlf))
        XCTAssertEqual(tab.lineCount, 3)

        // Enter вставляет перевод строки документа.
        tab.textView.setSelectedRange(NSRange(location: 8, length: 0))
        tab.textView.insertNewline(nil)
        XCTAssertEqual(tab.text as String, "Line one\r\n\r\nLine two\r\n")
        settle(0.05)
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, "Line one\r\nLine two\r\n")

        // Режим замены: набранное заменяет следующее, но не перевод строки.
        tab.textView.overwrite = true
        XCTAssertTrue(tab.overwrite)
        tab.textView.setSelectedRange(NSRange(location: 5, length: 0))
        tab.textView.insertText("ONE!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tab.text as String, "Line ONE!\r\nLine two\r\n")
        tab.textView.overwrite = false
        settle(0.05) // отдельное событие — отдельный шаг отмены, как при наборе

        // CRLF → LF одним шагом отмены.
        tab.convertLineEndings(to: .lf)
        XCTAssertEqual(tab.text as String, "Line ONE!\nLine two\n")
        XCTAssertEqual(tab.lineEnding, .single(.lf))
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, "Line ONE!\r\nLine two\r\n")
    }

    func testTypingKeepsLineIndexInSync() {
        let (workspace, tab) = tab("a\r\nb\rc\nd")
        _ = host(workspace)
        for (location, insert) in [(1, "\r"), (2, "\n"), (0, "x\ny"), (5, ""), (3, "\r\n\r")] {
            tab.textView.setSelectedRange(NSRange(location: min(location, tab.storage.length), length: insert.isEmpty ? 1 : 0))
            if insert.isEmpty { tab.textView.deleteBackward(nil) } else { tab.textView.insertText(insert, replacementRange: tab.textView.selectedRange()) }
            XCTAssertEqual(tab.lines.starts, LineIndex(tab.text).starts, "после \(insert.debugDescription) в \(location)")
        }
    }

    // MARK: - Окно

    /// «Светофор» — по центру полосы заголовка 50 pt, а клик по вкладкам доходит до SwiftUI, а не до заголовка окна.
    func testTitleBarLightsAndClicks() throws {
        let workspace = EditorWorkspace()
        _ = workspace.newDocument()
        let window = EditorWindow.make(workspace: workspace, size: NSSize(width: 900, height: 600))
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        windows.append(window)
        settle()
        window.centerTrafficLights()
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let center = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        XCTAssertEqual(center.y, window.frame.height - EditorRootView.titleBarHeight / 2, accuracy: 1.5)
        XCTAssertEqual(center.x, 27, accuracy: 3)
        let content = try XCTUnwrap(window.contentView)
        let frame = try XCTUnwrap(content.superview)
        for x in [140.0, 300.0, 820.0, 870.0] {
            let point = frame.convert(NSPoint(x: x, y: window.frame.height - 25), from: nil)
            let hit = frame.hitTest(point)
            XCTAssertTrue(hit?.isDescendant(of: content) == true, "x=\(x): \(String(describing: hit))")
        }
        // Кнопки окна остаются кнопками.
        let lights = frame.hitTest(frame.convert(center, from: nil))
        XCTAssertTrue(lights === close || lights?.isDescendant(of: close) == true, String(describing: lights))
    }

    // MARK: - Снимки для сверки с макетами

    func testSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_EDITOR_SNAPSHOTS"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_EDITOR_SNAPSHOTS=<папка>, чтобы снять окно редактора")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            // a — главное окно: три вкладки, выбранный $CLIENT_NAME, курсор в строке 9.
            let (workspace, tab) = tab(Self.demo)
            let second = EditorTab(document: EditorDocument(data: Data("{\\rtf1 $A}".utf8), url: URL(fileURLWithPath: "/tmp/contract_demo.frm")))
            workspace.add(second, select: false)
            let untitled = workspace.newDocument()
            untitled.textView.insertText("черновик", replacementRange: NSRange(location: 0, length: 0))
            workspace.selectedID = tab.id
            workspace.dollarPanelVisible = true
            let window = host(workspace, dark: dark)
            waitForScan(tab, count: 22)
            let client = try XCTUnwrap(tab.dollars.entries.first { $0.value == "CLIENT_NAME" })
            tab.dollars.selected = client.id
            tab.textView.setSelectedRange(NSRange(location: client.mark.dollar + 13, length: 0))
            tab.bookmarks = [14]
            tab.rehighlight()
            settle()
            try write(window, to: folder.appendingPathComponent("editor-a-main-\(suffix).png"))

            workspace.overlay = .encoding
            settle()
            try write(window, to: folder.appendingPathComponent("editor-b-encoding-\(suffix).png"))
            workspace.overlay = nil

            workspace.findMode = true
            workspace.search.options.regex = true
            workspace.search.query = #"\$(SUM|PRICE)_\d"#
            workspace.search.replacement = "$LINE_TOTAL"
            workspace.dollarPanelVisible = false
            settle()
            workspace.search.refresh()
            waitSearch(workspace.search)
            settle()
            try write(window, to: folder.appendingPathComponent("editor-c-find-\(suffix).png"))
            workspace.findMode = nil
            workspace.search.clear()
            workspace.dollarPanelVisible = true

            UserDefaults.standard.set(false, forKey: Pref.editorSkipFirst)
            settle()
            try write(window, to: folder.appendingPathComponent("editor-d1-skip-off-\(suffix).png"))
            UserDefaults.standard.set(true, forKey: Pref.editorSkipFirst)
            settle()
            tab.dollars.selected = nil
            tab.removeValues(Array(tab.dollars.split.active))
            settle(0.6)
            try write(window, to: folder.appendingPathComponent("editor-d2-after-clear-\(suffix).png"))
        }
        // e1 — вкладка «Редактор» в панели 🔧 (настройки раннера тестов, а не приложения).
        UserDefaults.standard.set(SettingsSection.textEditor.rawValue, forKey: Pref.toolsTab)
        UserDefaults.standard.set(PanelTabs.defaultValue, forKey: Pref.toolsPanelTabs)
        let panelSize = NSSize(width: DS.Size.popover.width, height: DS.Size.popover.height)
        let panel = NSHostingView(rootView: ToolsView(inPopover: true).frame(width: panelSize.width, height: panelSize.height))
        panel.frame = NSRect(origin: .zero, size: panelSize)
        let panelWindow = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: panelSize), styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        panelWindow.isReleasedWhenClosed = false
        panelWindow.appearance = NSAppearance(named: .darkAqua)
        panelWindow.contentView = panel
        panelWindow.orderBack(nil)
        windows.append(panelWindow)
        settle(0.8)
        try write(panelWindow, to: folder.appendingPathComponent("editor-e1-panel-dark.png"))

        let settings = NSHostingView(rootView: TextEditorPage().frame(width: 760, height: 760))
        settings.frame = NSRect(x: 0, y: 0, width: 760, height: 760)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 760, height: 760), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = settings
        window.orderBack(nil)
        windows.append(window)
        settle()
        try write(window, to: folder.appendingPathComponent("editor-e2-settings-light.png"))
    }

    private func write(_ window: NSWindow, to url: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

/// По ревью: ⌘S сверяется с диском, открываются только обычные файлы, запись не рвёт символическую ссылку.
@MainActor
final class EditorSaveSafetyTests: XCTestCase {
    private var folder: URL!
    private var savedPrompt: ((EditorTab, @escaping (EditorWindowController.ExternalChangeChoice) -> Void) -> Void)!
    private var asked = 0

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("editor-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedPrompt = EditorWindowController.shared.externalChangePrompt
        asked = 0
    }

    override func tearDown() {
        EditorWindowController.shared.externalChangePrompt = savedPrompt
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func answer(_ choice: EditorWindowController.ExternalChangeChoice) {
        EditorWindowController.shared.externalChangePrompt = { [weak self] _, reply in
            self?.asked += 1
            reply(choice)
        }
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func save(_ tab: EditorTab) -> Bool {
        var result: Bool?
        EditorWindowController.shared.save(tab) { result = $0 }
        return result ?? false
    }

    /// Сценарий B: правят в окне, а файл тем временем переписала другая программа — без согласия не пишем.
    func testEditedTabDoesNotOverwriteExternalChange() throws {
        let url = try file("form.frm", "one $A\n")
        let tab = EditorTab(document: try EditorDocument.open(url))
        tab.textView.insertText("my ", replacementRange: NSRange(location: 0, length: 0))
        try Data("external version $B\n".utf8).write(to: url)

        answer(.cancel)
        XCTAssertFalse(save(tab))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external version $B\n", "отмена — чужая версия на месте")
        XCTAssertTrue(tab.isDirty)

        answer(.overwrite)
        XCTAssertTrue(save(tab))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "my one $A\n", "явное «Перезаписать»")
        XCTAssertFalse(tab.isDirty)
        // После записи отпечаток новый — следующий ⌘S без вопроса.
        tab.textView.insertText("!", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(save(tab))
        XCTAssertEqual(asked, 2)
    }

    /// Сценарий A: файл не правили, появился баннер «изменён на диске», ⌘S по привычке — старые байты не пишутся.
    func testUneditedTabWithBannerAsksAndReloads() throws {
        let url = try file("form.frm", "old $A\n")
        let tab = EditorTab(document: try EditorDocument.open(url))
        try Data("new from git $B\n".utf8).write(to: url)
        tab.changedOnDisk = tab.document.isChangedOnDisk
        XCTAssertTrue(tab.changedOnDisk)

        answer(.reload)
        XCTAssertFalse(save(tab))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new from git $B\n", "файл не тронут")
        XCTAssertEqual(tab.text as String, "new from git $B\n", "«Перезагрузить» показывает версию с диска")
        XCTAssertFalse(tab.changedOnDisk)
        XCTAssertFalse(tab.isDirty)
    }

    func testSaveThroughSymlinkKeepsLink() throws {
        let target = try file("real.txt", "abc")
        let link = folder.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let tab = EditorTab(document: try EditorDocument.open(link))
        tab.textView.insertText("x", replacementRange: NSRange(location: 3, length: 0))
        answer(.cancel)
        XCTAssertTrue(save(tab))
        XCTAssertEqual(asked, 0, "своя запись через ссылку — не «изменён снаружи»")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path, "ссылка осталась ссылкой")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "abcx")
        XCTAssertFalse(tab.document.isChangedOnDisk)
    }

    func testOpensOnlyRegularFiles() throws {
        let regular = try file("a.txt", "a")
        XCTAssertEqual(EditorWindowController.openCheck(regular), .ok)
        guard case .unreadable = EditorWindowController.openCheck(folder) else { return XCTFail("папка") }
        guard case .unreadable = EditorWindowController.openCheck(URL(fileURLWithPath: "/dev/zero")) else { return XCTFail("устройство") }
        guard case .unreadable = EditorWindowController.openCheck(folder.appendingPathComponent("missing.txt")) else { return XCTFail("нет файла") }
        let fifo = folder.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        guard case .unreadable = EditorWindowController.openCheck(fifo) else { return XCTFail("канал") }
        XCTAssertThrowsError(try EditorDocument.open(URL(fileURLWithPath: "/dev/zero")), "модель тоже не читает устройства")
        XCTAssertThrowsError(try EditorDocument.open(fifo))
        // Большой файл — с вопросом (порог проверяется по размеру, файл не читается).
        let big = folder.appendingPathComponent("big.log")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(EditorWindowController.largeFileBytes + 1))
        try handle.close()
        XCTAssertEqual(EditorWindowController.openCheck(big), .large(EditorWindowController.largeFileBytes + 1))
    }
}

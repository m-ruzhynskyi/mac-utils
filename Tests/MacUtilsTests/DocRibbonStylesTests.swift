import AppKit
import SwiftUI
import XCTest
@testable import MUCore
@testable import MUDesign
@testable import MUTextEditor

/// S1 в ленте: плитки и список стилей, подсветка текущего, доступность, ужатие группы, снимки `s1-*`.
@MainActor
final class DocRibbonStylesTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.set(DocRibbonTab.home.rawValue, forKey: Pref.editorRibbonTab)
        UserDefaults.standard.set(false, forKey: Pref.editorInvisibles)
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    @discardableResult
    private func host(_ workspace: EditorWorkspace, width: CGFloat = 1440, dark: Bool = false) -> NSWindow {
        let size = NSSize(width: width, height: 640)
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

    private func open(width: CGFloat = 1440, dark: Bool = false) throws -> (EditorTab, DocumentController, NSWindow) {
        let (workspace, tab) = DocDemo.tab(DocStylesTests.source, name: "ribbon_styles.frm")
        tab.restoreMode(.document)
        let window = host(workspace, width: width, dark: dark)
        let document = try XCTUnwrap(tab.documentController)
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
        settle()
        return (tab, document, window)
    }

    private func select(_ text: String, in document: DocumentController, length: Int? = nil) {
        let range = (document.storage.string as NSString).range(of: text)
        document.textViews.first?.setSelectedRange(NSRange(location: range.location, length: length ?? range.length))
        document.updateStatus()
        settle(0.15)
    }

    /// Окно только с группой «Стили» (ширина достаточна для четырёх плиток): щелчки — внутренние события окна, в систему ничего не уходит.
    private func hostGroup(_ document: DocumentController, level: Int, width: CGFloat = 640) -> NSWindow {
        let formatter = DocFormatter.of(document)
        let view = NSHostingView(rootView: DocStylesGroup(document: document, formatter: formatter, level: level)
            .environment(\.controlActiveState, .key).background(Color.dsBg))
        view.frame = NSRect(x: 0, y: 0, width: width, height: 90)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 90), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        windows.append(window)
        settle()
        return window
    }

    private func click(_ window: NSWindow, x: CGFloat, y: CGFloat) {
        // Координаты окна — от левого нижнего угла.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: window.frame.height - y), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        settle(0.15)
    }

    private func fittingWidth(_ document: DocumentController, level: Int) -> CGFloat {
        let view = NSHostingView(rootView: DocStylesGroup(document: document, formatter: DocFormatter.of(document), level: level))
        return view.fittingSize.width
    }

    // MARK: - Плитки

    func testTilesAreMostUsedAndCurrentIsAlwaysShown() {
        let sheet = DocStyleSheet.parse(DocStylesTests.source as NSString)
        let usage = [0: 5, 1: 3, 2: 1]
        XCTAssertEqual(DocRibbonStyles.tiles(sheet, usage: usage, current: nil, count: 2).map(\.number), [0, 1], "самые используемые")
        XCTAssertEqual(DocRibbonStyles.tiles(sheet, usage: usage, current: 2, count: 2).map(\.number), [0, 2], "текущий стиль не прячется")
        XCTAssertEqual(DocRibbonStyles.tiles(sheet, usage: [:], current: nil, count: 3).map(\.number), [0, 1, 2], "без использования — по номеру")
        XCTAssertTrue(DocRibbonStyles.tiles(sheet, usage: usage, current: nil, count: 0).isEmpty)
        XCTAssertEqual((0...5).map(DocRibbonStyles.tileCount(level:)), [4, 3, 2, 0, 0, 0], "ужатие: 4 → 3 → 2 плитки → одна кнопка-меню")
    }

    func testTipsExplainDisabledStyles() throws {
        let sheet = DocStyleSheet.parse(DocStylesTests.source as NSString)
        let heading = try XCTUnwrap(sheet.style(.paragraph, 1))
        XCTAssertEqual(DocRibbonStyles.tip(heading, .enabled), "Стиль «Заголовок 1»")
        XCTAssertEqual(DocRibbonStyles.tip(heading, .disabled("нельзя")), "Стиль «Заголовок 1» — нельзя")
    }

    // MARK: - В окне

    /// Подсветка текущего: «Обычный» у абзаца без `\sN`, иначе номер стиля; ленточное состояние следует за курсором.
    func testCurrentStyleFollowsCaret() throws {
        let (_, document, _) = try open()
        let formatter = DocFormatter.of(document)
        select("Third", in: document, length: 0)
        XCTAssertEqual(DocRibbonStyles.currentNumber(formatter.state.paragraph), 0, "без \\sN — «Обычный»")
        select("Second", in: document, length: 0)
        XCTAssertEqual(DocRibbonStyles.currentNumber(formatter.state.paragraph), 2)
        XCTAssertNil(DocRibbonStyles.currentNumber(nil))
        select("some words", in: document)
        _ = document.applyStyle(try XCTUnwrap(document.styleSheet.style(.character, 11)))
        settle(0.3)
        select("words", in: document, length: 0)
        XCTAssertEqual(formatter.state.characterStyle, 11, "знаковый стиль у курсора — в состоянии ленты")
    }

    /// Щелчок по плитке применяет стиль: проходим по ряду плиток, набор применённых стилей — ровно показанные плитки; отмена — байт в байт.
    func testTileClicksApplyStyles() throws {
        let (tab, document, _) = try open()
        select("Third", in: document, length: 0)
        let window = hostGroup(document, level: 0)
        let original = tab.text as String
        var seen: Set<Int> = []
        var x: CGFloat = 4
        // Только плитки (84 pt и промежуток 4 pt, внутри группы отступ 10 pt): дальше — кнопка «▾» с меню, а щелчок по меню ждёт событий.
        let tilesEnd = 10 + CGFloat(DocRibbonStyles.tiles(document.styleSheet, usage: DocRibbonStyles.usage(document.model), current: 0, count: 4).count) * 88
        while x < tilesEnd - 4 {
            click(window, x: x, y: 38)
            if let number = document.currentParagraphStyle?.number { seen.insert(number) }
            if (tab.text as String) != original {
                tab.undo.undo()
                settle(0.15)
                XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
            }
            x += 14
        }
        let shown = DocRibbonStyles.tiles(document.styleSheet, usage: DocRibbonStyles.usage(document.model), current: 0, count: 4).map(\.number)
        XCTAssertTrue(Set(shown).subtracting([0]).isSubset(of: seen), "щелчок по каждой плитке применил её стиль: показаны \(shown), применены \(seen.sorted())")
    }

    /// Ужатие: группа сужается от четырёх плиток к одной кнопке-меню, и у каждого уровня своя ширина.
    func testGroupNarrowsWithLevel() throws {
        let (_, document, _) = try open()
        let widths = (0...3).map { fittingWidth(document, level: $0) }
        XCTAssertGreaterThanOrEqual(widths[0], widths[1], "в тестовом файле три абзацных стиля: четвёртой плитки нет")
        XCTAssertGreaterThan(widths[1], widths[2])
        XCTAssertGreaterThan(widths[2], widths[3], "уровни 3 и дальше — одна кнопка-меню")
        XCTAssertEqual(fittingWidth(document, level: 4), widths[3], accuracy: 0.5)
        XCTAssertEqual(fittingWidth(document, level: 5), widths[3], accuracy: 0.5)
        XCTAssertLessThan(widths[3], 100, "кнопка-меню узкая")
    }

    func testNoStylesNoGroup() throws {
        let (workspace, tab) = DocDemo.tab(#"{\rtf1\ansi\deff0{\fonttbl{\f0 Times New Roman;}}\pard\plain\f0 Plain doc.\par}"#, name: "nostyles.frm")
        tab.restoreMode(.document)
        host(workspace)
        let document = try XCTUnwrap(tab.documentController)
        XCTAssertTrue(document.styleSheet.styles.isEmpty)
        XCTAssertEqual(fittingWidth(document, level: 0), 0, accuracy: 0.5, "в файле нет стилей — группы нет")
    }

    // MARK: - Снимки

    func testStylesSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["MU_DOC_FORMAT_SNAPSHOTS"] else { throw XCTSkip("MU_DOC_FORMAT_SNAPSHOTS не задан") }
        for (name, width, dark) in [("s1-home-1440", 1440, false), ("s1-home-1024", 1024, false), ("s1-home-760", 760, false),
                                    ("s1-home-1440-dark", 1440, true), ("s1-home-760-dark", 760, true)] as [(String, CGFloat, Bool)] {
            let (_, document, window) = try open(width: width, dark: dark)
            select("Second", in: document, length: 0)
            settle(0.4)
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            for window in windows { window.contentView = nil; window.close() }
            windows = []
        }
    }
}


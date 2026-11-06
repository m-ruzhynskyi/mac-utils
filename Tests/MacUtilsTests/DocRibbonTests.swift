import AppKit
import SwiftUI
import XCTest
@testable import MUCore
@testable import MUDesign
@testable import MUTextEditor

/// R1/R2: лента «Документа» — вкладки (контекстные только к месту, запоминается ключ обычной), каждая кнопка «Главной» —
/// своя команда (правка файла и отмена байт в байт), регистр «Aa» без потери оформления, снимки ленты по ширине.
@MainActor
final class DocRibbonTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.removeObject(forKey: Pref.editorRibbonTab)
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
    private func host(_ workspace: EditorWorkspace, size: NSSize = NSSize(width: 1000, height: 700), dark: Bool = false) -> NSWindow {
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

    private func open() throws -> (EditorTab, DocumentController, DocFormatter) {
        let (workspace, tab) = DocDemo.tab()
        tab.restoreMode(nil)
        host(workspace)
        let document = try XCTUnwrap(tab.documentController)
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
        settle()
        return (tab, document, DocFormatter.of(document))
    }

    private func select(_ text: String, in document: DocumentController) {
        let range = (document.storage.string as NSString).range(of: text)
        document.textViews.first?.setSelectedRange(range)
        document.updateStatus()
        // Состояние ленты (жирный ли выделенный текст) обновляется по циклу событий, как после щелчка мышью;
        // так же и отдельный шаг отмены у каждой команды (группы `NSUndoManager` — по событию).
        settle(0.1)
    }

    // MARK: - Вкладки

    func testTabsContextualOnlyWhereTheyApply() {
        XCTAssertEqual(DocRibbonTab.visible(inTable: false, editingHeader: false), [.home, .insert, .layout, .view])
        XCTAssertEqual(DocRibbonTab.visible(inTable: true, editingHeader: false).last, .table, "курсор в таблице — «Таблица»")
        XCTAssertEqual(DocRibbonTab.visible(inTable: true, editingHeader: true).last, .header, "правка колонтитула — «Колонтитулы»")
        XCTAssertFalse(DocRibbonTab.visible(inTable: true, editingHeader: true).contains(.table))
        // Показанная: контекстная, пока к месту; иначе запомненная обычная; мусор и контекстный ключ — «Главная».
        XCTAssertEqual(DocRibbonTab.shown(stored: "view", contextual: nil, inTable: false, editingHeader: false), .view)
        XCTAssertEqual(DocRibbonTab.shown(stored: "view", contextual: .table, inTable: true, editingHeader: false), .table)
        XCTAssertEqual(DocRibbonTab.shown(stored: "view", contextual: .table, inTable: false, editingHeader: false), .view,
                       "курсор ушёл из таблицы — обратно к запомненной")
        XCTAssertEqual(DocRibbonTab.shown(stored: "table", contextual: nil, inTable: true, editingHeader: false), .home)
        XCTAssertEqual(DocRibbonTab.shown(stored: "garbage", contextual: nil, inTable: false, editingHeader: false), .home)
        XCTAssertEqual(DocRibbonTab.shown(stored: "insert", contextual: .header, inTable: false, editingHeader: true), .header)
    }

    /// Запоминается только ключ вкладки (строка из четырёх), никаких данных документа.
    func testOnlyTabKeyIsStored() {
        XCTAssertEqual(Pref.editorRibbonTab, "editorRibbonTab")
        for tab in DocRibbonTab.base { XCTAssertFalse(tab.rawValue.contains("/"), "ключ — имя вкладки, не путь и не текст") }
        XCTAssertEqual(Set(DocRibbonTab.base.map(\.rawValue)), ["home", "insert", "layout", "view"])
    }

    // MARK: - «Таблица» на `TableCommand`

    /// Вкладка показывает ровно то, что `TableCommand.visible` разрешает в этом месте; у каждой команды (кроме вставки
    /// таблицы — она на «Вставке») есть кнопка, кнопок без команды нет; недоступная — серая, причина в подсказке.
    func testTableTabFollowsTableCommand() {
        XCTAssertEqual(Set(DocRibbonTable.laidOut), Set(TableCommand.allCases).subtracting([.insertTable]))
        let contexts = [TableCommand.Context(), TableCommand.Context(inTable: true, rowEditable: true, selectedCells: 1, columns: 3),
                        TableCommand.Context(inTable: true, rowEditable: false, selectedCells: 2, columns: 1)]
        for context in contexts {
            XCTAssertEqual(DocRibbonTable.commands(in: context), TableCommand.visible(in: context).filter { $0 != .insertTable })
        }
        XCTAssertTrue(DocRibbonTable.commands(in: TableCommand.Context()).isEmpty, "вне таблицы — ни одной кнопки")
        let nested = contexts[2]
        XCTAssertEqual(DocRibbonTable.tip(.rowAbove, TableCommand.rowAbove.availability(in: nested)),
                       "Вставить строку выше — Строки вложенных таблиц и строки с вложенной таблицей пока не меняются")
        XCTAssertEqual(DocRibbonTable.tip(.merge, TableCommand.merge.availability(in: nested)), "Объединить ячейки")
        XCTAssertEqual(DocRibbonTable.tip(.deleteColumn, TableCommand.deleteColumn.availability(in: nested)),
                       "Удалить столбец — В таблице остался один столбец: удалите таблицу целиком")
        // «Вставка»: таблица в ячейке не вставляется — кнопки нет.
        XCTAssertFalse(TableCommand.insertTable.availability(in: contexts[1]).isVisible)
        XCTAssertTrue(TableCommand.insertTable.availability(in: contexts[0]).isEnabled)
    }

    /// Курсор в ячейке демо-формы: каждая доступная команда вкладки меняет файл, отмена — байт в байт.
    func testTableTabCommandsEditAndUndo() throws {
        let (tab, document, _) = try open()
        let original = tab.text as String
        for command in DocRibbonTable.laidOut {
            select("Влажность", in: document)
            let context = document.tableContext
            XCTAssertTrue(context.inTable)
            guard command.availability(in: context).isEnabled else { continue }
            let done = document.perform(command, color: command == .shading ? RTFColor(red: 217, green: 217, blue: 217) : nil)
            guard done else {
                // У демо-таблицы уже все границы: «Все» и «Внешние» (у одной ячейки это те же четыре стороны) ничего не меняют.
                XCTAssertTrue([.bordersAll, .bordersOuter].contains(command), "«\(command.title)» отказала")
                XCTAssertEqual(tab.text as String, original, "отказ — без правки")
                continue
            }
            XCTAssertNotEqual(tab.text as String, original, "«\(command.title)» меняет файл")
            settle(0.05)
            tab.undo.undo()
            XCTAssertEqual(tab.text as String, original, "«\(command.title)»: отмена — байт в байт")
            settle(0.1)
        }
    }

    // MARK: - «Вставка» на `InsertCommand`

    /// Каждая видимая команда вставки — на вкладке: разрыв и номер страницы кнопками, поля и символы — меню; лишних нет.
    func testInsertTabFollowsInsertCommand() {
        for context in [InsertCommand.Context(), InsertCommand.Context(inHeader: true), InsertCommand.Context(inTableCell: true),
                        InsertCommand.Context(isDocument: false)] {
            let visible = InsertCommand.visible(in: context)
            let onTab = visible.filter { $0 == .pageBreak || $0 == .pageNumber } + DocRibbonInsert.fields(in: context)
                + DocRibbonInsert.symbols(in: context)
            XCTAssertEqual(onTab.count, visible.count)
            for command in visible { XCTAssertTrue(onTab.contains(command), command.title) }
        }
        XCTAssertTrue(InsertCommand.visible(in: InsertCommand.Context(isDocument: false)).isEmpty)
        let cell = InsertCommand.Context(inTableCell: true)
        XCTAssertEqual(DocRibbonInsert.tip(.pageBreak, InsertCommand.pageBreak.availability(in: cell)),
                       "Разрыв страницы — В ячейке таблицы разрыв страницы не ставится")
        XCTAssertEqual(DocRibbonInsert.menuTitle(.symbol("№")), "№  №")
        XCTAssertEqual(DocRibbonInsert.menuTitle(.symbol("\u{00A0}")), "Неразрывный пробел")
    }

    /// Курсор после «Демоград»: каждая доступная команда вставки меняет файл, отмена — байт в байт.
    func testInsertTabCommandsEditAndUndo() throws {
        let (tab, document, _) = try open()
        let original = tab.text as String
        var performed = 0
        for command in InsertCommand.catalog {
            let word = (document.storage.string as NSString).range(of: "Демоград")
            document.textViews.first?.setSelectedRange(NSRange(location: NSMaxRange(word), length: 0))
            document.updateStatus()
            settle(0.05)
            guard command.availability(in: document.insertContext).isEnabled else { continue }
            XCTAssertTrue(document.perform(command), command.title)
            XCTAssertNotEqual(tab.text as String, original, "«\(command.title)» меняет файл")
            settle(0.05)
            tab.undo.undo()
            XCTAssertEqual(tab.text as String, original, "«\(command.title)»: отмена — байт в байт")
            settle(0.1)
            performed += 1
        }
        XCTAssertEqual(performed, InsertCommand.catalog.count, "в обычном абзаце доступно всё")
    }

    // MARK: - «Главная»: каждая кнопка — своя команда

    /// Кнопка «Главной» → команда меняет файл (точечная правка), отмена возвращает его байт в байт.
    func testEveryHomeButtonEditsAndUndoes() throws {
        let red = RTFColor(red: 192, green: 0, blue: 0)
        let buttons: [(String, String, (DocFormatter) -> Void)] = [
            ("Полужирный", "Демоград", { $0.toggleBold() }),
            ("Курсив", "Демоград", { $0.toggleItalic() }),
            ("Подчёркнутый", "Демоград", { $0.toggleUnderline() }),
            ("Зачёркнутый", "Демоград", { $0.toggleStrike() }),
            ("Надстрочный", "Демоград", { $0.toggleVertical(.superscript) }),
            ("Подстрочный", "Демоград", { $0.toggleVertical(.subscript) }),
            ("Регистр", "Демоград", { $0.changeCase(.upper) }),
            ("Цвет текста", "Демоград", { $0.setColor(red) }),
            ("Маркер", "Демоград", { $0.setHighlight(FormatPalette.highlight.first) }),
            ("Шрифт", "Демоград", { $0.setFont("Arial") }),
            ("Размер больше", "Демоград", { $0.stepSize(1) }),
            ("Размер", "Демоград", { $0.setSize(points: 20) }),
            ("Очистить формат", "ЗАКЛЮЧЕНИЕ", { $0.clearFormatting() }),
            ("По левому краю", "ЗАКЛЮЧЕНИЕ", { $0.setAlignment(.left) }),
            ("По центру", "Демоград", { $0.setAlignment(.center) }),
            ("По правому краю", "Демоград", { $0.setAlignment(.right) }),
            ("По ширине", "ЗАКЛЮЧЕНИЕ", { $0.setAlignment(.justify) }),
            ("Интервал 1,5", "Демоград", { $0.setLineSpacing(1.5) }),
            ("Интервал перед абзацем", "Демоград", { $0.setSpacing(before: 240) }),
            ("Увеличить отступ", "Демоград", { $0.stepIndent(1) }),
            ("Капитель", "Демоград", { $0.toggleSmallCaps() }),
            ("Все прописные", "Демоград", { $0.toggleCaps() }),
            ("Скрытый", "Демоград", { $0.toggleHidden() }),
            ("Не отрывать от следующего", "Демоград", { $0.toggle(.keepNext) }),
            ("Разрыв страницы", "Демоград", { $0.insertPageBreak() }),
        ]
        // Один документ на все кнопки: отмена возвращает его байт в байт, и следующая кнопка начинает с того же файла.
        let (tab, document, formatter) = try open()
        let original = tab.text as String
        for (title, word, action) in buttons {
            select(word, in: document)
            action(formatter)
            XCTAssertNotEqual(tab.text as String, original, "«\(title)» меняет файл")
            settle(0.05)
            tab.undo.undo()
            XCTAssertEqual(tab.text as String, original, "«\(title)»: отмена — байт в байт")
            settle(0.1)  // страница перерисовывается после отмены по циклу событий — до поиска слова следующей кнопкой
        }
    }

    func testUndoRedoButtons() throws {
        let (tab, document, formatter) = try open()
        let original = tab.text as String
        select("Демоград", in: document)
        formatter.toggleBold()
        let bold = tab.text as String
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original)
        tab.undo.redo()
        XCTAssertEqual(tab.text as String, bold)
    }

    // MARK: - Регистр «Aa»

    func testCaseTransform() {
        XCTAssertEqual(DocCase.transform("пРИВЕТ мир. ВТОРОЕ предложение", .sentence), "Привет мир. Второе предложение")
        XCTAssertEqual(DocCase.transform("ещё текст", .sentence, startsSentence: false), "ещё текст", "середина предложения")
        XCTAssertEqual(DocCase.transform("Привет Мир", .lower), "привет мир")
        XCTAssertEqual(DocCase.transform("привет мир", .upper), "ПРИВЕТ МИР")
        XCTAssertEqual(DocCase.transform("привет, мир-демо", .capitalized), "Привет, Мир-Демо")
        XCTAssertEqual(DocCase.transform("Привет", .toggle), "пРИВЕТ")
        XCTAssertEqual(DocCase.transform("straße", .upper), "STRAßE", "ß → SS длиннее: буква остаётся")
        for mode in DocCase.allCases {
            XCTAssertEqual(DocCase.transform("Ёлка ёж. ß", mode).utf16.count, "Ёлка ёж. ß".utf16.count, "\(mode): длина та же")
        }
    }

    /// Регистр у выделения через разное оформление: буквы меняются, оформление (жирный кусок) остаётся, один шаг отмены.
    func testChangeCaseKeepsFormattingAndUndoes() throws {
        let (tab, document, formatter) = try open()
        select("Демоград", in: document)
        formatter.toggleBold()
        let afterBold = tab.text as String
        settle(0.1)
        let boldAt = (document.storage.string as NSString).range(of: "Демоград").location
        let boldFont = document.storage.attribute(.font, at: boldAt, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false, "«Демоград» стал жирным")
        select("г. Демоград", in: document)
        formatter.changeCase(.upper)
        settle(0.1)
        XCTAssertTrue(document.storage.string.contains("Г. ДЕМОГРАД"), document.storage.string.prefix(200).description)
        let range = (document.storage.string as NSString).range(of: "ДЕМОГРАД")
        let font = try XCTUnwrap(document.storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "жирный кусок остался жирным")
        XCTAssertEqual(tab.undo.undoActionName, "Регистр")
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, afterBold, "отмена — байт в байт")
        settle(0.1)
        XCTAssertTrue(document.storage.string.contains("г. Демоград"), "после отмены страница показывает прежние буквы")
        // Уже такой регистр — без правки.
        select("ЗАКЛЮЧЕНИЕ", in: document)
        let before = tab.text as String
        formatter.changeCase(.upper)
        XCTAssertEqual(tab.text as String, before)
    }

    // MARK: - Снимки

    /// Лента по ширине: 1440 / 1024 / 760 pt, светлая и тёмная; «Вставка», «Таблица» (курсор в таблице) и свёрнутой не бывает
    /// в снимке. В каталог из `MU_DOC_FORMAT_SNAPSHOTS`, офскрин.
    func testRibbonSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["MU_DOC_FORMAT_SNAPSHOTS"] else { throw XCTSkip("MU_DOC_FORMAT_SNAPSHOTS не задан") }
        var shots: [(String, CGFloat, Bool, String, String?)] = []
        for width in [1440, 1024, 760] as [CGFloat] {
            for dark in [false, true] { shots.append(("r1-home-\(Int(width))\(dark ? "-dark" : "")", width, dark, "home", nil)) }
        }
        shots += [("r1-insert-1024", 1024, false, "insert", nil), ("r1-layout-1024", 1024, false, "layout", nil),
                  ("r1-view-1024", 1024, false, "view", nil), ("r1-table-tab-1024", 1024, false, "home", "Влажность")]
        for (name, width, dark, stored, word) in shots {
            UserDefaults.standard.set(stored, forKey: Pref.editorRibbonTab)
            let (workspace, tab) = DocDemo.tab()
            tab.restoreMode(nil)
            let window = host(workspace, size: NSSize(width: width, height: 640), dark: dark)
            let document = try XCTUnwrap(tab.documentController)
            select(word ?? "Демоград", in: document)
            settle(0.5)
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            for window in windows { window.contentView = nil; window.close() }
            windows = []
        }
        // Контекстная «Таблица» открытой: курсор в ячейке, лента на её вкладке (светлая и тёмная).
        for dark in [false, true] {
            let (workspace, tab) = DocDemo.tab()
            tab.restoreMode(nil)
            host(workspace, size: NSSize(width: 1024, height: 640), dark: dark)
            let document = try XCTUnwrap(tab.documentController)
            select("Влажность", in: document)
            settle()
            let formatter = DocFormatter.of(document)
            XCTAssertTrue(formatter.state.inTable)
            let ribbon = DocRibbon(tab: tab, document: document, formatter: formatter, contextual: .table) { _ in EmptyView() }
            let view = NSHostingView(rootView: ribbon.frame(width: 1024).background(Color.dsBg))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1024, height: view.frame.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            windows.append(window)
            settle()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("r1-table-1024\(dark ? "-dark" : "").png"))
            for window in windows { window.contentView = nil; window.close() }
            windows = []
        }
    }

    /// R4: «Макет» с группой «Параметры страницы»: 1440 и 760, светлая и тёмная (`r4-layout-*`).
    func testLayoutTabSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["MU_DOC_FORMAT_SNAPSHOTS"] else { throw XCTSkip("MU_DOC_FORMAT_SNAPSHOTS не задан") }
        for (name, width, dark) in [("r4-layout-1440", 1440, false), ("r4-layout-760", 760, false), ("r4-layout-1440-dark", 1440, true), ("r4-layout-760-dark", 760, true)] as [(String, CGFloat, Bool)] {
            UserDefaults.standard.set("layout", forKey: Pref.editorRibbonTab)
            let (workspace, tab) = DocDemo.tab()
            tab.restoreMode(nil)
            let window = host(workspace, size: NSSize(width: width, height: 640), dark: dark)
            let document = try XCTUnwrap(tab.documentController)
            select("Демоград", in: document)
            settle(0.5)
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            for window in windows { window.contentView = nil; window.close() }
            windows = []
        }
    }
}

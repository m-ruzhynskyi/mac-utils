import AppKit
import SwiftUI
import XCTest
@testable import MUCore
@testable import MUDesign
@testable import MUTextEditor

/// V2: правка значения `$` на странице — хит-тест знака, запись точечной правкой (кириллица — `\'hh`), пустое значение
/// оставляет `$`, отмена — байт в байт, ↩ / Tab / ⇧Tab / Esc, история только в памяти, «Код» видит то же.
@MainActor
final class DocValuePopoverTests: XCTestCase {
    private var defaults: EditorDefaultsSnapshot!
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.set(false, forKey: Pref.editorSkipFirst)
        DollarValueHistory.reset()
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        DollarValueHistory.reset()
        defaults.restore()
        super.tearDown()
    }

    /// Форма: три знака — «Катя Демо», пустой (только `{\b }` после `$`), «ул. Демо».
    private func open() throws -> (EditorTab, DocumentController) {
        let pard = #"\pard\plain \f0\fs24 "#
        var source = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}"# + "\r\n"
        source += pard + DocDemo.rtf("Клиент: $Катя Демо") + "\r\n" + #"\par"# + "\r\n"
        source += pard + DocDemo.rtf("Счёт: $") + #"{\b }"# + "\r\n" + #"\par"# + "\r\n"
        source += pard + DocDemo.rtf("Адрес: $ул. Демо") + "\r\n" + #"\par}"#
        let tab = EditorTab(document: EditorDocument(data: Data(source.utf8), url: URL(fileURLWithPath: "/tmp/value_demo.frm")))
        tab.dollars.scanNow(tab.text)
        tab.setMode(.document)
        let document = try XCTUnwrap(tab.documentController)
        document.showsDollarMarks = true
        return (tab, document)
    }

    private func entries(_ tab: EditorTab) -> [DollarEntry] { Array(tab.dollars.split.active) }

    func testHitTestFindsOnlyHighlightedDollar() throws {
        let (tab, document) = try open()
        let text = document.storage.string as NSString
        let katya = text.range(of: "$Катя").location
        XCTAssertEqual(document.dollarEntry(atUnit: katya)?.mark.dollar, entries(tab)[0].mark.dollar, "щелчок по `$`")
        XCTAssertNil(document.dollarEntry(atUnit: katya + 1), "по букве значения — не знак")
        XCTAssertNil(document.dollarEntry(atUnit: 0), "по обычному тексту — не знак")
        // Пропущенный («Пропускать первые» = 1) — без правки.
        UserDefaults.standard.set(true, forKey: Pref.editorSkipFirst)
        UserDefaults.standard.set(1, forKey: Pref.editorSkipCount)
        XCTAssertNil(document.dollarEntry(atUnit: katya), "пропущенный знак не правится")
    }

    func testWriteValueIsPointEditAndUndoRestoresBytes() throws {
        let (tab, document) = try open()
        let original = tab.text as String
        let first = entries(tab)[0]
        XCTAssertTrue(document.writeDollarValue("Иван Петров", to: first))
        let fresh = entries(tab)[0]
        XCTAssertEqual(document.visibleValue(of: fresh.mark), "Иван Петров", "на странице — новое значение")
        XCTAssertTrue((tab.text as String).contains(DocDemo.rtf("$Иван Петров")), "в исходнике — \\'hh в cp1251")
        XCTAssertEqual(tab.dollars.entries.count, 3, "знаки на месте")
        XCTAssertEqual(tab.undo.undoActionName, "Значение $")
        // Всё, кроме значения, — те же байты.
        let changed = (tab.text as String).replacingOccurrences(of: DocDemo.rtf("Иван Петров"), with: DocDemo.rtf("Катя Демо"))
        XCTAssertEqual(changed, original)
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original, "отмена — файл байт в байт")
    }

    func testEmptyValueKeepsDollar() throws {
        let (tab, document) = try open()
        let third = entries(tab)[2]
        XCTAssertTrue(document.writeDollarValue("", to: third))
        let fresh = entries(tab)[2]
        XCTAssertEqual(document.visibleValue(of: fresh.mark), "", "значение убрано")
        XCTAssertTrue(document.storage.string.contains("Адрес: $"), "сам `$` остался")
        XCTAssertEqual(tab.dollars.entries.count, 3)
        // В пустой знак (только `{\b }` после `$`) значение вписывается сразу за `$`.
        let second = entries(tab)[1]
        XCTAssertTrue(document.writeDollarValue("00142", to: second))
        XCTAssertEqual(document.visibleValue(of: entries(tab)[1].mark), "00142")
        XCTAssertTrue(document.storage.string.contains("Счёт: $00142"))
    }

    func testApplyMovesToNextSkipAndClose() throws {
        let (tab, document) = try open()
        let editor = DollarValueEditor(entry: entries(tab)[0], controller: document)
        var moves = 0, closed = false
        editor.onMove = { _ in moves += 1 }
        editor.onClose = { closed = true }
        XCTAssertEqual(editor.text, "Катя Демо", "поле — значение как на странице")
        XCTAssertEqual(tab.dollars.editing, entries(tab)[0].mark.dollar, "строка панели — «правится»")

        editor.text = "ООО Ромашка"
        editor.apply()
        XCTAssertEqual(editor.entry.order, 1, "↩ — записать и к следующему")
        XCTAssertEqual(moves, 1)
        XCTAssertEqual(document.visibleValue(of: entries(tab)[0].mark), "ООО Ромашка")
        XCTAssertEqual(tab.dollars.editing, editor.entry.mark.dollar)

        editor.skip(1)
        XCTAssertEqual(editor.entry.order, 2, "Tab — пропустить без записи")
        XCTAssertEqual(document.visibleValue(of: entries(tab)[1].mark), "", "пропущенный не изменился")
        editor.skip(-1)
        XCTAssertEqual(editor.entry.order, 1, "⇧Tab — назад")
        editor.skip(1)
        editor.skip(1)
        XCTAssertTrue(closed, "за последним — закрыть")
        XCTAssertNil(tab.dollars.editing, "поповер закрыт — «правится» снято")
    }

    func testHistoryIsInMemoryOnly() throws {
        let (tab, document) = try open()
        let secret = "ТОВ Квітка-\(UUID().uuidString.prefix(6))"
        let editor = DollarValueEditor(entry: entries(tab)[0], controller: document)
        editor.text = secret
        editor.apply()
        XCTAssertEqual(DollarValueHistory.recent.first, secret)
        DollarValueHistory.remember("ООО Ромашка")
        XCTAssertEqual(DollarValueHistory.suggestions(for: "тов"), [secret, "ООО Ромашка"], "похожие — первыми, остальные — следом")
        XCTAssertEqual(DollarValueHistory.suggestions(for: "ооо ромашка"), [secret], "набранное не повторяется")
        // На диск — ничего: ни в общих настройках, ни в домене приложения.
        let stored = UserDefaults.standard.dictionaryRepresentation().values.map { "\($0)" }
        XCTAssertFalse(stored.contains { $0.contains(secret) }, "значение не попало в UserDefaults")
        for _ in 0..<20 { DollarValueHistory.remember("v\(UUID().uuidString)") }
        XCTAssertEqual(DollarValueHistory.recent.count, DollarValueHistory.limit)
    }

    func testCodeModeSeesDocumentEditAndBack() throws {
        let (tab, document) = try open()
        XCTAssertTrue(document.writeDollarValue("Олег", to: entries(tab)[0]))
        tab.setMode(.code)
        XCTAssertTrue((tab.text as String).contains(DocDemo.rtf("$Олег")), "«Код» — тот же исходник")
        // Правка в «Коде» — «Документ» видит её после пересчёта.
        let range = (tab.text as NSString).range(of: DocDemo.rtf("Олег"))
        tab.storage.replaceCharacters(in: range, with: DocDemo.rtf("Пётр"))
        tab.dollars.scanNow(tab.text)
        tab.setMode(.document)
        document.refresh()
        XCTAssertEqual(document.visibleValue(of: entries(tab)[0].mark), "Пётр")
    }

    /// Снимок поповера (светлый и тёмный) — в каталог из `MU_DOC_FORMAT_SNAPSHOTS`, офскрин.
    func testPopoverSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["MU_DOC_FORMAT_SNAPSHOTS"] else { throw XCTSkip("MU_DOC_FORMAT_SNAPSHOTS не задан") }
        let (tab, document) = try open()
        DollarValueHistory.remember("ФОП Іваненко")
        DollarValueHistory.remember("ТОВ Квітка")
        DollarValueHistory.remember("ООО Ромашка")
        for dark in [false, true] {
            let editor = DollarValueEditor(entry: entries(tab)[0], controller: document)
            editor.text = "ООО «Ромашка»"
            let size = NSSize(width: 300, height: 200)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let view = NSHostingView(rootView: DocValuePopoverView(editor: editor).environment(\.controlActiveState, .key))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            window.setContentSize(view.fittingSize)
            window.contentView = view
            window.orderBack(nil)
            windows.append(window)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("v2-popover-\(dark ? "dark" : "light").png"))
            editor.close()
        }
    }
}

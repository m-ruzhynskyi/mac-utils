import AppKit
import SwiftUI
import XCTest
@testable import MacUtils

/// Демо-документы режима «Документ» (выдуманное содержимое, как на макетах `d01`–`d11`).
enum DocDemo {
    /// Текст → RTF: кириллица `\'hh` в cp1251, служебные `\ { }` экранированы.
    static func rtf(_ text: String) -> String {
        let table = SingleByteTable.table(for: .windows1251)!
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\", "{", "}": out += "\\" + String(scalar)
            case _ where scalar.value < 0x80: out.unicodeScalars.append(scalar)
            default:
                if let byte = table.byte(for: scalar.value) {
                    out += String(format: "\\'%02x", byte)
                } else {
                    out += "\\u\(Int16(truncatingIfNeeded: Int(scalar.value)))?"
                }
            }
        }
        return out
    }

    /// «Заключение эксперта»: колонтитул с PAGE/NUMPAGES, шапка, таблица с заливкой, `$` (значение — до конца строки
    /// исходника), скрытый текст, подписи; второй раздел — фигура и рисунок WMF.
    static var expertReport: String {
        let pard = #"\pard\plain \ltrpar"#
        let font = #"\f0\fs24"#
        var s = #"{\rtf1\ansi\ansicpg1251\uc1\deff0\deftab708{\fonttbl{\f0\froman\fcharset204\fprq2 Times New Roman;}{\f1\fswiss\fcharset204\fprq2 Arial;}{\f2\fswiss\fcharset0\fprq2 Calibri;}}"# + "\r\n"
        s += #"{\colortbl;\red0\green0\blue0;\red226\green232\blue240;\red192\green0\blue0;}"# + "\r\n"
        s += #"{\info{\title Demo}}\paperw11906\paperh16838\margl1701\margr850\margt1134\margb1134"# + "\r\n"
        s += #"\sectd\headery567\footery567{\headerr "# + pard + #"\brdrb\brdrs\brdrw6\brsp20 \tqr\tx9355 {\f1\fs16 "# + rtf("ООО «Демо-Лаб» · отдел экспертиз") + #"\tab "#
        s += rtf("Стр. ") + #"}{\field{\*\fldinst {\f1\fs16 PAGE }}{\fldrslt {\f1\fs16 1}}}{\f1\fs16  "# + rtf("из") + #" }"#
        s += #"{\field{\*\fldinst {\f1\fs16 NUMPAGES }}{\fldrslt {\f1\fs16 2}}}\par }"# + "\r\n"
        s += pard + #"\qc\sb120\sa60 {\b\fs28 "# + rtf("ЗАКЛЮЧЕНИЕ ЭКСПЕРТА № ") + "$17-204\r\n}" + #"\par"# + "\r\n"
        s += pard + #"\qc\sa240 {\i\fs22 "# + rtf("по результатам лабораторного исследования") + #"}\par"# + "\r\n"
        s += pard + #"\tqr\tx9355\sa120 {"# + font + " " + rtf("г. Демоград") + #"\tab $20.10.2026"# + "\r\n}" + #"\par"# + "\r\n"
        s += pard + #"\qj\sa120 {"# + font + " " + rtf("Эксперт $Катя Демо") + "\r\n}{" + rtf(", рассмотрев образец $Б-12") + "\r\n}{"
        s += rtf(", поступивший в лабораторию, установил следующее:") + #"}\par"# + "\r\n"
        let rows: [(String, String, String, String)] = [("№", "Показатель", "Результат", "Норма"), ("1", "Влажность, %", "$7,4", "не более 8,0"),
                                                         ("2", "Зольность, %", "$0,62", "0,5–0,8"), ("3", "Плотность, г/см³", "$1,08", "1,05–1,10")]
        for (index, row) in rows.enumerated() {
            let border = #"\clbrdrt\brdrs\brdrw10 \clbrdrl\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \clbrdrr\brdrs\brdrw10 "#
            let shade = index == 0 ? #"\clcbpat2"# : ""
            s += #"\trowd\trgaph108\trleft0"# + (index == 0 ? #"\trhdr"# : "") + border + shade + #"\cellx800"# + border + shade + #"\cellx5200"#
            s += border + shade + #"\cellx7300"# + border + shade + #"\cellx9355"# + "\r\n"
            for cell in [row.0, row.1, row.2, row.3] {
                let bold = index == 0 ? #"\b\qc"# : ""
                s += pard + #"\intbl"# + bold + " {" + font + " " + rtf(cell) + (cell.hasPrefix("$") ? "\r\n" : "") + #"\cell}"#
            }
            // Как Word: описание строки ещё раз перед `\row` — полностью.
            s += #"{\trowd\trgaph108\trleft0"# + border + shade + #"\cellx800"# + border + shade + #"\cellx5200"# + border + shade + #"\cellx7300"#
            s += border + shade + #"\cellx9355\row}"# + "\r\n"
        }
        s += pard + #"\sb240\sa120 {\b "# + rtf("Вывод:") + #"}{ "# + rtf("образец $соответствует") + "\r\n}{" + rtf(" требованиям методики ЛМ-3.") + #"}\par"# + "\r\n"
        s += pard + #"\sa120 {\v "# + rtf("Служебная пометка для архива") + #"}\par"# + "\r\n"
        s += pard + #"\tx4500\tx6600\sa120 {"# + rtf("Эксперт") + #"\tab ________________\tab $"# + rtf("К. Демо") + "\r\n}" + #"\par"# + "\r\n"
        s += pard + #"\tx4500\tx6600\sa120 {"# + rtf("Руководитель лаборатории") + #"\tab ________________\tab $"# + rtf("М. Демо") + "\r\n}" + #"\par"# + "\r\n"
        s += #"\sect\sectd\headery567\footery567"# + "\r\n"
        s += pard + #" {\shp{\*\shpinst\shpleft0\shpright3515\shptop0\shpbottom1191{\sp{\sn shapeType}{\sv 1}}}}\par"# + "\r\n"
        s += pard + #" {\pict\wmetafile8\picwgoal2268\pichgoal1701 010009000003}\par"# + "\r\n"
        s += "}"
        return s
    }

    @MainActor
    static func tab(_ source: String = expertReport, name: String = "expert_report_demo.frm") -> (EditorWorkspace, EditorTab) {
        let workspace = EditorWorkspace()
        let document = EditorDocument(data: Data(source.utf8), url: URL(fileURLWithPath: "/tmp/" + name))
        let tab = EditorTab(document: document)
        workspace.add(tab)
        return (workspace, tab)
    }
}

/// Режим «Документ» на экране: страницы, колонтитулы, `$`, переключатель с переносом места, тёмная тема.
@MainActor
final class DocViewTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        // Общие настройки: режим для .frm по умолчанию — «Документ», первые три `$` пропускаются.
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.set(true, forKey: Pref.editorSkipFirst)
        UserDefaults.standard.set(3, forKey: Pref.editorSkipCount)
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
    private func host(_ workspace: EditorWorkspace, size: NSSize = NSSize(width: 800, height: 600), dark: Bool = false) -> NSWindow {
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

    private func waitForScan(_ tab: EditorTab) {
        let deadline = Date().addingTimeInterval(5)
        while !tab.dollars.isCurrent || tab.dollars.entries.isEmpty, Date() < deadline { settle(0.05) }
    }

    func testOpensAsDocumentWithPagesAndHeaders() throws {
        let (workspace, tab) = DocDemo.tab()
        XCTAssertTrue(tab.canShowDocument)
        tab.restoreMode(nil)
        XCTAssertEqual(tab.mode, .document, ".frm — сразу «Документ»")
        host(workspace)
        let document = try XCTUnwrap(tab.documentController)
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
        settle()
        XCTAssertEqual(document.pageCount, 2, "второй раздел — с новой страницы")
        let first = try XCTUnwrap(document.pagesView.pages.first)
        XCTAssertEqual(first.frame.size, NSSize(width: 11906.0 / 20, height: 16838.0 / 20), "A4 из \\paperw/\\paperh")
        XCTAssertEqual(first.bodyRect.minX, 1701.0 / 20)
        XCTAssertEqual(first.header?.string, "ООО «Демо-Лаб» · отдел экспертиз\tСтр. 1 из 2\n", "PAGE и NUMPAGES — свои номера")
        XCTAssertEqual(document.pagesView.pages[1].header?.string, "ООО «Демо-Лаб» · отдел экспертиз\tСтр. 2 из 2\n")
        XCTAssertEqual(first.appearance?.name, .aqua, "бумага белая и в тёмной теме")
        XCTAssertFalse(document.storage.string.contains("Служебная пометка"), "скрытый текст не показан")
        XCTAssertGreaterThan(document.wordCount, 40)
        // Таблица — NSTextTable 4 столбца, заголовок с заливкой.
        let header = document.storage.string as NSString
        let cell = header.range(of: "Показатель").location
        let style = try XCTUnwrap(document.storage.attribute(.paragraphStyle, at: cell, effectiveRange: nil) as? NSParagraphStyle)
        let block = try XCTUnwrap(style.textBlocks.first as? NSTextTableBlock)
        XCTAssertEqual(block.table.numberOfColumns, 4)
        XCTAssertEqual(block.startingColumn, 1)
        XCTAssertNotNil(block.backgroundColor)
        // Рамка — по краю ячейки, места у текста не занимает (как в Word).
        XCTAssertEqual(block.width(for: .border, edge: .minX), 0)
        XCTAssertEqual((block as? DocCellBlock)?.lines.first { $0.edge == .minX }?.width, 0.5)
    }

    func testDollarHighlightsVisiblePartOfLineValue() throws {
        let (workspace, tab) = DocDemo.tab()
        tab.restoreMode(nil)
        host(workspace)
        waitForScan(tab)
        let document = try XCTUnwrap(tab.documentController)
        document.highlightDollars()
        let text = document.storage.string as NSString
        // Первые три знака пропускаются (настройка по умолчанию); «соответствует» — подсвеченный. Значение в исходнике —
        // до конца строки, на странице — видимая часть (сами буквы).
        let value = text.range(of: "$соответствует")
        var effective = NSRange()
        let fill = document.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: value.location + 1, effectiveRange: &effective)
        XCTAssertNotNil(fill, "значение подсвечено")
        XCTAssertNotNil(document.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: value.location, effectiveRange: nil), "и сам $")
        XCTAssertNil(document.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: NSMaxRange(value) + 2, effectiveRange: nil),
                     "после конца строки исходника — нет")
        // Панель: номер страницы вместо строки.
        let dollar = document.rendering.map.range(at: value.location).location
        let entry = try XCTUnwrap(tab.dollars.entries.first { $0.mark.dollar == dollar })
        XCTAssertEqual(document.page(ofSource: entry.mark.dollar), 1)
        // Пропущенный (первые три) — бледный, без заливки.
        let skipped = text.range(of: "$Катя")
        XCTAssertNil(document.layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: skipped.location, effectiveRange: nil))
        XCTAssertNotNil(document.layoutManager.temporaryAttribute(.underlineStyle, atCharacterIndex: skipped.location, effectiveRange: nil))
    }

    func testSwitchKeepsPlaceBothWays() throws {
        let (workspace, tab) = DocDemo.tab()
        host(workspace)
        XCTAssertEqual(tab.mode, .code)
        let source = tab.text
        let target = source.range(of: "1,08")
        tab.textView.setSelectedRange(target)
        tab.setMode(.document)
        settle()
        let document = try XCTUnwrap(tab.documentController)
        let shown = try XCTUnwrap(document.textViews.first?.selectedRange())
        XCTAssertEqual((document.storage.string as NSString).substring(with: shown), "1,08", "Код → Документ: то же место")
        // Документ → Код: выделение «Демоград» на странице — его кусок исходника.
        let word = (document.storage.string as NSString).range(of: "Демоград")
        document.textViews.first?.setSelectedRange(word)
        tab.setMode(.code)
        settle()
        XCTAssertEqual(tab.textView.selectedRange(), tab.text.range(of: DocDemo.rtf("Демоград")), "в коде выделены ровно его \\'hh")
        XCTAssertEqual(EditorViewModes.preferred(for: tab.document.url), .code, "выбор запомнен для .frm")
    }

    func testNotRTFHasNoDocument() {
        let (_, plain) = DocDemo.tab("just text", name: "note.txt")
        XCTAssertFalse(plain.isRTF)
        XCTAssertFalse(plain.canShowDocument)
        let (_, broken) = DocDemo.tab("not rtf at all", name: "form.frm")
        XCTAssertTrue(broken.isRTF)
        XCTAssertFalse(broken.canShowDocument)
        XCTAssertNotNil(broken.documentUnavailableReason)
        broken.setMode(.document)
        XCTAssertEqual(broken.mode, .code)
    }

    func testRemoveValuesInDocumentSameAsCode() throws {
        let (workspace, tab) = DocDemo.tab()
        let (codeWorkspace, codeTab) = DocDemo.tab()
        tab.restoreMode(nil)
        host(workspace)
        host(codeWorkspace)
        waitForScan(tab)
        waitForScan(codeTab)
        let before = tab.text as String
        let removed = tab.removeHighlightedValues()
        XCTAssertEqual(removed, codeTab.removeHighlightedValues())
        XCTAssertEqual(tab.text as String, codeTab.text as String, "те же правки исходника, что в «Коде»")
        settle()
        let document = try XCTUnwrap(tab.documentController)
        XCTAssertFalse(document.storage.string.contains("соответствует"), "документ обновился")
        XCTAssertTrue(document.storage.string.contains("Катя"), "пропущенные первые три — на месте")
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, before, "одна отмена")
        settle()
        XCTAssertTrue(document.storage.string.contains("соответствует"))
    }

    func testInvisiblesShowHiddenText() throws {
        let (workspace, tab) = DocDemo.tab()
        tab.restoreMode(nil)
        host(workspace)
        let document = try XCTUnwrap(tab.documentController)
        tab.showsInvisibles = true
        settle()
        let text = document.storage.string as NSString
        let hidden = text.range(of: "Служебная пометка")
        XCTAssertNotEqual(hidden.location, NSNotFound, "с ¶ скрытый текст виден")
        let underline = document.storage.attribute(.underlineStyle, at: hidden.location, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle([.single, .patternDot]).rawValue, "точечное подчёркивание")
        XCTAssertEqual(document.rendering.map.kind(at: hidden.location), .hidden)
        tab.showsInvisibles = false
        settle()
        XCTAssertFalse(document.storage.string.contains("Служебная пометка"))
    }

    // MARK: - Снимки офскрин

    func testSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_DOC_SNAPSHOTS"], !path.isEmpty else {
            throw XCTSkip("Задайте MU_DOC_SNAPSHOTS=<папка>, чтобы снять экраны режима «Документ»")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let (workspace, tab) = DocDemo.tab()
            workspace.dollarPanelVisible = true
            UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
            tab.restoreMode(nil)
            let window = host(workspace, dark: dark)
            waitForScan(tab)
            tab.documentController?.zoom = 0.8
            settle(0.5)
            try snapshot(window, to: folder.appendingPathComponent("doc-\(theme).png"))
            tab.showsInvisibles = true
            settle(0.4)
            try snapshot(window, to: folder.appendingPathComponent("doc-invisibles-\(theme).png"))
            tab.showsInvisibles = false
            tab.documentController?.scrollToSource(tab.text.length - 10)
            settle(0.4)
            try snapshot(window, to: folder.appendingPathComponent("doc-placeholders-\(theme).png"))
            tab.setMode(.code)
            settle(0.4)
            try snapshot(window, to: folder.appendingPathComponent("doc-code-\(theme).png"))
        }
    }

    private func snapshot(_ window: NSWindow, to url: URL) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

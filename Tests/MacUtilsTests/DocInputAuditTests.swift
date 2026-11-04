import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Аудит ввода на формах (T1): дописывание после последнего абзаца, пустая строка «Подпись», пустая ячейка, конец ячейки,
/// Tab / ↩ / ⇧↩, метод ввода (кириллица, украинский), отказы с подсказкой, 100 правок на форму без нарушений `DocSaveGuard`.
/// Демо — выдуманный текст; реальные формы — только копии из `MU_WORD_REF_DIR` (по `real-frm-rules.md`), в отчёте только числа.
@MainActor
final class DocInputAuditTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!
    private var folder: URL!
    private var savedGuard: ((DocSaveGuard.Report, EditorTab, @escaping (Bool) -> Void) -> Void)!
    private var guardShown: [DocSaveGuard.Report] = []

    override func setUpWithError() throws {
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.set(false, forKey: Pref.editorInvisibles)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("doc-input-\(UUID().uuidString)", isDirectory: true)
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

    private func open(_ source: Data, name: String = "form.frm") throws -> (EditorTab, DocumentController) {
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
        return (tab, try XCTUnwrap(tab.documentController))
    }

    /// Форма: заголовок, абзац, строка «Подпись» с подчёркиванием, пустая строка для подписи, таблица 1×2 (текст и пустая ячейка), последний абзац.
    private static var form: String {
        let rtf = DocDemo.rtf
        let pard = #"\pard\plain \ltrpar"#
        var s = #"{\rtf1\ansi\ansicpg1251\uc1\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134\sectd"# + "\r\n"
        s += pard + #"\qc {\b\f0\fs28 "# + rtf("АКТ ПРИЁМКИ") + #"}\par"# + "\r\n"
        s += pard + #"\f0\fs24 "# + rtf("Настоящий акт составлен в двух экземплярах.") + #"\par"# + "\r\n"
        s += pard + #"\f0\fs24 "# + rtf("Подпись: ________________") + #"\par"# + "\r\n"
        s += pard + #"\f0\fs24 \par"# + "\r\n"
        let border = #"\clbrdrt\brdrs\brdrw10 \clbrdrl\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \clbrdrr\brdrs\brdrw10 "#
        let row = #"\trowd\trgaph108\trleft0"# + border + #"\cellx3000"# + border + #"\cellx6000"#
        s += row + "\r\n"
        s += pard + #"\intbl\f0\fs24 "# + rtf("Имя") + #"\cell"# + pard + #"\intbl\f0\fs24 \cell"# + #"\row"# + "\r\n"
        s += row.replacingOccurrences(of: #"\trowd"#, with: #"{\trowd"#)
        s = s.replacingOccurrences(of: "\r\n{\\trowd\\trgaph108\\trleft0" + border + "\\cellx3000" + border + "\\cellx6000", with: "\r\n")
        s += pard + #"\f0\fs24 "# + rtf("Конец акта") + #"\par"# + "\r\n"
        s += "}"
        return s
    }

    private func end(_ tab: EditorTab) -> Bool {
        var saved: Bool?
        EditorWindowController.shared.save(tab) { saved = $0 }
        return saved == true && guardShown.isEmpty
    }

    private func unit(_ document: DocumentController, of marker: String, after: Bool = false) throws -> Int {
        let found = (document.storage.string as NSString).range(of: marker)
        XCTAssertNotEqual(found.location, NSNotFound, marker)
        return after ? NSMaxRange(found) : found.location
    }

    private let anywhere = NSRange(location: NSNotFound, length: 0)

    // MARK: - Сценарии

    func testAppendAfterLastParagraph() throws {
        let (tab, document) = try open(Data(Self.form.utf8))
        let view = try XCTUnwrap(document.textViews.first)
        view.setSelectedRange(NSRange(location: document.storage.length, length: 0))
        view.insertText(" Дописано.", replacementRange: anywhere)
        XCTAssertTrue(document.storage.string.contains("Конец акта Дописано."), document.storage.string)
        XCTAssertNil(document.notice)
        XCTAssertTrue(end(tab), guardShown.first?.problem ?? "")
    }

    func testBlankSignatureLine() throws {
        let (tab, document) = try open(Data(Self.form.utf8))
        let view = try XCTUnwrap(document.textViews.first)
        // Пустая строка — абзац сразу после «Подпись: ____».
        let line = try unit(document, of: "________________", after: true)
        view.setSelectedRange(NSRange(location: line + 1, length: 0))
        view.insertText("Підпис ї є і ґ", replacementRange: anywhere)
        XCTAssertTrue(document.storage.string.contains("________________\nПідпис ї є і ґ\n"), document.storage.string)
        XCTAssertTrue((tab.text as String).contains(DocDemo.rtf("Підпис ї є і ґ")), "украинские буквы — в cp1251")
        XCTAssertTrue(end(tab), guardShown.first?.problem ?? "")
    }

    func testEmptyCellAndEndOfCell() throws {
        let (tab, document) = try open(Data(Self.form.utf8))
        let view = try XCTUnwrap(document.textViews.first)
        let name = try unit(document, of: "Имя", after: true)
        view.setSelectedRange(NSRange(location: name, length: 0))
        view.insertText(" Петро", replacementRange: anywhere)
        XCTAssertTrue(document.storage.string.contains("Имя Петро"), "конец ячейки")
        // Пустая ячейка — следующая единица за концом первой.
        let text = document.storage.string as NSString
        let first = text.range(of: "Имя Петро")
        var empty = NSMaxRange(first) + 1
        while empty < text.length, text.character(at: empty) == 0x0A || text.character(at: empty) == 0x07 { empty += 1 }
        view.setSelectedRange(NSRange(location: NSMaxRange(first) + 1, length: 0))
        view.insertText("Київ", replacementRange: anywhere)
        XCTAssertTrue(document.storage.string.contains("Київ"), document.storage.string)
        XCTAssertEqual(RTFReader.read(tab.text).body.paragraphs.filter { $0.props.inTable }.count, 2, "обе ячейки на месте")
        XCTAssertTrue(end(tab), guardShown.first?.problem ?? "")
    }

    func testEnterShiftEnterAndTab() throws {
        let (tab, document) = try open(Data(Self.form.utf8))
        let view = try XCTUnwrap(document.textViews.first)
        let before = RTFReader.read(tab.text).body.paragraphs.count
        let at = try unit(document, of: "двух экземплярах.", after: true)
        view.setSelectedRange(NSRange(location: at, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(RTFReader.read(tab.text).body.paragraphs.count, before + 1, "↩ — новый абзац")
        view.insertLineBreak(nil)
        XCTAssertTrue((tab.text as String).contains("\\line"), "⇧↩ — перевод строки внутри абзаца")
        view.insertTab(nil)
        XCTAssertTrue(document.storage.string.contains("\t"), "Tab вне таблицы — знак табуляции")
        // Tab в ячейке — следующая ячейка; из последней — новая строка таблицы.
        let name = try unit(document, of: "Имя")
        view.setSelectedRange(NSRange(location: name, length: 0))
        view.insertTab(nil)
        let rows = { RTFReader.read(tab.text).body.paragraphs.filter { $0.props.inTable }.count }
        XCTAssertEqual(rows(), 2)
        view.insertTab(nil)
        XCTAssertEqual(rows(), 4, "Tab из последней ячейки — новая строка")
        XCTAssertTrue(end(tab), guardShown.first?.problem ?? "")
    }

    func testInputMethodCyrillicAndUkrainian() throws {
        let (tab, document) = try open(Data(Self.form.utf8))
        let view = try XCTUnwrap(document.textViews.first)
        let at = try unit(document, of: "Конец акта", after: true)
        view.setSelectedRange(NSRange(location: at, length: 0))
        for word in [" Привіт", " світе", " щастя"] {
            view.setMarkedText(String(word.prefix(3)), selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            view.setMarkedText(word, selectedRange: NSRange(location: word.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            view.insertText(word, replacementRange: anywhere)
        }
        XCTAssertTrue(document.storage.string.contains("Конец акта Привіт світе щастя"), document.storage.string)
        XCTAssertFalse(document.storage.string.contains("ПривітПривіт"))
        // Отмена набора и возврат к тому же месту.
        tab.undo.undo()
        XCTAssertFalse((tab.text as String).contains(DocDemo.rtf("Привіт")), "набор отменился")
    }

    func testEveryRefusalSaysWhy() throws {
        let (tab, document) = try open(Data(DocDemo.expertReport.utf8))
        let before = tab.text as String
        let text = document.storage.string as NSString
        // 1. Выделение, где часть не удаляется (рисунок, разрыв раздела): всё, что можно, удаляется, а подсказка называет остальное.
        let object = try XCTUnwrap((0..<text.length).first { document.rendering.map.kind(at: $0) == .object })
        document.show(notice: "-")
        XCTAssertFalse(document.perform(replacing: NSRange(location: object, length: 1), with: ""))
        XCTAssertNotEqual(document.notice, "-", "отказ — с подсказкой")
        // 2. Несколько выделений сразу — не тишина.
        let view = try XCTUnwrap(document.textViews.first)
        let result = document.textView(view, shouldChangeTextInRanges: [NSValue(range: NSRange(location: 0, length: 1)), NSValue(range: NSRange(location: 5, length: 1))],
                                       replacementStrings: ["x", "y"])
        XCTAssertFalse(result)
        XCTAssertEqual(document.notice, "Правка нескольких мест сразу не поддерживается — выделите одно")
        XCTAssertEqual(tab.text as String, before, "ничего не изменилось")
        // 3. ⇧Tab в первой ячейке таблицы — понятная подсказка.
        let cell = text.range(of: "Показатель").location
        view.setSelectedRange(NSRange(location: cell, length: 0))
        let first = text.range(of: "№", options: .backwards).location
        view.setSelectedRange(NSRange(location: first, length: 0))
        document.show(notice: "-")
        view.insertBacktab(nil)
        XCTAssertEqual(document.notice, "Это первая ячейка таблицы")
    }

    // MARK: - 100 правок на форму

    /// Случайные, но повторяемые правки в разных местах (конец, пустые строки, ячейки, середина) через путь ввода окна.
    private func hundredEdits(on source: Data, seed: UInt64, name: String) throws -> (done: Int, silent: Int, saved: Bool, problem: String) {
        let (tab, document) = try open(source, name: name)
        let view = try XCTUnwrap(document.textViews.first)
        var random = SeededRandom(seed: seed)
        let pieces = ["a", "Я", "1", " ", "ї", "є", "Демо", "—", "\n", ""]
        var done = 0, silent = 0
        for _ in 0..<100 {
            let count = document.storage.length
            guard count > 0 else { break }
            let location: Int
            switch random.next(4) {
            case 0: location = count
            case 1: location = max(0, count - 1)
            default: location = random.next(count + 1)
            }
            let length = random.next(6) == 0 ? random.next(min(6, count - min(location, count)) + 1) : 0
            let range = NSRange(location: location, length: min(length, count - min(location, count)))
            let text = pieces[random.next(pieces.count)]
            document.show(notice: "-")
            // Как в жизни: каждая правка — свой шаг цикла событий (иначе NSUndoManager сливает их в одну группу отмены).
            RunLoop.main.run(until: Date().addingTimeInterval(0.003))
            let outcome = document.perform(replacing: range, with: text)
            if outcome {
                done += 1
            } else if document.notice == "-", !text.isEmpty || range.length > 0 {
                // Тихо можно только стереть границы ячеек (как в Word).
                let cellsOnly = range.length > 0 && text.isEmpty && (range.location..<NSMaxRange(range)).allSatisfy { document.rendering.map.kind(at: $0) == .cellEnd }
                if !cellsOnly { silent += 1 }
            }
        }
        var saved: Bool?
        EditorWindowController.shared.save(tab) { saved = $0 }
        return (done, silent, saved == true && guardShown.isEmpty, guardShown.first?.problem ?? "")
    }

    func testHundredEditsOnDemoForms() throws {
        for (index, source) in [Self.form, DocDemo.expertReport].enumerated() {
            guardShown = []
            let result = try hundredEdits(on: Data(source.utf8), seed: UInt64(100 + index), name: "demo\(index).frm")
            XCTAssertGreaterThan(result.done, 40, "демо \(index): правок прошло")
            XCTAssertTrue(result.saved, "демо \(index): \(result.problem)")
            XCTAssertEqual(result.silent, 0, "демо \(index): отказ без подсказки")
        }
    }

    /// Копии настоящих форм: `MU_WORD_REF_DIR` (rtf/fNNN.rtf), `MU_INPUT_AUDIT_FORMS` — сколько форм (по умолчанию 12). Без переменной — пропуск.
    func testHundredEditsOnRealFormCopies() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else { throw XCTSkip("MU_WORD_REF_DIR") }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("rtf")
        let limit = Int(ProcessInfo.processInfo.environment["MU_INPUT_AUDIT_FORMS"] ?? "") ?? 12
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".rtf") }.sorted()
        var forms = 0, violations = 0, edits = 0, silent = 0
        for (index, name) in names.enumerated() where index % max(1, names.count / limit) == 0 && forms < limit {
            guardShown = []
            let data = try Data(contentsOf: base.appendingPathComponent(name))
            guard data.count < 400_000 else { continue }
            let result = try hundredEdits(on: data, seed: UInt64(index), name: name)
            forms += 1
            edits += result.done
            silent += result.silent
            if !result.saved { violations += 1; XCTFail("\(name): нарушение проверки записи") }
        }
        print("T1-AUDIT forms=\(forms) edits=\(edits) violations=\(violations) silent=\(silent)")
        XCTAssertEqual(violations, 0)
        XCTAssertEqual(silent, 0, "отказы без подсказки")
        XCTAssertGreaterThan(forms, 0)
    }
}

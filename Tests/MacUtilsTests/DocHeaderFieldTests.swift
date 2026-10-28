import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Поля в колонтитулах (H2): число страниц, дата и время с образцом, имя файла, список «Поле…»; серый фон полей; «Обновить поля»
/// переписывает DATE и TIME. Каждая вставка — точечная правка (`FormatCheck`), отмена возвращает файл байт в байт.
@MainActor
final class DocHeaderFieldTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.set(false, forKey: Pref.editorInvisibles)
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func open() throws -> (EditorTab, DocumentController, DocFormatter) {
        let (workspace, tab) = DocDemo.tab()
        tab.restoreMode(nil)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace).environment(\.controlActiveState, .key))
        window.orderBack(nil)
        windows.append(window)
        settle()
        let document = try XCTUnwrap(tab.documentController)
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
        settle()
        return (tab, document, DocFormatter.of(document))
    }

    /// 5 марта 2026, 14:07 по Москве.
    private let moment = Date(timeIntervalSince1970: 1_772_708_820)
    private let zone = TimeZone(identifier: "Europe/Moscow")!

    func testPicturesBecomeText() {
        let text = { DocFieldFormat.text(picture: $0, date: self.moment, timeZone: self.zone) }
        XCTAssertEqual(text("dd.MM.yyyy"), "05.03.2026")
        XCTAssertEqual(text("d MMMM yyyy"), "5 марта 2026")
        XCTAssertEqual(text("dddd, d MMMM yyyy"), "четверг, 5 марта 2026")
        XCTAssertEqual(text("HH:mm"), "14:07")
        XCTAssertEqual(text("H:mm:ss"), "14:07:00")
        XCTAssertEqual(text("h:mm AM/PM"), "2:07 PM")
        XCTAssertEqual(text("d MMMM yyyy 'г.'"), "5 марта 2026 г.")
        XCTAssertEqual(DocFieldFormat.picture(ofInstruction: #"DATE \@ "dd.MM.yyyy" "#), "dd.MM.yyyy")
        XCTAssertNil(DocFieldFormat.picture(ofInstruction: "DATE"))
    }

    func testInsertDateAndTimeAreSurgicalAndUndoable() throws {
        let (tab, document, formatter) = try open()
        let original = tab.text as String
        let page = try XCTUnwrap(document.pagesView.pages.first)
        formatter.beginHeaderEditing(page: page, header: true)
        let session = try XCTUnwrap(formatter.headerSession)
        let fields = document.model.fields.count
        session.textView.setSelectedRange(NSRange(location: (session.storage.string as NSString).range(of: "·").location, length: 0))
        formatter.insertField(.date("dd.MM.yyyy"))
        XCTAssertNil(document.notice.flatMap { $0.hasPrefix("Нельзя") ? $0 : nil })
        XCTAssertEqual(document.model.fields.count, fields + 1)
        let source = tab.text as String
        XCTAssertTrue(source.contains(#"{\field{\*\fldinst DATE \\@ "dd.MM.yyyy" }{\fldrslt "#), "образец записан, как пишет Word")
        XCTAssertTrue(document.model.fields.contains { $0.kind == .other("DATE") })
        XCTAssertGreaterThanOrEqual(session.storage.string.filter { $0 == "." }.count, 2, "дата показана в колонтитуле: \(session.storage.string)")
        // Байты вне вставки те же.
        let inserted = (source as NSString).length - (original as NSString).length
        XCTAssertGreaterThan(inserted, 30)
        let start = (source as NSString).range(of: #"{\field{\*\fldinst DATE"#)
        let close = (source as NSString).range(of: "}}", range: NSRange(location: start.location, length: (source as NSString).length - start.location))
        let group = NSRange(location: start.location, length: NSMaxRange(close) - start.location)
        XCTAssertEqual(group.length, inserted, "вставлена ровно группа поля")
        XCTAssertEqual((source as NSString).replacingCharacters(in: group, with: ""), original, "вне вставки — те же байты")
        // Cocoa читает файл с полем.
        let rtf: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        XCTAssertNotNil(try? NSAttributedString(data: Data(source.utf8), options: rtf, documentAttributes: nil))
        formatter.insertField(.time("HH:mm"))
        XCTAssertTrue((tab.text as String).contains(#"TIME \\@ "HH:mm""#))
        formatter.insertField(.numPages)
        XCTAssertTrue((tab.text as String).contains("NUMPAGES"))
        formatter.insertField(.sectionPages)
        formatter.insertField(.fileName)
        XCTAssertTrue((tab.text as String).contains("FILENAME"), "имя файла вкладки")
        // Отмена — по шагу на вставку; в конце файл как был.
        for _ in 0..<5 { tab.undo.undo() }
        XCTAssertEqual(tab.text as String, original)
        formatter.endHeaderEditing()
    }

    func testFieldsHaveGreyShadeInHeaderEditor() throws {
        let (_, document, formatter) = try open()
        let page = try XCTUnwrap(document.pagesView.pages.first)
        formatter.beginHeaderEditing(page: page, header: true)
        let session = try XCTUnwrap(formatter.headerSession)
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        formatter.insertField(.numPages)
        formatter.insertField(.date("dd.MM.yyyy"))
        let shaded = (0..<session.storage.length).filter { session.storage.attribute(.backgroundColor, at: $0, effectiveRange: nil) != nil }
        XCTAssertGreaterThanOrEqual(shaded.count, 1 + 10, "число страниц (1 знак) и дата (10 знаков)")
        let plain = (0..<session.storage.length).first { session.storage.attribute(.backgroundColor, at: $0, effectiveRange: nil) == nil }
        XCTAssertNotNil(plain, "обычный текст — без фона")
        formatter.endHeaderEditing()
    }

    func testCatalogCoversRequestedFields() {
        let titles = HeaderField.catalog.map(\.title)
        XCTAssertTrue(titles.contains("Число страниц"))
        XCTAssertTrue(titles.contains("Имя файла"))
        XCTAssertTrue(titles.contains { $0.hasPrefix("Дата") })
        XCTAssertTrue(titles.contains { $0.hasPrefix("Время") })
    }

    func testUpdateFieldsRewritesDateAndTime() throws {
        let head = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}}\sectd{\header \pard\plain "#
        let tail = #"\par}\pard\plain Text\par}"#
        let source = head
            + #"{\field{\*\fldinst DATE \\@ "dd.MM.yyyy" }{\fldrslt 01.01.2020}}  {\field{\*\fldinst TIME \\@ "HH:mm" }{\fldrslt 09:00}}"# + tail
        var values = DocFieldUpdate.Values(page: { _ in 1 }, total: 1, sectionPages: { _ in 1 }, now: moment)
        values.timeZone = zone
        let model = RTFReader.read(source as NSString)
        let result = DocFieldUpdate.edits(model: model, source: source as NSString, values: values)
        XCTAssertEqual(result.updated, 2)
        let after = NSMutableString(string: source)
        for edit in result.edits.sorted(by: { $0.range.location > $1.range.location }) { after.replaceCharacters(in: edit.range, with: edit.text) }
        XCTAssertTrue((after as String).contains("05.03.2026") && (after as String).contains("14:07"), after as String)
        XCTAssertFalse((after as String).contains("01.01.2020"))
        // Повторно — нечего менять; без `now` даты не трогаем.
        XCTAssertTrue(DocFieldUpdate.edits(model: RTFReader.read(after), source: after, values: values).edits.isEmpty)
        values.now = nil
        XCTAssertTrue(DocFieldUpdate.edits(model: model, source: source as NSString, values: values).edits.isEmpty)
    }

    /// Копии настоящих форм (`MU_WORD_REF_DIR`): каждое поле каталога — в начало первого колонтитула формы; правка проходит `FormatCheck`,
    /// поле читается нашим разбором (+1 поле нужного вида, остальные поля те же), Cocoa открывает файл. Только числа.
    func testEveryFieldInRealFormHeaders() throws {
        guard let path = ProcessInfo.processInfo.environment["MU_WORD_REF_DIR"], !path.isEmpty else { throw XCTSkip("MU_WORD_REF_DIR") }
        let base = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).appendingPathComponent("rtf")
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasSuffix(".rtf") }.sorted()
        let rtf: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: NSAttributedString.DocumentType.rtf]
        var forms = 0, inserted = 0, refused = 0, failures = 0
        for name in names {
            guard let data = try? Data(contentsOf: base.appendingPathComponent(name)), data.count < 600_000 else { continue }
            let source = EditorDocument(data: data).decodedText as NSString
            let model = RTFReader.read(source)
            guard let (section, kind, header) = model.sections.enumerated().lazy.compactMap({ index, section in
                section.headers.first.map { (index, $0.key, $0.value) }
            }).first else { continue }
            forms += 1
            let renderer = DocRenderer()
            let rendering = renderer.renderMargins(header.story, model: model, textWidth: 500) { _ in "1" }
            let reference = DocStoryRef.header(section: section, kind: kind)
            for field in HeaderField.catalog {
                let result = DocHeaderFooterEdits.insertField(field, story: reference, unit: 0, map: rendering.map, source: source, model: model,
                                                              now: moment, fileName: "form.frm")
                switch result {
                case .failure: refused += 1
                case .success(let plan):
                    let after = NSMutableString(string: source as String)
                    for edit in plan.edits.sorted(by: { $0.range.location > $1.range.location }) { after.replaceCharacters(in: edit.range, with: edit.string) }
                    let reread = RTFReader.read(after as NSString)
                    if !reread.isRTF || reread.fields.count < model.fields.count + 1 { failures += 1; XCTFail("\(name): поле не прочиталось") }
                    if (try? NSAttributedString(data: Data((after as String).utf8), options: rtf, documentAttributes: nil)) == nil,
                       (try? NSAttributedString(data: data, options: rtf, documentAttributes: nil)) != nil {
                        failures += 1
                        XCTFail("\(name): Cocoa не открывает")
                    }
                    inserted += 1
                }
            }
            if forms >= (Int(ProcessInfo.processInfo.environment["MU_H2_FORMS"] ?? "") ?? 10) { break }
        }
        print("H2-AUDIT forms=\(forms) inserted=\(inserted) refused=\(refused) failures=\(failures)")
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(forms, 0)
    }
}

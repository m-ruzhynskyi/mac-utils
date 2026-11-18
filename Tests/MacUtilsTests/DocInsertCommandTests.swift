import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUTextEditor

/// R3: команды вкладки «Вставка» — доступность по месту курсора и вставка точечной правкой (байты вне правки те же, отмена — байт в байт).
@MainActor
final class DocInsertCommandTests: XCTestCase {
    private typealias Context = InsertCommand.Context

    func testCatalogHasNoDuplicatesAndTitles() {
        XCTAssertEqual(InsertCommand.catalog.first, .pageNumber)
        XCTAssertEqual(InsertCommand.catalog.last, .pageBreak)
        XCTAssertFalse(InsertCommand.catalog.contains(.field(.page)), "номер страницы — отдельная команда")
        XCTAssertEqual(Set(InsertCommand.catalog.map(\.title)).count, InsertCommand.catalog.count)
    }

    func testNotDocumentModeShowsNothing() {
        XCTAssertTrue(InsertCommand.visible(in: Context(isDocument: false)).isEmpty, "нет команды — нет кнопки")
    }

    func testAvailabilityByContext() {
        let normal = Context()
        XCTAssertEqual(InsertCommand.visible(in: normal), InsertCommand.catalog)
        XCTAssertTrue(InsertCommand.pageBreak.availability(in: normal).isEnabled)
        XCTAssertFalse(InsertCommand.pageBreak.availability(in: Context(inTableCell: true)).isEnabled)
        XCTAssertFalse(InsertCommand.pageBreak.availability(in: Context(inHeader: true)).isEnabled)
        XCTAssertFalse(InsertCommand.symbol("©").availability(in: Context(inHeader: true)).isEnabled)
        XCTAssertTrue(InsertCommand.pageNumber.availability(in: Context(inHeader: true)).isEnabled, "поля в колонтитуле вставляются")
        XCTAssertEqual(InsertCommand.symbol("©").availability(in: Context(textRefusal: "защищено")), .disabled("защищено"))
        XCTAssertEqual(InsertCommand.pageNumber.availability(in: Context(fieldRefusal: "внутри поля")), .disabled("внутри поля"))
        XCTAssertFalse(InsertCommand.field(.fileName).availability(in: Context(hasFileName: false)).isEnabled)
        XCTAssertTrue(InsertCommand.field(.numPages).availability(in: Context(hasFileName: false)).isEnabled)
    }

    // MARK: - На документе

    private func open(_ source: String = DocTableEditTests.wordTable) throws -> (tab: EditorTab, document: DocumentController, window: NSWindow) {
        let (workspace, tab) = DocDemo.tab(source, name: "insert_cmd.frm")
        tab.restoreMode(.document)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none  // показ/закрытие без анимации: вне экрана она не кончается и навсегда занимает поток GCD
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (tab, try XCTUnwrap(tab.documentController), window)
    }

    /// Всё, кроме вставленного куска, не изменилось: до и после совпадают префикс и суффикс.
    private func assertOnlyInserted(_ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line) {
        let a = Array(before.utf16), b = Array(after.utf16)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        XCTAssertEqual(prefix + suffix, a.count, "байты вне правки те же", file: file, line: line)
    }

    /// Правится колонтитул: поле с вкладки «Вставка» встаёт в колонтитул (как в Word), основной текст не меняется; символ и разрыв —
    /// выключены. Раньше `insertContext` не знал о колонтитуле, и поле уходило в тело — к курсору, которого не видно.
    func testFieldGoesIntoHeaderWhileItIsEdited() throws {
        let (workspace, tab) = DocDemo.tab()
        tab.restoreMode(nil)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace).environment(\.controlActiveState, .key))
        window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let document = try XCTUnwrap(tab.documentController)
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let formatter = DocFormatter.of(document)
        let page = try XCTUnwrap(document.pagesView.pages.first)
        formatter.beginHeaderEditing(page: page, header: true)
        let session = try XCTUnwrap(formatter.headerSession)
        session.textView.setSelectedRange(NSRange(location: (session.storage.string as NSString).range(of: "·").location, length: 0))
        let original = tab.text as String
        let body = document.storage.string
        let fields = document.model.fields.count
        let context = document.insertContext
        XCTAssertTrue(context.inHeader)
        XCTAssertFalse(InsertCommand.pageBreak.availability(in: context).isEnabled)
        XCTAssertTrue(document.perform(.field(.numPages)))
        XCTAssertEqual(document.model.fields.count, fields + 1)
        XCTAssertTrue((tab.text as String).contains("NUMPAGES"))
        XCTAssertEqual(document.storage.string, body, "основной текст не тронут — поле в колонтитуле")
        XCTAssertFalse(document.perform(.pageBreak))
        XCTAssertFalse(document.perform(.symbol("©")))
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original, "одна отмена — байт в байт")
        formatter.endHeaderEditing()
    }

    func testCommandsAreOnePointEditAndUndoIsByteForByte() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let view = try XCTUnwrap(document.textViews.first)
        let text = { document.storage.string as NSString }
        let original = tab.text as String
        for command in [InsertCommand.symbol("©"), .symbol("№"), .symbol("\u{00A0}"), .pageBreak, .pageNumber, .field(.numPages), .field(.date("dd.MM.yyyy"))] {
            view.setSelectedRange(NSRange(location: text().range(of: "After").location + 2, length: 0))
            let before = tab.text as String
            XCTAssertTrue(command.availability(in: document.insertContext).isEnabled, "\(command)")
            XCTAssertTrue(document.perform(command), "\(command)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let after = tab.text as String
            XCTAssertNotEqual(before, after, "\(command)")
            assertOnlyInserted(before, after)
            tab.undo.undo()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(tab.text as String, before, "\(command): отмена — байт в байт")
        }
        XCTAssertEqual(tab.text as String, original)
    }

    func testInsertedFormsAreReadBack() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let view = try XCTUnwrap(document.textViews.first)
        let text = { document.storage.string as NSString }
        view.setSelectedRange(NSRange(location: text().range(of: "After").location + 2, length: 0))
        XCTAssertTrue(document.perform(.symbol("№")))
        XCTAssertTrue(text().contains("№"), "символ виден на странице")
        XCTAssertTrue((tab.text as String).contains("\\'b9"), "в файле — \\'hh кодовой страницы")
        XCTAssertTrue(document.perform(.symbol("€")))
        XCTAssertTrue(text().contains("€"))
        XCTAssertTrue(document.perform(.pageNumber))
        XCTAssertTrue((tab.text as String).contains("PAGE"), "поле PAGE в файле")
        let fields = document.model.body.paragraphs.flatMap(\.runs).filter { if case .field = $0.kind { return true } else { return false } }
        XCTAssertFalse(fields.isEmpty, "поле прочитано моделью")
    }

    func testRefusedInsideTableBreakAndOutsideDocumentMode() throws {
        let (tab, document, window) = try open()
        defer { window.contentView = nil; window.close() }
        let view = try XCTUnwrap(document.textViews.first)
        let text = { document.storage.string as NSString }
        view.setSelectedRange(NSRange(location: text().range(of: "B1").location, length: 0))
        let before = tab.text as String
        XCTAssertTrue(document.insertContext.inTableCell)
        XCTAssertFalse(document.perform(.pageBreak), "в ячейке разрыв страницы не ставится")
        XCTAssertEqual(tab.text as String, before, "правки не было")
        XCTAssertTrue(document.perform(.symbol("©")), "символ в ячейке можно")
    }
}

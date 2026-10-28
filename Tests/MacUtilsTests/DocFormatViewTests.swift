import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Панель форматирования и колонтитулы в окне (офскрин): команды меняют только свои байты, отмена возвращает файл
/// байт в байт, колонтитул правится по двойному клику.
@MainActor
final class DocFormatViewTests: XCTestCase {
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
    }

    private func font(at text: String, in document: DocumentController) -> NSFont? {
        let range = (document.storage.string as NSString).range(of: text)
        return document.storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
    }

    // MARK: - Символы и абзацы

    func testBoldFromPanelThenUndoRestoresBytes() throws {
        let (tab, document, formatter) = try open()
        let original = tab.text as String
        select("Демоград", in: document)
        formatter.updateState()
        XCTAssertFalse(formatter.state.bold)
        formatter.toggleBold()
        XCTAssertNotEqual(tab.text as String, original)
        XCTAssertTrue(tab.editedInDocument, "правка из «Документа» — с проверкой перед записью")
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(font(at: "Демоград", in: document))).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: try XCTUnwrap(font(at: "г. ", in: document))).contains(.boldFontMask))
        // Выделение осталось на тех же символах — кнопка теперь «нажата».
        XCTAssertEqual((document.storage.string as NSString).substring(with: document.selectedUnits), "Демоград")
        formatter.updateState()
        XCTAssertTrue(formatter.state.bold)
        tab.undo.undo()
        settle(0.1)
        XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
    }

    func testMissingWordFontKeepsNameShowsSubstitute() throws {
        let (tab, document, formatter) = try open()
        select("по результатам", in: document)
        formatter.setFont("Calibri")
        formatter.updateState()
        XCTAssertEqual(formatter.state.fontName, "Calibri", "в файле — исходное имя")
        if !FontCatalog.isInstalled("Calibri") {
            // Нет Word — замена той же ширины из ресурсов (Carlito), без неё — по таблице.
            XCTAssertEqual(formatter.state.displayFont, FontSubstitution.display(for: "Calibri"), "на экране — замена")
            XCTAssertNotEqual(formatter.state.displayFont, "Calibri")
        }
        XCTAssertTrue(tab.text.contains("Calibri;}"))
        // Размер −/+ по списку Word, поле принимает 10,5.
        formatter.setSize(points: 10.5)
        formatter.updateState()
        XCTAssertEqual(formatter.state.halfPoints, 21)
        formatter.stepSize(1)
        formatter.updateState()
        XCTAssertEqual(formatter.state.halfPoints, 22)
    }

    func testAlignmentIndentsAndClear() throws {
        let (tab, document, formatter) = try open()
        select("Демоград", in: document)
        formatter.setAlignment(.center)
        formatter.setIndents(left: 567, firstLine: 283, right: 0)
        formatter.updateState()
        XCTAssertEqual(formatter.state.alignment, .center)
        XCTAssertEqual(formatter.state.paragraph?.left, 567)
        XCTAssertEqual(formatter.state.paragraph?.firstLine, 283)
        let style = try XCTUnwrap(document.storage.attribute(.paragraphStyle, at: document.selectedUnits.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .center)
        XCTAssertEqual(style.headIndent, 567.0 / 20, accuracy: 0.01)
        formatter.clearFormatting()
        formatter.updateState()
        XCTAssertEqual(formatter.state.alignment, .left)
        XCTAssertEqual(formatter.state.paragraph?.left, 0)
        XCTAssertGreaterThan(tab.text.length, 0)
    }

    func testCommandThatCannotBeLosslessExplainsAndChangesNothing() throws {
        let (tab, document, formatter) = try open()
        let original = tab.text as String
        // Курсор не в слове (между табуляцией и «$») — нечего оформлять, исходник не трогается.
        let tabStop = (document.storage.string as NSString).range(of: "\t$20").location
        document.textViews.first?.setSelectedRange(NSRange(location: tabStop + 1, length: 0))
        formatter.toggleItalic()
        XCTAssertEqual(tab.text as String, original)
    }

    // MARK: - Колонтитулы

    func testHeaderEditingFormatAndPageNumber() throws {
        let (tab, document, formatter) = try open()
        let page = try XCTUnwrap(document.pagesView.pages.first)
        formatter.beginHeaderEditing(page: page, header: true)
        let session = try XCTUnwrap(formatter.headerSession)
        XCTAssertEqual(session.kind, .headerRight)
        XCTAssertTrue(page.faded, "основной текст бледнеет")
        XCTAssertEqual(page.headerFrame?.title, "Верхний колонтитул")
        XCTAssertTrue(session.storage.string.hasPrefix("ООО «Демо-Лаб»"))
        // Оформление внутри колонтитула.
        let word = (session.storage.string as NSString).range(of: "ООО")
        session.textView.setSelectedRange(word)
        formatter.toggleBold()
        let run = try XCTUnwrap(document.model.sections[0].headers[.headerRight]?.story.paragraphs[0].runs.first)
        XCTAssertTrue(run.props.bold)
        XCTAssertTrue(run.text.hasPrefix("ООО"))
        XCTAssertTrue(page.header?.string.hasPrefix("ООО") ?? false)
        // Номер страницы у курсора — поле PAGE, показ — свой номер.
        let fields = document.model.fields.count
        session.textView.setSelectedRange(NSRange(location: (session.storage.string as NSString).range(of: "·").location, length: 0))
        formatter.insertPageNumber(.page)
        XCTAssertEqual(document.model.fields.count, fields + 1)
        XCTAssertTrue(session.storage.string.contains("Лаб» 1· отдел") || session.storage.string.contains("Лаб» 1·"), session.storage.string)
        // «Другой на первой странице»: \titlepg и пустой колонтитул первой страницы, правка переходит на него.
        formatter.setTitlePage(true)
        XCTAssertTrue(document.model.sections[0].props.titlePage)
        XCTAssertEqual(formatter.headerSession?.kind, .headerFirst)
        XCTAssertEqual(page.headerFrame?.title, "Верхний колонтитул — первая страница")
        XCTAssertNotNil(document.model.sections[0].headers[.headerFirst])
        XCTAssertTrue(tab.text.contains("\\titlepg "))
        formatter.setTitlePage(false)
        XCTAssertFalse(document.model.sections[0].props.titlePage)
        XCTAssertEqual(formatter.headerSession?.kind, .headerRight)
        // Выход — основной текст снова обычный.
        formatter.endHeaderEditing()
        XCTAssertNil(formatter.headerSession)
        XCTAssertFalse(page.faded)
        XCTAssertNil(page.headerFrame)
    }

    /// H1: вкладка «Колонтитулы» на ленте — метка «· Как в предыдущем» у связанного колонтитула, развязка и отмена байт в байт,
    /// Esc закрывает правку, курсор основного текста остаётся на месте.
    func testHeaderRibbonLinkLabelEscAndBodyCaret() throws {
        let (tab, document, formatter) = try open()
        let original = tab.text as String
        let body = (document.storage.string as NSString).range(of: "Демоград")
        document.textViews.first?.setSelectedRange(body)
        let pages = document.pagesView.pages
        XCTAssertGreaterThanOrEqual(pages.count, 2)
        let second = pages[1]
        XCTAssertEqual(second.section, 1, "вторая страница — второй раздел, своего колонтитула у него нет")
        formatter.beginHeaderEditing(page: second, header: true)
        XCTAssertEqual(formatter.headerLink, .linked)
        XCTAssertEqual(second.headerFrame?.title, "Верхний колонтитул · Как в предыдущем")

        formatter.setLinkedToPrevious(false)
        settle()
        XCTAssertEqual(formatter.headerLink, .own, "раздел получил свою копию")
        XCTAssertNotNil(document.model.sections[1].headers[.headerRight])
        XCTAssertEqual(second.headerFrame?.title, "Верхний колонтитул", "метка без «Как в предыдущем»")
        tab.undo.undo()
        settle()
        XCTAssertEqual(tab.text as String, original, "отмена — файл байт в байт")
        // Своя копия колонтитула ушла вместе с отменой — правка не закрывается, а переходит на колонтитул предыдущего раздела.
        XCTAssertNotNil(formatter.headerSession, "правка осталась открытой")
        XCTAssertEqual(formatter.headerSession?.section, 0, "перешла на колонтитул первого раздела")
        XCTAssertEqual(formatter.headerLink, .linked)
        XCTAssertEqual(second.headerFrame?.title, "Верхний колонтитул · Как в предыдущем")

        // Esc в тексте колонтитула — выход; тело не бледное, курсор тела тот же.
        let session = try XCTUnwrap(formatter.headerSession)
        session.textView.cancelOperation(nil)
        XCTAssertNil(formatter.headerSession)
        XCTAssertFalse(second.faded)
        XCTAssertNil(second.headerFrame)
        XCTAssertEqual(document.textViews.first?.selectedRange(), body, "курсор основного текста не сдвинулся")
    }

    /// Метка рамки — на верхней границе справа, внутри ширины рамки.
    func testHeaderFrameLabelSitsOnTopBorder() {
        let frame = NSRect(x: 80, y: 30, width: 420, height: 40)
        let label = DocHeaderFrameStyle.labelRect(for: frame, title: "Нижний колонтитул · Как в предыдущем")
        XCTAssertEqual(label.midY, frame.minY, accuracy: 0.5, "по центру верхней границы")
        XCTAssertLessThanOrEqual(label.maxX, frame.maxX - DocHeaderFrameStyle.labelInset + 0.5)
        XCTAssertGreaterThanOrEqual(label.minX, frame.minX)
    }

    func testFooterAddedOnDoubleClickAndRemoved() throws {
        let (tab, document, formatter) = try open()
        let original = tab.text as String
        let page = try XCTUnwrap(document.pagesView.pages.first)
        XCTAssertNil(document.headerKind(for: page, header: false), "нижнего колонтитула нет")
        formatter.beginHeaderEditing(page: page, header: false)
        XCTAssertEqual(formatter.headerSession?.kind, .footer)
        XCTAssertNotNil(document.model.sections[0].headers[.footer])
        formatter.insertPageNumber(.pageOfTotal)
        XCTAssertEqual(formatter.headerSession?.storage.string, "Стр. 1 из 2\n")
        XCTAssertEqual(document.pagesView.pages[1].footer?.string, "Стр. 2 из 2\n")
        formatter.removeHeader()
        XCTAssertNil(formatter.headerSession)
        XCTAssertNil(document.model.sections[0].headers[.footer])
        XCTAssertEqual(tab.text as String, original, "добавили и удалили — файл как был")
    }

    func testFacingPagesAddsEvenHeaders() throws {
        let (tab, document, formatter) = try open()
        let page = try XCTUnwrap(document.pagesView.pages.first)
        formatter.beginHeaderEditing(page: page, header: true)
        formatter.setFacingPages(true)
        XCTAssertTrue(document.model.facingPages)
        XCTAssertNotNil(document.model.sections[0].headers[.headerLeft], "чётным — свой, пустой")
        XCTAssertTrue(tab.text.contains("\\facingp "))
        XCTAssertEqual(page.headerFrame?.title, "Верхний колонтитул — нечётные")
        formatter.setFacingPages(false)
        XCTAssertFalse(document.model.facingPages)
        formatter.endHeaderEditing()
    }

    func testDoubleClickPlaces() throws {
        let (_, document, formatter) = try open()
        let page = try XCTUnwrap(document.pagesView.pages.first)
        func event(_ y: CGFloat) -> NSEvent {
            let point = page.convert(NSPoint(x: page.bodyRect.midX, y: y), to: nil)
            return NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: page.window!.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!
        }
        XCTAssertFalse(formatter.pageDoubleClick(event(page.bodyRect.midY), on: page), "по тексту без правки колонтитула — обычный двойной клик")
        XCTAssertTrue(formatter.pageDoubleClick(event(page.bodyRect.minY - 10), on: page))
        XCTAssertEqual(formatter.headerSession?.isHeader, true)
        XCTAssertTrue(formatter.pageDoubleClick(event(page.bodyRect.midY), on: page), "по тексту во время правки — выход")
        XCTAssertNil(formatter.headerSession)
    }

    func testTypingInHeaderEditsItsGroupAndUndoes() throws {
        let (tab, document, formatter) = try open()
        let original = tab.text as String
        formatter.beginHeaderEditing(page: try XCTUnwrap(document.pagesView.pages.first), header: true)
        let session = try XCTUnwrap(formatter.headerSession)
        session.textView.setSelectedRange(NSRange(location: 0, length: 0))
        session.textView.insertText("Демо: ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(session.storage.string.hasPrefix("Демо: ООО"), session.storage.string)
        XCTAssertTrue(document.model.sections[0].headers[.headerRight]?.story.paragraphs[0].plainText.hasPrefix("Демо: ООО") ?? false)
        XCTAssertEqual(session.textView.selectedRange().location, 6, "курсор — за набранным")
        XCTAssertEqual(document.pagesView.pages[1].header?.string.hasPrefix("Демо: "), true, "и на других страницах")
        session.textView.deleteBackward(nil)
        XCTAssertTrue(session.storage.string.hasPrefix("Демо:ООО"))
        tab.undo.undo()
        tab.undo.undo()
        settle(0.1)
        XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
    }

    func testFormattedPasteKeepsKnownFormattingInOneUndoStep() throws {
        let (tab, document, formatter) = try open()
        let original = tab.text as String
        select("Демоград", in: document)
        let pasted = NSMutableAttributedString(string: "Жирный ", attributes: [.font: NSFont(name: "Times New Roman Bold", size: 12)!])
        pasted.append(NSAttributedString(string: "красный", attributes: [.font: NSFont(name: "Times New Roman", size: 12)!,
                                                                         .foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)]))
        formatter.paste(pasted)
        let text = document.storage.string as NSString
        XCTAssertTrue(text.contains("г. Жирный красный"), text as String)
        let bold = try XCTUnwrap(font(at: "Жирный", in: document))
        XCTAssertTrue(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        XCTAssertFalse(NSFontManager.shared.traits(of: try XCTUnwrap(font(at: "красный", in: document))).contains(.boldFontMask))
        let red = document.storage.attribute(.foregroundColor, at: text.range(of: "красный").location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(red?.usingColorSpace(.sRGB)?.redComponent ?? 0, 1, accuracy: 0.01)
        XCTAssertEqual(document.selectedUnits, NSRange(location: NSMaxRange(text.range(of: "красный")), length: 0), "курсор — после вставленного")
        tab.undo.undo()
        settle(0.1)
        XCTAssertEqual(tab.text as String, original, "вставка с форматом — один шаг отмены")
    }

    func testShortcutsReachPanelFromPageText() throws {
        let (_, document, formatter) = try open()
        select("Демоград", in: document)
        let view = try XCTUnwrap(document.textViews.first)
        let window = try XCTUnwrap(view.window)
        window.makeFirstResponder(view)
        settle(0.3)
        func press(_ key: String, _ modifiers: NSEvent.ModifierFlags = .command) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            if !(NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false) { _ = window.performKeyEquivalent(with: event) }
            settle(0.1)
            formatter.updateState()
        }
        press("b")
        XCTAssertTrue(formatter.state.bold, "⌘B")
        press("i")
        XCTAssertTrue(formatter.state.italic, "⌘I")
        press("u")
        XCTAssertTrue(formatter.state.underline, "⌘U")
        press("e")
        XCTAssertEqual(formatter.state.alignment, .center, "⌘E")
    }

    // MARK: - Вид

    /// Снимки панели для сверки с макетами (`d01`, `d06`, `d11`) — в каталог из `MU_DOC_FORMAT_SNAPSHOTS`, без экрана.
    func testSnapshotsForReview() throws {
        guard let directory = ProcessInfo.processInfo.environment["MU_DOC_FORMAT_SNAPSHOTS"] else { throw XCTSkip("MU_DOC_FORMAT_SNAPSHOTS не задан") }
        // header: страница, где открыть правку колонтитула (`nil` — без правки); d11-linked — второй раздел, «Как в предыдущем».
        let shots: [(String, NSSize, Bool, Int?)] = [
            ("d01", NSSize(width: 1000, height: 700), false, nil), ("d06", NSSize(width: 520, height: 600), false, nil),
            ("d11", NSSize(width: 1000, height: 700), false, 0), ("d11-dark", NSSize(width: 1000, height: 700), true, 0),
            ("d11-linked", NSSize(width: 1000, height: 700), false, 1), ("d01-dark", NSSize(width: 1000, height: 700), true, nil),
        ]
        for (name, size, dark, header) in shots {
            let (workspace, tab) = DocDemo.tab()
            tab.restoreMode(nil)
            let window = host(workspace, size: size, dark: dark)
            let document = try XCTUnwrap(tab.documentController)
            select("Демоград", in: document)
            if let header, let page = document.pagesView.pages[safe: header] {
                DocFormatter.of(document).beginHeaderEditing(page: page, header: true)
                let clip = document.scrollView.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, page.frame.minY - 16)))
                document.scrollView.reflectScrolledClipView(clip)
            }
            settle(0.5)
            let view = try XCTUnwrap(window.contentView)
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}

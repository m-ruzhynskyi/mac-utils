import AppKit
import CoreText
import SwiftUI
import XCTest
@testable import MacUtils

/// Точность раскладки как в Word: если текст по RTF помещается в ячейку (`\cellx` минус поля ячейки и отступы абзаца)
/// или в строку с табуляциями, у нас нет переноса. Демо — колонтитул-таблица первой страницы, выходящая в поля
/// (`\trleft` < 0, правый `\cellx` за правым полем), с правой табуляцией; настоящие формы — по `MU_REAL_FRM_DIR`.
@MainActor
final class DocTableFitTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
    }

    override func tearDown() {
        closeWindows()
        defaults.restore()
        super.tearDown()
    }

    private func closeWindows() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
    }

    /// Демо (выдуманный текст) по структуре форм: `\titlepg`, нижний колонтитул первой страницы — таблица 2×4 / 2×2 без
    /// рамок, слева на 426 твипов в поле и правее правого поля; жирная ячейка с отрицательными отступами; строка с
    /// табуляциями по центру и по правому краю; абзац вне таблицы с выступом в поле и правой табуляцией.
    nonisolated static var form: String {
        let row1 = #"\trowd\trgaph108\trrh1191\trleft-426\trpaddl108\trpaddr108\trpaddfl3\trpaddfr3"#
            + #"\clvertalt\cellx765\clvertalt\cellx3209\clvertalt\cellx6326\clvertalc\cellx10348 "#
        let row2 = #"\trowd\trgaph108\trrh70\trleft-426\trpaddl108\trpaddr108\trpaddfl3\trpaddfr3\cellx6326\cellx10348 "#
        let tabs = #"\tqc\tx4677\tqr\tx9355"#
        var footer = #"{\footerf "# + row1
        footer += #"\pard\plain\qc\li-113\ri-113\intbl"# + tabs + #"\fs40 # #\cell "#
        footer += #"\pard\plain\ql\li-108\ri-57\sb960\intbl"# + tabs + #"\b\fs24 Підпис контролера\cell "#
        footer += #"\pard\plain\qc\intbl\fs24 \cell \cell "#
        footer += #"\pard\plain\intbl{"# + row1 + #"\row}"# + row2
        footer += #"\pard\plain\ql\li-57\ri-57\intbl\tqc\tx3000\tqr\tx6100\i\fs20 Код Ф-12/вер. 3\tab Згідно наказу 4\tab \cell "#
        footer += #"\pard\plain\qr\ri-57\intbl\i\fs20 Аркуш {\field{\*\fldinst PAGE}{\fldrslt 1}} з {\field{\*\fldinst NUMPAGES}{\fldrslt 1}}\cell "#
        footer += #"\pard\plain\intbl{"# + row2 + #"\row}"#
        footer += #"\pard\plain\li-284"# + tabs + #"\fs20 Ліворуч\tab По центру\tab Праворуч\par}"#
        var s = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}"#
        s += #"\paperw11906\paperh16838\margl1701\margr850\margt1134\margb1134"#
        s += #"\sectd\titlepg\headery709\footery284"# + footer + #"{\footer \pard\plain\fs20 Звичайна сторінка\par}"#
        for number in 1...60 { s += #"\pard\plain\fs24 Абзац тексту "# + "\(number)" + #" для заповнення сторінки\par "# }
        // Кириллица — как пишет Word: `\uN?`.
        return (s + "}").unicodeScalars.map { $0.isASCII ? String($0) : "\\u\($0.value)?" }.joined()
    }

    private func load(_ data: Data, url: URL) -> DocumentController? {
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: data, url: url))
        tab.restoreMode(nil)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        windows.append(window)
        guard let document = tab.documentController else { return nil }
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers.last!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return document
    }

    func testFooterTableFitsLikeWord() throws {
        let document = try XCTUnwrap(load(Data(Self.form.utf8), url: URL(fileURLWithPath: "/tmp/fit.frm")))
        let page = try XCTUnwrap(document.pagesView.pages.first)
        let footer = try XCTUnwrap(page.footer)
        var fit = TableFit()
        fit.check(document)
        XCTAssertGreaterThanOrEqual(fit.checks, 4, "ячейки колонтитула и строки с табуляциями проверены")
        XCTAssertEqual(fit.violations, 0, fit.details.joined(separator: "; "))
        XCTAssertEqual(fit.unmapped, 0)

        // Таблица — на своём месте: левая граница на 426 твипов левее поля, правая — на `\cellx10348` от поля.
        let laid = TableFit.layout(footer, width: page.footerRect.width)
        let text = footer.string as NSString
        let bold = text.range(of: "Підпис контролера")
        let glyphs = laid.manager.glyphRange(forCharacterRange: bold, actualCharacterRange: nil)
        var lines: [NSRect] = []
        laid.manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in lines.append(rect) }
        XCTAssertEqual(lines.count, 1, "жирная ячейка — в одну строку, как в Word")
        // `\\li-108` при `\\trgaph108`: текст — от левой границы ячейки, справа `\\ri-57` — до 51 твипа от правой.
        let margin = DocPageView.bodyRect(page.props).minX
        let cell = try XCTUnwrap(lines.first)
        XCTAssertEqual(page.footerRect.minX + cell.minX, margin + CGFloat(765) / 20, accuracy: 1, "\\cellx765 от \\trleft-426")
        XCTAssertEqual(page.footerRect.minX + cell.maxX, margin + CGFloat(3209 - 51) / 20, accuracy: 1, "\\cellx3209")
        XCTAssertEqual(page.footerRect.minX, margin - 21.3, accuracy: 0.5, "рамка — от левого края таблицы")
        XCTAssertGreaterThanOrEqual(page.footerRect.maxX, margin + CGFloat(10348) / 20 - 0.5, "и до правого")

        // Абзац вне таблицы: выступ в поле не сдвигает табуляции — «Праворуч» у правого поля, в одну строку.
        let right = text.range(of: "Праворуч")
        let rightGlyphs = laid.manager.glyphRange(forCharacterRange: right, actualCharacterRange: nil)
        let rightRect = laid.manager.boundingRect(forGlyphRange: rightGlyphs, in: laid.container)
        XCTAssertEqual(page.footerRect.minX + rightRect.maxX, margin + CGFloat(9355) / 20, accuracy: 2)
    }

    /// Демо (выдуманный текст): таблица тела шире полосы текста (`\trleft-900`, правый `\cellx` за правым полем), абзац
    /// с `\li-567` в поле и абзац с табуляцией по умолчанию. Рамка текста страницы — шире полосы на выступ; полоса
    /// (`bodyRect`) для линейки та же; правка и выделение работают, в линейке — исходные отступы.
    nonisolated static var wideForm: String {
        let border = #"\clbrdrt\brdrs\brdrw10\clbrdrl\brdrs\brdrw10\clbrdrb\brdrs\brdrw10\clbrdrr\brdrs\brdrw10"#
        var s = #"{\rtf1\ansi\ansicpg1251\deff0\deftab720{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}"#
        s += #"\paperw11906\paperh16838\margl1701\margr850\margt1134\margb1134\sectd "#
        s += #"\pard\plain\fs24 Звичайний абзац\par "#
        s += #"\pard\plain\li-567\fs24 Абзац у полі\par "#
        s += #"\pard\plain\fs24 Ключ\tab Значення\par "#
        s += #"\trowd\trgaph108\trleft-900"# + border + #"\cellx4300"# + border + #"\cellx9639 "#
        s += #"\pard\plain\intbl\fs24 Масова частка вологи в зразку, відсотків (м/м)\cell "#
        s += #"\pard\plain\intbl\li-108\ri-138\fs24 Норма\cell \row "#
        s += #"\pard\plain\fs24 Після таблиці\par}"#
        return s.unicodeScalars.map { $0.isASCII ? String($0) : "\\u\($0.value)?" }.joined()
    }

    func testWideBodyTableLikeWord() throws {
        let document = try XCTUnwrap(load(Data(Self.wideForm.utf8), url: URL(fileURLWithPath: "/tmp/wide.frm")))
        let page = try XCTUnwrap(document.pagesView.pages.first)
        let margin = CGFloat(1701) / 20
        XCTAssertEqual(page.bodyRect.minX, margin, "полоса текста — та же (линейка, колонтитулы)")
        XCTAssertEqual(page.textRect.minX, margin - 45, accuracy: 0.01, "рамка текста — от левого края таблицы")
        XCTAssertGreaterThanOrEqual(page.textRect.maxX, margin + CGFloat(9639) / 20, "и до правого")
        var fit = TableFit()
        fit.check(document)
        XCTAssertGreaterThanOrEqual(fit.checks, 2)
        XCTAssertEqual(fit.violations, 0, fit.details.joined(separator: "; "))

        // Где на странице начинается текст: x глифа в координатах страницы.
        let manager = document.layoutManager
        func x(_ text: String) -> CGFloat {
            let range = (document.storage.string as NSString).range(of: text)
            let glyph = manager.glyphIndexForCharacter(at: range.location)
            return page.textRect.minX + manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x
        }
        XCTAssertEqual(x("Звичайний"), margin, accuracy: 0.5, "обычный абзац — от поля")
        XCTAssertEqual(x("Абзац у"), margin - 28.35, accuracy: 0.5, "\\li-567 — в поле")
        XCTAssertEqual(x("Значення"), margin + 36, accuracy: 0.5, "шаг табуляции по умолчанию — от поля, не от рамки")
        XCTAssertEqual(x("Масова"), margin - 45 + 5, accuracy: 1, "ячейка — от \\trleft-900 плюс \\trgaph")
        let cell = (document.storage.string as NSString).range(of: "Масова частка вологи в зразку, відсотків (м/м)")
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(forCharacterRange: cell, actualCharacterRange: nil)) { _, _, _, _, _ in
            lines += 1
        }
        XCTAssertEqual(lines, 1, "как в Word — в одну строку")

        // Линейка и команды — по исходным отступам; правка в ячейке сохраняет рамку текста.
        let view = try XCTUnwrap(document.textViews.first)
        let formatter = DocFormatter.of(document)
        view.setSelectedRange(NSRange(location: (document.storage.string as NSString).range(of: "Абзац у").location + 2, length: 0))
        formatter.updateState()
        XCTAssertEqual(formatter.state.paragraph?.left, -567)
        let tab = try XCTUnwrap(document.tab)
        let original = tab.text as String
        view.setSelectedRange(NSRange(location: (document.storage.string as NSString).range(of: "Норма").location + 5, length: 0))
        view.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNotEqual(tab.text as String, original, "правка — в исходнике")
        XCTAssertTrue(document.storage.string.contains("Норма!"))
        XCTAssertEqual(page.textRect.minX, margin - 45, accuracy: 0.01)
        XCTAssertEqual(x("Значення"), margin + 36, accuracy: 0.5)
        tab.undo.undo()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(tab.text as String, original, "отмена — байт в байт")
    }

    /// Настоящие формы — только по `MU_REAL_FRM_DIR` (копии вне репозитория); в выводе — только числа.
    func testRealFormsTablesAndTabsFitLikeWord() throws {
        guard let dir = ProcessInfo.processInfo.environment["MU_REAL_FRM_DIR"] else { throw XCTSkip("MU_REAL_FRM_DIR не задан") }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)
            .filter { ["frm", "rtf"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        var total = TableFit(), closed = 0
        for (index, url) in urls.enumerated() {
            guard let document = load(try Data(contentsOf: url), url: url) else { closed += 1; continue }
            var fit = TableFit()
            fit.check(document)
            // Подробности — только числа (ширины, отступы), по `MU_FIT_DETAILS`.
            if ProcessInfo.processInfo.environment["MU_FIT_DETAILS"] != nil {
                let laid = document.layoutManager.firstUnlaidCharacterIndex() >= document.layoutManager.textStorage?.length ?? 0
                print("REAL fit file #\(index): pages \(document.pagesView.pages.count) laid out \(laid)")
                for line in fit.details { print("REAL fit file #\(index): \(line)") }
            }
            if fit.violations > 0 || fit.unmapped > 0 {
                print("REAL fit file #\(index): checks \(fit.checks) violations \(fit.violations) (body \(fit.bodyViolations), "
                      + "wide body tables \(fit.wideBodyTables)) unmapped \(fit.unmapped)")
            }
            total.add(fit)
            closeWindows()
        }
        print("REAL fit files \(urls.count), checks \(total.checks) (cells \(total.cellChecks), tabs \(total.tabChecks)), "
              + "violations \(total.violations) (body \(total.bodyViolations), of them wide body tables \(total.wideBodyTables); "
              + "headers \(total.violations - total.bodyViolations)), wrap checks \(total.wrapChecks), one line where Word wraps \(total.overflows), "
              + "unmapped \(total.unmapped), not in Document mode \(closed)")
        XCTAssertEqual(total.violations - total.bodyViolations, 0, "колонтитулы")
        XCTAssertEqual(total.bodyViolations - total.wideBodyTables, 0, "основной текст, таблицы в полосе текста")
        XCTAssertEqual(total.overflows, 0, "не шире, чем в Word")
        XCTAssertEqual(total.unmapped, 0)
    }
}

/// Проверка «помещается по RTF → у нас одна строка» для основного текста и колонтитулов документа.
@MainActor
struct TableFit {
    var checks = 0, cellChecks = 0, tabChecks = 0
    var violations = 0, bodyViolations = 0, wideBodyTables = 0, unmapped = 0
    /// Обратная проверка: где Word переносит, у нас тоже перенос.
    var wrapChecks = 0, overflows = 0
    /// Только числа: где нарушение (тело/колонтитул, ширины в пунктах).
    var details: [String] = []

    mutating func add(_ other: TableFit) {
        checks += other.checks; cellChecks += other.cellChecks; tabChecks += other.tabChecks
        violations += other.violations; bodyViolations += other.bodyViolations; wideBodyTables += other.wideBodyTables
        unmapped += other.unmapped; wrapChecks += other.wrapChecks; overflows += other.overflows
    }

    /// Раскладка колонтитула как на странице; хранилище возвращается — менеджер держит его слабой ссылкой.
    static func layout(_ string: NSAttributedString, width: CGFloat) -> (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) {
        let storage = NSTextStorage(attributedString: string)
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: width, height: 100_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        return (storage, manager, container)
    }

    mutating func check(_ document: DocumentController) {
        let model = document.model
        // Основной текст: абзацы модели ↔ показанные диапазоны.
        let ranges = document.rendering.paragraphRanges
        if ranges.count == model.body.paragraphs.count {
            for (index, paragraph) in model.body.paragraphs.enumerated() {
                let props = model.sections[safe: paragraph.section]?.props ?? RTFSectionProps()
                check(paragraph, story: model.body, range: ranges[index], manager: document.layoutManager, model: model,
                      textWidth: DocPageView.bodyRect(props).width, body: true)
            }
        } else {
            unmapped += 1
        }
        // Колонтитулы: каждый показанный один раз (по первой странице, где он есть).
        var seen = Set<String>()
        for page in document.pagesView.pages {
            for header in [true, false] {
                guard let kind = document.headerKind(for: page, header: header), let story = document.headers(of: page.section)[kind]?.story,
                      let string = header ? page.header : page.footer, seen.insert("\(page.section)-\(kind.rawValue)").inserted else { continue }
                let rect = header ? page.headerRect : page.footerRect
                let laid = Self.layout(string, width: rect.width)
                guard let paragraphRanges = Self.paragraphRanges(story, in: string.string as NSString) else { unmapped += 1; continue }
                for (index, range) in paragraphRanges {
                    check(story.paragraphs[index], story: story, range: range, manager: laid.manager, model: model,
                          textWidth: DocPageView.bodyRect(page.props).width, body: false)
                }
                withExtendedLifetime(laid.storage) {}
            }
        }
    }

    /// Абзацы истории колонтитула в показанном тексте: показанные абзацы заканчиваются «\n» (пропущенные — продолжения
    /// объединённых ячеек — не показаны вовсе).
    static func paragraphRanges(_ story: RTFStory, in text: NSString) -> [(Int, NSRange)]? {
        var shown: [Int] = []
        for (index, paragraph) in story.paragraphs.enumerated() {
            if let def = cellDef(paragraph, story), def.verticalMerged || def.horizontalMerged { continue }
            shown.append(index)
        }
        var result: [(Int, NSRange)] = []
        var start = 0
        for index in shown {
            guard start <= text.length else { return nil }
            let newline = text.range(of: "\n", range: NSRange(location: start, length: text.length - start))
            let end = newline.location == NSNotFound ? text.length : NSMaxRange(newline)
            result.append((index, NSRange(location: start, length: end - start)))
            start = end
        }
        return start == text.length ? result : nil
    }

    static func cellDef(_ paragraph: RTFParagraph, _ story: RTFStory) -> RTFCellDef? {
        guard let ref = paragraph.cell else { return nil }
        return story.tables[safe: ref.table]?.rows[safe: ref.row]?.cells[safe: ref.cell]
    }

    /// Ширина ячейки по RTF (с объединением по горизонтали) и поле `\trgaph`, в твипах.
    static func cellWidth(_ paragraph: RTFParagraph, _ story: RTFStory) -> (width: Int, gap: Int)? {
        guard let ref = paragraph.cell, let row = story.tables[safe: ref.table]?.rows[safe: ref.row], ref.cell < row.cells.count else { return nil }
        var left = row.left
        for cell in row.cells[..<ref.cell] { left = max(cell.right, left) }
        var right = max(row.cells[ref.cell].right, left)
        var next = ref.cell + 1
        if row.cells[ref.cell].horizontalMergeFirst {
            while next < row.cells.count, row.cells[next].horizontalMerged { right = max(row.cells[next].right, right); next += 1 }
        }
        return (right - left, max(row.gap, 0))
    }

    private mutating func check(_ paragraph: RTFParagraph, story: RTFStory, range: NSRange, manager: NSLayoutManager, model: RTFDocumentModel,
                                textWidth: CGFloat, body: Bool) {
        guard range.length > 0, let storage = manager.textStorage, NSMaxRange(range) <= storage.length else { return }
        var text = range
        let units = (storage.string as NSString).substring(with: range)
        // Разрывы и рисунки — не про перенос по ширине.
        if units.contains("\u{0C}") || units.contains("\u{2028}") || units.contains("\u{FFFC}") || units.contains("\u{0B}") { return }
        if units.hasSuffix("\n") { text.length -= 1 }
        guard text.length > 0 else { return }
        let props = paragraph.props
        let tabbed = units.contains("\t")
        let available: CGFloat
        if let cell = Self.cellWidth(paragraph, story) {
            available = CGFloat(cell.width - 2 * cell.gap) / 20
        } else {
            guard tabbed else { return }
            available = textWidth
        }
        let first = CGFloat(props.left + props.firstLine) / 20, right = CGFloat(props.right) / 20
        let limit = available - right
        let attributed = storage.attributedSubstring(from: text)
        let segments = attributed.string.components(separatedBy: "\t")
        var location = 0
        var widths: [CGFloat] = []
        for (number, segment) in segments.enumerated() {
            let length = (segment as NSString).length
            let piece = attributed.attributedSubstring(from: NSRange(location: location, length: length))
            let line = CTLineCreateWithAttributedString(piece)
            var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if number == segments.count - 1 { width -= CGFloat(CTLineGetTrailingWhitespaceWidth(line)) }
            widths.append(max(0, width))
            location += length + 1
        }
        guard let end = Self.wordEnd(widths, tabs: props.tabs, start: first, limit: limit, defaultTab: CGFloat(max(model.defaultTab, 1)) / 20)
        else { return }
        // Обратное: по RTF не помещается (запас 1 pt) — у нас тоже перенос, а не строка шире, чем в Word.
        // Один знак не переносится и в Word.
        if !tabbed, end >= limit + 1, attributed.string.trimmingCharacters(in: .whitespaces).count > 1 {
            wrapChecks += 1
            var lines = 0
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(forCharacterRange: text, actualCharacterRange: nil)) { _, _, _, _, _ in
                lines += 1
            }
            if lines < 2 {
                overflows += 1
                details.append("\(body ? "body" : "header") one line, need \(String(format: "%.1f", end)) of \(String(format: "%.1f", limit))")
            }
            return
        }
        guard end <= limit - 1 else { return }
        checks += 1
        if tabbed { tabChecks += 1 } else { cellChecks += 1 }
        let glyphs = manager.glyphRange(forCharacterRange: text, actualCharacterRange: nil)
        var lines = 0
        var fragments: [String] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, used, _, _, _ in
            lines += 1
            fragments.append(String(format: "%.1f…%.1f used %.1f…%.1f", rect.minX, rect.maxX, used.minX, used.maxX))
        }
        if lines > 1 {
            violations += 1
            if body { bodyViolations += 1 }
            // Таблица основного текста шире полосы текста (выходит в поля): текст страницы рисуется в ширину полосы,
            // и `NSTextTable` сжимает её столбцы — отдельный класс, считается отдельно.
            var table = ""
            if body, let ref = paragraph.cell, let rows = story.tables[safe: ref.table]?.rows,
               let left = rows.map(\.left).min(), let right = rows.compactMap({ $0.cells.last?.right }).max() {
                if right - left > Int(textWidth * 20) { wideBodyTables += 1 }
                let cell = Self.cellWidth(paragraph, story)
                table = " table \(left)…\(right) text \(Int(textWidth * 20)) cell \(cell?.width ?? 0)/\(cell?.gap ?? 0)"
                    + " li \(props.left) fi \(props.firstLine) ri \(props.right)"
                    + " brdr \(Self.cellDef(paragraph, story).map { "\($0.borderLeft.isVisible ? $0.borderLeft.width : 0)/\($0.borderRight.isVisible ? $0.borderRight.width : 0)" } ?? "")"
            }
            details.append("\(body ? "body" : "header")\(table) lines \(lines) [\(fragments.joined(separator: "; "))] need \(String(format: "%.1f", end)) of \(String(format: "%.1f", limit)) tabs \(tabbed)")
        }
    }

    /// Где по Word кончится однострочный абзац с табуляциями (от начала отступа); `nil` — табуляция за правым краем
    /// (так не судим).
    static func wordEnd(_ widths: [CGFloat], tabs: [RTFTabStop], start: CGFloat, limit: CGFloat, defaultTab: CGFloat) -> CGFloat? {
        var x = start + (widths.first ?? 0)
        let stops = tabs.filter { $0.kind != .bar }.sorted { $0.position < $1.position }
        for width in widths.dropFirst() {
            let custom = stops.first { CGFloat($0.position) / 20 > x + 0.01 }
            let position = custom.map { CGFloat($0.position) / 20 } ?? (floor(x / defaultTab) + 1) * defaultTab
            guard position <= limit + 0.5 else { return nil }
            switch custom?.kind ?? .left {
            case .left, .bar: x = position + width
            case .right, .decimal: x = max(x + width, position)
            case .center: x = max(x + width, position + width / 2)
            }
        }
        return x
    }
}

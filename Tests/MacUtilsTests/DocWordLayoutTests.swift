import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Вертикаль «Документа» как у Word (`DocLineMetrics`): высота строк без округления TextKit, `\sl`, `\sb`/`\sa`,
/// `\contextualspace`, строки таблиц без лишних полей, знак конца пустой ячейки, плавающие фигуры без места в тексте,
/// колонтитул без пустой строки в конце, разрыв перед таблицей, `\caps`/`\scaps`, табуляция висячего отступа.
/// Демо — выдуманный текст.
@MainActor
final class DocWordLayoutTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
    }

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    private static let head = #"{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\froman Times New Roman;}}"#
        + #"\paperw11906\paperh16838\margl1134\margr850\margt1134\margb1134\sectd\headery709\footery709 "#

    private func open(_ body: String) throws -> DocumentController {
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: Data((Self.head + body + "}").utf8), url: URL(fileURLWithPath: "/tmp/word-layout.rtf")))
        tab.restoreMode(.document)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        windows.append(window)
        let document = try XCTUnwrap(tab.documentController)
        for _ in 0..<3 {
            if let last = document.layoutManager.textContainers.last { document.layoutManager.ensureLayout(for: last) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        return document
    }

    /// Строки (рамки) абзаца, в котором стоит `marker`.
    private func lines(_ document: DocumentController, _ marker: String) throws -> [NSRect] {
        let text = document.storage.string as NSString
        let found = text.range(of: marker)
        XCTAssertNotEqual(found.location, NSNotFound, marker)
        let paragraph = text.paragraphRange(for: found)
        let manager = document.layoutManager
        var rects: [NSRect] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)) { rect, _, _, _, _ in
            rects.append(rect)
        }
        return rects
    }

    /// Одинарный интервал Word для шрифта: ascent + descent + lineGap без округления.
    private func single(_ size: CGFloat) -> CGFloat {
        let font = NSFont(name: "Times New Roman", size: size) ?? .systemFont(ofSize: size)
        let metrics = DocLineMetrics.metrics(font)
        return metrics.above + metrics.below
    }

    func testLineHeightsLikeWord() throws {
        var body = #"\pard\plain\fs24 Alpha line\par "#
        body += #"\pard\plain\sl-300\slmult0\fs24 Exactly fifteen\par "#
        body += #"\pard\plain\sl360\slmult0\fs24 At least eighteen\par "#
        body += #"\pard\plain\sl276\slmult1\fs24 Multiple line\par "#
        body += #"\pard\plain\sb120\sa240\fs24 Spaced paragraph\par "#
        body += #"\pard\plain\fs20\super Raised\par "#
        let document = try open(body)
        let line = single(12)
        if NSFont(name: "Times New Roman", size: 12) != nil {
            XCTAssertEqual(line, 13.8, accuracy: 0.01, "TNR 12 у Word — 13,8 pt (TextKit давал 14,51)")
        }
        XCTAssertEqual(try lines(document, "Alpha").first?.height ?? 0, line, accuracy: 0.01)
        XCTAssertEqual(try lines(document, "Exactly").first?.height ?? 0, 15, accuracy: 0.01, "\\sl-300 — точно")
        XCTAssertEqual(try lines(document, "At least").first?.height ?? 0, 18, accuracy: 0.01, "\\sl360 — не меньше")
        XCTAssertEqual(try lines(document, "Multiple").first?.height ?? 0, line * 276 / 240, accuracy: 0.01, "\\slmult1 — от одинарного")
        XCTAssertEqual(try lines(document, "Spaced").first?.height ?? 0, 6 + line + 12, accuracy: 0.01, "\\sb над, \\sa под строкой")
        XCTAssertEqual(try lines(document, "Raised").first?.height ?? 0, single(10), accuracy: 0.01, "надстрочный — по полному кеглю")
        // Строки идут одна за другой: шаг — высота строки.
        let alpha = try XCTUnwrap(try lines(document, "Alpha").first), exactly = try XCTUnwrap(try lines(document, "Exactly").first)
        XCTAssertEqual(exactly.minY - alpha.minY, line, accuracy: 0.01)
    }

    func testContextualSpacingBetweenParagraphsOfOneStyle() throws {
        var body = #"\pard\plain\s3\contextualspace\sa240\fs24 First item\par "#
        body += #"\pard\plain\s3\contextualspace\sa240\fs24 Second item\par "#
        body += #"\pard\plain\fs24 After list\par "#
        let document = try open(body)
        let first = try XCTUnwrap(try lines(document, "First").first), second = try XCTUnwrap(try lines(document, "Second").first)
        XCTAssertEqual(first.height, single(12), accuracy: 0.01, "тот же стиль следом — без \\sa")
        XCTAssertEqual(second.height, single(12) + 12, accuracy: 0.01, "дальше другой стиль — \\sa есть")
        let info = document.storage.attribute(.docPara, at: (document.storage.string as NSString).range(of: "First").location, effectiveRange: nil)
        XCTAssertEqual((info as? DocParaInfo)?.props.spaceAfter, 240, "в свойствах абзаца — исходный \\sa (линейка, команды)")
    }

    func testTableRowsLikeWord() throws {
        let row = #"\trowd\trgaph108\trleft0\cellx3000\cellx6000 "#
        var body = row + #"\pard\plain\intbl\fs20 Cell text\cell {\fs14 \cell }{"# + row + #"\row}"#
        body += row + #"\pard\plain\intbl\fs14 Small\cell \cell {"# + row + #"\row}"#
        body += #"\pard\plain\fs24 Below\par "#
        let document = try open(body)
        let first = try XCTUnwrap(try lines(document, "Cell text").first), second = try XCTUnwrap(try lines(document, "Small").first)
        XCTAssertEqual(second.minY - first.minY, single(10), accuracy: 0.01, "без полей ячейки сверху и снизу (\\trpaddt/\\trpaddb = 0)")
        // Пустая ячейка: высота — от знака \cell (\fs14), а не от шрифта по умолчанию.
        let text = document.storage.string as NSString
        let manager = document.layoutManager
        let empty = NSMaxRange(text.range(of: "Cell text")) + 1
        let rect = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: empty), effectiveRange: nil)
        XCTAssertEqual(rect.height, single(7), accuracy: 0.01)
    }

    func testFloatingShapeTakesNoSpaceAndIsDrawnAtItsPlace() throws {
        let shape = #"{\shp{\*\shpinst\shpleft567\shpright2835\shptop-100\shpbottom467\shpbxcolumn\shpbxignore\shpbypara\shpbyignore\shpwr3"#
            + #"\shpfblwtxt0{\sp{\sn shapeType}{\sv 1}}{\sp{\sn fFilled}{\sv 0}}{\sp{\sn posrelh}{\sv 0}}}"#
            + #"{\shprslt{\*\do\dobxcolumn\dobypara\dprect\dpx567\dpy0\dpxsize2268\dpysize567}}}"#
        let body = #"\pard\plain\fs24 Before\par \pard\plain\fs24 Anchor"# + shape + #" text\par \pard\plain\fs24 After\par "#
        let document = try open(body)
        let text = document.storage.string as NSString
        let location = text.range(of: "\u{FFFC}").location
        XCTAssertNotEqual(location, NSNotFound)
        let attachment = try XCTUnwrap(document.storage.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment)
        let cell = try XCTUnwrap(attachment.attachmentCell as? DocFloatingCell, "плавающая фигура — опора, не заглушка")
        XCTAssertEqual(cell.cellSize(), .zero)
        XCTAssertFalse(text.contains("Показать в коде"))
        let anchor = try XCTUnwrap(try lines(document, "Anchor").first)
        XCTAssertEqual(anchor.height, single(12), accuracy: 0.01, "строка с опорой — обычной высоты")
        let page = try XCTUnwrap(document.pagesView.pages.first)
        let (_, frame) = try XCTUnwrap(page.floatingShapes().first)
        // posrelh 0 — от поля; по вертикали — от верха абзаца опоры.
        XCTAssertEqual(frame.minX, DocPageView.bodyRect(page.props).minX + 28.35, accuracy: 0.01)
        XCTAssertEqual(frame.width, 113.4, accuracy: 0.01)
        XCTAssertEqual(frame.minY, page.textView.frame.minY + anchor.minY - 5, accuracy: 0.01)
        XCTAssertEqual(frame.height, 28.35, accuracy: 0.01)
    }

    func testFooterBottomOnFooterY() throws {
        let body = #"{\footer \pard\plain\fs20 Footer line\par}\pard\plain\fs24 Body\par "#
        let document = try open(body)
        let page = try XCTUnwrap(document.pagesView.pages.first)
        // Высота — одна строка: без пустой строки после последнего \par (иначе текст поднимался на строку).
        XCTAssertEqual(page.footerHeight, single(10), accuracy: 0.01)
        XCTAssertEqual(page.footerRect.maxY, page.bounds.height - 35.45, accuracy: 0.01)
    }

    func testPageBreakBeforeTableRow() throws {
        let row = #"\trowd\trgaph108\trleft0\cellx4000 "#
        var body = #"\pard\plain\fs24 First page\par "#
        body += row + #"\pard\plain\pagebb\intbl\fs24 Second page cell\cell {"# + row + #"\row}"#
        body += #"\pard\plain\fs24 Tail\par "#
        let document = try open(body)
        XCTAssertEqual(document.pagesView.pages.count, 2, "\\pagebb в первой ячейке — строка таблицы с новой страницы")
        let manager = document.layoutManager
        let text = document.storage.string as NSString
        let cell = manager.glyphIndexForCharacter(at: text.range(of: "Second page").location)
        XCTAssertTrue(manager.textContainer(forGlyphAt: cell, effectiveRange: nil) === document.pagesView.pages[1].container)
        // Таблица — у верха страницы (NSTextTable ставит её на полпункта ниже края): служебный абзац места не занял.
        XCTAssertLessThanOrEqual(manager.lineFragmentRect(forGlyphAt: cell, effectiveRange: nil).minY, 0.5 + 0.01,
                                 "служебный абзац разрыва — нулевой высоты")
    }

    func testWhollyHiddenParagraphTakesNoLine() throws {
        let body = #"\pard\plain\fs20 {\v\fs16 $}{\v\fs16 \par }\pard\plain\fs24 Visible\par "#
        let document = try open(body)
        let visible = try XCTUnwrap(try lines(document, "Visible").first)
        XCTAssertEqual(visible.minY, 0, accuracy: 0.01, "скрытый целиком абзац (и знак \\par) — без пустой строки")
        document.showsInvisibles = true
        document.layoutManager.ensureLayout(for: document.layoutManager.textContainers[0])
        XCTAssertGreaterThan(try XCTUnwrap(try lines(document, "Visible").first).minY, 0, "при ¶ — виден")
    }

    func testPageBreakLineAtFullPageLeavesNoBlankPage() throws {
        // Страница заполнена почти до низа, следующий абзац — с \pagebb: «\f» внизу места не просит.
        var body = ""
        for number in 1...52 { body += #"\pard\plain\fs24 Line "# + "\(number)" + #"\par "# }
        body += #"\pard\plain\pagebb\fs24 Next page\par "#
        let document = try open(body)
        XCTAssertEqual(document.pagesView.pages.count, 2)
        let manager = document.layoutManager
        let glyph = manager.glyphIndexForCharacter(at: (document.storage.string as NSString).range(of: "Next page").location)
        XCTAssertTrue(manager.textContainer(forGlyphAt: glyph, effectiveRange: nil) === document.pagesView.pages[1].container)
    }

    func testCapsAndHangingIndentTab() throws {
        var body = #"\pard\plain\fs24 {\caps upper words}\par "#
        body += #"\pard\plain\fs24 {\scaps Small caps}\par "#
        body += #"\pard\plain\fi-360\li360\fs24 1.\tab Hanging item\par "#
        let document = try open(body)
        let text = document.storage.string as NSString
        XCTAssertNotEqual(text.range(of: "UPPER WORDS").location, NSNotFound)
        let small = text.range(of: "SMALL CAPS")
        XCTAssertNotEqual(small.location, NSNotFound)
        let capital = document.storage.attribute(.font, at: small.location, effectiveRange: nil) as? NSFont
        let lower = document.storage.attribute(.font, at: small.location + 1, effectiveRange: nil) as? NSFont
        XCTAssertEqual(capital?.pointSize, 12)
        XCTAssertEqual(lower?.pointSize, 9.5, "строчные капители — на 80 % кегля (до полупункта)")
        let style = document.storage.attribute(.paragraphStyle, at: text.range(of: "Hanging").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertTrue(style?.tabStops.contains { abs($0.location - 18) < 0.01 } == true, "левый отступ — позиция табуляции")
        // Правка по-прежнему в исходнике: показ заглавными его не меняет.
        XCTAssertTrue(document.tab?.text.contains("upper words") == true)
    }

    /// `\trrh` > 0 — строка не ниже заданного (у `NSTextTable` `minimumHeight` блока не действует), и в ячейке из нескольких
    /// абзацев высота не удваивается; в строке с вертикальным объединением высота — по тексту (гейт, .audit/doc-resume.md).
    func testRowHeightAtLeastLikeWord() throws {
        let row = #"\trowd\trgaph108\trleft0\trrh1000\cellx3000\cellx6000 "#
        for cell in [#"\pard\intbl AAA\cell"#, #"\pard\intbl A1\par\pard\intbl A2\par\pard\intbl A3\cell"#] {
            let body = #"\pard before\par "# + row + cell + #"\pard\intbl BBB\cell"# + row + #"\row "# + row
                + #"\pard\intbl CCC\cell\pard\intbl DDD\cell"# + row + #"\row\pard after\par"#
            let document = try open(body)
            let top = try XCTUnwrap(lines(document, "BBB").first).minY, next = try XCTUnwrap(lines(document, "CCC").first).minY
            XCTAssertEqual(next - top, 50, accuracy: 0.01, "\\trrh1000 = 50 pt")
        }
        let merged = #"\trowd\trgaph108\trleft0\trrh1000\clvmgf\cellx3000\cellx6000 "#
        let below = #"\trowd\trgaph108\trleft0\trrh1000\clvmrg\cellx3000\cellx6000 "#
        let body = merged + #"\pard\intbl MMM\cell\pard\intbl EEE\cell"# + merged + #"\row "# + below
            + #"\pard\intbl \cell\pard\intbl FFF\cell"# + below + #"\row\pard after\par"#
        let document = try open(body)
        let top = try XCTUnwrap(lines(document, "EEE").first).minY, next = try XCTUnwrap(lines(document, "FFF").first).minY
        XCTAssertLessThan(next - top, 50, "строка с объединением — по тексту")
    }

    /// Вложенная таблица (P-4): начинается у верха ячейки (без слияния рамок `NSTextTable` не сдвигает её на полпункта),
    /// строка внешней с `\trrh` — своей высоты плюс полоса рамки (у Word рамка занимает место: здесь только верхняя `\brdrw10`,
    /// половина линии — 0,24 pt); ячейка по центру выравнивается по оценке строк вложенной.
    func testNestedTableTopAndOuterRowHeight() throws {
        let outer = #"\trowd\trgaph108\trleft0\trrh3272\clbrdrt\brdrs\brdrw10 \cellx3000\clvertalc\clbrdrt\brdrs\brdrw10 \cellx9000 "#
        let nprops = { (h: Int) in #"{\*\nesttableprops\trowd\trgaph28\trleft0\trrh"# + String(h) + #"\clbrdrt\brdrs\brdrw10 \cellx3000\clbrdrt\brdrs\brdrw10 \cellx6000\nestrow}{\nonesttables\par }"# }
        let nrow = { (a: String, h: Int) in #"\pard\plain\intbl\itap2\fs20 "# + a + #"1\nestcell\pard\plain\intbl\itap2\fs20 "# + a + #"2\nestcell\pard\plain\intbl\itap2\fs20 "# + nprops(h) }
        let top = outer.replacingOccurrences(of: #"\clvertalc"#, with: "")
        for (row, centered) in [(top, false), (outer, true)] {
            let body = #"\pard before\par "# + row + #"\pard\plain\intbl\itap1\fs20 LEFT\cell"# + nrow("NA", 480) + nrow("NB", 566)
                + #"\pard\plain\intbl\itap1\fs20 \cell"# + row + #"\row "# + row + #"\pard\plain\intbl\itap1\fs20 SECOND\cell\pard\plain\intbl\itap1\fs20 X\cell"#
                + row + #"\row\pard AFTER\par"#
            let document = try open(body)
            let left = try XCTUnwrap(lines(document, "LEFT").first).minY, nested = try XCTUnwrap(lines(document, "NA1").first).minY
            let second = try XCTUnwrap(lines(document, "SECOND").first).minY
            XCTAssertEqual(second - left, 163.6 + 0.24, accuracy: 0.05, "строка внешней — \\trrh3272 и полоса верхней рамки")
            if centered {
                // Содержимое: 24 + 28,3 pt вложенной и пустая строка — сдвиг по центру примерно (163,6 − ~64) / 2.
                XCTAssertGreaterThan(nested - left, 40)
                XCTAssertLessThan(nested - left, 60)
            } else {
                XCTAssertEqual(nested - left, 0.24, accuracy: 0.05, "вложенная — у верха ячейки, ниже на полосу своей верхней рамки")
            }
        }
    }

    /// Интервал «Авто» (`\sbauto1`/`\saauto1`; `\sb100`/`\sa100` рядом — для старых читателей): 14 pt, у начала и конца ячейки — 0,
    /// два «авто» подряд не складываются (f145: строки таблиц были на 5–7 pt выше Word).
    func testAutoSpacingLikeWord() throws {
        let row = #"\trowd\trgaph108\trleft0\cellx3000\cellx6000 "#
        let auto = #"\pard\plain\intbl\sbauto1\saauto1\sb100\sa100\fs24 "#
        let body = #"\pard before\par "# + row + auto + #"PA\par"# + auto + #"PB\cell\pard\plain\intbl\fs24 OTHER\cell"# + row + #"\row\pard\plain\fs24 AFTER\par"#
        let document = try open(body)
        let a = try XCTUnwrap(lines(document, "PA").first), b = try XCTUnwrap(lines(document, "PB").first)
        let other = try XCTUnwrap(lines(document, "OTHER").first), after = try XCTUnwrap(lines(document, "AFTER").first)
        XCTAssertEqual(a.minY, other.minY, accuracy: 0.05, "у начала ячейки «авто» сверху нет")
        XCTAssertEqual(b.minY - a.minY, single(12) + 14, accuracy: 0.05, "между «авто» — 14 pt, не 28")
        XCTAssertEqual(after.minY - b.maxY, 0, accuracy: 0.05, "у конца ячейки «авто» снизу нет")
    }

    /// Вертикаль как у Word (правила из .audit/wordcraft-eval.md): высоту строки задают её символы — крупный пробел или табуляция
    /// строку не растят; при `\slmult` добавок множителя — под текстом; рамка ячейки занимает место в высоте строки таблицы.
    func testLineHeightBaselineAndBorderBandLikeWord() throws {
        let document = try open(#"\pard\plain\fs24 Small{\fs48   }text\par\pard\plain\fs24 NEXT\par\pard\plain\sl276\slmult1\fs24 MULTI\par\pard\plain\fs24 AFTER\par"#
            + #"\trowd\trgaph108\trleft0\clbrdrt\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \cellx3000 \pard\plain\intbl\fs24 R1\cell\trowd\trgaph108\trleft0\clbrdrt\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \cellx3000\row"#
            + #"\trowd\trgaph108\trleft0\clbrdrt\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \cellx3000 \pard\plain\intbl\fs24 R2\cell\trowd\trgaph108\trleft0\clbrdrt\brdrs\brdrw10 \clbrdrb\brdrs\brdrw10 \cellx3000\row\pard END\par"#)
        let small = try XCTUnwrap(lines(document, "Small").first), next = try XCTUnwrap(lines(document, "NEXT").first)
        XCTAssertEqual(next.minY - small.minY, single(12), accuracy: 0.05, "пробел 24 pt строку не растит")
        let manager = document.layoutManager
        let multi = (document.storage.string as NSString).range(of: "MULTI").location
        let glyph = manager.glyphIndexForCharacter(at: multi)
        let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = NSFont(name: "Times New Roman", size: 12) ?? .systemFont(ofSize: 12)
        XCTAssertEqual(rect.height, single(12) * 1.15, accuracy: 0.05)
        XCTAssertEqual(manager.location(forGlyphAt: glyph).y, DocLineMetrics.metrics(font).above, accuracy: 0.05, "базовая линия — на ascent от верха")
        let r1 = try XCTUnwrap(lines(document, "R1").first), r2 = try XCTUnwrap(lines(document, "R2").first)
        XCTAssertEqual(r2.minY - r1.minY, single(12) + 0.48, accuracy: 0.05, "строка таблицы — текст и полосы рамок (по 0,24 pt)")
    }
}

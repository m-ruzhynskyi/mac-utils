import AppKit
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUTextEditor

/// Внутренний разбор `$` по видимому тексту RTF — для будущего режима «Документ»; панель «$» его не использует
/// (правило панели — до конца строки исходника, TextEditorValueRuleTests). Через коды, группы и переводы строк
/// исходника; конец — видимый пробельный символ, `\par \line \pard \sect \page \tab \cell \row`, следующий `$` или конец.
final class TextEditorRTFValueTests: XCTestCase {
    private func values(_ rtf: String) -> [String] {
        RTFDollarScanner.scan(rtf as NSString).map { $0.visible ?? "" }
    }

    /// Пример пользователя (только коды): Word разорвал значение группами с rsid.
    func testUserExampleThroughWordGroups() {
        let rtf = #"\pard Name: $}{\rtlch\fcs1 \af0\afs32 \ltrch\fcs0 \fs32\lang1033\langfe1049\langnp1033\insrsid4548749 }{\rtlch\fcs1 \af0\afs2 \ltrch\fcs0 \fs32 Ivanov}\par"#
        XCTAssertEqual(values(rtf), ["Ivanov"], "пробел после кода — разделитель, не текст")
        // Второй пробел после `\insrsid4548749` — уже видимый текст: по окончательному правилу значение на нём кончается.
        let doubleSpace = #"$}{\insrsid4548749  }{\fs32 Ivanov}\par"#
        XCTAssertEqual(values(doubleSpace), [""])
    }

    func testValueSplitInsideWordAndAcrossSourceLines() {
        let rtf = "$AB}{\\insrsid1 CD}{\\fs20 E\r\nF}\\par" as NSString
        let mark = RTFDollarScanner.scan(rtf)[0]
        XCTAssertEqual(mark.visible, "ABCDEF", "перевод строки исходника не виден и значение не прерывает")
        XCTAssertEqual(mark.parts.map { rtf.substring(with: $0) }, ["AB", "CD", "E", "F"])
        XCTAssertEqual(DollarMarks.removingValues(of: [mark], in: rtf as String), "$}{\\insrsid1 }{\\fs20 \r\n}\\par",
                       "убираются только видимые символы, все коды и группы на месте")
    }

    func testEscapesAndUnicode() {
        XCTAssertEqual(values(#"$caf\'e9\par"#), ["café"])
        XCTAssertEqual(values(#"{\rtf1\ansi\ansicpg1251 $\'cf\'f0\par}"#), ["Пр"], "\\'hh — в кодировке документа")
        XCTAssertEqual(values(#"$\u1071?\u1046?\par"#), ["ЯЖ"])
        XCTAssertEqual(values(#"{\uc2 $\u1071\'3f\'3fZ\par}"#), ["ЯZ"], "\\uc2 — два заменителя")
        XCTAssertEqual(values(#"{\uc0 $\u1071 Z\par}"#), ["ЯZ"], "без заменителей; пробел после \\u1071 — разделитель")
        XCTAssertEqual(values(#"$a\\b\{c\}\par"#), [#"a\b{c}"#])
        XCTAssertEqual(values(#"$x\-y\_z\par"#), ["xy\u{2011}z"])
        XCTAssertEqual(values(#"$A;B=1-2'c]\cell"#), ["A;B=1-2'c]"], "; = - ' ] входят в значение")
        let unicode = RTFDollarScanner.scan(#"$\u1071?\par"# as NSString)[0]
        XCTAssertEqual(unicode.parts, [NSRange(location: 1, length: 7)], "\\u1071 вместе с заменителем — один кусок")
    }

    func testEnds() {
        XCTAssertEqual(values(#"$abc\par next"#), ["abc"])
        XCTAssertEqual(values(#"$\par"#), [""], "сразу конец абзаца — пусто")
        XCTAssertEqual(values("$A $B"), ["A", "B"], "видимый пробел заканчивает")
        XCTAssertEqual(values(#"$A\~B"#), ["A"], "неразрывный пробел — тоже пробел")
        XCTAssertEqual(values("$A\tB"), ["A"])
        XCTAssertEqual(values(#"$A\tab B"#), ["A"])
        XCTAssertEqual(values("$A$B"), ["A", "B"])
        XCTAssertEqual(values(#"$A\line B"#), ["A"])
        XCTAssertEqual(values(#"$A\row"#), ["A"])
        XCTAssertEqual(values(#"$A\sect"#), ["A"])
        XCTAssertEqual(values(#"$A\page"#), ["A"])
        XCTAssertEqual(values(#"$A\pard B"#), ["A"])
        XCTAssertEqual(values(#"$A\b B\b0 C"#), ["ABC"], "пробел после \\b и \\b0 — разделитель кода, не текст")
        XCTAssertEqual(values("$tail"), ["tail"], "до конца текста")
        XCTAssertEqual(values(#"$A\emdash B"#), ["A\u{2014}B"])
    }

    func testHiddenGroups() {
        let rtf = #"{\rtf1{\info{\title $FORM}{\author $WHO}}{\*\bkmkstart $mark}{\fonttbl{\f0 $font;}}\pard $body\par}"# as NSString
        let marks = RTFDollarScanner.scan(rtf)
        XCTAssertEqual(marks.map(\.hidden), [true, true, true, true, false])
        XCTAssertEqual(marks.map { $0.visible ?? "" }, ["FORM", "WHO", "mark", "font;", "body"])
        // Видимый знак не берёт текст служебной группы внутри значения.
        XCTAssertEqual(values(#"$AB{\*\bkmkend x}CD\par"#), ["ABCD"])
        // `$` служебной группы посреди значения его не прерывает (замечание тестировщика, rtf-split 05).
        let inner = RTFDollarScanner.scan(#"S1: $A{\*\bkmkstart x$y}B}\par"# as NSString)
        XCTAssertEqual(inner.map(\.dollar), [4, 21], "по порядку в тексте")
        XCTAssertEqual(inner.map(\.hidden), [false, true])
        XCTAssertEqual(inner.map { $0.visible ?? "" }, ["AB", "y"])
        XCTAssertEqual(inner[0].parts, [NSRange(location: 5, length: 1), NSRange(location: 24, length: 1)])
    }

    /// Панель: служебные знаки отдельно и вне «Пропускать первые N»; «Убрать значения» их не трогает.
    @MainActor
    func testPanelSplitAndRemovalKeepCodes() throws {
        let defaults = EditorDefaultsSnapshot()
        defer { defaults.restore() }
        UserDefaults.standard.set(true, forKey: Pref.editorSkipFirst)
        UserDefaults.standard.set(1, forKey: Pref.editorSkipCount)
        let rtf = #"{\rtf1\ansi\ansicpg1252{\info{\title $T}}\pard $one\par $tw}{\insrsid9 o}\par $thr\'e9e\par}"#
        let data = try XCTUnwrap(TextEncoding.windows1252.encode(rtf))
        let tab = EditorTab(document: EditorDocument(data: data, url: URL(fileURLWithPath: "/tmp/demo.frm")))
        XCTAssertEqual(tab.dollarRule, .source, "панель — одно правило для всех файлов")
        tab.dollarRule = .rtf
        let deadline = Date().addingTimeInterval(3)
        while tab.dollars.entries.count != 4, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(tab.dollars.service.map(\.value), ["T"])
        XCTAssertEqual(tab.dollars.split.skipped.map(\.value), ["one"])
        XCTAssertEqual(tab.dollars.split.active.map(\.value), ["two", "thrée"])
        XCTAssertEqual(tab.removeHighlightedValues(), 2)
        XCTAssertEqual(tab.text as String, #"{\rtf1\ansi\ansicpg1252{\info{\title $T}}\pard $one\par $}{\insrsid9 }\par $\par}"#,
                       "служебный и пропущенный не тронуты, коды на месте")
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, rtf, "одна отмена")
        XCTAssertEqual(try tab.document.data(for: tab.text as String), data)
        // Снова правило панели — до конца строки (в списке без хвостовых пробелов).
        tab.dollarRule = .source
        XCTAssertEqual(tab.dollars.entries.map(\.value).first, "T}}\\pard")
    }

    /// 10 МБ RTF: скан по видимому тексту < 300 мс (в отладочной сборке время только печатается).
    func testScanTenMegabytes() throws {
        let big = TextEditorPerformanceTests.bigFile()
        let text = try XCTUnwrap(TextEncoding.windows1252.decode(big.data)) as NSString
        var marks: [DollarMark] = []
        let time = TextEditorPerformanceTests.measure { marks = RTFDollarScanner.scan(text) }
        XCTAssertEqual(marks.count, big.dollars)
        XCTAssertTrue(marks.allSatisfy { !$0.isEmpty })
        print(String(format: "[editor-perf] %@ RTF-скан $ в 10 МБ: %.0f мс", TextEditorPerformanceTests.build, time))
        XCTAssertLessThan(time, TextEditorPerformanceTests.limit(300))
    }
}

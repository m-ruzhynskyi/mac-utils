import AppKit
import XCTest
@testable import MUCore
@testable import MUTextEditor

/// V1 (`.audit/plan-word-ui.md`): статус знака в строке панели «$» (заполнено ✓ / пусто / правится) и «Заполнено N из M»
/// в строке состояния — из того же значения, что показывает строка (в «Документе» — `visibleValue`).
@MainActor
final class DollarStatusTests: XCTestCase {
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.set(true, forKey: Pref.editorSkipFirst)
        UserDefaults.standard.set(1, forKey: Pref.editorSkipCount)
    }

    override func tearDown() {
        defaults.restore()
        super.tearDown()
    }

    private func tab(_ text: String, name: String = "demo.txt") -> EditorTab {
        let tab = EditorTab(document: EditorDocument(data: Data(text.utf8), url: URL(fileURLWithPath: "/tmp/" + name)))
        tab.dollars.scanNow(tab.text)
        return tab
    }

    func testStatusFromShownValue() {
        XCTAssertEqual(DollarStatus.of(value: "ООО Ромашка", editing: false), .filled)
        XCTAssertEqual(DollarStatus.of(value: "", editing: false), .empty)
        XCTAssertEqual(DollarStatus.of(value: "  \t", editing: false), .empty, "одни пробелы — пусто")
        XCTAssertEqual(DollarStatus.of(value: "Иванов", editing: true), .editing, "курсор в значении — «правится»")
        XCTAssertEqual(DollarStatus.of(value: "", editing: true), .editing)
    }

    func testEditingFollowsCaretInsideValue() throws {
        let text = "Счёт $00142\nКлиент $\nАдрес $ул. Демо 1\n"
        let tab = tab(text)
        let entries = tab.dollars.entries
        XCTAssertEqual(entries.count, 3)
        let model = tab.dollars
        let first = entries[0].mark, second = entries[1].mark

        model.caretMoved(to: NSRange(location: first.dollar, length: 0))
        XCTAssertNil(model.editing, "курсор перед `$` — знак не правится")
        model.caretMoved(to: NSRange(location: first.dollar + 1, length: 0))
        XCTAssertEqual(model.editing, first.dollar, "сразу после `$`")
        model.caretMoved(to: NSRange(location: first.dollar + 3, length: 0))
        XCTAssertEqual(model.editing, first.dollar, "внутри значения")
        model.caretMoved(to: NSRange(location: NSMaxRange(first.whole), length: 0))
        XCTAssertEqual(model.editing, first.dollar, "сразу за значением — набор его дописывает")
        model.caretMoved(to: NSRange(location: 1, length: 2))
        XCTAssertNil(model.editing, "выделение в обычном тексте")
        model.caretMoved(to: NSRange(location: second.dollar + 1, length: 0))
        XCTAssertEqual(model.editing, second.dollar, "пустой знак: курсор после `$`")
        model.caretMoved(to: NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(model.editing, entries[2].mark.dollar, "выделение через несколько знаков — последний задетый")

        model.caretMoved(to: NSRange(location: first.dollar + 2, length: 0))
        XCTAssertEqual(model.status(of: entries[0], value: tab.dollarValue(entries[0])), .editing)
        XCTAssertEqual(model.status(of: entries[1], value: tab.dollarValue(entries[1])), .empty)
        XCTAssertEqual(model.status(of: entries[2], value: tab.dollarValue(entries[2])), .filled)
    }

    func testEditingIsRecomputedAfterRescan() {
        let model = DollarPanelModel()
        model.scanNow("$a $b")
        model.caretMoved(to: NSRange(location: 4, length: 0))
        XCTAssertEqual(model.editing, 3, "курсор после второго `$`")
        // Перед знаками вставили «xxx »: знаки сдвинулись на 4, курсор (смещение 4) теперь перед первым `$` — ничего не правится.
        model.scanNow("xxx $a $b")
        XCTAssertNil(model.editing, "после пересчёта «правится» ищется заново по сохранённому курсору")
        model.scanNow("$a $b")
        XCTAssertEqual(model.editing, 3, "и снова находится, когда курсор опять в значении")
    }

    func testFillCountsOnlyHighlightedAndMatchesRowStatuses() {
        // Первый знак пропущен (настройка «Пропускать первые» = 1): в счётчик не входит.
        let tab = tab("$заголовок\n$00142\n$\n$   \n$Иванов\n")
        let fill = tab.dollars.fill(value: tab.dollarValue)
        XCTAssertEqual(fill.total, 4)
        XCTAssertEqual(fill.filled, 2, "00142 и Иванов; пусто и одни пробелы — не заполнены")
        let rows = tab.dollars.split.active.filter { tab.dollars.status(of: $0, value: tab.dollarValue($0)) == .filled }
        XCTAssertEqual(rows.count, fill.filled, "счётчик = число строк со ✓")
        XCTAssertNil(tab.dollarFill(panelVisible: false), "панель закрыта — счётчика нет")
        XCTAssertEqual(tab.dollarFill(panelVisible: true)?.filled, 2)
        XCTAssertNil(self.tab("без знаков\n").dollarFill(panelVisible: true), "знаков нет — счётчика нет")
    }

    /// В «Документе» значение строки — как видно на странице (`visibleValue`), и счётчик считает по нему же.
    func testDocumentModeUsesVisibleValue() throws {
        UserDefaults.standard.set(false, forKey: Pref.editorSkipFirst)
        let pard = #"\pard\plain \f0\fs24 "#
        var source = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}"# + "\r\n"
        source += pard + DocDemo.rtf("Клиент: $Катя Демо") + "\r\n" + #"\par"# + "\r\n"
        source += pard + DocDemo.rtf("Счёт: $") + #"{\b }"# + "\r\n" + #"\par"# + "\r\n"
        source += pard + DocDemo.rtf("Адрес: $ул. Демо") + "\r\n" + #"\par}"#
        let tab = tab(source, name: "fill_demo.frm")
        tab.setMode(.document)
        let document = try XCTUnwrap(tab.documentController)
        XCTAssertEqual(tab.mode, .document)
        let entries = Array(tab.dollars.split.active)
        XCTAssertEqual(entries.count, 3)
        for entry in entries {
            XCTAssertEqual(tab.dollarValue(entry), document.visibleValue(of: entry.mark) ?? entry.value, "строка = visibleValue")
        }
        XCTAssertEqual(tab.dollarValue(entries[0]), "Катя Демо", "\\'hh → буквы, как на странице")
        XCTAssertNotEqual(entries[0].value, "Катя Демо", "в исходнике — коды RTF")
        let fill = tab.dollars.fill(value: tab.dollarValue)
        XCTAssertEqual(fill.total, 3)
        let filled = entries.filter { !(document.visibleValue(of: $0.mark) ?? $0.value).allSatisfy(\.isWhitespace) }.count
        XCTAssertEqual(fill.filled, filled, "счётчик считает по visibleValue")
    }

    // MARK: - Скорость: 22 знака — мгновенно, 500 — не дольше 100 мс

    private func timeStatuses(_ tab: EditorTab) -> TimeInterval {
        let start = Date()
        let model = tab.dollars
        _ = tab.dollarFill(panelVisible: true)
        for entry in model.split.active { _ = model.status(of: entry, value: tab.dollarValue(entry)) }
        model.caretMoved(to: NSRange(location: (tab.text as NSString).length / 2, length: 0))
        return Date().timeIntervalSince(start)
    }

    func testStatusesAreFastInCode() {
        for (count, limit) in [(22, 0.01), (500, 0.1)] {
            let text = (0..<count).map { "Строка \($0): $значение-\($0)\n" }.joined()
            let tab = tab(text)
            XCTAssertEqual(tab.dollars.entries.count, count)
            let elapsed = timeStatuses(tab)
            XCTAssertLessThan(elapsed, limit, "\(count) знаков: \(Int(elapsed * 1000)) мс")
        }
    }

    func testStatusesAreFastInDocument() throws {
        UserDefaults.standard.set(false, forKey: Pref.editorSkipFirst)
        for (count, limit) in [(22, 0.01), (500, 0.1)] {
            var source = #"{\rtf1\ansi\ansicpg1251\deff0{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}"# + "\r\n"
            for index in 0..<count {
                source += #"\pard\plain \f0\fs24 "# + DocDemo.rtf("Поле \(index): $Значение \(index)") + "\r\n" + #"\par"# + "\r\n"
            }
            source += "}"
            let tab = tab(source, name: "fill_\(count).frm")
            tab.setMode(.document)
            XCTAssertNotNil(tab.documentController)
            XCTAssertEqual(tab.dollars.split.active.count, count)
            _ = timeStatuses(tab)  // первый проход строит кэши карты
            let elapsed = timeStatuses(tab)
            XCTAssertLessThan(elapsed, limit, "«Документ», \(count) знаков: \(Int(elapsed * 1000)) мс")
            XCTAssertEqual(tab.dollarFill(panelVisible: true)?.filled, count)
        }
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUDesign
@testable import MUAudio
@testable import MUScreenshot
@testable import MUTextEditor

/// Орфография «Документа» (T4): язык куска по `\lang`, подчёркивание временным атрибутом (байты и текст те же), исправление из меню — обычная
/// точечная правка с одной отменой, значения `$` не проверяются. Словари берутся у системы: нет словаря — тест пропускается.
@MainActor
final class DocSpellingTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var defaults: EditorDefaultsSnapshot!

    override func setUp() {
        super.setUp()
        defaults = EditorDefaultsSnapshot()
        UserDefaults.standard.removeObject(forKey: Pref.editorViewModes)
        UserDefaults.standard.removeObject(forKey: Pref.docSpelling)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Pref.docSpelling)
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        defaults.restore()
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func open(_ source: String) throws -> (EditorTab, DocumentController) {
        let workspace = EditorWorkspace()
        let tab = EditorTab(document: EditorDocument(data: Data(source.utf8), url: URL(fileURLWithPath: "/tmp/spell.rtf")))
        tab.restoreMode(.document)
        workspace.add(tab)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: EditorRootView(workspace: workspace))
        window.orderBack(nil)
        windows.append(window)
        settle()
        return (tab, try XCTUnwrap(tab.documentController))
    }

    /// Русский абзац с опечаткой, украинский (`\lang1058`) с опечаткой, английский с опечаткой и значение `$` (не проверяется).
    static let mixed: String = {
        let rtf = DocDemo.rtf
        var s = #"{\rtf1\ansi\ansicpg1251\deff0\deflang1049{\fonttbl{\f0\froman\fcharset204 Times New Roman;}}\sectd"# + "\r\n"
        s += #"\pard\plain\f0\fs24 "# + rtf("Это проверка срелки в тексте.") + #"\par"# + "\r\n"
        s += #"\pard\plain\f0\fs24 {\lang1058 "# + rtf("Це перевірка ристрою у тексті.") + #"}\par"# + "\r\n"
        s += #"\pard\plain\f0\fs24\lang1033 This is a speling test.\par"# + "\r\n"
        s += #"\pard\plain\f0\fs24 "# + rtf("Имя: $Ксенофонтович") + "\r\n" + #"\par}"#
        return s
    }()

    func testLanguageChangesSplitParagraph() {
        let source = #"{\rtf1\ansi\deflang1049 \pard\plain Mixed {\lang1033 English} again {\plain\lang1058 uk} end\par}"# as NSString
        let changes = DocLanguage.changes(from: 0, to: source.length, in: source)
        XCTAssertEqual(changes.map(\.lcid), [1049, 1033, 1049, 1058, 1049], "в начале — язык документа; группа возвращает прежний")
        XCTAssertEqual(DocLanguage.spellingCode(lcid: 1049), "ru")
        XCTAssertEqual(DocLanguage.spellingCode(lcid: 1058), "uk")
        XCTAssertEqual(DocLanguage.spellingCode(lcid: 1033), "en_US")
        XCTAssertEqual(DocLanguage.spellingCode(lcid: 2057), "en_GB")
        XCTAssertNil(DocLanguage.spellingCode(lcid: 1031), "немецкого словаря в списке нет")
    }

    func testOffByDefaultAndNothingChanges() throws {
        let (tab, document) = try open(Self.mixed)
        document.spelling.run()
        XCTAssertTrue(document.spelling.misspelled.isEmpty, "по умолчанию выключено")
    }

    func testUnderlinesMisspellingsWithoutChangingBytes() throws {
        try XCTSkipUnless(DocSpelling.available("ru") && DocSpelling.available("en"), "нет словарей ru/en")
        UserDefaults.standard.set(true, forKey: Pref.docSpelling)
        let (tab, document) = try open(Self.mixed)
        let bytes = tab.text as String
        let text = document.storage.string
        document.spelling.run()
        settle(0.8)
        let shown = document.storage.string as NSString
        let marked = document.spelling.misspelled.map { shown.substring(with: $0) }
        XCTAssertTrue(marked.contains("срелки"), "русская опечатка: \(marked)")
        XCTAssertTrue(marked.contains("speling"), "английская опечатка: \(marked)")
        XCTAssertFalse(marked.contains { $0.contains("Ксенофонтович") }, "значение $ не проверяется")
        XCTAssertFalse(marked.contains("This"), "верные слова не помечены")
        let bad = document.spelling.misspelled[0]
        XCTAssertNotNil(document.layoutManager.temporaryAttribute(.spellingState, atCharacterIndex: bad.location, effectiveRange: nil), "подчёркнуто временным атрибутом")
        XCTAssertNil(document.storage.attribute(.spellingState, at: bad.location, effectiveRange: nil), "в тексте атрибута нет")
        XCTAssertEqual(tab.text as String, bytes, "подчёркивание не меняет байты")
        XCTAssertEqual(document.storage.string, text, "и видимый текст")
        XCTAssertFalse(tab.isDirty)
        if DocSpelling.available("uk") { XCTAssertTrue(marked.contains("ристрою"), "украинская опечатка проверена украинским словарём: \(marked)") }
        // Выключили — подчёркивание снято.
        UserDefaults.standard.set(false, forKey: Pref.docSpelling)
        document.spelling.clear()
        XCTAssertTrue(document.spelling.misspelled.isEmpty)
        XCTAssertNil(document.layoutManager.temporaryAttribute(.spellingState, atCharacterIndex: bad.location, effectiveRange: nil))
    }

    func testFixFromMenuIsOnePointEditWithUndo() throws {
        try XCTSkipUnless(DocSpelling.available("ru"), "нет словаря ru")
        UserDefaults.standard.set(true, forKey: Pref.docSpelling)
        let (tab, document) = try open(Self.mixed)
        let original = tab.text as String
        document.spelling.run()
        settle(0.8)
        let shown = document.storage.string as NSString
        let word = shown.range(of: "срелки")
        let items = document.spelling.menuItems(forUnit: word.location + 2, target: self, apply: #selector(noop(_:)))
        XCTAssertFalse(items.isEmpty, "варианты исправления в меню")
        let guess = try XCTUnwrap(document.spelling.guesses(for: word).first(where: { $0 != "срелки" }), "словарь предложил вариант")
        XCTAssertTrue(document.perform(replacing: word, with: guess))
        XCTAssertTrue(document.storage.string.contains(guess))
        XCTAssertTrue((tab.text as String).contains(DocDemo.rtf(guess)), "в файле — \\'hh cp1251")
        tab.undo.undo()
        XCTAssertEqual(tab.text as String, original, "одна отмена — байт в байт")
    }

    @objc private func noop(_ sender: Any?) {}

    func testChoiceFixedLanguageAndOff() throws {
        try XCTSkipUnless(DocSpelling.available("en"), "нет словаря en")
        UserDefaults.standard.set(true, forKey: Pref.docSpelling)
        let (_, document) = try open(Self.mixed)
        document.spelling.choice = .off
        document.spelling.run()
        XCTAssertTrue(document.spelling.misspelled.isEmpty, "«Не проверять»")
        document.spelling.choice = .fixed("en_US")
        settle(0.8)
        let shown = document.storage.string as NSString
        XCTAssertTrue(document.spelling.misspelled.contains { shown.substring(with: $0) == "speling" })
        XCTAssertTrue(document.spelling.misspelled.contains { shown.substring(with: $0) == "Это" } || document.spelling.misspelled.count > 3,
                      "один английский словарь на весь текст помечает русские слова")
    }
}

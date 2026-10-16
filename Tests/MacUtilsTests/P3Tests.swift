import XCTest
import Carbon.HIToolbox
@testable import MacUtils

final class P3Tests: XCTestCase {
    // AI4
    func testSecureInputMessage() {
        XCTAssertNil(TextFixer.blockedMessage(secureInput: false))
        XCTAssertNotNil(TextFixer.blockedMessage(secureInput: true))
    }

    // AI5
    func testUndoOnlyInSameApp() {
        XCTAssertTrue(TextFixer.canUndo(pastedIn: 10, frontmost: 10))
        XCTAssertFalse(TextFixer.canUndo(pastedIn: 10, frontmost: 11))
        XCTAssertFalse(TextFixer.canUndo(pastedIn: nil, frontmost: 10))
        XCTAssertFalse(TextFixer.canUndo(pastedIn: 10, frontmost: nil))
    }

    // AN2 / A4
    func testHotKeyReregisterSkippedOnlyWhenUnchangedAndRegistered() {
        let a = LayoutHotKey(keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey)
        let b = LayoutHotKey(keyCode: kVK_ANSI_B, modifiers: controlKey | optionKey)
        XCTAssertTrue(HotKeyCenter.isUnchanged(old: a, new: a, registered: true))
        XCTAssertFalse(HotKeyCenter.isUnchanged(old: a, new: b, registered: true))
        XCTAssertFalse(HotKeyCenter.isUnchanged(old: nil, new: a, registered: true))
        XCTAssertFalse(HotKeyCenter.isUnchanged(old: a, new: a, registered: false)) // прошлая попытка не удалась — пробуем снова
    }

    // A6
    @MainActor func testMainMenuHasSettingsAboutUpdatesQuit() {
        let menu = MainMenu.build()
        let app = menu.items[0].submenu!
        let titles = app.items.map(\.title)
        XCTAssertTrue(titles.contains("О программе Mac Utils"))
        XCTAssertTrue(titles.contains("Проверить обновления…"))
        let settings = app.items.first { $0.title == "Настройки…" }
        XCTAssertEqual(settings?.keyEquivalent, ",")
        XCTAssertTrue(titles.contains("Закрыть окно"))
        XCTAssertTrue(titles.contains("Выйти из Mac Utils"))
        XCTAssertEqual(menu.items.count, 2) // приложение и «Правка»
    }

    // T7
    func testToolsLauncherPlan() {
        XCTAssertEqual(ToolsLauncher.plan(consent: nil, alreadyInstalled: false, asks: ToolsLauncher.maxAsks - 1), .ask)
        XCTAssertEqual(ToolsLauncher.plan(consent: nil, alreadyInstalled: false, asks: ToolsLauncher.maxAsks), .skip,
                       "проигнорированный вопрос не повторяется бесконечно")
        XCTAssertEqual(ToolsLauncher.plan(consent: nil, alreadyInstalled: false), .ask)
        XCTAssertEqual(ToolsLauncher.plan(consent: nil, alreadyInstalled: true), .install)
        XCTAssertEqual(ToolsLauncher.plan(consent: true, alreadyInstalled: false), .install)
        XCTAssertEqual(ToolsLauncher.plan(consent: false, alreadyInstalled: true), .skip)
    }

    // UI5
    func testPanelTabsMusicKeyViaPref() {
        XCTAssertEqual(Pref.panelTabsMusicAdded, "panelTabsMusicAdded") // имя ключа не меняется: иначе вкладка добавится второй раз
    }

    // QR
    func testWiFiPasswordMasked() {
        let payload = "WIFI:T:WPA;S:Home;P:s3cr3t;;"
        let shown = QRTools.masked(payload)
        XCTAssertFalse(shown.contains("s3cr3t"))
        XCTAssertTrue(shown.contains("S:Home"))
        XCTAssertTrue(shown.contains("P:••••"))
        XCTAssertTrue(QRTools.isWiFi(payload))
    }

    func testWiFiMaskHandlesEscapedSemicolonAndOrder() {
        let shown = QRTools.masked(#"WIFI:S:My\;Net;P:pa\;ss;T:WPA;;"#)
        XCTAssertFalse(shown.contains("pa"))
        XCTAssertTrue(shown.contains(#"S:My\;Net"#))
        XCTAssertTrue(shown.contains("T:WPA"))
    }

    func testNonWiFiUntouched() {
        XCTAssertEqual(QRTools.masked("https://example.com/?P:1"), "https://example.com/?P:1")
        XCTAssertFalse(QRTools.isWiFi("hello"))
    }
}

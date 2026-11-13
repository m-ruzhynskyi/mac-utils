import XCTest
import SwiftUI
import AppKit
import Carbon.HIToolbox
@testable import MacUtils
@testable import MUHiddenScreen
import MUCore
import MUDesign

@MainActor
final class HiddenScreenRulesTests: XCTestCase {
    func testWindowsPlural() {
        XCTAssertEqual(HiddenScreenRules.windows(0), "0 окон")
        XCTAssertEqual(HiddenScreenRules.windows(1), "1 окно")
        XCTAssertEqual(HiddenScreenRules.windows(2), "2 окна")
        XCTAssertEqual(HiddenScreenRules.windows(5), "5 окон")
        XCTAssertEqual(HiddenScreenRules.windows(11), "11 окон")
        XCTAssertEqual(HiddenScreenRules.windows(21), "21 окно")
        XCTAssertEqual(HiddenScreenRules.windows(114), "114 окон")
    }

    func testStatusLine() {
        var s = HiddenScreenState.demo
        XCTAssertEqual(HiddenScreenRules.statusLine(s), "Claude и ChatGPT скрыты")
        s.apps.removeLast()
        XCTAssertEqual(HiddenScreenRules.statusLine(s), "Claude скрыт")
        s.apps = []
        XCTAssertEqual(HiddenScreenRules.statusLine(s), "Нет программ для скрытия")
        s.isEnabled = false
        XCTAssertEqual(HiddenScreenRules.statusLine(s), "Скрытый экран выключен")
    }

    func testAppSubtitle() {
        let app = HiddenScreenApp(bundleID: "a", name: "A", windowCount: 2)
        XCTAssertEqual(HiddenScreenRules.appSubtitle(app, enabled: true), "2 окна на скрытом экране")
        XCTAssertEqual(HiddenScreenRules.appSubtitle(HiddenScreenApp(bundleID: "a", name: "A"), enabled: true), "Нет открытых окон")
        XCTAssertEqual(HiddenScreenRules.appSubtitle(app, enabled: false), "Скрытый экран выключен")
    }

    func testBadge() {
        var s = HiddenScreenState.demo
        XCTAssertEqual(HiddenScreenRules.badge(s), .hidden)
        s.hidingVerified = false
        XCTAssertEqual(HiddenScreenRules.badge(s), .visible)
        XCTAssertEqual(HiddenScreenRules.badgeText(.visible), "видно в звонке!")
        s.hidingVerified = nil
        XCTAssertEqual(HiddenScreenRules.badge(s), .unchecked)
        XCTAssertEqual(HiddenScreenRules.badgeText(.hidden), "не видно в звонке")
    }

    func testMenuEntries() {
        let menu = HiddenScreenRules.menu(.demo, toggleKey: "⌥⇧H", windowKey: "⌥Space")
        XCTAssertEqual(menu.first, .header("Скрытый экран"))
        XCTAssertTrue(menu.contains(.toggle(title: "Скрытый экран включён", on: true, key: "⌥⇧H")))
        XCTAssertTrue(menu.contains(.showWindow(title: "Спрятать окно ИИ", key: "⌥Space", enabled: true)))
        XCTAssertTrue(menu.contains(.app(bundleID: "com.openai.chat", name: "ChatGPT", on: true)))
        XCTAssertTrue(menu.contains(.addApp))
        var off = HiddenScreenState()
        off.apps = HiddenScreenState.demo.apps.map { var a = $0; a.windowCount = 0; return a }
        let offMenu = HiddenScreenRules.menu(off, toggleKey: "x", windowKey: "y")
        XCTAssertTrue(offMenu.contains(.showWindow(title: "Показать окно ИИ", key: "y", enabled: false)))
        XCTAssertTrue(offMenu.contains(.returnAll(enabled: false)))
    }

    func testStubRecordsCommands() {
        let stub = StubHiddenScreenController(.demo)
        var changes = 0
        stub.onChange = { changes += 1 }
        stub.setEnabled(false)
        stub.addApp(bundleID: "x", name: "X")
        stub.addApp(bundleID: "x", name: "X")
        stub.removeApp("com.openai.chat")
        stub.returnAllWindows()
        XCTAssertEqual(stub.state.apps.map(\.bundleID), ["com.anthropic.claudefordesktop", "x"])
        XCTAssertEqual(stub.state.totalWindows, 0)
        XCTAssertGreaterThan(changes, 0)
    }
}

final class PreCallRulesTests: XCTestCase {
    func testDock() {
        XCTAssertEqual(PreCallRules.dock(autohide: true).level, .ok)
        XCTAssertEqual(PreCallRules.dock(autohide: false).level, .attention)
        XCTAssertEqual(PreCallRules.dock(autohide: nil).level, .attention)
    }

    func testNotifications() {
        XCTAssertEqual(PreCallRules.notifications(.off(apps: [])).level, .ok)
        let on = PreCallRules.notifications(.on(apps: ["Claude"]))
        XCTAssertEqual(on.level, .attention)
        XCTAssertEqual(on.action, .openNotificationSettings)
        XCTAssertEqual(on.title, "Уведомления Claude включены")
        let unknown = PreCallRules.notifications(.unknown)
        XCTAssertEqual(unknown.action, .openNotificationSettings)
        XCTAssertEqual(unknown.level, .attention)
    }

    func testNotificationFlags() {
        XCTAssertNil(PreCallRules.notificationsEnabled(flags: nil))
        XCTAssertEqual(PreCallRules.notificationsEnabled(flags: 0), true)
        XCTAssertEqual(PreCallRules.notificationsEnabled(flags: 1 << 25), false)
    }

    func testOutputKind() {
        XCTAssertEqual(PreCallRules.outputKind(isBuiltIn: nil, dataSourceIsHeadphones: false), .unknown)
        XCTAssertEqual(PreCallRules.outputKind(isBuiltIn: false, dataSourceIsHeadphones: false), .external)
        XCTAssertEqual(PreCallRules.outputKind(isBuiltIn: true, dataSourceIsHeadphones: false), .builtInSpeakers)
        XCTAssertEqual(PreCallRules.outputKind(isBuiltIn: true, dataSourceIsHeadphones: true), .builtInHeadphones)
    }

    func testHeadphones() {
        XCTAssertEqual(PreCallRules.headphones(.builtInSpeakers).level, .attention)
        XCTAssertEqual(PreCallRules.headphones(.builtInSpeakers).title, "Нет наушников")
        XCTAssertEqual(PreCallRules.headphones(.external).level, .ok)
        XCTAssertEqual(PreCallRules.headphones(.builtInHeadphones).level, .ok)
        XCTAssertEqual(PreCallRules.headphones(.unknown).level, .attention)
    }

    func testShareHintAndAll() {
        XCTAssertEqual(PreCallRules.shareHint(mainDisplayName: "Встроенный дисплей").title, "В звонке показывайте экран «Встроенный дисплей»")
        XCTAssertEqual(PreCallRules.shareHint(mainDisplayName: nil).title, "В звонке показывайте экран основной")
        let ok = PreCallRules.all(dockAutohide: true, notifications: .off(apps: []), output: .external, mainDisplayName: "X")
        XCTAssertEqual(ok.map(\.id), ["dock", "notifications", "headphones", "share"])
        XCTAssertTrue(PreCallRules.allClear(ok))
        let bad = PreCallRules.all(dockAutohide: false, notifications: .unknown, output: .builtInSpeakers, mainDisplayName: nil)
        XCTAssertFalse(PreCallRules.allClear(bad))
    }
}

@MainActor
final class HiddenScreenShellTests: XCTestCase {
    func testDefaultKeysAndConflicts() {
        XCTAssertEqual(HotKeyAction.hiddenScreen.defaultCombo, LayoutHotKey(keyCode: kVK_ANSI_H, modifiers: optionKey | shiftKey))
        XCTAssertEqual(HotKeyAction.hiddenScreenWindow.defaultCombo, LayoutHotKey(keyCode: kVK_Space, modifiers: optionKey))
        let defaults = UserDefaults(suiteName: "hs-ui-tests-\(UUID().uuidString)")!
        let entries = HotKeyRegistry.entries(defaults: defaults)
        for action in [HotKeyAction.hiddenScreen, .hiddenScreenWindow] {
            let combo = HotKeyRegistry.combo(for: action, defaults: defaults)
            XCTAssertTrue(HotKeyRegistry.isValid(combo))
            XCTAssertTrue(HotKeyConflicts.duplicates(of: combo, excluding: .action(action), in: entries).isEmpty, "\(action) конфликтует")
        }
        XCTAssertEqual(HotKeyAction.hiddenScreen.section, .hiddenScreen)
    }

    func testSectionIsInSidebarNextToShare() {
        XCTAssertEqual(SettingsSection.hiddenScreen.group, SettingsSection.share.group)
        let sections = SettingsSection.share.group.sections
        XCTAssertEqual(sections.firstIndex(of: .hiddenScreen), sections.firstIndex(of: .share).map { $0 + 1 })
    }

    func testStripFrameSitsAboveMirror() {
        let frame = MirrorStripPanel.frame(above: CGRect(x: 100, y: 200, width: 640, height: 400))
        XCTAssertEqual(frame, CGRect(x: 100, y: 600, width: 640, height: MirrorStripPanel.height))
    }

    func testStripPanelIsHiddenFromSharing() {
        let store = HiddenScreenStore(StubHiddenScreenController())
        let panel = MirrorStripPanel(store: store)
        XCTAssertEqual(panel.sharingType, .none)
    }

    func testMenuBuilderItems() {
        let stub = StubHiddenScreenController(.demo)
        var asked = 0
        let builder = HiddenScreenMenuBuilder(controller: stub) { asked += 1 }
        let items = builder.items(toggleKey: HotKeyAction.hiddenScreen.defaultCombo, windowKey: HotKeyAction.hiddenScreenWindow.defaultCombo)
        let titles = items.map(\.title)
        XCTAssertEqual(titles.first, "СКРЫТЫЙ ЭКРАН")
        XCTAssertTrue(titles.contains("Скрытый экран включён"))
        XCTAssertTrue(titles.contains("Claude") && titles.contains("ChatGPT"))
        let toggle = items.first { $0.title == "Скрытый экран включён" }!
        XCTAssertEqual(toggle.state, .on)
        XCTAssertEqual(toggle.keyEquivalent, "h")
        XCTAssertEqual(toggle.keyEquivalentModifierMask, [.option, .shift])
        let window = items.first { $0.title.hasSuffix("окно ИИ") }!
        XCTAssertEqual(window.keyEquivalent, " ")
        _ = NSApp
        _ = NSApplication.shared.sendAction(toggle.action!, to: toggle.target, from: toggle)
        XCTAssertFalse(stub.state.isEnabled)
    }

    func testPageRendersOffscreen() {
        let page = HiddenScreenPage(controller: StubHiddenScreenController(.demo),
                                    checks: PreCallRules.all(dockAutohide: true, notifications: .on(apps: ["ChatGPT"]), output: .builtInSpeakers, mainDisplayName: "Встроенный дисплей"))
        let host = NSHostingView(rootView: page.frame(width: 760, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 760, height: 900)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 100)
    }
}

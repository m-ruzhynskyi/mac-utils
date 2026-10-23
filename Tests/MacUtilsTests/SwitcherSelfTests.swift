import AppKit
import XCTest
@testable import MacUtils
@testable import MUDesign

/// Mac Utils в своём переключателе, пока у него есть значок в Dock. Окна в тестах не показываются.
@MainActor
final class SwitcherSelfTests: XCTestCase {
    private func window(_ style: NSWindow.StyleMask = [.titled, .closable], title: String = "a.frm — Редактор",
                        panel: Bool = false) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = panel ? NSPanel(contentRect: rect, styleMask: style, backing: .buffered, defer: true)
            : NSWindow(contentRect: rect, styleMask: style, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.title = title
        return window
    }

    func testSnapshotIncludesSelfOnlyWithDockIcon() {
        let own = WindowList.ownPID
        let regular = WindowList.snapshotApps(includeSelf: true).value
        XCTAssertNotNil(regular[own], "значок в Dock — Mac Utils в списке")
        XCTAssertNotNil(regular[own]?.ownWindows, "его окна — из NSApp.windows, не через AX")
        XCTAssertNil(WindowList.snapshotApps(includeSelf: false).value[own], ".accessory — нет")
    }

    func testOwnWindowFilter() {
        XCTAssertTrue(WindowList.isSwitchable(window()), "обычное окно с заголовком")
        XCTAssertFalse(WindowList.isSwitchable(window(panel: true)), "панель (сам переключатель, «Поиск в папке»…)")
        XCTAssertFalse(WindowList.isSwitchable(window([.borderless])), "оверлей без рамки")
        XCTAssertFalse(WindowList.isSwitchable(window(title: "")), "без заголовка")
        let floating = window()
        floating.level = .floating
        XCTAssertFalse(WindowList.isSwitchable(floating), "не на обычном уровне")
        let clickThrough = window()
        clickThrough.ignoresMouseEvents = true
        XCTAssertFalse(WindowList.isSwitchable(clickThrough), "прозрачный для мыши оверлей")
        // Не показанное и не свёрнутое окно — не в списке.
        XCTAssertTrue(WindowList.ownWindows([window(), window(panel: true)]).isEmpty)
    }

    func testOwnBackgroundWindows() {
        let editor = WindowList.OwnWindow(number: 11, title: "a.frm", isMinimized: false, isVisible: true)
        let minimized = WindowList.OwnWindow(number: 12, title: "b.frm", isMinimized: true, isVisible: false)
        let viewer = WindowList.OwnWindow(number: 13, title: "Трансляция", isMinimized: false, isVisible: true)
        // Видимые берутся из CG по порядку на экране; после них — свёрнутые.
        XCTAssertEqual(WindowList.ownBackground([editor, minimized, viewer], appHidden: false, used: [11, 13]), [minimized])
        // Mac Utils скрыт — все его окна после видимых окон других программ.
        XCTAssertEqual(WindowList.ownBackground([editor, minimized, viewer], appHidden: true, used: []), [editor, minimized, viewer])
        XCTAssertEqual(WindowList.ownBackground([minimized], appHidden: false, used: [12]), [])
    }

    func testOwnItemsDropWhenPolicyReturnsToAccessory() throws {
        let own = NSRunningApplication.current
        let other = try XCTUnwrap(NSWorkspace.shared.runningApplications.first { $0.processIdentifier != own.processIdentifier })
        func item(_ app: NSRunningApplication, _ id: String) -> SwitcherItem {
            SwitcherItem(id: id, app: app, appName: "x", title: id, icon: NSImage(), windowID: nil, axWindow: nil, isMinimized: false)
        }
        let items = [item(own, "w1"), item(other, "w2")]
        XCTAssertEqual(AppSwitcher.withoutOwnIfAccessory(items, policy: .regular).map(\.id), ["w1", "w2"])
        XCTAssertEqual(AppSwitcher.withoutOwnIfAccessory(items, policy: .accessory).map(\.id), ["w2"])
    }
}

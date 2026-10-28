import AppKit
@testable import MUDesign

// Стенд для WindowSnapStandTests: своё окно с объединённой панелью инструментов (как Finder, Safari, Заметки на
// macOS 27) в отдельном процессе. Печатает pid, рамку окна в координатах AX и высоту полосы над содержимым — только
// числа — и живёт, пока открыт stdin (тест закрыл трубу или упал — стенд выходит сам).

final class Toolbar: NSObject, NSToolbarDelegate {
    private let ids: [NSToolbarItem.Identifier] = [.init("back"), .flexibleSpace, .init("share")]
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        item.label = id.rawValue
        return item
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Toolbar()
let visible = NSScreen.screens[0].visibleFrame
let frame = NSRect(x: visible.minX + 200, y: visible.maxY - 520, width: 640, height: 460)
let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
// Каждый запуск — с той же рамки: без восстановления окон с прошлого запуска.
window.isRestorable = false
window.title = "Стенд"
let toolbar = NSToolbar(identifier: "stand")
toolbar.delegate = delegate
window.toolbar = toolbar
window.toolbarStyle = .unified
window.isReleasedWhenClosed = false
// Поверх обычных окон: нажатие стенда не должно попасть в чужое окно (такие окна раскладка тоже берёт).
window.level = .floating
window.makeKeyAndOrderFront(nil)
window.setFrame(frame, display: true)
window.orderFrontRegardless()
app.activate(ignoringOtherApps: true)

Thread.detachNewThread {
    while readLine() != nil {}
    exit(0)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
    let height = NSScreen.screens[0].frame.height
    let shown = window.frame
    print("ready pid=\(ProcessInfo.processInfo.processIdentifier) x=\(shown.minX) y=\(height - shown.maxY) w=\(shown.width) h=\(shown.height) bar=\(shown.height - window.contentLayoutRect.maxY)")
    fflush(stdout)
}
app.run()

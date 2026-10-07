import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Сочетание пункта меню в виде «⌃⌥⇧⌘K» (без UI — для тестов).
enum ShortcutFormat {
    /// kAXMenuItemCmdModifiers: 1 — ⇧, 2 — ⌥, 4 — ⌃, 8 — без ⌘.
    static func modifiers(_ mask: Int) -> String {
        var result = ""
        if mask & 4 != 0 { result += "⌃" }
        if mask & 2 != 0 { result += "⌥" }
        if mask & 1 != 0 { result += "⇧" }
        if mask & 8 == 0 { result += "⌘" }
        return result
    }

    /// Клавиша: символ из меню или значок для служебных (kAXMenuItemCmdGlyph).
    static func key(char: String?, glyph: Int?) -> String? {
        if let char, !char.isEmpty, char != "\u{0}" {
            switch char {
            case " ": return "Пробел"
            case "\u{1B}": return "Esc"
            case "\r": return "↩"
            case "\t": return "⇥"
            case "\u{7F}", "\u{8}": return "⌫"
            default: return char.uppercased()
            }
        }
        guard let glyph else { return nil }
        let glyphs: [Int: String] = [
            0x02: "⇥", 0x04: "⌅", 0x0B: "↩", 0x17: "⌫", 0x1B: "Esc", 0x09: "Пробел",
            0x64: "←", 0x65: "→", 0x68: "↑", 0x6A: "↓", 0x0A: "⌦",
            0x6F: "F1", 0x70: "F2", 0x71: "F3", 0x72: "F4", 0x73: "F5", 0x74: "F6",
            0x75: "F7", 0x76: "F8", 0x77: "F9", 0x78: "F10", 0x79: "F11", 0x7A: "F12",
            0x62: "⇞", 0x6B: "⇟", 0x66: "↖", 0x67: "↘",
        ]
        return glyphs[glyph]
    }
}

struct CheatItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let shortcut: String
}

struct CheatGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [CheatItem]
}

/// «Шпаргалка»: удерживайте ⌘ — появятся все сочетания клавиш активного
/// приложения (из его меню) и Mac Utils. Отпустите ⌘ — исчезнет.
@MainActor
final class CheatSheet: ObservableObject {
    static let shared = CheatSheet()

    @Published private(set) var appName = ""
    @Published private(set) var appIcon: NSImage?
    @Published private(set) var groups: [CheatGroup] = []
    @Published private(set) var loading = false
    @Published private(set) var isRunning = false

    private var tap: EventTap?
    private var holdTimer: Timer?
    private var panel: NSPanel?

    func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.cheatSheet) && Permissions.accessibility
        if enabled {
            if tap == nil {
                tap = EventTap(types: [.flagsChanged, .keyDown, .leftMouseDown, .scrollWheel]) { [weak self] type, event in
                    self?.handle(type: type, event: event)
                    return true
                }
            }
            isRunning = tap?.start() ?? false
        } else {
            tap?.stop()
            tap = nil
            cancel()
            isRunning = false
        }
    }

    // MARK: - Удержание ⌘

    private func handle(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else {
            // Любая клавиша или клик — это не «просто держу ⌘».
            cancel()
            return
        }
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
        let flags = event.flags.intersection(relevant)
        if flags == .maskCommand {
            guard holdTimer == nil, panel?.isVisible != true else { return }
            let delay = max(0.4, UserDefaults.standard.double(forKey: Pref.cheatSheetDelay))
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { CheatSheet.shared.show() }
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        } else {
            cancel()
        }
    }

    private func cancel() {
        holdTimer?.invalidate()
        holdTimer = nil
        panel?.orderOut(nil)
    }

    // MARK: - Показ

    func show() {
        holdTimer = nil
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        appName = app.localizedName ?? ""
        appIcon = app.icon
        loading = true
        groups = []
        presentPanel()
        let pid = app.processIdentifier
        let own = pid == ProcessInfo.processInfo.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let menus = own ? [] : Self.readMenus(pid: pid)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let sheet = CheatSheet.shared
                    sheet.groups = menus + [Self.macUtilsGroup()]
                    sheet.loading = false
                    sheet.resizePanel()
                }
            }
        }
    }

    private func presentPanel() {
        let panel = self.panel ?? makePanel()
        resizePanel()
        panel.orderFrontRegardless()
    }

    private func resizePanel() {
        guard let panel, let host = panel.contentView as? NSHostingView<CheatSheetView>,
              let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        _ = host
        let width = min(visible.width - 80, 1100)
        let height = min(visible.height - 120, 640)
        panel.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height),
                       display: true)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: CheatSheetView(sheet: self))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    // MARK: - Меню приложения

    nonisolated private static func readMenus(pid: pid_t) -> [CheatGroup] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return [] }
        let menus: [AXUIElement] = attribute(bar, kAXChildrenAttribute) ?? []
        var groups: [CheatGroup] = []
        // Первое меню — Apple, его пропускаем.
        for menu in menus.dropFirst() {
            let title: String = attribute(menu, kAXTitleAttribute) ?? ""
            var items: [CheatItem] = []
            collect(menu, into: &items, depth: 0)
            if !items.isEmpty { groups.append(CheatGroup(title: title, items: items)) }
        }
        return groups
    }

    nonisolated private static func collect(_ element: AXUIElement, into items: inout [CheatItem], depth: Int) {
        guard depth < 4, items.count < 400 else { return }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            let role: String = attribute(child, kAXRoleAttribute) ?? ""
            if role == kAXMenuItemRole as String {
                let title: String = attribute(child, kAXTitleAttribute) ?? ""
                let char: String? = attribute(child, kAXMenuItemCmdCharAttribute)
                let glyph = (attribute(child, kAXMenuItemCmdGlyphAttribute) as NSNumber?)?.intValue
                let mods = (attribute(child, kAXMenuItemCmdModifiersAttribute) as NSNumber?)?.intValue ?? 0
                if !title.isEmpty, let key = ShortcutFormat.key(char: char, glyph: glyph) {
                    items.append(CheatItem(title: title, shortcut: ShortcutFormat.modifiers(mods) + key))
                }
            }
            collect(child, into: &items, depth: depth + 1)
        }
    }

    nonisolated private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func macUtilsGroup() -> CheatGroup {
        let layout = LayoutHotKey.current.title
        return CheatGroup(title: "Mac Utils", items: [
            CheatItem(title: "Инструменты", shortcut: "⌃⌥⌘T"),
            CheatItem(title: "Настройки", shortcut: "⌃⌥⌘,"),
            CheatItem(title: "Снимок экрана", shortcut: "⌘⇧X"),
            CheatItem(title: "Распознать текст", shortcut: "⌘⇧⌥X"),
            CheatItem(title: "Полка", shortcut: "⌃⌥D"),
            CheatItem(title: "Громкость приложений", shortcut: "⌃⌥V"),
            CheatItem(title: "Исправить раскладку", shortcut: layout),
            CheatItem(title: "Окно влево / вправо", shortcut: "⌃⌥← / →"),
            CheatItem(title: "На весь экран", shortcut: "⌃⌥↩"),
        ])
    }
}

// MARK: - Вид

struct CheatSheetView: View {
    @ObservedObject var sheet: CheatSheet

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let icon = sheet.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                }
                Text(sheet.appName).font(.title3.weight(.semibold))
                Spacer()
                Text("Отпустите ⌘, чтобы закрыть").font(.caption).foregroundStyle(.secondary)
            }
            if sheet.loading {
                ProgressView().frame(maxWidth: .infinity)
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(sheet.groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            ForEach(group.items) { item in
                                HStack(spacing: 8) {
                                    Text(item.title).font(.callout).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 6)
                                    Text(item.shortcut).font(.callout.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(4)
    }
}

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI
import MUCore
import MUDesign

/// «Шпаргалка»: удерживайте ⌘ — появятся все сочетания клавиш активного
/// приложения (из его меню) и Mac Utils. Отпустите ⌘ — исчезнет.
@MainActor
package final class CheatSheet: ObservableObject {
    package static let shared = CheatSheet()

    @Published package private(set) var appName = ""
    @Published package private(set) var appIcon: NSImage?
    @Published package private(set) var groups: [CheatGroup] = []
    @Published package private(set) var loading = false
    @Published package private(set) var isRunning = false

    private var tap: EventTap?
    private var holdTimer: Timer?
    private var panel: NSPanel?

    package func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.cheatSheet) && Permissions.accessibility
        if enabled {
            if tap == nil {
                // Только слушаем: события не поглощаются, и ввод системы не ждёт главный поток Mac Utils.
                tap = EventTap(types: [.flagsChanged, .keyDown, .leftMouseDown, .scrollWheel], listenOnly: true) { [weak self] type, event in
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

    /// ⌘ сейчас зажата (чтобы повторное нажатие закрывало закреплённую шпаргалку).
    private var commandDown = false

    private var isVisible: Bool { panel?.isVisible == true }

    private var sticky: Bool { UserDefaults.standard.bool(forKey: Pref.cheatSheetSticky) }

    /// Курсор над шпаргалкой: прокрутка и клики внутри её не закрывают.
    private var mouseInside: Bool {
        guard let panel, panel.isVisible else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // В виртуальной машине и удалённом рабочем столе подсказки по ⌘ не нужны (там своя система сочетаний).
        if AppExclusions.shared.isFrontExcluded {
            if isVisible || commandDown { cancel() }
            return
        }
        switch type {
        case .scrollWheel:
            // Прокрутка над шпаргалкой листает её; в другом месте — значит, пользователь занят другим.
            if mouseInside { return }
            if !isVisible { cancelTimer() } else if !sticky { cancel() }
            return
        case .leftMouseDown:
            if mouseInside { return }
            cancel()
            return
        case .keyDown:
            // Любая клавиша — это не «просто держу ⌘».
            cancel()
            return
        default:
            break
        }
        let relevant: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
        let flags = event.flags.intersection(relevant)
        if flags == .maskCommand {
            defer { commandDown = true }
            guard !commandDown else { return }
            if isVisible {
                // Закреплённая шпаргалка: повторное нажатие ⌘ закрывает.
                if sticky { cancel() }
                return
            }
            guard holdTimer == nil else { return }
            let delay = max(0.4, UserDefaults.standard.double(forKey: Pref.cheatSheetDelay))
            let timer = Timer(timeInterval: delay, repeats: false) { _ in
                MainActor.assumeIsolated { CheatSheet.shared.show() }
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        } else {
            commandDown = false
            cancelTimer()
            // Отпустили ⌘: обычная шпаргалка закрывается, закреплённая остаётся.
            if !(sticky && isVisible) { cancel() }
        }
    }

    private func cancelTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func cancel() {
        cancelTimer()
        panel?.orderOut(nil)
    }

    // MARK: - Показ

    package func show() {
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
                    // Окно плеера впереди — его клавиши (их нет в меню: они без ⌘).
                    let router = AppRouter.shared
                    sheet.groups = (own ? router.cheatFrontGroups() : []) + menus + [router.cheatMacUtilsGroup()]
                    sheet.loading = false
                    sheet.resizePanel()
                }
            }
        }
    }

    private func presentPanel() {
        let panel = self.panel ?? makePanel()
        resizePanel()
        panel.orderFrontRegardlessOnScreen()
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
        // Колесо мыши над шпаргалкой листает список.
        panel.ignoresMouseEvents = false
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
}

// MARK: - Вид

package struct CheatSheetView: View {
    @ObservedObject package var sheet: CheatSheet

    package var body: some View {
        CheatSheetContent(appName: sheet.appName, appIcon: sheet.appIcon, loading: sheet.loading, groups: sheet.groups,
                          sticky: UserDefaults.standard.bool(forKey: Pref.cheatSheetSticky))
    }
}

/// Шпаргалка-оверлей (Graphite: `panel`, обводка `line`, радиус 20; заголовки групп — `GroupLabel`, сочетания — кейкапы).
/// Без модели — для снимков интерфейса.
package struct CheatSheetContent: View {
    package let appName: String
    package var appIcon: NSImage?
    package var loading = false
    package let groups: [CheatGroup]
    package var sticky = false

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 22, alignment: .top)]

    package var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: 10) {
                if let appIcon {
                    Image(nsImage: appIcon).resizable().frame(width: 28, height: 28)
                }
                Text(appName).font(DS.Font.headline).foregroundStyle(.dsText)
                Spacer()
                Text(sticky ? "Нажмите ⌘ или Esc, чтобы закрыть · колесо мыши — листать"
                            : "Отпустите ⌘, чтобы закрыть · колесо мыши — листать")
                    .font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            }
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            GroupLabel(group.title)
                            ForEach(group.items) { item in
                                HStack(spacing: DS.Space.s) {
                                    Text(item.title).font(DS.Font.manrope(13, .semibold, relativeTo: .callout))
                                        .foregroundStyle(.dsText).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 6)
                                    Keycap([item.shortcut], compact: true)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(DS.Space.xl)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .padding(4)
    }
}

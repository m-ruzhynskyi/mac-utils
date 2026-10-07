import AppKit
import SwiftUI

/// Окно «Инструменты»: удаление программ, монитор системы, диспетчер задач
/// и очистка диска — вкладками в одном окне (⌃⌥⌘T).
@MainActor
final class ToolsWindowController: NSObject, NSWindowDelegate {
    static let shared = ToolsWindowController()

    enum Tab: String, CaseIterable, Identifiable {
        case uninstaller, monitor, tasks, cleanup
        var id: String { rawValue }

        var title: String {
            switch self {
            case .uninstaller: return "Удаление программ"
            case .monitor: return "Монитор системы"
            case .tasks: return "Диспетчер задач"
            case .cleanup: return "Очистка диска"
            }
        }

        /// Для панели из строки меню.
        var shortTitle: String {
            switch self {
            case .uninstaller: return "Программы"
            case .monitor: return "Монитор"
            case .tasks: return "Задачи"
            case .cleanup: return "Очистка"
            }
        }

        var symbol: String {
            switch self {
            case .uninstaller: return "trash"
            case .monitor: return "gauge.with.dots.needle.67percent"
            case .tasks: return "list.bullet.rectangle"
            case .cleanup: return "externaldrive.badge.minus"
            }
        }
    }

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ tab: Tab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: Pref.toolsTab) }
        // Есть значок в строке меню — инструменты выпадают из него панелью со вкладками.
        if AppStatusItem.shared.showTools() { return }
        let window = self.window ?? make()
        if !window.isVisible { FocusReturn.remember() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = ToolsWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Инструменты"
        window.contentViewController = NSHostingController(rootView: ToolsView())
        window.setContentSize(NSSize(width: 1000, height: 660))
        window.minSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("MacUtilsTools")
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if !SettingsWindowController.shared.isVisible { FocusReturn.restore() }
    }
}

/// Заголовок всегда «Инструменты»: вкладки SwiftUI иначе подставляют свой.
final class ToolsWindow: NSWindow {
    override var title: String {
        get { super.title }
        set { super.title = "Инструменты" }
    }
}

struct ToolsView: View {
    @AppStorage(Pref.toolsTab) private var tab = ToolsWindowController.Tab.uninstaller.rawValue
    /// В панели из строки меню — шапка с настройками и выходом.
    var inPopover = false

    var body: some View {
        if inPopover {
            VStack(spacing: 0) {
                header
                compactTabs
                Divider().padding(.top, 8)
                compactContent
            }
        } else {
            tabs
        }
    }

    /// Панель из строки меню: короткие вкладки со значками.
    private var compactTabs: some View {
        Picker("Вкладка", selection: $tab) {
            ForEach(ToolsWindowController.Tab.allCases) { item in
                Label(item.shortTitle, systemImage: item.symbol).tag(item.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var compactContent: some View {
        switch ToolsWindowController.Tab(rawValue: tab) ?? .uninstaller {
        case .uninstaller: UninstallerPage(compact: true)
        case .monitor: SystemMonitorView(model: .shared, compact: true)
        case .tasks: TaskManagerView(model: .shared, compact: true)
        case .cleanup: DiskCleanupView(model: .shared)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(Color.accentColor)
            Text("Mac Utils").font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                AppStatusItem.shared.closeTools()
                SettingsWindowController.shared.show()
            } label: {
                Label("Настройки", systemImage: "gearshape")
            }
            .help("Настройки Mac Utils (⌃⌥⌘,)")
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Выйти", systemImage: "power")
            }
            .help("Выйти из Mac Utils")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            UninstallerPage()
                .tabItem { Label(ToolsWindowController.Tab.uninstaller.title, systemImage: ToolsWindowController.Tab.uninstaller.symbol) }
                .tag(ToolsWindowController.Tab.uninstaller.rawValue)
            SystemMonitorView(model: .shared)
                .tabItem { Label(ToolsWindowController.Tab.monitor.title, systemImage: ToolsWindowController.Tab.monitor.symbol) }
                .tag(ToolsWindowController.Tab.monitor.rawValue)
            TaskManagerView(model: .shared)
                .tabItem { Label(ToolsWindowController.Tab.tasks.title, systemImage: ToolsWindowController.Tab.tasks.symbol) }
                .tag(ToolsWindowController.Tab.tasks.rawValue)
            DiskCleanupView(model: .shared)
                .tabItem { Label(ToolsWindowController.Tab.cleanup.title, systemImage: ToolsWindowController.Tab.cleanup.symbol) }
                .tag(ToolsWindowController.Tab.cleanup.rawValue)
        }
        .padding(.top, 6)
        .frame(minWidth: 740, minHeight: 480)
    }
}

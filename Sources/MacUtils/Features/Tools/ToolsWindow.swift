import AppKit
import SwiftUI

/// Окно «Инструменты»: удаление программ, монитор системы, диспетчер задач
/// и очистка диска — вкладками в одном окне (⌃⌥⌘T).
@MainActor
final class ToolsWindowController: NSObject, NSWindowDelegate {
    static let shared = ToolsWindowController()

    enum Tab: String, CaseIterable, Identifiable {
        case uninstaller, monitor, tasks, cleanup, shots
        var id: String { rawValue }

        var title: String {
            switch self {
            case .uninstaller: return "Удаление программ"
            case .monitor: return "Монитор системы"
            case .tasks: return "Диспетчер задач"
            case .cleanup: return "Очистка диска"
            case .shots: return "Мои снимки"
            }
        }

        /// Для панели из строки меню.
        var shortTitle: String {
            switch self {
            case .uninstaller: return "Программы"
            case .monitor: return "Монитор"
            case .tasks: return "Задачи"
            case .cleanup: return "Очистка"
            case .shots: return "Снимки"
            }
        }

        /// Вкладки, которые показываются в панели 🔧 (хотя бы одна).
        static func visible(hidden: String) -> [Tab] {
            let hiddenSet = Set(hidden.split(separator: ",").map(String.init))
            let tabs = allCases.filter { !hiddenSet.contains($0.rawValue) }
            return tabs.isEmpty ? allCases : tabs
        }

        var symbol: String {
            switch self {
            case .uninstaller: return "trash"
            case .monitor: return "gauge.with.dots.needle.67percent"
            case .tasks: return "list.bullet.rectangle"
            case .cleanup: return "externaldrive.badge.minus"
            case .shots: return "photo.on.rectangle.angled"
            }
        }
    }

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ tab: Tab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: Pref.toolsTab) }
        // Есть значок в строке меню — инструменты выпадают из него панелью со вкладками.
        if AppStatusItem.shared.showTools() { return }
        showWindow()
    }

    /// Полное окно 1000×660 — даже когда есть значок в строке меню (⌥-клик по значку в строке меню).
    func showWindow() {
        AppStatusItem.shared.closeTools()
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
        let controller = NSHostingController(rootView: ToolsView())
        // Размер задаёт окно (и его minSize), а не содержимое: содержимое всегда вписывается в окно, в том числе при ресайзе.
        controller.sizingOptions = []
        window.contentViewController = controller
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
    /// Выбранная вкладка панели: `SettingsSection.rawValue`. Окно «Инструменты» хранит здесь же свою.
    @AppStorage(Pref.toolsTab) private var tab = ""
    @AppStorage(Pref.toolsPanelTabs) private var panelTabs = PanelTabs.defaultValue
    @AppStorage(Pref.warmScreen) private var warmEnabled = false
    @AppStorage(Pref.warmMode) private var warmMode = "schedule"
    @AppStorage(Pref.warmManualOn) private var warmManualOn = false
    @ObservedObject private var updater = Updater.shared
    @Namespace private var tabNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var warmOn: Bool { warmEnabled && warmMode == "manual" && warmManualOn }

    private var visibleTabs: [SettingsSection] { PanelTabs.sections(panelTabs) }

    /// Выбранный раздел; сохранённая «Главная» (её больше нет) и скрытая вкладка — первая вкладка.
    private var currentSection: SettingsSection {
        SettingsSection(rawValue: tab).flatMap { visibleTabs.contains($0) ? $0 : nil } ?? visibleTabs[0]
    }

    /// В панели из строки меню — шапка, вкладки, нижняя панель.
    var inPopover = false

    var body: some View {
        // Разрешения на вкладках панели и окна обновляются, только пока они на экране.
        main.onScreen { PermissionsModel.shared.viewerChanged($0) }
    }

    @ViewBuilder private var main: some View {
        if inPopover {
            VStack(spacing: DS.Space.m) {
                header
                tabBar
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !PanelSectionView.usesPage(currentSection) {
                    footer(currentSection)
                }
            }
            .padding(.top, DS.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.dsPanel.ignoresSafeArea())
            .tint(.dsAccText)
        } else {
            windowBody
        }
    }

    // MARK: Окно «Инструменты»

    /// Вкладки окна: как в панели; инструменты (программы, монитор, задачи, снимки, очистка) и плеер — всегда,
    /// даже если в панели их скрыли (вкладка «Плеер» в панели по умолчанию выключена).
    private var windowTabs: [SettingsSection] {
        let tools = ToolsWindowController.Tab.allCases.compactMap { SettingsSection(rawValue: $0.rawValue) } + [.videoPlayer]
        return visibleTabs + tools.filter { !visibleTabs.contains($0) }
    }

    /// Выбранная вкладка окна; сохранённая «Главная» и вкладки не из окна — первая вкладка.
    private var windowSection: SettingsSection {
        SettingsSection(rawValue: tab).flatMap { windowTabs.contains($0) ? $0 : nil } ?? windowTabs[0]
    }

    /// Окно: тот же ряд вкладок (со значком и подписью у каждой) и без кнопок шапки (они — в поповере).
    private var windowBody: some View {
        let section = windowSection
        return VStack(spacing: DS.Space.m) {
            tabStrip(tabs: windowTabs.map { ($0.rawValue, $0.panelTitle, $0.symbol, $0.title) }, selected: section.rawValue,
                     showsAllLabels: true)
            Group {
                if PanelSectionView.usesPage(section) {
                    // Инструменты и разделы со своей страницей — в полном виде, как в окне раньше.
                    SettingsSectionPage(section: section)
                } else {
                    PanelSectionView(section: section)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                }
            }
            .id(section)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !PanelSectionView.usesPage(section) {
                footer(section)
            }
        }
        .padding(.top, DS.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        // Фон — на всё окно, включая полосу под заголовком.
        .background(Color.dsBg.ignoresSafeArea())
        .tint(.dsAccText)
    }

    // MARK: Шапка

    private var versionNote: String {
        switch updater.state {
        case .upToDate: return "\(updater.displayVersion) · актуальная версия"
        case .available(let version): return "\(updater.displayVersion) · доступна версия \(version)"
        default: return updater.displayVersion
        }
    }

    private var header: some View {
        HStack(spacing: DS.Space.m) {
            AppMark(size: 22)
                .frame(width: 38, height: 38)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            VStack(alignment: .leading, spacing: 0) {
                Text("Mac Utils").font(DS.Font.headline).tracking(DS.Font.tracking(-0.01, size: 17)).foregroundStyle(.dsText)
                Text(versionNote).font(DS.Font.rowSub).foregroundStyle(.dsMute).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s)
            IconButton("Тёплый экран: включить или выключить вручную", systemImage: warmOn ? "sun.horizon.fill" : "sun.horizon",
                       active: warmOn) {
                WarmScreen.shared.toggleManual()
            }
            IconButton("Настройки Mac Utils (\(HotKeyRegistry.combo(for: .settings).title))", systemImage: "gearshape") {
                AppStatusItem.shared.closeTools()
                SettingsWindowController.shared.show()
            }
            IconButton("Выйти из Mac Utils", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, DS.Space.l)
    }

    // MARK: Вкладки

    /// Ряд вкладок поповера: вкладки панели.
    private var tabBar: some View {
        tabStrip(tabs: visibleTabs.map { ($0.rawValue, $0.panelTitle, $0.symbol, $0.title) },
                 selected: currentSection.rawValue, showsAllLabels: false)
    }

    /// Ряд вкладок как в концепте: выбранная — лайм со значком и подписью, остальные — значки `mute` (подпись — в подсказке
    /// и для VoiceOver; в окне — у всех, места хватает). Не помещаются — ряд прокручивается вбок.
    private func tabStrip(tabs: [(id: String, title: String, symbol: String, accessibility: String)], selected: String,
                          showsAllLabels: Bool) -> some View {
        GeometryReader { geometry in
            // Подписи у всех (окно) — только если весь ряд помещается; иначе — как в поповере: подпись у выбранной,
            // ряд прокручивается вбок.
            ViewThatFits(in: .horizontal) {
                if showsAllLabels {
                    tabRow(tabs, selected: selected, labels: true)
                        .frame(minWidth: geometry.size.width)
                }
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        tabRow(tabs, selected: selected, labels: false)
                            .frame(minWidth: geometry.size.width)
                    }
                    .scrollIndicators(.never)
                    .onAppear { proxy.scrollTo(selected) }
                    .onChange(of: selected) { _, new in
                        withAnimation(DS.Motion.animation(DS.Motion.quick, reduceMotion: reduceMotion)) { proxy.scrollTo(new) }
                    }
                }
            }
        }
        .frame(height: 46)
        .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        .padding(.horizontal, DS.Space.l)
    }

    private func tabRow(_ tabs: [(id: String, title: String, symbol: String, accessibility: String)], selected: String,
                        labels: Bool) -> some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(tabs, id: \.id) { item in
                tabButton(id: item.id, title: item.title, symbol: item.symbol, selected: item.id == selected,
                          showsLabel: labels, accessibility: item.accessibility)
            }
        }
        .padding(DS.Space.xs)
    }

    private func tabButton(id: String, title: String, symbol: String, selected: Bool, showsLabel: Bool = false,
                           accessibility: String? = nil) -> some View {
        Button {
            withAnimation(DS.Motion.animation(DS.Motion.toggle, reduceMotion: reduceMotion)) { tab = id }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                if selected || showsLabel {
                    Text(title).font(DS.Font.manrope(13, .bold, relativeTo: .callout)).lineLimit(1).fixedSize()
                }
            }
            .foregroundStyle(selected ? Color.dsAccInk : Color.dsMute)
            .frame(height: 38)
            .frame(minWidth: selected ? nil : 34, maxWidth: selected ? nil : .infinity)
            .padding(.horizontal, selected || showsLabel ? DS.Space.m : 0)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(Color.dsAcc)
                        .matchedGeometryEffect(id: "selectedTab", in: tabNamespace)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .id(id)
        .help(accessibility ?? title)
        .accessibilityLabel(accessibility ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Содержимое и нижняя панель

    @ViewBuilder
    private var content: some View {
        // Содержимое вкладки сменяется мягким переходом, без рывка (без анимации при «Уменьшить движение»).
        ZStack {
            PanelSectionView(section: currentSection)
                .id(currentSection.rawValue)
            .transition(.opacity)
        }
        .animation(DS.Motion.animation(DS.Motion.standard, reduceMotion: reduceMotion), value: tab)
    }

    private func footer(_ section: SettingsSection) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.dsLine).frame(height: 1)
            HStack {
                Button {
                    AppStatusItem.shared.closeTools()
                    SettingsWindowController.shared.show(section: section)
                } label: {
                    Label("Все настройки раздела", systemImage: "gearshape")
                        .font(DS.Font.bodyStrong)
                        .foregroundStyle(.dsAccText)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, DS.Space.l)
            .frame(height: 40)
        }
    }
}

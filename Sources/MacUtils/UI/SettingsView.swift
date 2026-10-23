import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Модель разрешений

@MainActor
final class PermissionsModel: NSObject, ObservableObject {
    static let shared = PermissionsModel()

    @Published private(set) var accessibility = Permissions.accessibility
    @Published private(set) var screenRecording = Permissions.screenRecording
    @Published private(set) var microphone = Permissions.microphone
    @Published private(set) var fullDiskAccess = Permissions.fullDiskAccess
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Опрос раз в 1,5 с — только пока экран с разрешениями виден и чего-то не хватает, или пока ждём выдачи после
    /// «Открыть настройки». В остальное время — при возврате в приложение и при открытии настроек (опрос держал ~4 % ядра).
    private var timer: Timer?
    private(set) var viewers = ViewerCount()
    /// До какого момента ждём выдачи разрешения после «Открыть настройки» (Системные настройки закрывают наше окно).
    private var waitingUntil: Date?
    static let pollInterval: TimeInterval = 1.5
    nonisolated static let waitForGrant: TimeInterval = 180

    var isPolling: Bool { timer != nil }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PermissionsModel.shared.refresh() }
        }
    }

    /// Вид с разрешениями появился на экране или ушёл с него (`onScreen`).
    func viewerChanged(_ shown: Bool) {
        viewers.update(shown)
        if shown { refresh() } else { updatePolling() }
    }

    /// Пользователь ушёл выдавать разрешение в Системные настройки: опрашиваем, пока оно не появится (не дольше 3 минут).
    func awaitGrant(for seconds: TimeInterval = waitForGrant) {
        waitingUntil = Date().addingTimeInterval(seconds)
        updatePolling()
    }

    /// Нужен ли опрос: что-то не выдано и его ждут на экране или после «Открыть настройки».
    static func pollNeeded(missing: Bool, onScreen: Bool, waiting: Bool) -> Bool {
        missing && (onScreen || waiting)
    }

    /// Не выдано то, что ловим опросом. Микрофон — по ответу на запрос и при возврате в приложение (проверка ~8 мс).
    var missing: Bool {
        !accessibility || !screenRecording || fullDiskAccess == false
    }

    private func updatePolling() {
        if let waitingUntil, waitingUntil < Date() { self.waitingUntil = nil }
        let needed = Self.pollNeeded(missing: missing, onScreen: viewers.any, waiting: waitingUntil != nil)
        if needed, timer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// Опрос — только того, чего не хватает: выданное перепроверяется при возврате в приложение и показе настроек.
    @objc private func tick() {
        if !accessibility, Permissions.accessibility { accessibility = true }
        if !screenRecording, Permissions.screenRecording { screenRecording = true }
        if fullDiskAccess == false, Permissions.fullDiskAccess == true { fullDiskAccess = true }
        if !missing { waitingUntil = nil }
        updatePolling()
    }

    /// `includingLogin` — ещё и «Открывать при входе» (запрос к службе входа дорогой; меняется из наших настроек или
    /// Системных, после чего мы снова становимся активными).
    func refresh(includingLogin: Bool = true) {
        let ax = Permissions.accessibility
        let screen = Permissions.screenRecording
        if ax != accessibility { accessibility = ax }
        if screen != screenRecording { screenRecording = screen }
        let mic = Permissions.microphone
        if mic != microphone { microphone = mic }
        let disk = Permissions.fullDiskAccess
        if disk != fullDiskAccess { fullDiskAccess = disk }
        if includingLogin {
            let login = SMAppService.mainApp.status == .enabled
            if login != launchAtLogin { launchAtLogin = login }
        }
        // Всё выдано — ждать больше нечего.
        if !missing { waitingUntil = nil }
        updatePolling()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Feedback.beep()
        }
        refresh()
    }
}

enum SettingsSearch {
    /// Каждое слово запроса должно встречаться в тексте (без учёта регистра, ё = е).
    static func matches(_ text: String, query: String) -> Bool {
        let words = normalize(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = normalize(text)
        return words.allSatisfy { haystack.contains($0) }
    }

    static func filter(_ sections: [SettingsSection], query: String) -> [SettingsSection] {
        sections.filter { matches($0.searchText, query: query) }
    }

    /// Порядок показа в боковой панели: по группам (`SettingsGroup.sections`), а не по `allCases`.
    static func displayOrder(_ sections: [SettingsSection]) -> [SettingsSection] {
        SettingsGroup.allCases.flatMap(\.sections).filter(sections.contains)
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}

/// Окно настроек Graphite (`.audit/design-spec-v2.md` §3): боковая панель 250 pt на `side` с группами и поиском,
/// справа — страница раздела на `bg`. Без `NavigationSplitView`: ширина и вид боковой панели под полным контролем.
struct SettingsView: View {
    @State private var selection: SettingsSection
    @State private var query = ""

    init(selection: SettingsSection = .general) {
        _selection = State(initialValue: selection)
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection, query: $query)
                .frame(width: DS.Size.sidebar)
            Rectangle().fill(Color.dsLine).frame(width: 1).accessibilityHidden(true)
            SettingsSectionPage(section: selection)
                // Страницы, ещё не переведённые на Graphite (Form), — на общем фоне `bg`.
                .scrollContentBackground(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.dsBg)
        }
        .background(Color.dsBg)
        // Системные контролы прежних страниц — в акценте Graphite (`accText`: текст кнопок ≥ 4,5:1 в обеих темах).
        .tint(.dsAccText)
        .onChange(of: query) { _, newValue in
            // Единственный найденный раздел сразу открывается.
            let now = SettingsSearch.filter(SettingsSection.allCases, query: newValue)
            if now.count == 1 { selection = now[0] }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsSection)) { note in
            if let section = note.object as? SettingsSection { selection = section }
        }
    }
}

/// Боковая панель: поиск, группы капсом, разделы (значок + название). Выбранный — фон `field` и цвет `accText`.
/// ↑ ↓ с клавиатуры переходят по разделам.
struct SettingsSidebar: View {
    @Binding var selection: SettingsSection
    @Binding var query: String

    @FocusState private var listFocused: Bool

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var found: [SettingsSection] { SettingsSearch.displayOrder(SettingsSearch.filter(SettingsSection.allCases, query: query)) }
    private var order: [SettingsSection] { searching ? found : SettingsGroup.allCases.flatMap(\.sections) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSearchField(text: $query)
                .padding(.horizontal, DS.Space.s)
                .padding(.top, DS.Size.titlebar)
                .padding(.bottom, DS.Space.s)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    if searching {
                        if found.isEmpty {
                            EmptyState("Ничего не найдено", systemImage: "magnifyingglass", compact: true)
                        }
                        ForEach(found) { row($0, showsGroup: true) }
                    } else {
                        ForEach(Array(SettingsGroup.allCases.enumerated()), id: \.element) { index, group in
                            Text(group.title.uppercased())
                                .font(DS.Font.groupLabel)
                                .tracking(DS.Font.tracking(0.12, size: 11))
                                .foregroundStyle(.dsMute)
                                .padding(.top, index == 0 ? DS.Space.xs : 14)
                                .padding(.bottom, DS.Space.xs)
                                .padding(.horizontal, 10)
                                .accessibilityLabel(group.title)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.sections) { row($0) }
                        }
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.bottom, DS.Space.l)
            }
            .scrollIndicators(.never)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand(perform: move)
            // Выбранный раздел всегда на виду (в том числе когда его открыли из панели или поиска).
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, new in
                withAnimation(DS.Motion.quick) { proxy.scrollTo(new, anchor: .center) }
            }
            }
        }
        .background(Color.dsSide)
    }

    private func row(_ section: SettingsSection, showsGroup: Bool = false) -> some View {
        SettingsSidebarRow(section: section, selected: section == selection, showsGroup: showsGroup) {
            selection = section
        }
        .id(section)
    }

    private func move(_ direction: MoveCommandDirection) {
        guard let index = order.firstIndex(of: selection) else {
            if let first = order.first { selection = first }
            return
        }
        switch direction {
        case .up where index > 0: selection = order[index - 1]
        case .down where index < order.count - 1: selection = order[index + 1]
        default: break
        }
    }
}

/// Строка боковой панели: значок 18 + название 14/600; невыбранная — `mute`, выбранная — фон `field` и `accText`.
struct SettingsSidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    var showsGroup = false
    let action: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    /// Выделение: в тёмной теме — `field` (как в концепте); в светлой `field` на `side` не виден (≈1,01:1),
    /// поэтому — `panel` с обводкой `line`.
    private var selectedFill: Color { scheme == .light ? .dsPanel : .dsField }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: DS.Size.rowIcon)
                Text(section.title)
                    .font(DS.Font.bodyStrong)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                Spacer(minLength: DS.Space.xs)
                if showsGroup {
                    Text(section.group.title).font(DS.Font.caption).foregroundStyle(.dsMute).lineLimit(1)
                }
            }
            .foregroundStyle(selected ? Color.dsAccText : Color.dsMute)
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? selectedFill : (hovered ? selectedFill.opacity(0.6) : .clear), in: shape)
            .overlay { if selected && scheme == .light { shape.strokeBorder(Color.dsLine, lineWidth: 1) } }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityHint(showsGroup ? section.group.title : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Поле поиска боковой панели: `field`, радиус 10, лупа; фокус — рамка `accLine`.
struct SidebarSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        HStack(spacing: DS.Space.s) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.dsMute)
                .accessibilityHidden(true)
            TextField("Поиск настроек", text: $text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(.dsText)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.dsMute)
                    .help("Очистить поиск")
                    .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.dsField, in: shape)
        .overlay(shape.strokeBorder(focused ? Color.dsAccLine : Color.dsLine, lineWidth: focused ? DS.State.focusRing : 1))
    }
}

/// Страница раздела: в окне настроек и вкладкой в панели 🔧.
struct SettingsSectionPage: View {
    let section: SettingsSection
    var compact = false
    /// Снимки интерфейса: страницы с сетью показывают демо-состояние (`ScreenSharePage(demo:)`).
    @Environment(\.uiDemo) private var demo

    var body: some View {
        switch section {
            case .general: GeneralPage()
            case .hotKeys: HotKeysPage()
            case .exclusions: ExclusionsPage()
            case .panel: PanelSettingsPage()
            case .music: NowPlayingView(compact: compact).navigationTitle("Музыка")
            case .share: ScreenSharePage(compact: compact, demo: demo)
            case .textInput: TextInputPage()
            case .focus: FocusPage()
            case .cutPaste: CutPastePage()
            case .smoothScroll: SmoothScrollPage()
            case .switcher: SwitcherPage()
            case .screenshot: ScreenshotPage()
            case .windows: WindowsPage()
            case .volume: VolumePage()
            case .layout: LayoutPage()
            case .shelf: ShelfPage()
            case .cheatSheet: CheatSheetPage()
            case .downloads: DownloadsPage()
            case .qr: QRPage()
            case .annotate: AnnotatePage()
            case .wellbeing: WellbeingPage()
            case .meetings: MeetingsPage()
            case .ai: AIPage()
            case .uninstaller: UninstallerPage(compact: compact)
            case .monitor: SystemMonitorView(model: .shared, compact: compact).navigationTitle("Монитор системы")
            case .tasks: TaskManagerView(model: .shared, compact: compact).navigationTitle("Диспетчер задач")
            case .cleanup: DiskCleanupView(model: .shared, compact: compact).navigationTitle("Очистка диска")
            case .shots: ScreenshotLibraryView(library: .shared, compact: compact).navigationTitle("Мои снимки")
            case .textEditor: TextEditorPage()
            case .videoPlayer: VideoPlayerPage()
            case .remote: RemoteConnectionsPanel()
        }
    }
}

// MARK: - Демо для снимков

private struct UIDemoKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Снимки интерфейса (`UISnapshotTests`): без сети и личных данных. В приложении всегда false.
    var uiDemo: Bool {
        get { self[UIDemoKey.self] }
        set { self[UIDemoKey.self] = newValue }
    }
}

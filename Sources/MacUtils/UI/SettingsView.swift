import AppKit
import ServiceManagement
import SwiftUI
import MUDesign
import MUFocus
import MUMusic
import MUDownloadsSorter

// MARK: - Модель разрешений

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

import AppKit
import SwiftUI
import MUDesign

/// Общий список программ, в которых функции с перехватом клавиш и мыши (переключатель окон, подсказки по ⌘,
/// плавная прокрутка, исправление раскладки) не работают: виртуальные машины и удалённые рабочие столы сами забирают
/// клавиатуру, и наш перехват только мешает (⌥Tab, ⌘-сочетания, колесо мыши должны дойти до гостевой системы).
@MainActor
final class AppExclusions: ObservableObject {
    static let shared = AppExclusions()

    static let defaultsKey = "excludedApps"

    /// Передний план стал исключённым или перестал им быть (после обновления списка тоже): подписчики включают и выключают
    /// свои перехваты (системный ⌘Tab у переключателя, горячая клавиша раскладки).
    static let didChangeNotification = Notification.Name("MacUtilsAppExclusionsDidChange")

    /// Значения по умолчанию: виртуальные машины и удалённые рабочие столы. Запись с точкой на конце — префикс
    /// (`com.parallels.` — вся семья Parallels, включая Windows-приложения), иначе точное совпадение bundle id.
    static let defaultList: [String] = [
        // Parallels: сама программа, окна Windows-программ (Coherence) и виртуальные машины; Parallels Toolbox (обычные
        // утилиты Mac, `com.parallels.toolbox`) сюда не входит.
        "com.parallels.desktop.console", "com.parallels.winapp.", "com.parallels.vm.",
        "com.vmware.", "org.virtualbox.app.VirtualBoxVM", "com.utmapp.UTM",
        "com.apple.ScreenSharing", "com.apple.RemoteDesktop", "com.microsoft.rdc.macos", "com.microsoft.rdc.mac",
        "com.teamviewer.TeamViewer", "com.anydesk.anydesk", "com.philandro.anydesk", "tv.parsec.www",
        "com.p5sys.jump.", "com.citrix.", "com.realvnc.", "com.nomachine.",
    ]

    /// Сохранённый список; ключа нет — значения по умолчанию.
    @Published private(set) var list: [String]
    /// На переднем плане программа из списка (обновляется при активации программ и при смене списка: в обработчиках tap
    /// запрашивать `frontmostApplication` на каждое событие незачем).
    private(set) var isFrontExcluded = false
    private var frontBundleID: String?
    private var observer: Any?

    private init() {
        list = Self.load()
        frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        recompute()
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                self?.frontBundleID = app?.bundleIdentifier
                self?.recompute()
            }
        }
    }

    // MARK: - Чистая логика

    /// bundle id попадает в список: точное совпадение или префикс (запись, оканчивающаяся на «.»). Регистр не важен.
    static func matches(_ bundleID: String?, in list: [String]) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return list.contains { entry in
            let item = entry.lowercased()
            guard !item.isEmpty else { return false }
            return item.hasSuffix(".") ? id.hasPrefix(item) : id == item
        }
    }

    /// Запись из ввода пользователя: пробелы убираются, пустое отбрасывается, повтор не добавляется.
    static func adding(_ entry: String, to list: [String]) -> [String] {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return list }
        return list + [trimmed]
    }

    static func load(defaults: UserDefaults = .standard) -> [String] {
        (defaults.array(forKey: defaultsKey) as? [String]) ?? defaultList
    }

    // MARK: - Состояние

    func isExcluded(_ bundleID: String?) -> Bool { Self.matches(bundleID, in: list) }

    private func recompute() {
        let now = Self.matches(frontBundleID, in: list)
        guard now != isFrontExcluded else { return }
        isFrontExcluded = now
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func set(_ newList: [String]) {
        list = newList
        UserDefaults.standard.set(newList, forKey: Self.defaultsKey)
        recompute()
    }

    func add(_ entry: String) { set(Self.adding(entry, to: list)) }

    func remove(_ entry: String) { set(list.filter { $0 != entry }) }

    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        list = Self.defaultList
        recompute()
    }

    /// Название для списка: имя программы, если она установлена, иначе сам bundle id.
    static func title(for entry: String) -> String {
        if !entry.hasSuffix("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return entry
    }
}

/// Страница настроек «Исключённые программы»: объяснение и список.
struct ExclusionsPage: View {
    var body: some View {
        SettingsPage(.exclusions) {
            Footnote("Это нужно для виртуальных машин (Parallels, VMware, UTM) и удалённых рабочих столов (Общий экран, Microsoft Remote Desktop, TeamViewer, AnyDesk): они сами передают клавиатуру в другую систему, и перехват Mac Utils им мешает. Если таких программ у вас нет, здесь ничего менять не нужно.")
            ExcludedAppsSection()
        }
    }
}

/// Список исключённых программ с кнопками (на странице «Исключённые программы»).
struct ExcludedAppsSection: View {
    @ObservedObject private var exclusions = AppExclusions.shared
    @State private var running: [NSRunningApplication] = []

    var body: some View {
        GroupLabel("Список")
        ListCard {
            ForEach(exclusions.list, id: \.self) { entry in
                let title = AppExclusions.title(for: entry)
                // Значок программы, если она установлена; префикс bundle id — «все с таким началом».
                AppRow(title, subtitle: entry.hasSuffix(".") ? "(все с таким началом)" : (title == entry ? nil : entry),
                       bundleID: entry.hasSuffix(".") ? nil : entry, fallbackSymbol: "rectangle.on.rectangle.slash") {
                    IconButton("Убрать из списка", systemImage: "minus", compact: true) { exclusions.remove(entry) }
                }
            }
        }
        HStack(spacing: DS.Space.s) {
            Menu {
                ForEach(running, id: \.processIdentifier) { app in
                    if let id = app.bundleIdentifier {
                        Button(app.localizedName ?? id) { exclusions.add(id) }
                    }
                }
            } label: {
                Label("Добавить запущенную программу…", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.graphite(.secondary))
            .fixedSize()
            .onAppear { refreshRunning() }
            Spacer()
            Button("По умолчанию") { exclusions.resetToDefaults() }
                .buttonStyle(.graphite(.ghost))
        }
    }

    private func refreshRunning() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !exclusions.isExcluded($0.bundleIdentifier) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

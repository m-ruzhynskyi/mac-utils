import AppKit
import MURemoteConnections
import OSLog
import UniformTypeIdentifiers

/// Ключи настроек «Удалённых подключений». Паролей среди них нет и быть не может: только путь, лист, программа
/// по умолчанию и ID в избранном и недавних.
enum RemotePref {
    static let filePath = "remoteConnectionsFile"
    static let sheet = "remoteConnectionsSheet"
    static let favorites = "remoteConnectionsFavorites"
    static let recents = "remoteConnectionsRecents"
    static let defaultProgram = "remoteConnectionsDefaultProgram"
    /// Вкладка «Удалённые» уже добавлена в панель 🔧 (один раз при обновлении).
    static let panelTabAdded = "panelTabsRemoteAdded"
}

/// Адаптер модуля к UserDefaults: выбор файла, избранное, недавние.
final class DefaultsRemoteStore: ConnectionsSettingsStore, RemotePreferencesStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var filePath: String? {
        get { defaults.string(forKey: RemotePref.filePath) }
        set { set(newValue, RemotePref.filePath) }
    }

    var sheetName: String? {
        get { defaults.string(forKey: RemotePref.sheet) }
        set { set(newValue, RemotePref.sheet) }
    }

    var favoriteIDs: [String] {
        get { defaults.stringArray(forKey: RemotePref.favorites) ?? [] }
        set { defaults.set(newValue, forKey: RemotePref.favorites) }
    }

    var recentIDs: [String] {
        get { defaults.stringArray(forKey: RemotePref.recents) ?? [] }
        set { defaults.set(newValue, forKey: RemotePref.recents) }
    }

    private func set(_ value: String?, _ key: String) {
        if let value, !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Журнал модуля: события уже без ID, имён и путей — только числа и коды.
final class RemoteConnectionsLog: RemoteLogger {
    private let logger = Logger(subsystem: "com.mruzhynskyi.macutils", category: "remote")
    func log(_ event: RemoteLogEvent) { logger.info("\(event.message, privacy: .public)") }
}

/// Состояние «Удалённых подключений» для вкладки панели и палитры ⌥⌘A. Вся логика — в модуле MURemoteConnections.
@MainActor
final class RemoteConnectionsCenter: ObservableObject {
    static let shared = RemoteConnectionsCenter()

    @Published private(set) var state: ConnectionsFileState = .noFile
    @Published private(set) var snapshot = ConnectionsSnapshot()
    @Published private(set) var favorites: [String] = []
    @Published private(set) var recents: [String] = []
    @Published private(set) var loadedAt: Date?
    private(set) var search = ConnectionSearch([])

    private let defaults: UserDefaults
    private let prefs: DefaultsRemoteStore
    private let store: ConnectionsFileStore
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefs = DefaultsRemoteStore(defaults: defaults)
        store = ConnectionsFileStore(settings: prefs, logger: RemoteConnectionsLog())
        favorites = prefs.favoriteIDs
        recents = prefs.recentIDs
        store.onChange = { [weak self] in self?.sync() }
    }

    /// Первое обращение (вкладка, палитра) — начать читать файл и следить за ним.
    func start() {
        guard !started else { return }
        started = true
        store.start()
    }

    var fileURL: URL? { store.fileURL }
    var sheetName: String? { store.sheetName }

    var defaultProgram: RemoteProgram {
        get { defaults.string(forKey: RemotePref.defaultProgram).flatMap(RemoteProgram.init(rawValue:)) ?? .anyDesk }
        set { defaults.set(newValue.rawValue, forKey: RemotePref.defaultProgram); objectWillChange.send() }
    }

    func listing(query: String, filter: ProgramFilter) -> ConnectionListing {
        ConnectionListBuilder.build(search: search, query: query, filter: filter, defaultProgram: defaultProgram,
                                    favorites: favorites, recents: recents)
    }

    private func sync() {
        state = store.state
        if snapshot != store.snapshot {
            snapshot = store.snapshot
            search = ConnectionSearch(snapshot.records)
        }
        if state == .ready { loadedAt = Date() }
    }

    // MARK: Файл

    func reload() {
        start()
        store.reload()
    }

    func setFile(_ url: URL?, sheet: String? = nil) {
        start()
        store.setFile(url, sheet: sheet)
    }

    func setSheet(_ name: String?) { store.setSheet(name) }

    /// Выбор таблицы. Только путь; файл не копируется и не меняется.
    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Файл подключений"
        panel.message = "Таблица .xlsx или .xml со списком компьютеров"
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx"), UTType(filenameExtension: "xlsm"), .xml].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFile(url)
    }

    /// «Excel»: открыть таблицу в программе по умолчанию.
    func openFile() {
        guard let url = fileURL else { return chooseFile() }
        NSWorkspace.shared.open(url)
    }

    // MARK: Избранное и недавние

    func isFavorite(_ record: ConnectionRecord) -> Bool { favorites.contains(record.favoriteKey) }

    func toggleFavorite(_ record: ConnectionRecord) {
        ConnectionLists.toggleFavorite(record, in: prefs)
        favorites = prefs.favoriteIDs
    }

    // MARK: Программы

    func isInstalled(_ program: RemoteProgram) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: program.bundleID) != nil
    }

    /// Подключение без ввода пароля: программа открывает окно подключения к ID, пароль вводит пользователь.
    func connect(_ record: ConnectionRecord) {
        let program = record.program(default: defaultProgram)
        guard isInstalled(program) else {
            Toast.show("\(program.title) не установлен", symbol: "xmark.octagon.fill", tint: .red,
                       action: Toast.Action(title: "Скачать") { NSWorkspace.shared.open(program.downloadURL) })
            return
        }
        guard let url = program.connectURL(id: record.id) else {
            Toast.show("\(program.title) не открывает алиасы — укажите числовой ID", symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        ConnectionLists.noteConnected(record, in: prefs)
        recents = prefs.recentIDs
        NSWorkspace.shared.open(url)
    }

    /// Новая вкладка «Удалённые» — один раз, сразу после «Редактора» (или в конец).
    static func addPanelTabOnce(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: RemotePref.panelTabAdded) else { return }
        defaults.set(true, forKey: RemotePref.panelTabAdded)
        var tabs = (defaults.string(forKey: Pref.toolsPanelTabs) ?? PanelTabs.defaultValue).split(separator: ",").map(String.init)
        guard !tabs.contains(SettingsSection.remote.rawValue) else { return }
        tabs.insert(SettingsSection.remote.rawValue, at: tabs.firstIndex(of: "textEditor").map { $0 + 1 } ?? tabs.count)
        defaults.set(tabs.joined(separator: ","), forKey: Pref.toolsPanelTabs)
    }
}

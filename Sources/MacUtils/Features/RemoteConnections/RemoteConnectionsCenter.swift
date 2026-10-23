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
    /// Ставить в окне пароля галочку «входить автоматически».
    static let autologin = "remoteConnectionsAutologin"
    /// Сколько секунд ждать окно пароля.
    static let timeout = "remoteConnectionsTimeout"
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

    /// Программа для строк без колонки «Программа». nil — AnyDesk, а если в файле есть обе программы — спросить.
    var defaultProgramSetting: RemoteProgram? {
        get { defaults.string(forKey: RemotePref.defaultProgram).flatMap(RemoteProgram.init(rawValue:)) }
        set {
            if let newValue { defaults.set(newValue.rawValue, forKey: RemotePref.defaultProgram) }
            else { defaults.removeObject(forKey: RemotePref.defaultProgram) }
            objectWillChange.send()
        }
    }

    /// Программа строки без колонки «Программа» — для значков и фильтра списка.
    var defaultProgram: RemoteProgram { defaultProgramSetting ?? .anyDesk }

    var autologin: Bool {
        get { defaults.bool(forKey: RemotePref.autologin) }
        set { defaults.set(newValue, forKey: RemotePref.autologin); objectWillChange.send() }
    }

    static let timeoutRange = 5...60

    var timeoutSeconds: Int {
        get {
            let value = defaults.integer(forKey: RemotePref.timeout)
            return value == 0 ? 20 : min(max(value, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
        }
        set { defaults.set(newValue, forKey: RemotePref.timeout); objectWillChange.send() }
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

    // MARK: Подключение

    private lazy var launcher = WorkspaceLauncher()
    private lazy var connector = RemoteConnector(ax: SystemAXAccess(), launcher: launcher, keyboard: ProcessKeyboard(),
                                                 logger: RemoteConnectionsLog())
    private var connection: Task<Void, Never>?
    private var last: (record: ConnectionRecord, program: RemoteProgram, withPassword: Bool)?
    @Published private(set) var isConnecting = false

    /// Подключиться: пароль — из файла в момент подключения, ввод — в окно программы (HUD показывает ход).
    /// `withPassword: false` — ⌘↩, только открыть программу на этом ID.
    func connect(_ record: ConnectionRecord, withPassword: Bool = true, program chosen: RemoteProgram? = nil,
                 retry: Bool = false) {
        connection?.cancel()
        let hud = RemoteHUDController.shared
        hud.onAction = { [weak self] action in self?.handle(action) }
        let ambiguous = snapshot.diagnostics.ambiguousProgramRows.contains(record.sourceRow)
        guard let program = chosen ?? record.resolvedProgram(default: defaultProgramSetting, ambiguous: ambiguous) else {
            last = (record, .anyDesk, withPassword)
            hud.show(.finished(.failed(.programNotSpecified)), program: .anyDesk, record: record)
            return
        }
        last = (record, program, withPassword)
        let request = ConnectRequest(record: record, program: program, withPassword: withPassword, autologin: autologin,
                                     timeoutSeconds: timeoutSeconds, reuseOpenWindow: retry)
        let provider = RemoteProviders.provider(for: program, texts: texts(for: program))
        let store = self.store
        isConnecting = true
        connection = Task { [weak self] in
            var opened = false
            let outcome = await self?.connector.connect(request, provider: provider, password: {
                try await store.lookupPassword(for: record)
            }, progress: { phase in
                if phase == .opening { opened = true }
                hud.show(phase, program: program, record: record)
            })
            guard let self, let outcome else { return }
            self.isConnecting = false
            if opened, outcome != .failed(.launchFailed) {
                ConnectionLists.noteConnected(record, in: self.prefs)
                self.recents = self.prefs.recentIDs
            }
            if outcome == .failed(.entryGone) { self.store.reload() }
        }
    }

    /// Надписи окна пароля — из установленной программы, на всех её языках.
    private func texts(for program: RemoteProgram) -> ProviderTexts {
        guard let url = launcher.appURL(bundleID: program.bundleID) else { return ProviderTexts() }
        return ProviderTexts.load(appURL: url, keys: RemoteProviders.keys(for: program))
    }

    private func handle(_ action: RemoteHUDAction) {
        let hud = RemoteHUDController.shared
        switch action {
        case .cancel:
            connection?.cancel()
            hud.dismiss()
        case .close:
            hud.dismiss()
        case .openAccessibility:
            hud.dismiss()
            Permissions.open(.accessibility)
        case .download:
            hud.dismiss()
            if let program = last?.program { NSWorkspace.shared.open(program.downloadURL) }
        case .diagnostics:
            hud.toggleStructure()
        case .openFile:
            hud.dismiss()
            openFile()
        case .retry:
            guard let last else { return hud.dismiss() }
            connect(last.record, withPassword: last.withPassword, program: last.program, retry: true)
        case .choose(let program):
            guard let last else { return hud.dismiss() }
            connect(last.record, withPassword: last.withPassword, program: program)
        }
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

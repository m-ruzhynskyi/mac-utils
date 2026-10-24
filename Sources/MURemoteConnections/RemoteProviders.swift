import Foundation

/// Надписи окон конкретной программы. Ищем по ролям (`AXSecureTextField`), надписи — подсказки: узнать окно пароля
/// без поля, отказ в пароле, галочку автологина, промежуточные окна подключения и открытый сеанс. Берутся из
/// установленной программы (`ProviderTexts.load`), поэтому совпадают с её языком.
public struct ProviderTexts: Equatable, Sendable {
    public var passwordWindowTitles: Set<String>
    public var rejectionTexts: Set<String>
    public var autologinTitles: Set<String>
    public var confirmTitles: Set<String>
    /// Промежуточное окно, которое мы проходим сами (AnyDesk «Terminal Session»).
    public var promptTexts: Set<String>
    /// Кнопка продолжения в нём («Connect»). Отмену и закрытие не нажимаем никогда — их здесь нет.
    public var promptContinueTitles: Set<String>
    /// Выбор по умолчанию, который оставляем («Console»).
    public var promptDefaultTitles: Set<String>
    /// Программа соединяется или ждёт, пока та сторона примет запрос.
    public var progressTexts: Set<String>
    /// Сеанс установлен (AnyDesk «Waiting for image»).
    public var sessionTexts: Set<String>
    /// Сеанс закрыт или не открылся.
    public var closedTexts: Set<String>
    /// Поле ID на главном экране (TeamViewer: «ID, IP address, or hostname»).
    public var connectFieldTexts: Set<String>
    /// Кнопка «Connect» рядом с ним.
    public var connectButtonTitles: Set<String>

    public init(passwordWindowTitles: Set<String> = [], rejectionTexts: Set<String> = [],
                autologinTitles: Set<String> = [], confirmTitles: Set<String> = ["OK", "ОК", "Connect", "Log In"],
                promptTexts: Set<String> = [], promptContinueTitles: Set<String> = [], promptDefaultTitles: Set<String> = [],
                progressTexts: Set<String> = [], sessionTexts: Set<String> = [], closedTexts: Set<String> = [],
                connectFieldTexts: Set<String> = [], connectButtonTitles: Set<String> = []) {
        self.passwordWindowTitles = Set(passwordWindowTitles.map(Self.key))
        self.rejectionTexts = Set(rejectionTexts.map(Self.key))
        self.autologinTitles = Set(autologinTitles.map(Self.key))
        self.confirmTitles = Set(confirmTitles.map(Self.key))
        self.promptTexts = Set(promptTexts.map(Self.key))
        self.promptContinueTitles = Set(promptContinueTitles.map(Self.key))
        self.promptDefaultTitles = Set(promptDefaultTitles.map(Self.key))
        self.progressTexts = Set(progressTexts.map(Self.key))
        self.sessionTexts = Set(sessionTexts.map(Self.key))
        self.closedTexts = Set(closedTexts.map(Self.key))
        self.connectFieldTexts = Set(connectFieldTexts.map(Self.key))
        self.connectButtonTitles = Set(connectButtonTitles.map(Self.key))
    }

    /// Ключи строк в `Localizable.strings` программы и в переводах её веб-интерфейса.
    public struct Keys: Sendable {
        public var passwordWindow: [String] = []
        public var rejection: [String] = []
        public var autologin: [String] = []
        public var confirm: [String] = []
        public var prompt: [String] = []
        public var promptContinue: [String] = []
        public var promptDefault: [String] = []
        public var progress: [String] = []
        public var session: [String] = []
        /// Все заголовки и сообщения с этим префиксом (`ad.dlg.closed.…title/message`).
        public var closedPrefix: String?
        public var connectField: [String] = []
        public var connectButton: [String] = []
        /// Папка с `<язык>/translation.json` веб-интерфейса внутри `Contents/Resources`.
        public var webLocales: String?
    }

    /// Надписи на всех языках из `Contents/Resources/*.lproj/Localizable.strings` установленной программы
    /// и из переводов её веб-интерфейса. Только чтение файлов; программа не запускается.
    public static func load(appURL: URL, keys: Keys) -> ProviderTexts {
        let resources = appURL.appendingPathComponent("Contents/Resources")
        var texts = ProviderTexts()
        var tables: [[String: String]] = []
        let fm = FileManager.default
        for lang in (try? fm.contentsOfDirectory(atPath: resources.path)) ?? [] where lang.hasSuffix(".lproj") {
            let url = resources.appendingPathComponent(lang).appendingPathComponent("Localizable.strings")
            if let table = NSDictionary(contentsOf: url) as? [String: String] { tables.append(table) }
        }
        if let web = keys.webLocales {
            let dir = resources.appendingPathComponent(web)
            for lang in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let url = dir.appendingPathComponent(lang).appendingPathComponent("translation.json")
                guard let data = try? Data(contentsOf: url), data.count < 8 << 20,
                      let json = try? JSONSerialization.jsonObject(with: data) else { continue }
                var table: [String: String] = [:]
                flatten(json, "", into: &table)
                tables.append(table)
            }
        }
        for table in tables {
            func add(_ keys: [String], _ set: inout Set<String>) {
                for k in keys { if let v = table[k], !v.isEmpty { set.insert(key(v)) } }
            }
            add(keys.passwordWindow, &texts.passwordWindowTitles)
            add(keys.rejection, &texts.rejectionTexts)
            add(keys.autologin, &texts.autologinTitles)
            add(keys.confirm, &texts.confirmTitles)
            add(keys.prompt, &texts.promptTexts)
            add(keys.promptContinue, &texts.promptContinueTitles)
            add(keys.promptDefault, &texts.promptDefaultTitles)
            add(keys.progress, &texts.progressTexts)
            add(keys.session, &texts.sessionTexts)
            add(keys.connectField, &texts.connectFieldTexts)
            add(keys.connectButton, &texts.connectButtonTitles)
            if let prefix = keys.closedPrefix {
                for (k, v) in table where k.hasPrefix(prefix) && (k.hasSuffix(".title") || k.hasSuffix(".message"))
                    && !v.isEmpty && !v.contains("%") {
                    texts.closedTexts.insert(key(v))
                }
            }
        }
        return texts
    }

    /// `{"a": {"b": "текст"}}` → `["a.b": "текст"]`.
    private static func flatten(_ value: Any, _ prefix: String, into table: inout [String: String]) {
        if let s = value as? String {
            table[prefix] = s
        } else if let d = value as? [String: Any] {
            for (k, v) in d { flatten(v, prefix.isEmpty ? k : prefix + "." + k, into: &table) }
        }
    }

    /// Сравнение без регистра, пробелов по краям и многоточий.
    static func key(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".…:")))
            .lowercased()
    }

    func isPasswordWindow(_ window: AXNode) -> Bool {
        guard !passwordWindowTitles.isEmpty else { return false }
        if let t = window.label, passwordWindowTitles.contains(Self.key(t)) { return true }
        return AXTree.first(in: window) { $0.role == "AXStaticText" && $0.label.map { passwordWindowTitles.contains(Self.key($0)) } == true } != nil
    }

    func isRejection(_ window: AXNode) -> Bool {
        guard !rejectionTexts.isEmpty else { return false }
        if let t = window.label, rejectionTexts.contains(Self.key(t)) { return true }
        return AXTree.first(in: window) { $0.label.map { rejectionTexts.contains(Self.key($0)) } == true } != nil
    }

    /// Заголовок окна или надпись в нём из набора. Кнопки не считаются: «New Session» есть и на главном экране.
    func shows(_ set: Set<String>, in window: AXNode) -> AXNode? {
        guard !set.isEmpty else { return nil }
        if let t = window.label, set.contains(Self.key(t)) { return window }
        return AXTree.first(in: window) { $0.role == "AXStaticText" && $0.label.map { set.contains(Self.key($0)) } == true }
    }

    /// У элемента есть подпись из набора.
    static func named(_ node: AXNode, _ set: Set<String>) -> Bool {
        AXTree.names(of: node).contains { set.contains(key($0)) }
    }
}

/// Программа удалённого доступа на этой платформе: как открыть подключение и как выглядит её окно пароля.
/// Новая программа — новый поставщик; список, файл и HUD не меняются.
public protocol RemoteProvider {
    var program: RemoteProgram { get }
    var texts: ProviderTexts { get }
    /// В окне пароля есть галочка «входить автоматически».
    var supportsAutologin: Bool { get }
    /// Ссылка не подставила ID (программа открылась на главном экране) — вписать его в поле и нажать «Connect».
    var fillsConnectForm: Bool { get }
    /// Подключение не подтвердилось — посоветовать вставить ID вручную (приложение кладёт его в буфер обмена).
    var copiesIDWhenUnconfirmed: Bool { get }
    func connectURL(id: String) -> URL?
}

/// AnyDesk для Mac: `anydesk:<ID>`, окно «Авторизация» с `NSSecureTextField`, галочкой «Входить автоматически»
/// и кнопкой «ОК»; отказ — окно «Пароль отклонён». До пароля может показать «Terminal Session» (выбор сеанса
/// Windows-сервера) — оставляем «Console» и жмём «Connect». Надписи — из `Localizable.strings` AnyDesk.
public struct AnyDeskAutomator: RemoteProvider {
    public static let keys = ProviderTexts.Keys(passwordWindow: ["ad.dlg.passwd.title"],
                                                rejection: ["ad.dlg.closed.auth_failed.title"],
                                                autologin: ["ad.dlg.passwd.remember"],
                                                confirm: ["ad.dlg.ok"],
                                                prompt: ["ad.dlg.terminal.title", "ad.dlg.terminal.users_logged_on"],
                                                promptContinue: ["ad.dlg.connect"],
                                                promptDefault: ["ad.dlg.terminal.console"],
                                                progress: ["ad.dlg.connect.msg", "ad.dlg.connect.title",
                                                           "ad.dlg.wait_for_accept.msg", "ad.dlg.wait_for_accept.title",
                                                           "ad.dlg.connecting_to_ios_extension.msg"],
                                                session: ["ad.dlg.wait_for_image.msg"],
                                                closedPrefix: "ad.dlg.closed.")
    public let texts: ProviderTexts

    public init(texts: ProviderTexts = ProviderTexts()) { self.texts = texts }

    public var program: RemoteProgram { .anyDesk }
    public var supportsAutologin: Bool { true }
    public var fillsConnectForm: Bool { false }
    public var copiesIDWhenUnconfirmed: Bool { false }
    public func connectURL(id: String) -> URL? { program.connectURL(id: id) }
}

/// TeamViewer для Mac: `teamviewer10://control?device=<ID>` (обработчик есть в TeamViewer 15), окно
/// «Аутентификация» с защищённым полем. Галочки автологина в нём нет. Если ссылка не подставила ID и TeamViewer
/// открылся на главном экране, ID вписывается в поле «ID, IP address, or hostname» (новый интерфейс, надписи — из его
/// переводов) или «Partner ID» (прежний) и нажимается «Connect».
public struct TeamViewerAutomator: RemoteProvider {
    public static let keys = ProviderTexts.Keys(
        connectField: ["remote_support.participant_id.search_dropdown.recent_connections_with_ip.label",
                       "remote_support.participant_id.search_dropdown.recent_connections_with_ip.placeholder",
                       "remote_support.participant_id.search_dropdown.recent_connections.placeholder"],
        connectButton: ["remote_support.connections.connect"],
        webLocales: "BrowserUI_TVOne/locales")
    /// Прежний интерфейс: надписи в коде программы, в файлах их нет.
    static let classicConnectFields: Set<String> = ["Partner ID", "ID партнёра", "Partner-ID", "ID партнера",
                                                    "ID, IP address, or hostname"]
    static let classicConnectButtons: Set<String> = ["Connect", "Подключиться", "Verbinden"]
    public let texts: ProviderTexts

    public init(texts: ProviderTexts = ProviderTexts()) {
        var t = texts
        t.connectFieldTexts.formUnion(Self.classicConnectFields.map(ProviderTexts.key))
        t.connectButtonTitles.formUnion(Self.classicConnectButtons.map(ProviderTexts.key))
        self.texts = t
    }

    public var program: RemoteProgram { .teamViewer }
    public var supportsAutologin: Bool { false }
    public var fillsConnectForm: Bool { true }
    public var copiesIDWhenUnconfirmed: Bool { true }
    public func connectURL(id: String) -> URL? { program.connectURL(id: id) }
}

public enum RemoteProviders {
    public static func keys(for program: RemoteProgram) -> ProviderTexts.Keys {
        switch program {
        case .anyDesk: return AnyDeskAutomator.keys
        case .teamViewer: return TeamViewerAutomator.keys
        }
    }

    public static func provider(for program: RemoteProgram, texts: ProviderTexts = ProviderTexts()) -> RemoteProvider {
        switch program {
        case .anyDesk: return AnyDeskAutomator(texts: texts)
        case .teamViewer: return TeamViewerAutomator(texts: texts)
        }
    }
}

extension ConnectionRecord {
    /// Программа записи: из файла; алиас — AnyDesk; иначе программа по умолчанию.
    /// nil — спросить: в файле есть обе программы, у строки программа не указана, а по умолчанию — «спрашивать».
    public func resolvedProgram(default fallback: RemoteProgram?, ambiguous: Bool) -> RemoteProgram? {
        if let program { return program }
        if isAlias { return .anyDesk }
        if ambiguous, fallback == nil { return nil }
        return fallback ?? .anyDesk
    }
}

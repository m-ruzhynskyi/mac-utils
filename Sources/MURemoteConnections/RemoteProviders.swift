import Foundation

/// Надписи окна пароля конкретной программы. Ищем по ролям (`AXSecureTextField`), надписи — только подсказки:
/// узнать окно пароля без поля, отказ в пароле и галочку автологина. Берутся из установленной программы
/// (`ProviderTexts.load`), поэтому совпадают с её языком.
public struct ProviderTexts: Equatable, Sendable {
    public var passwordWindowTitles: Set<String>
    public var rejectionTexts: Set<String>
    public var autologinTitles: Set<String>
    public var confirmTitles: Set<String>

    public init(passwordWindowTitles: Set<String> = [], rejectionTexts: Set<String> = [],
                autologinTitles: Set<String> = [], confirmTitles: Set<String> = ["OK", "ОК", "Connect", "Log In"]) {
        self.passwordWindowTitles = Set(passwordWindowTitles.map(Self.key))
        self.rejectionTexts = Set(rejectionTexts.map(Self.key))
        self.autologinTitles = Set(autologinTitles.map(Self.key))
        self.confirmTitles = Set(confirmTitles.map(Self.key))
    }

    /// Ключи строк в `Localizable.strings` программы.
    public struct Keys: Sendable {
        public var passwordWindow: [String] = []
        public var rejection: [String] = []
        public var autologin: [String] = []
        public var confirm: [String] = []
    }

    /// Надписи на всех языках из `Contents/Resources/*.lproj/Localizable.strings` установленной программы.
    /// Только чтение файлов; программа не запускается.
    public static func load(appURL: URL, keys: Keys) -> ProviderTexts {
        let resources = appURL.appendingPathComponent("Contents/Resources")
        var texts = ProviderTexts()
        guard let langs = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else { return texts }
        for lang in langs where lang.hasSuffix(".lproj") {
            let url = resources.appendingPathComponent(lang).appendingPathComponent("Localizable.strings")
            guard let table = NSDictionary(contentsOf: url) as? [String: String] else { continue }
            func add(_ keys: [String], _ set: inout Set<String>) {
                for k in keys { if let v = table[k], !v.isEmpty { set.insert(key(v)) } }
            }
            add(keys.passwordWindow, &texts.passwordWindowTitles)
            add(keys.rejection, &texts.rejectionTexts)
            add(keys.autologin, &texts.autologinTitles)
            add(keys.confirm, &texts.confirmTitles)
        }
        return texts
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
}

/// Программа удалённого доступа на этой платформе: как открыть подключение и как выглядит её окно пароля.
/// Новая программа — новый поставщик; список, файл и HUD не меняются.
public protocol RemoteProvider {
    var program: RemoteProgram { get }
    var texts: ProviderTexts { get }
    /// В окне пароля есть галочка «входить автоматически».
    var supportsAutologin: Bool { get }
    func connectURL(id: String) -> URL?
}

/// AnyDesk для Mac: `anydesk:<ID>`, окно «Авторизация» с `NSSecureTextField`, галочкой «Входить автоматически»
/// и кнопкой «ОК»; отказ — окно «Пароль отклонён». Надписи — из `Localizable.strings` AnyDesk.
public struct AnyDeskAutomator: RemoteProvider {
    public static let keys = ProviderTexts.Keys(passwordWindow: ["ad.dlg.passwd.title"],
                                                rejection: ["ad.dlg.closed.auth_failed.title"],
                                                autologin: ["ad.dlg.passwd.remember"],
                                                confirm: ["ad.dlg.ok"])
    public let texts: ProviderTexts

    public init(texts: ProviderTexts = ProviderTexts()) { self.texts = texts }

    public var program: RemoteProgram { .anyDesk }
    public var supportsAutologin: Bool { true }
    public func connectURL(id: String) -> URL? { program.connectURL(id: id) }
}

/// TeamViewer для Mac: `teamviewer10://control?device=<ID>` (обработчик есть в TeamViewer 15), окно
/// «Аутентификация» с защищённым полем. Галочки автологина в нём нет; надписи не известны — только роли.
public struct TeamViewerAutomator: RemoteProvider {
    public static let keys = ProviderTexts.Keys()
    public let texts: ProviderTexts

    public init(texts: ProviderTexts = ProviderTexts()) { self.texts = texts }

    public var program: RemoteProgram { .teamViewer }
    public var supportsAutologin: Bool { false }
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

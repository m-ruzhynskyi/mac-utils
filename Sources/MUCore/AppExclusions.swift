import Foundation
import AppKit
import Combine

/// Общий список программ, в которых функции с перехватом клавиш и мыши (переключатель окон, подсказки по ⌘,
/// плавная прокрутка, исправление раскладки) не работают: виртуальные машины и удалённые рабочие столы сами забирают
/// клавиатуру, и наш перехват только мешает (⌥Tab, ⌘-сочетания, колесо мыши должны дойти до гостевой системы).
@MainActor
package final class AppExclusions: ObservableObject {
    package static let shared = AppExclusions()

    package static let defaultsKey = "excludedApps"

    /// Передний план стал исключённым или перестал им быть (после обновления списка тоже): подписчики включают и выключают
    /// свои перехваты (системный ⌘Tab у переключателя, горячая клавиша раскладки).
    package static let didChangeNotification = Notification.Name("MacUtilsAppExclusionsDidChange")

    /// Значения по умолчанию: виртуальные машины и удалённые рабочие столы. Запись с точкой на конце — префикс
    /// (`com.parallels.` — вся семья Parallels, включая Windows-приложения), иначе точное совпадение bundle id.
    package static let defaultList: [String] = [
        // Parallels: сама программа, окна Windows-программ (Coherence) и виртуальные машины; Parallels Toolbox (обычные
        // утилиты Mac, `com.parallels.toolbox`) сюда не входит.
        "com.parallels.desktop.console", "com.parallels.winapp.", "com.parallels.vm.",
        "com.vmware.", "org.virtualbox.app.VirtualBoxVM", "com.utmapp.UTM",
        "com.apple.ScreenSharing", "com.apple.RemoteDesktop", "com.microsoft.rdc.macos", "com.microsoft.rdc.mac",
        "com.teamviewer.TeamViewer", "com.anydesk.anydesk", "com.philandro.anydesk", "tv.parsec.www",
        "com.p5sys.jump.", "com.citrix.", "com.realvnc.", "com.nomachine.",
    ]

    /// Сохранённый список; ключа нет — значения по умолчанию.
    @Published package private(set) var list: [String]
    /// На переднем плане программа из списка (обновляется при активации программ и при смене списка: в обработчиках tap
    /// запрашивать `frontmostApplication` на каждое событие незачем).
    package private(set) var isFrontExcluded = false
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
    package static func matches(_ bundleID: String?, in list: [String]) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return list.contains { entry in
            let item = entry.lowercased()
            guard !item.isEmpty else { return false }
            return item.hasSuffix(".") ? id.hasPrefix(item) : id == item
        }
    }

    /// Запись из ввода пользователя: пробелы убираются, пустое отбрасывается, повтор не добавляется.
    package static func adding(_ entry: String, to list: [String]) -> [String] {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return list }
        return list + [trimmed]
    }

    package static func load(defaults: UserDefaults = .standard) -> [String] {
        (defaults.array(forKey: defaultsKey) as? [String]) ?? defaultList
    }

    // MARK: - Состояние

    package func isExcluded(_ bundleID: String?) -> Bool { Self.matches(bundleID, in: list) }

    private func recompute() {
        let now = Self.matches(frontBundleID, in: list)
        guard now != isFrontExcluded else { return }
        isFrontExcluded = now
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    package func set(_ newList: [String]) {
        list = newList
        UserDefaults.standard.set(newList, forKey: Self.defaultsKey)
        recompute()
    }

    package func add(_ entry: String) { set(Self.adding(entry, to: list)) }

    package func remove(_ entry: String) { set(list.filter { $0 != entry }) }

    package func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        list = Self.defaultList
        recompute()
    }

    /// Название для списка: имя программы, если она установлена, иначе сам bundle id.
    package static func title(for entry: String) -> String {
        if !entry.hasSuffix("."), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return entry
    }
}

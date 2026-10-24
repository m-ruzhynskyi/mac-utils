import AppKit
import Security
import MUDesign

/// Установленное приложение.
package struct InstalledApp: Identifiable, Hashable {
    package let url: URL
    package let name: String
    package let bundleID: String
    package let teamID: String?

    package var id: URL { url }

    package init?(url: URL) {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return nil }
        self.url = url
        self.bundleID = bundleID
        name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        teamID = Self.teamID(of: url)
    }

    /// Почему приложение нельзя удалять (системное, Apple, сам Mac Utils).
    package var refusal: String? {
        if url.path.hasPrefix("/System/") { return "Системное приложение macOS" }
        if bundleID.hasPrefix("com.apple.") { return "Приложение Apple" }
        if bundleID == Bundle.main.bundleIdentifier { return "Это сам Mac Utils" }
        return nil
    }

    private static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Приложения из /Applications и ~/Applications (с подпапками первого уровня).
    package static func all() -> [InstalledApp] {
        let manager = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"),
                     manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var result: [InstalledApp] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            guard url.pathExtension == "app", let app = InstalledApp(url: url), app.refusal == nil,
                  seen.insert(app.url.path).inserted else { return }
            result.append(app)
        }
        for root in roots {
            for url in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                if url.pathExtension == "app" {
                    add(url)
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for inner in (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] {
                        add(inner)
                    }
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Найденный «хвост» приложения.
package struct Leftover: Identifiable, Hashable {
    package enum Kind { case app, file, receipt }

    package let url: URL
    package let group: String
    package let kind: Kind
    /// Найдено по совпадению Team ID (общая папка разработчика) — по умолчанию не отмечено.
    package let shared: Bool
    package let needsAdmin: Bool
    /// Найдено только по имени папки, без bundle id — по умолчанию не отмечено.
    package var nameOnly = false
    /// Размер не считаем (контейнеры других приложений защищены macOS).
    package let sizeUnknown: Bool

    package var id: URL { url }
    package var checkedByDefault: Bool { kind != .receipt && !shared && !nameOnly }
}

/// Поиск файлов приложения в стандартных папках. Только точные совпадения:
/// bundle id (и «bundle id.что-то»), точное имя папки, префикс Team ID.
package enum AppScanner {
    package struct Location {
        package let path: String
        package let group: String
        /// Сравнивать с именем приложения (только для папок данных).
        package var byName = false
        /// Группы приложений: «TEAMID.…».
        package var byTeam = false
        package var receipts = false
        package var protected = false
    }

    package static var locations: [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var list: [Location] = [
            Location(path: "\(home)/Library/Application Support", group: "Данные приложения", byName: true),
            Location(path: "\(home)/Library/Caches", group: "Кэш", byName: true),
            Location(path: "\(home)/Library/Preferences", group: "Настройки"),
            Location(path: "\(home)/Library/Preferences/ByHost", group: "Настройки"),
            Location(path: "\(home)/Library/Containers", group: "Контейнеры", protected: true),
            Location(path: "\(home)/Library/Group Containers", group: "Контейнеры", byTeam: true, protected: true),
            Location(path: "\(home)/Library/Saved Application State", group: "Сохранённое состояние"),
            Location(path: "\(home)/Library/Logs", group: "Журналы", byName: true),
            Location(path: "\(home)/Library/HTTPStorages", group: "Кэш"),
            Location(path: "\(home)/Library/WebKit", group: "Кэш"),
            Location(path: "\(home)/Library/Cookies", group: "Cookies"),
            Location(path: "\(home)/Library/LaunchAgents", group: "Автозапуск"),
            Location(path: "\(home)/Library/Application Scripts", group: "Скрипты", byTeam: true),
            Location(path: "/Library/Application Support", group: "Данные приложения", byName: true),
            Location(path: "/Library/Caches", group: "Кэш", byName: true),
            Location(path: "/Library/Preferences", group: "Настройки"),
            Location(path: "/Library/Logs", group: "Журналы", byName: true),
            Location(path: "/Library/LaunchAgents", group: "Автозапуск"),
            Location(path: "/Library/LaunchDaemons", group: "Автозапуск"),
            Location(path: "/Library/PrivilegedHelperTools", group: "Служебные программы"),
            Location(path: "/var/db/receipts", group: "Квитанции установщика (только просмотр)", receipts: true),
        ]
        if let cache = userCacheDir() {
            list.append(Location(path: cache, group: "Кэш"))
        }
        return list
    }

    /// Папки данных, которые принадлежат системе или общим службам: по одному имени их не связываем с приложением.
    package static let systemNames: Set<String> = [
        "apple", "google", "microsoft", "adobe", "mozilla", "addressbook", "knowledge", "callhistorydb",
        "callhistorytransactions", "cloudstorage", "com.apple", "crashreporter", "diagnosticreports",
        "dock", "icloud", "mobilesync", "networkserviceproxy", "notes", "safari", "syncservices",
        "accounts", "assistant", "caches", "containers", "cookies", "keychains", "logs", "preferences",
        "saved application state", "webkit", "fontcollections", "colorpickers", "input methods",
    ]

    /// Другие установленные приложения того же разработчика (для пометки «общее»).
    /// `locations` — для тестов; по умолчанию стандартные папки.
    package static func scan(_ app: InstalledApp, others: [InstalledApp], locations: [Location]? = nil) -> [Leftover] {
        let manager = FileManager.default
        var result: [Leftover] = [
            Leftover(url: app.url, group: "Приложение", kind: .app, shared: false,
                     needsAdmin: !manager.isDeletableFile(atPath: app.url.path), sizeUnknown: false),
        ]
        let id = app.bundleID.lowercased()
        let name = app.name.lowercased()
        let parts = id.split(separator: ".")
        let family: String? = parts.count >= 4 ? parts.dropLast().joined(separator: ".") : nil
        let sameTeam = others.contains { $0.bundleID != app.bundleID && $0.teamID != nil && $0.teamID == app.teamID }
        var seen = Set<String>()

        for location in locations ?? Self.locations {
            guard let names = try? manager.contentsOfDirectory(atPath: location.path) else { continue }
            for entry in names {
                let lower = entry.lowercased()
                var matched = lower == id || lower.hasPrefix(id + ".") || lower.hasPrefix(id + "_")
                var shared = false
                var nameOnly = false
                // Точное имя папки — только для папок данных и не короче 3 символов; не системные имена.
                // Показываем, но не отмечаем: совпадение по имени не доказывает, что папка принадлежит этому приложению.
                if !matched, location.byName, name.count >= 3, lower == name, !Self.systemNames.contains(lower) {
                    matched = true
                    nameOnly = true
                }
                // Общая папка разработчика: «TEAMID.…».
                // Только если в имени есть bundle id или его «семейство» (без последней части,
                // не короче трёх частей: com.parallels.desktop) — иначе это чужие продукты разработчика.
                if !matched, location.byTeam, let team = app.teamID, entry.hasPrefix(team + ".") {
                    let rest = String(lower.dropFirst(team.count + 1))
                    if rest == id || rest.hasPrefix(id + ".") {
                        matched = true
                        // Если от этого разработчика есть ещё приложения — не отмечаем.
                        shared = sameTeam
                    } else if let family, rest == family || rest.hasPrefix(family + ".") {
                        matched = true
                        shared = true
                    }
                }
                guard matched else { continue }
                // «com.google.Chrome.canary» — это другое приложение, а не хвост «com.google.Chrome».
                if others.contains(where: {
                    let other = $0.bundleID.lowercased()
                    return other != id && other.count > id.count && (lower == other || lower.hasPrefix(other + "."))
                }) { continue }
                let url = URL(fileURLWithPath: location.path).appendingPathComponent(entry)
                guard seen.insert(url.path).inserted else { continue }
                result.append(Leftover(url: url, group: location.group,
                                       kind: location.receipts ? .receipt : .file,
                                       shared: shared,
                                       needsAdmin: !location.receipts && !manager.isDeletableFile(atPath: url.path),
                                       nameOnly: nameOnly,
                                       sizeUnknown: location.protected))
            }
        }
        return result
    }

    /// Размер файла или папки на диске (байты).
    package static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        guard values.isDirectory == true else { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                        options: [], errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func userCacheDir() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

import Foundation

/// Остановка служб (LaunchAgents/LaunchDaemons) перед переносом их plist в Корзину:
/// иначе служба работает до перезагрузки, хотя «удалена».
enum LaunchUnload {
    enum Domain: Equatable {
        case gui(uid_t)
        case system

        var name: String {
            switch self {
            case .gui(let uid): return "gui/\(uid)"
            case .system: return "system"
            }
        }
    }

    /// Домен службы по расположению plist; nil — это не plist службы. Расположение сверяется по родительской папке
    /// целиком (после `standardized`), а не по префиксу пути.
    static func domain(for url: URL, uid: uid_t = getuid(), home: String = NSHomeDirectory()) -> Domain? {
        guard url.pathExtension == "plist" else { return nil }
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        switch parent.path {
        case "/Library/LaunchDaemons": return .system
        case "/Library/LaunchAgents", home + "/Library/LaunchAgents": return .gui(uid)
        default:
            // Агент из бандла программы (SMAppService): `<программа>.app/Contents/Library/LaunchAgents`.
            let components = parent.pathComponents
            guard components.count >= 5, components.suffix(3) == ["Contents", "Library", "LaunchAgents"],
                  components[components.count - 4].hasSuffix(".app") else { return nil }
            return .gui(uid)
        }
    }

    /// plist агентов в бандле программы: программа регистрирует их сама (SMAppService), и после удаления бандла
    /// они работают до перезагрузки. Демоны из бандла сюда не входят: их остановка требует root.
    static func bundledAgents(in app: URL) -> [URL] {
        let folder = app.appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
    }

    /// Аргументы `launchctl` для остановки; nil — останавливать нечего.
    static func bootoutArguments(for url: URL, uid: uid_t = getuid(), home: String = NSHomeDirectory()) -> [String]? {
        domain(for: url, uid: uid, home: home).map { ["bootout", $0.name, url.standardizedFileURL.path] }
    }

    /// Код результата, если `launchctl` не уложился в срок.
    static let timedOut: Int32 = -2

    /// Остановка пользовательских служб (без root). Ошибка («не загружена») не мешает удалению. Возвращает код выхода по plist.
    @discardableResult
    static func bootoutUserServices(_ urls: [URL], uid: uid_t = getuid(), home: String = NSHomeDirectory(),
                                    launchctl: String = "/bin/launchctl", timeout: TimeInterval = 12) -> [URL: Int32] {
        var codes: [URL: Int32] = [:]
        for url in urls {
            guard let arguments = bootoutArguments(for: url, uid: uid, home: home), domain(for: url, uid: uid, home: home) != .system else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchctl)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                // Служба может не завершаться: ждём не дольше `timeout`, иначе удаление навсегда осталось бы «в работе».
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning {
                    process.terminate()
                    codes[url] = timedOut
                } else {
                    codes[url] = process.terminationStatus
                }
            } catch {
                codes[url] = -1
            }
        }
        return codes
    }

    /// Команды для скрипта root: остановка системных демонов. Каждая команда сама по себе не ломает цепочку.
    static func rootCommands(for urls: [URL], quote: (String) -> String) -> String {
        urls.compactMap { url -> String? in
            guard domain(for: url) == .system else { return nil }
            return "/bin/launchctl bootout system \(quote(url.standardizedFileURL.path)) >/dev/null 2>&1 || :; "
        }.joined()
    }

    /// Ждёт выхода процесса, но не дольше `attempts` проверок. `sleep` и `isTerminated` подменяются в тестах.
    static func waitForExit(attempts: Int, isTerminated: () -> Bool, sleep: () async -> Void) async -> Bool {
        for _ in 0..<attempts {
            if isTerminated() { return true }
            await sleep()
        }
        return isTerminated()
    }
}

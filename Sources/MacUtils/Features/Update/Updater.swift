// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// Автообновление из GitHub Releases: раз в несколько часов смотрит последний
/// релиз репозитория, скачивает MacUtils.zip, подменяет приложение и перезапускает его.
@MainActor
final class Updater: NSObject, ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date?

    private static let assetName = "MacUtils.zip"
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Репозиторий «владелец/имя»: из настроек или из Info.plist (его прописывает сборка на GitHub).
    var repository: String {
        let custom = UserDefaults.standard.string(forKey: Pref.updateRepo)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        return (Bundle.main.object(forInfoDictionaryKey: "MUUpdateRepo") as? String) ?? ""
    }

    // MARK: - Расписание

    func start() {
        let defaults = UserDefaults.standard
        if let updated = defaults.string(forKey: Pref.justUpdatedTo) {
            defaults.removeObject(forKey: Pref.justUpdatedTo)
            if updated == currentVersion {
                Toast.show("Mac Utils обновлён до \(updated)", symbol: "arrow.down.circle.fill", tint: .green)
            }
        }
        let timer = Timer(timeInterval: 6 * 3600, target: self, selector: #selector(scheduledCheck),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self.scheduledCheck()
        }
    }

    @objc private func scheduledCheck() {
        guard UserDefaults.standard.bool(forKey: Pref.autoUpdate) else { return }
        check(install: true, userInitiated: false)
    }

    // MARK: - Проверка

    func check(install: Bool, userInitiated: Bool) {
        switch state {
        case .checking, .installing: return
        default: break
        }
        let repo = repository
        guard repo.split(separator: "/").count == 2 else {
            if userInitiated { state = .failed("Укажите репозиторий в формате владелец/имя") }
            return
        }
        state = .checking
        Task { @MainActor in
            do {
                let release = try await Self.fetchLatest(repo: repo)
                self.lastCheck = Date()
                guard Self.isVersion(release.version, newerThan: self.currentVersion) else {
                    self.state = .upToDate
                    return
                }
                self.state = .available(release.version)
                if install {
                    try await self.install(release)
                }
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    func installAvailable() {
        if case .available = state {
            check(install: true, userInitiated: true)
        }
    }

    // MARK: - GitHub

    struct ReleaseInfo {
        let version: String
        let zipURL: URL
    }

    private struct ReleaseDTO: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease, assets
        }
    }

    private static func fetchLatest(repo: String) async throws -> ReleaseInfo {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError("Неверное имя репозитория")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacUtils-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw UpdateError("Релизы не найдены (репозиторий приватный или релизов ещё нет)")
        }
        guard status == 200 else { throw UpdateError("GitHub ответил \(status)") }
        let release = try JSONDecoder().decode(ReleaseDTO.self, from: data)
        guard let asset = release.assets.first(where: { $0.name == assetName }) else {
            throw UpdateError("В релизе нет файла \(assetName)")
        }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return ReleaseInfo(version: version, zipURL: asset.browserDownloadURL)
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Установка

    private func install(_ release: ReleaseInfo) async throws {
        state = .installing(release.version)
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("Нет прав на запись в \(parent.path)")
        }

        let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("Не удалось скачать обновление")
        }
        let bundleID = Bundle.main.bundleIdentifier
        let newApp = try await Task.detached(priority: .userInitiated) { () -> URL in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("MacUtilsUpdate-\(UUID().uuidString)")
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            try fm.moveItem(at: downloaded, to: zip)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            guard let app = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw UpdateError("В архиве нет приложения")
            }
            guard Bundle(url: app)?.bundleIdentifier == bundleID else {
                throw UpdateError("Архив содержит другое приложение")
            }
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", app.path])
            return app
        }.value

        // Скрипт ждёт выхода текущего процесса, заменяет бандл и запускает новую версию.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(Self.quote(target.path))
        /usr/bin/ditto \(Self.quote(newApp.path)) \(Self.quote(target.path))
        /usr/bin/xattr -dr com.apple.quarantine \(Self.quote(target.path)) 2>/dev/null
        /usr/bin/touch \(Self.quote(target.path))
        /usr/bin/open \(Self.quote(target.path))
        /bin/rm -rf \(Self.quote(newApp.deletingLastPathComponent().path))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()

        UserDefaults.standard.set(release.version, forKey: Pref.justUpdatedTo)
        AppSwitcher.shared.shutdown()
        NSApp.terminate(nil)
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) завершился с ошибкой \(process.terminationStatus)")
        }
    }

    /// Экранирование для sh: 'путь с пробелами'.
    nonisolated private static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

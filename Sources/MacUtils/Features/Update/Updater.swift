import AppKit
import Foundation
import Security

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
            } else {
                // Скрипт замены не отработал (процесс не вышел вовремя, нет прав): остались на старой версии.
                Toast.show("Обновление до \(updated) не установилось", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
        // Новая линейка версий — один раз показываем «Что нового».
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { WhatsNewWindowController.shared.showIfUpdated() }
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
        // Идёт запись или расшифровка — перезапуск всё оборвёт; попробуем через 10 минут.
        if MeetingRecorder.shared.state != .idle || ScreenRecorder.current != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
                MainActor.assumeIsolated { Updater.shared.scheduledCheck() }
            }
            return
        }
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
        // Список, а не /latest: в том же репозитории есть релизы Windows-версии — берём только Mac-релиз.
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20") else {
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
        return try parseRelease(data)
    }

    /// Первый подходящий Mac-релиз из ответа GitHub (список релизов).
    static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        let releases = try JSONDecoder().decode([ReleaseDTO].self, from: data)
        guard let release = releases.first(where: { release in
            !release.draft && !release.prerelease && release.tagName.hasPrefix("v")
                && release.assets.contains { $0.name == assetName }
        }), let asset = release.assets.first(where: { $0.name == assetName }) else {
            throw UpdateError("Релиз Mac Utils не найден")
        }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return ReleaseInfo(version: version, zipURL: asset.browserDownloadURL)
    }

    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
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
            throw UpdateError(MoveToApplications.isInApplications
                ? "Нет прав на запись в \(parent.path)"
                : "Перенесите Mac Utils в «Программы» и запустите оттуда — тогда он сможет обновляться")
        }

        let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("Не удалось скачать обновление")
        }
        let bundleID = Bundle.main.bundleIdentifier
        let staged = target.appendingPathExtension("new")
        let currentShort = currentVersion
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        do {
            // Требование — из запущенного кода, а не из бандла на диске, который мог измениться.
            let requirement = try Self.currentRequirement()
            let work = try await Task.detached(priority: .userInitiated) { () -> URL in
                let fm = FileManager.default
                let work = fm.temporaryDirectory.appendingPathComponent("MacUtilsUpdate-\(UUID().uuidString)")
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("update.zip")
                try fm.moveItem(at: downloaded, to: zip)
                let unpacked = work.appendingPathComponent("unpacked")
                try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
                guard let app = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isSymbolicLinkKey])
                    .first(where: { $0.pathExtension == "app" }) else {
                    throw UpdateError("В архиве нет приложения")
                }
                if (try? app.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                    throw UpdateError("В архиве символическая ссылка вместо приложения")
                }
                guard let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else {
                    throw UpdateError("Архив содержит другое приложение")
                }
                // Версия внутри бандла должна совпасть с релизом и быть новее: иначе подсунут старую подписанную сборку.
                try Self.checkVersions(bundleShort: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                       bundleBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                                       release: release.version, currentShort: currentShort, currentBuild: currentBuild)
                try Self.verifySignature(of: app, requirement: requirement)
                // Рядом с целью, чтобы последующая замена была переименованием на одном томе.
                try? fm.removeItem(at: staged)
                try Self.run("/usr/bin/ditto", [app.path, staged.path])
                // Карантин снимаем только у проверенной сборки, и копию, которая встанет на место, проверяем ещё раз.
                try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
                try Self.verifySignature(of: staged, requirement: requirement)
                return work
            }.value

            // Скрипт ждёт выхода текущего процесса, меняет бандлы местами с откатом и запускает новую версию.
            let script = Self.installScript(pid: ProcessInfo.processInfo.processIdentifier,
                                            target: target, staged: staged, work: work)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }

        UserDefaults.standard.set(release.version, forKey: Pref.justUpdatedTo)
        AppSwitcher.shared.shutdown()
        NSApp.terminate(nil)
    }

    /// Версия внутри скачанного бандла: совпадает с релизом, новее текущей, номер сборки больше текущего.
    nonisolated static func checkVersions(bundleShort: String?, bundleBuild: String?, release: String,
                                          currentShort: String, currentBuild: String?) throws {
        guard bundleShort == release else {
            throw UpdateError("Версия в архиве (\(bundleShort ?? "нет")) не совпадает с релизом \(release)")
        }
        guard isVersion(release, newerThan: currentShort) else {
            throw UpdateError("Версия \(release) не новее установленной \(currentShort)")
        }
        guard let bundleBuild, isVersion(bundleBuild, newerThan: currentBuild ?? "0") else {
            throw UpdateError("Номер сборки в архиве (\(bundleBuild ?? "нет")) не больше текущего (\(currentBuild ?? "0"))")
        }
    }

    /// Скрипт замены: `target` → `target.old`, `staged` → `target`; если второй `mv` не удался, старая версия возвращается.
    /// Ждёт выхода процесса не дольше `waitSeconds`: иначе убирает `staged` и ничего не меняет.
    nonisolated static func installScript(pid: Int32, target: URL, staged: URL, work: URL, waitSeconds: Int = 60) -> String {
        let old = quote(target.path + ".old")
        let target = quote(target.path)
        let staged = quote(staged.path)
        return """
        waited=0
        while /bin/kill -0 \(pid) 2>/dev/null; do
          /bin/sleep 0.2
          waited=$((waited + 1))
          if [ "$waited" -ge \(waitSeconds * 5) ]; then
            /bin/rm -rf \(staged) \(quote(work.path))
            exit 1
          fi
        done
        /bin/rm -rf \(old)
        if /bin/mv \(target) \(old); then
          if /bin/mv \(staged) \(target); then
            /bin/rm -rf \(old)
          else
            /bin/mv \(old) \(target)
            /bin/rm -rf \(staged)
          fi
        else
          /bin/rm -rf \(staged)
        fi
        /usr/bin/touch \(target)
        /usr/bin/open \(target)
        /bin/rm -rf \(quote(work.path))
        """
    }

    /// Designated requirement запущенного приложения. Ad-hoc сборка требует точного cdhash,
    /// поэтому проверить издателя обновления по ней нельзя — отказываем.
    nonisolated static func currentRequirement() throws -> SecRequirement {
        var selfCode: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError("Не удалось прочитать подпись текущей версии")
        }
        var text: CFString?
        if SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text,
           (text as String).hasPrefix("cdhash") {
            throw UpdateError("Текущая сборка подписана ad-hoc: проверить издателя обновления нельзя")
        }
        return requirement
    }

    /// То же по требованию бандла на диске (для тестов; в установке требование берётся из запущенного кода).
    nonisolated static func verifySignature(of app: URL, matchingBundleAt current: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError("Не удалось прочитать подпись текущей версии")
        }
        var text: CFString?
        if SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text,
           (text as String).hasPrefix("cdhash") {
            throw UpdateError("Текущая сборка подписана ad-hoc: проверить издателя обновления нельзя")
        }
        try verifySignature(of: app, requirement: requirement)
    }

    /// Бандл целостный и подписан по `requirement` (тот же издатель), без символических ссылок внутри.
    nonisolated static func verifySignature(of app: URL, requirement: SecRequirement) throws {
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError("Не удалось прочитать подпись обновления")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
                               | kSecCSCheckNestedCode | kSecCSRestrictSymlinks | kSecCSRestrictToAppLike)
        var failure: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(newCode, flags, requirement, &failure) == errSecSuccess else {
            let reason = failure?.takeRetainedValue().localizedDescription ?? "подпись не совпадает"
            throw UpdateError("Обновление подписано другим издателем или повреждено (\(reason))")
        }
    }

    nonisolated static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw UpdateError("\((tool as NSString).lastPathComponent) не ответил за \(Int(timeout)) с")
        }
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) завершился с ошибкой \(process.terminationStatus)")
        }
    }

    /// Экранирование для sh: 'путь с пробелами'.
    nonisolated static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

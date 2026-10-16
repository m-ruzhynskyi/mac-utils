import AppKit
import Foundation

/// Значок «Инструменты» в Программах: маленькое приложение внутри Mac Utils.app
/// (Contents/Resources/Инструменты.app), которое при запуске Mac Utils копируется
/// в /Applications (или ~/Applications) и обновляется вместе с ним.
enum ToolsLauncher {
    static let name = "Инструменты.app"

    enum Plan: Equatable { case ask, install, skip }

    /// Без согласия пользователя второе приложение в «Программы» не ставим.
    /// - согласие дано или уже есть установленный значок (поставила прежняя версия) → ставим/обновляем;
    /// - отказ → ничего; - ещё не спрашивали и значка нет → спросить (не больше `maxAsks` раз, если на вопрос не отвечали).
    static func plan(consent: Bool?, alreadyInstalled: Bool, asks: Int = 0) -> Plan {
        if let consent { return consent ? .install : .skip }
        if alreadyInstalled { return .install }
        return asks < maxAsks ? .ask : .skip
    }

    static let maxAsks = 3
    private static let asksKey = "toolsLauncherAsks"

    private static var installedCopies: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
            .map { $0.appendingPathComponent(name) }
    }

    @MainActor
    static func start() {
        let defaults = UserDefaults.standard
        let consent = defaults.object(forKey: Pref.toolsLauncherInstall) as? Bool
        let installed = installedCopies.contains { FileManager.default.fileExists(atPath: $0.path) }
        let asks = defaults.integer(forKey: asksKey)
        switch plan(consent: consent, alreadyInstalled: installed, asks: asks) {
        case .skip: return
        case .install: installIfNeeded()
        case .ask:
            // Не модальное окно: при запуске при входе оно возникало бы за чужими окнами или под набор текста.
            // Игнорированный вопрос повторяется при следующих запусках (до `maxAsks` раз), «Добавить» запоминается.
            defaults.set(asks + 1, forKey: asksKey)
            let token = Toast.show("Добавить значок «Инструменты» в «Программы»? Откроет панель Mac Utils из Launchpad и Spotlight.",
                                   symbol: "wrench.and.screwdriver.fill", tint: .accentColor,
                                   action: Toast.Action(title: "Добавить") {
                                       UserDefaults.standard.set(true, forKey: Pref.toolsLauncherInstall)
                                       installIfNeeded()
                                   },
                                   sticky: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { MainActor.assumeIsolated { Toast.dismiss(token: token) } }
        }
    }

    static func installIfNeeded() {
        let manager = FileManager.default
        guard let source = Bundle.main.resourceURL?.appendingPathComponent(name),
              manager.fileExists(atPath: source.path) else { return }
        let sourceVersion = version(of: source)
        let targets = [URL(fileURLWithPath: "/Applications"),
                       manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        // Уже установлен и той же версии — ничего не делаем.
        for folder in targets {
            let installed = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: installed.path) {
                if version(of: installed) == sourceVersion { return }
                if (try? replace(installed, with: source)) != nil { return }
            }
        }
        for folder in targets {
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? replace(folder.appendingPathComponent(name), with: source)) != nil {
                Log.window.info("Значок «Инструменты» установлен в \(folder.path, privacy: .public)")
                return
            }
        }
    }

    private static func version(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    private static func replace(_ target: URL, with source: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
        try manager.copyItem(at: source, to: target)
    }
}

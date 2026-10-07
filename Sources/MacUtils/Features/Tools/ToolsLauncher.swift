import Foundation

/// Значок «Инструменты» в Программах: маленькое приложение внутри Mac Utils.app
/// (Contents/Resources/Инструменты.app), которое при запуске Mac Utils копируется
/// в /Applications (или ~/Applications) и обновляется вместе с ним.
enum ToolsLauncher {
    static let name = "Инструменты.app"

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

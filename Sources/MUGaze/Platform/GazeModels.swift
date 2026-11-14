import CoreML
import Foundation

/// Пакеты моделей «Взгляда»: где лежат и куда компилируются.
enum GazeModels {
    /// В бандле (Contents/Resources/Models), а при запуске из .build — по переменной окружения (`MU_GAZE_MODEL`, `MU_GAZE_FACEMESH`).
    static func packageURL(name: String, env: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage", subdirectory: "Models") { return url }
        if let path = ProcessInfo.processInfo.environment[env] { return URL(fileURLWithPath: path) }
        return nil
    }

    /// Компиляция один раз (по дате пакета), дальше — из Application Support; старые версии удаляются.
    static func compiledURL(name: String, package: URL?, cacheDirectory: URL? = nil) throws -> URL? {
        guard let package else { return nil }
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: package.appendingPathComponent("Manifest.json").path)
        let stamp = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let dir = cacheDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Utils/Models", isDirectory: true)
        let target = dir.appendingPathComponent("\(name)-\(stamp).mlmodelc", isDirectory: true)
        if fm.fileExists(atPath: target.path) { return target }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = try MLModel.compileModel(at: package)
        // Старые версии — убрать.
        for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent.hasPrefix("\(name)-") {
            try? fm.removeItem(at: old)
        }
        try fm.moveItem(at: tmp, to: target)
        return target
    }
}

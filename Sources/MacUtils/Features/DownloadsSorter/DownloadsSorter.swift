import AppKit
import SwiftUI

/// Правила раскладки (без UI — для тестов).
enum DownloadsRules {
    enum Category: String, CaseIterable {
        case images = "Изображения"
        case documents = "Документы"
        case archives = "Архивы"
        case installers = "Установщики"
        case video = "Видео"
        case audio = "Аудио"
        case code = "Код"
    }

    private static let extensions: [Category: Set<String>] = [
        .images: ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "svg", "bmp", "tif", "tiff", "raw", "psd", "ico"],
        .documents: ["pdf", "doc", "docx", "txt", "rtf", "pages", "xls", "xlsx", "csv", "numbers", "key", "ppt", "pptx",
                     "md", "odt", "ods", "epub", "fb2", "djvu"],
        .archives: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"],
        .installers: ["dmg", "pkg", "mpkg", "iso", "app"],
        .video: ["mp4", "mov", "mkv", "avi", "webm", "m4v", "wmv", "flv"],
        .audio: ["mp3", "wav", "m4a", "flac", "aac", "ogg", "aiff", "opus"],
        .code: ["swift", "py", "js", "ts", "json", "html", "css", "sh", "java", "kt", "c", "cpp", "h", "go", "rs", "rb",
                "php", "sql", "yml", "yaml", "xml", "ipynb"],
    ]

    static func category(for url: URL) -> Category? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return Category.allCases.first { extensions[$0]?.contains(ext) == true }
    }

    /// Недокачанные файлы браузеров и служебные — не трогаем.
    static func isPartial(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        let partial: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]
        return partial.contains(url.pathExtension.lowercased())
    }

    /// Свободное имя в папке: «файл.pdf», «файл (2).pdf», «файл (3).pdf»…
    static func uniqueName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }

    /// Пора ли в Корзину: не менялся и не открывался дольше `days` дней.
    static func isExpired(modified: Date?, accessed: Date?, days: Int, now: Date = Date()) -> Bool {
        guard days > 0 else { return false }
        let last = [modified, accessed].compactMap { $0 }.max() ?? now
        return now.timeIntervalSince(last) > Double(days) * 86_400
    }
}

/// «Загрузки»: новые файлы раскладываются по папкам по типу, старые
/// (через N дней) уходят в Корзину. Безвозвратно ничего не удаляется.
@MainActor
final class DownloadsSorter: ObservableObject {
    static let shared = DownloadsSorter()

    @Published private(set) var isRunning = false
    @Published private(set) var lastResult: String?

    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var pending: DispatchWorkItem?

    var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.downloadsSort)
        source?.cancel()
        source = nil
        timer?.invalidate()
        timer = nil
        guard enabled else {
            isRunning = false
            return
        }
        // Следим за папкой: любое изменение — разложить через несколько секунд.
        let fd = open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { DownloadsSorter.shared.schedule() } }
            source.setCancelHandler { close(fd) }
            source.resume()
            self.source = source
        }
        // И раз в 10 минут — для тех, что докачались, и для чистки старых.
        let timer = Timer(timeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { _ = DownloadsSorter.shared.run() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        isRunning = source != nil
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { _ = DownloadsSorter.shared.run() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Разложить новые файлы и убрать старые. Возвращает (перемещено, в Корзину).
    @discardableResult
    func run(in root: URL? = nil, trashDays: Int? = nil) -> (moved: Int, trashed: Int) {
        let folder = root ?? self.folder
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .contentAccessDateKey, .isPackageKey]
        let categoryNames = Set(DownloadsRules.Category.allCases.map(\.rawValue))
        let now = Date()
        var moved = 0, trashed = 0

        let entries = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles])) ?? []
        for url in entries {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard !DownloadsRules.isPartial(url) else { continue }
            // Папки (кроме .app) не трогаем; свои папки категорий — тем более.
            if values?.isDirectory == true, values?.isPackage != true { continue }
            if categoryNames.contains(url.lastPathComponent) { continue }
            // Ещё пишется — подождём следующего раза.
            if let modified = values?.contentModificationDate, now.timeIntervalSince(modified) < 5 { continue }
            guard let category = DownloadsRules.category(for: url) else { continue }
            let target = folder.appendingPathComponent(category.rawValue, isDirectory: true)
            do {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                let existing = Set((try? manager.contentsOfDirectory(atPath: target.path)) ?? [])
                let name = DownloadsRules.uniqueName(url.lastPathComponent, existing: existing)
                try manager.moveItem(at: url, to: target.appendingPathComponent(name))
                moved += 1
            } catch {
                Log.window.error("Загрузки: не удалось переместить \(url.lastPathComponent, privacy: .public)")
            }
        }

        let days = trashDays ?? UserDefaults.standard.integer(forKey: Pref.downloadsTrashDays)
        if days > 0 {
            for category in DownloadsRules.Category.allCases {
                let dir = folder.appendingPathComponent(category.rawValue, isDirectory: true)
                for url in (try? manager.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles])) ?? [] {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    guard DownloadsRules.isExpired(modified: values?.contentModificationDate,
                                                   accessed: values?.contentAccessDate, days: days, now: now) else { continue }
                    if (try? manager.trashItem(at: url, resultingItemURL: nil)) != nil { trashed += 1 }
                }
            }
        }
        if moved > 0 || trashed > 0 {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            lastResult = "\(formatter.string(from: now)): разложено \(moved), в Корзину \(trashed)"
        }
        return (moved, trashed)
    }
}

struct DownloadsPage: View {
    @AppStorage(Pref.downloadsSort) private var enabled = false
    @AppStorage(Pref.downloadsTrashDays) private var days = 0
    @ObservedObject private var sorter = DownloadsSorter.shared

    var body: some View {
        Form {
            Section {
                Toggle("Раскладывать «Загрузки» по папкам", isOn: $enabled)
                Text("Новые файлы сами перемещаются в папки по типу: \(DownloadsRules.Category.allCases.map(\.rawValue).joined(separator: ", ")). Недокачанные файлы и ваши папки не трогаются.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Старые файлы") {
                Picker("Убирать в Корзину", selection: $days) {
                    Text("Никогда").tag(0)
                    Text("Через 7 дней").tag(7)
                    Text("Через 30 дней").tag(30)
                    Text("Через 90 дней").tag(90)
                }
                Text("Файлы в папках категорий, которые не открывали и не меняли дольше этого срока, перемещаются в Корзину — безвозвратно ничего не удаляется.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)
            Section {
                HStack {
                    Button("Разложить сейчас") {
                        let result = sorter.run()
                        Toast.show("Разложено: \(result.moved), в Корзину: \(result.trashed)", symbol: "folder.fill", tint: .green)
                    }
                    .disabled(!enabled)
                    Button("Открыть «Загрузки»") { NSWorkspace.shared.open(sorter.folder) }
                    Spacer()
                    if let result = sorter.lastResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Загрузки")
    }
}

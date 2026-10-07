import AVFoundation
import AppKit
import SwiftUI
import Vision

/// Запись в индексе: путь, день, программа и распознанный текст.
struct ShotRecord: Codable, Hashable, Identifiable {
    var path: String
    var date: Date
    var app: String
    var text: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    /// Запись экрана (MP4 или GIF), а не снимок.
    var isVideo: Bool { ShotLibraryRules.isVideo(url) }
}

/// Раскладка и поиск (без UI и диска — для тестов).
enum ShotLibraryRules {
    /// Папка снимка: «Снимки экрана/2026-10-07/Safari».
    static func folder(root: URL, date: Date, app: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return root.appendingPathComponent("Снимки экрана", isDirectory: true)
            .appendingPathComponent(formatter.string(from: date), isDirectory: true)
            .appendingPathComponent(sanitized(app), isDirectory: true)
    }

    static func sanitized(_ app: String) -> String {
        let cleaned = app.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Другое" : cleaned
    }

    /// Все слова запроса должны найтись в тексте, имени программы или дате.
    static func matches(_ record: ShotRecord, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let haystack = (record.text + " " + record.app + " " + formatter.string(from: record.date)
                        + " " + record.url.lastPathComponent).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Снимки и записи, которые можно забрать из корня папки: наши и системные.
    static func isCapture(_ name: String) -> Bool {
        let lower = name.lowercased()
        let media = ["png", "jpg", "jpeg", "heic", "gif", "mp4", "mov"].contains((lower as NSString).pathExtension)
        let prefixes = ["screenshot", "снимок экрана", "знімок екрана", "recording", "screen recording",
                        "запись экрана", "длинный снимок", "qr "]
        return media && prefixes.contains { lower.hasPrefix($0) }
    }

    static func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "gif"].contains(url.pathExtension.lowercased())
    }

    /// Похоже на системный снимок (⌘⇧3/4): «Screenshot …» / «Снимок экрана …».
    static func isSystemScreenshot(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".heic") else { return false }
        return lower.hasPrefix("screenshot") || lower.hasPrefix("снимок экрана") || lower.hasPrefix("знімок екрана")
    }
}

/// «Умная папка» снимков: свои снимки сохраняются по дням и программам, системные
/// (⌘⇧3/4) — по желанию тоже; текст на картинках распознаётся для поиска.
@MainActor
final class ScreenshotLibrary: ObservableObject {
    static let shared = ScreenshotLibrary()

    @Published private(set) var records: [ShotRecord] = []
    @Published private(set) var indexing = 0

    /// Программа, которая была впереди, когда начали снимок.
    var captureApp = ""

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?

    private static var indexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Mac Utils", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("screenshots.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let decoded = try? JSONDecoder().decode([ShotRecord].self, from: data) {
            records = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.screenshotLibrary) }

    func sync() {
        watcher?.cancel()
        watcher = nil
        // Один раз забираем то, что лежало в папке до умной папки.
        if enabled, !UserDefaults.standard.bool(forKey: Pref.screenshotLibraryImported) {
            UserDefaults.standard.set(true, forKey: Pref.screenshotLibraryImported)
            importExisting()
        }
        guard enabled, UserDefaults.standard.bool(forKey: Pref.screenshotLibrarySystem) else { return }
        let folder = Self.systemScreenshotFolder
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { ScreenshotLibrary.shared.collectSystemScreenshots() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        watchedFolder = folder
    }

    /// Куда macOS кладёт снимки ⌘⇧3/4 (com.apple.screencapture location, иначе Рабочий стол).
    static var systemScreenshotFolder: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
    }

    // MARK: - Сохранение

    /// Путь для нового снимка: в умной папке — по дню и программе.
    func destination(fileName: String, root: URL) -> URL {
        guard enabled else { return root.appendingPathComponent(fileName) }
        let folder = ShotLibraryRules.folder(root: root, date: Date(), app: captureApp)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(fileName)
    }

    /// Запомнить снимок и распознать текст в фоне.
    func add(_ url: URL, image: CGImage?, app: String, date: Date = Date()) {
        guard enabled else { return }
        let record = ShotRecord(path: url.path, date: date, app: ShotLibraryRules.sanitized(app), text: "")
        records.removeAll { $0.path == record.path }
        records.append(record)
        records.sort { $0.date > $1.date }
        save()
        indexing += 1
        let isVideo = record.isVideo
        Task.detached(priority: .utility) {
            // В видео текст не распознаём — ищутся по программе, дате и имени.
            let cgImage = isVideo ? nil : (image ?? NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let text = cgImage.map(TextRecognizer.recognize) ?? ""
            await MainActor.run {
                let library = ScreenshotLibrary.shared
                if let index = library.records.firstIndex(where: { $0.path == record.path }) {
                    library.records[index].text = text
                }
                library.indexing -= 1
                library.save()
            }
        }
    }

    /// Системные снимки с Рабочего стола (или их папки) — в умную папку.
    func collectSystemScreenshots() {
        guard enabled, let folder = watchedFolder else { return }
        let manager = FileManager.default
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Другое"
        for url in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where ShotLibraryRules.isSystemScreenshot(url.lastPathComponent) {
            let target = destination(fileName: url.lastPathComponent, root: Pref.screenshotDirectory)
            guard (try? manager.moveItem(at: url, to: target)) != nil else { continue }
            add(target, image: nil, app: app)
        }
    }

    /// Уже сохранённые снимки и записи из корня папки — в «Снимки экрана/дата/Другое».
    @discardableResult
    func importExisting(from root: URL = Pref.screenshotDirectory) -> Int {
        guard enabled else { return 0 }
        let manager = FileManager.default
        var count = 0
        let keys: Set<URLResourceKey> = [.creationDateKey, .isRegularFileKey]
        for url in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
            where ShotLibraryRules.isCapture(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }
            let date = values?.creationDate ?? Date()
            let folder = ShotLibraryRules.folder(root: root, date: date, app: "Другое")
            try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = Set((try? manager.contentsOfDirectory(atPath: folder.path)) ?? [])
            let target = folder.appendingPathComponent(DownloadsRules.uniqueName(url.lastPathComponent, existing: existing))
            guard (try? manager.moveItem(at: url, to: target)) != nil else { continue }
            add(target, image: nil, app: "Другое", date: date)
            count += 1
        }
        return count
    }

    func remove(_ record: ShotRecord) {
        try? FileManager.default.trashItem(at: record.url, resultingItemURL: nil)
        records.removeAll { $0.path == record.path }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }
}

// MARK: - Вид

struct ScreenshotLibraryView: View {
    @ObservedObject var library: ScreenshotLibrary
    var compact = false
    @State private var query = ""
    @State private var kind = 0
    @AppStorage(Pref.screenshotLibrary) private var enabled = true

    private var results: [ShotRecord] {
        library.records.filter {
            ShotLibraryRules.matches($0, query: query) && (kind == 0 || (kind == 2) == $0.isVideo)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Поиск по тексту на снимке, программе, дате", text: $query)
                Picker("", selection: $kind) {
                    Text("Все").tag(0)
                    Image(systemName: "photo").tag(1)
                    Image(systemName: "video").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: compact ? 110 : 140)
                .help("Все / снимки / видео")
                    .textFieldStyle(.roundedBorder)
                if library.indexing > 0 {
                    ProgressView().controlSize(.small).help("Распознаётся текст…")
                }
                Button {
                    NSWorkspace.shared.open(Pref.screenshotDirectory.appendingPathComponent("Снимки экрана"))
                } label: { Image(systemName: "folder") }
                .help("Открыть папку снимков")
            }
            .padding(compact ? 8 : 10)

            if !enabled {
                Text("Умная папка выключена — включите её в настройках «Снимки экрана».")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(library.records.isEmpty ? "Здесь появятся ваши снимки (⌘⇧X)" : "Ничего не найдено")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 104 : 150), spacing: 10)], spacing: 10) {
                        ForEach(results) { record in
                            ShotThumbnail(record: record, compact: compact)
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(record.url) }
                                .contextMenu {
                                    Button("Открыть") { NSWorkspace.shared.open(record.url) }
                                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.url]) }
                                    Button("Скопировать текст") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(record.text, forType: .string)
                                    }
                                    .disabled(record.text.isEmpty)
                                    Divider()
                                    Button("В Корзину") { library.remove(record) }
                                }
                        }
                    }
                    .padding(compact ? 8 : 12)
                }
            }
        }
    }
}

private struct ShotThumbnail: View {
    let record: ShotRecord
    let compact: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if record.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: compact ? 18 : 24))
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
            }
            .frame(height: compact ? 64 : 96)
            Text(record.app).font(.caption2.weight(.semibold)).lineLimit(1)
            Text(record.date, format: .dateTime.day().month().hour().minute())
                .font(.caption2).foregroundStyle(.secondary)
        }
        .help(record.text.isEmpty ? record.url.lastPathComponent : String(record.text.prefix(300)))
        .task(id: record.path) {
            let url = record.url
            if record.isVideo && url.pathExtension.lowercased() != "gif" {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 240)
                if let frame = try? await generator.image(at: .zero).image {
                    image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
                }
                return
            }
            image = await Task.detached(priority: .utility) {
                NSImage(contentsOf: url).flatMap { Self.thumbnail($0) }
            }.value
        }
    }

    nonisolated private static func thumbnail(_ image: NSImage) -> NSImage? {
        let side: CGFloat = 240
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size))
        thumb.unlockFocus()
        return thumb
    }
}

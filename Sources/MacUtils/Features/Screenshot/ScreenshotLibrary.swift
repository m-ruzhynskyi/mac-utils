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

    static func isExpired(_ record: ShotRecord, days: Int, now: Date = Date()) -> Bool {
        days > 0 && now.timeIntervalSince(record.date) > Double(days) * 86_400
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
    private var cleanupTimer: Timer?

    private static var indexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Mac Utils", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("screenshots.json")
    }

    /// Для тестов и снимков интерфейса: готовые записи, индекс на диске не читается.
    init(records: [ShotRecord]) {
        self.records = records
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
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        if enabled, UserDefaults.standard.integer(forKey: Pref.screenshotLibraryTrashDays) > 0 {
            removeExpired()
            let timer = Timer(timeInterval: 3600, repeats: true) { _ in
                MainActor.assumeIsolated { _ = ScreenshotLibrary.shared.removeExpired() }
            }
            RunLoop.main.add(timer, forMode: .common)
            cleanupTimer = timer
        }
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
                library.nameWithAI(record.path, text: text, app: record.app)
            }
        }
    }

    /// Умное имя по распознанному тексту (локальная модель); файл переименовывается.
    func nameWithAI(_ path: String, text: String, app: String) {
        guard Ollama.isOn(Pref.aiShotNames), text.count >= 12 else { return }
        Task {
            guard let name = try? await ShotNamer.name(for: text, app: app),
                  let index = records.firstIndex(where: { $0.path == path }),
                  let renamed = ShotNamer.renamed(URL(fileURLWithPath: path), to: name) else { return }
            records[index].path = renamed.path
            save()
            Log.ai.info("Снимок назван: \(renamed.lastPathComponent, privacy: .public)")
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
    /// Из папки снимков и из папки видео (если она своя).
    @discardableResult
    func importExisting() -> Int {
        let roots = Set([Pref.screenshotDirectory.standardizedFileURL, Pref.recordingDirectory.standardizedFileURL])
        return roots.reduce(0) { $0 + importExisting(from: $1) }
    }

    @discardableResult
    func importExisting(from root: URL) -> Int {
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

    /// Снимки и видео старше срока — в Корзину (безвозвратно ничего не удаляется).
    @discardableResult
    func removeExpired(now: Date = Date()) -> Int {
        let days = UserDefaults.standard.integer(forKey: Pref.screenshotLibraryTrashDays)
        guard days > 0 else { return 0 }
        let expired = records.filter { ShotLibraryRules.isExpired($0, days: days, now: now) }
        for record in expired {
            try? FileManager.default.trashItem(at: record.url, resultingItemURL: nil)
        }
        guard !expired.isEmpty else { return 0 }
        let paths = Set(expired.map(\.path))
        records.removeAll { paths.contains($0.path) }
        save()
        Log.capture.info("Умная папка: в Корзину \(expired.count) старых снимков и видео")
        return expired.count
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

    @ObservedObject private var semantic = SemanticShotSearch.shared

    private var results: [ShotRecord] {
        let words = semantic.words(for: query)
        return library.records.filter {
            (ShotLibraryRules.matches($0, query: query) || SemanticShotSearch.matches($0, words: words))
                && (kind == 0 || (kind == 2) == $0.isVideo)
        }
    }

    var body: some View {
        ToolsPageFrame(.shots, compact: compact) {
            VStack(spacing: compact ? DS.Space.s : DS.Space.m) {
                toolbar
                if !enabled {
                    EmptyState("Умная папка выключена", systemImage: "photo.on.rectangle.angled",
                               message: "Включите её в настройках «Снимки экрана».")
                } else if results.isEmpty {
                    EmptyState(library.records.isEmpty ? "Здесь появятся ваши снимки (⌘⇧X)" : "Ничего не найдено",
                               systemImage: "photo.on.rectangle.angled")
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 104 : 150), spacing: DS.Space.m)], spacing: DS.Space.m) {
                            ForEach(results) { record in
                                ShotThumbnail(record: record, compact: compact)
                                    .onTapGesture(count: 2) { NSWorkspace.shared.open(record.url) }
                                    .onDrag { NSItemProvider(contentsOf: record.url) ?? NSItemProvider() }
                                    .contextMenu {
                                        Button("Скопировать") { Self.copy(record) }
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
                        .padding(.vertical, compact ? 0 : DS.Space.xs)
                        .padding(.bottom, compact ? DS.Space.s : 0)
                    }
                }
            }
            .padding(.horizontal, compact ? DS.Space.m : 0)
            .padding(.top, compact ? DS.Space.s : 0)
        }
    }

    /// Поиск, фильтр (все / снимки / видео), прогресс распознавания и папка.
    private var toolbar: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                ToolsSearchField(prompt: "Поиск по тексту на снимке, программе, дате", text: $query)
                    .onChange(of: query) { _, value in semantic.expand(value) }
                if semantic.thinking {
                    Image(systemName: "sparkles").foregroundStyle(.dsAccText).help("Ищу по смыслу…")
                } else if !semantic.words(for: query).isEmpty {
                    Image(systemName: "sparkles").foregroundStyle(.dsMute)
                        .help("Ищу и по смыслу: " + semantic.words(for: query).joined(separator: ", "))
                }
            }
            HStack(spacing: DS.Space.s) {
                Chip("Все", selected: kind == 0) { kind = 0 }.help("Все")
                Chip("Снимки", selected: kind == 1) { kind = 1 }.help("Только снимки")
                Chip("Видео", selected: kind == 2) { kind = 2 }.help("Только видео")
                Spacer()
                if library.indexing > 0 {
                    ProgressView().controlSize(.small).help("Распознаётся текст…")
                }
                IconButton("Открыть папку снимков", systemImage: "folder", compact: true) {
                    NSWorkspace.shared.open(Pref.screenshotDirectory.appendingPathComponent("Снимки экрана"))
                }
            }
        }
    }
}

extension ScreenshotLibraryView {
    /// В буфер — и файл (вставка в Finder, Telegram, почту), и картинка (вставка в редакторы и чаты).
    static func copy(_ record: ShotRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [record.url as NSURL]
        if !record.isVideo, let image = NSImage(contentsOf: record.url) { objects.append(image) }
        pasteboard.writeObjects(objects)
        Toast.show("Скопировано", symbol: "doc.on.doc.fill")
    }
}

private struct ShotThumbnail: View {
    @State private var hovering = false

    let record: ShotRecord
    let compact: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            ZStack {
                Color.dsField
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                }
                if record.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: compact ? 20 : 26))
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
            }
            .frame(height: compact ? 64 : 96)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.dsLine, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    IconButton("Скопировать (или перетащите снимок куда нужно)", systemImage: "doc.on.doc", compact: true) {
                        ScreenshotLibraryView.copy(record)
                    }
                    .scaleEffect(0.8)
                    .padding(2)
                }
            }
            .onHover { hovering = $0 }
            Text(record.app).font(DS.Font.caption).foregroundStyle(.dsText).lineLimit(1)
            Text(record.date, format: .dateTime.day().month().hour().minute())
                .font(DS.Font.mono(11, relativeTo: .caption2)).foregroundStyle(.dsMute)
        }
        .padding(DS.Space.s)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
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

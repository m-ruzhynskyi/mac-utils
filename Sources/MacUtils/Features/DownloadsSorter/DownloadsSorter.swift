import AppKit
import SwiftUI

/// Правила раскладки (без UI — для тестов).
enum DownloadsRules {
    enum Category: String, CaseIterable {
        case images = "Images"
        case documents = "Documents"
        case archives = "Archives"
        case installers = "Installers"
        case video = "Video"
        case audio = "Audio"
        case code = "Code"

        /// Старые русские названия папок (до 1.2.88) — их содержимое переносится.
        var legacyName: String {
            switch self {
            case .images: return "Изображения"
            case .documents: return "Документы"
            case .archives: return "Архивы"
            case .installers: return "Установщики"
            case .video: return "Видео"
            case .audio: return "Аудио"
            case .code: return "Код"
            }
        }
    }

    /// Расширение без точки, в нижнем регистре: «.Sketch» → «sketch».
    static func normalizedExtension(_ ext: String) -> String {
        ext.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    /// Папка для файла: своё правило важнее встроенной категории.
    static func folderName(for url: URL, custom: [String: String]) -> String? {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, let folder = custom[ext]?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            // Полный путь — любая папка на диске; иначе — папка внутри «Загрузок».
            return folder.hasPrefix("/") ? folder : folder.replacingOccurrences(of: "/", with: "-")
        }
        return category(for: url)?.rawValue
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
    @Published private(set) var customRules: [String: String] = DownloadsSorter.customRules

    /// Свои правила: расширение → папка.
    nonisolated static var customRules: [String: String] {
        UserDefaults.standard.dictionary(forKey: Pref.downloadsCustomRules) as? [String: String] ?? [:]
    }

    func setRule(extension ext: String, folder: String?) {
        var rules = Self.customRules
        let key = DownloadsRules.normalizedExtension(ext)
        guard !key.isEmpty else { return }
        rules[key] = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
        if rules[key]?.isEmpty == true { rules[key] = nil }
        UserDefaults.standard.set(rules, forKey: Pref.downloadsCustomRules)
        customRules = rules
    }

    /// Типы файлов в «Загрузках», для которых нет ни категории, ни своего правила.
    func unknownExtensions() -> [(ext: String, count: Int)] {
        let custom = Self.customRules
        var counts: [String: Int] = [:]
        for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? [] {
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty, !DownloadsRules.isPartial(url),
                  DownloadsRules.folderName(for: url, custom: custom) == nil else { continue }
            counts[ext, default: 0] += 1
        }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    /// Русские папки прежних версий → английские (содержимое переносится).
    private static func migrateLegacyFolders(in folder: URL) {
        let manager = FileManager.default
        for category in DownloadsRules.Category.allCases {
            let legacy = folder.appendingPathComponent(category.legacyName, isDirectory: true)
            guard manager.fileExists(atPath: legacy.path) else { continue }
            let target = folder.appendingPathComponent(category.rawValue, isDirectory: true)
            if !manager.fileExists(atPath: target.path) {
                try? manager.moveItem(at: legacy, to: target)
                continue
            }
            for item in (try? manager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? [] {
                let existing = Set((try? manager.contentsOfDirectory(atPath: target.path)) ?? [])
                let name = DownloadsRules.uniqueName(item.lastPathComponent, existing: existing)
                try? manager.moveItem(at: item, to: target.appendingPathComponent(name))
            }
            if ((try? manager.contentsOfDirectory(atPath: legacy.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
                try? manager.removeItem(at: legacy)
            }
        }
    }

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
        let custom = Self.customRules
        Self.migrateLegacyFolders(in: folder)
        let categoryNames = Set(DownloadsRules.Category.allCases.map(\.rawValue))
            .union(custom.values.filter { !$0.hasPrefix("/") })
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
            guard let folderName = DownloadsRules.folderName(for: url, custom: custom) else { continue }
            let target = folderName.hasPrefix("/")
                ? URL(fileURLWithPath: folderName, isDirectory: true)
                : folder.appendingPathComponent(folderName, isDirectory: true)
            do {
                try manager.createDirectory(at: target, withIntermediateDirectories: true)
                let existing = Set((try? manager.contentsOfDirectory(atPath: target.path)) ?? [])
                let name = DownloadsRules.uniqueName(url.lastPathComponent, existing: existing)
                try manager.moveItem(at: url, to: target.appendingPathComponent(name))
                moved += 1
                if root == nil { DocumentTagger.shared.enqueue(target.appendingPathComponent(name)) }
            } catch {
                Log.window.error("Загрузки: не удалось переместить \(url.lastPathComponent, privacy: .public)")
            }
        }

        let days = trashDays ?? UserDefaults.standard.integer(forKey: Pref.downloadsTrashDays)
        if days > 0 {
            for name in categoryNames {
                let dir = folder.appendingPathComponent(name, isDirectory: true)
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
    @State private var newExtension = ""
    @State private var newFolder = ""
    @ObservedObject private var tagger = DocumentTagger.shared
    @State private var suggesting = false
    @State private var aiNote: String?
    @AppStorage(Pref.ai) private var aiEnabled = true
    @AppStorage(Pref.aiDownloads) private var aiDownloads = true

    private var aiOn: Bool { aiEnabled && aiDownloads }

    private func suggest() {
        let ext = DownloadsRules.normalizedExtension(newExtension)
        let samples = ((try? FileManager.default.contentsOfDirectory(atPath: sorter.folder.path)) ?? [])
            .filter { ($0 as NSString).pathExtension.lowercased() == ext }
        let existing = DownloadsRules.Category.allCases.map(\.rawValue) + Array(Set(sorter.customRules.values))
        suggesting = true
        aiNote = nil
        Task {
            defer { suggesting = false }
            do {
                newFolder = try await DownloadsAI.suggestFolder(ext: ext, samples: samples.isEmpty ? ["file.\(ext)"] : samples,
                                                                existing: existing)
                aiNote = "Предложено ИИ — проверьте и нажмите «Добавить»"
            } catch {
                aiNote = error.localizedDescription
            }
        }
    }

    /// «Lab» — папка в «Загрузках»; полный путь показываем как «~/Projects/Lab».
    static func folderTitle(_ value: String) -> String {
        guard value.hasPrefix("/") else { return "Загрузки/\(value)" }
        return (value as NSString).abbreviatingWithTildeInPath
    }

    static func askFolderName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Новая папка в «Загрузках»"
        alert.informativeText = "Как назвать папку?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Например, Lab"
        alert.accessoryView = field
        alert.addButton(withTitle: "Готово")
        alert.addButton(withTitle: "Отмена")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        return name.isEmpty ? nil : name
    }

    static func chooseFolder(start: URL) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    var body: some View {
        Form {
            Section {
                Toggle("Раскладывать «Загрузки» по папкам", isOn: $enabled)
                Text("Новые файлы сами перемещаются в папки по типу: \(DownloadsRules.Category.allCases.map(\.rawValue).joined(separator: ", ")) — и по вашим правилам ниже. Недокачанные файлы и ваши папки не трогаются.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Свои правила") {
                Text("Куда класть файлы других типов. Правило важнее встроенных категорий.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(sorter.customRules.keys.sorted(), id: \.self) { ext in
                    HStack(spacing: 8) {
                        Text(".\(ext)").monospaced()
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Label(Self.folderTitle(sorter.customRules[ext] ?? ""), systemImage: "folder")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { sorter.setRule(extension: ext, folder: nil) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Удалить правило")
                    }
                }
                HStack(spacing: 8) {
                    TextField("", text: $newExtension, prompt: Text("mdz"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 90)
                        .help("Расширение файла, без точки")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Menu {
                        ForEach(DownloadsRules.Category.allCases, id: \.self) { category in
                            Button(category.rawValue) { newFolder = category.rawValue }
                        }
                        Divider()
                        Button("Новая папка в «Загрузках»…") {
                            if let name = Self.askFolderName() { newFolder = name }
                        }
                        Button("Выбрать папку…") {
                            if let path = Self.chooseFolder(start: sorter.folder) { newFolder = path }
                        }
                    } label: {
                        Label(newFolder.isEmpty ? "Папка…" : Self.folderTitle(newFolder), systemImage: "folder")
                    }
                    .frame(maxWidth: 260)
                    Spacer()
                    Button("Добавить") {
                        sorter.setRule(extension: newExtension, folder: newFolder)
                        newExtension = ""
                        newFolder = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(DownloadsRules.normalizedExtension(newExtension).isEmpty || newFolder.isEmpty)
                }
                let unknown = sorter.unknownExtensions()
                if !unknown.isEmpty {
                    HStack(spacing: 6) {
                        Text("Сейчас без правила:").font(.caption).foregroundStyle(.secondary)
                        ForEach(unknown.prefix(6), id: \.ext) { item in
                            Button(".\(item.ext) (\(item.count))") { newExtension = item.ext }
                                .buttonStyle(.link).font(.caption)
                                .help("Подставить в поле")
                        }
                    }
                }
                if aiOn {
                    HStack(spacing: 8) {
                        Button {
                            suggest()
                        } label: {
                            Label("Предложить папку", systemImage: "sparkles")
                        }
                        .disabled(suggesting || DownloadsRules.normalizedExtension(newExtension).isEmpty)
                        .help("Локальная модель посмотрит на имена таких файлов и предложит папку")
                        if suggesting { ProgressView().controlSize(.small) }
                        if let aiNote {
                            Text(aiNote).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .disabled(!enabled)
            if aiEnabled && UserDefaults.standard.bool(forKey: Pref.aiDownloadsTags) {
                Section("Подписи файлов (ИИ)") {
                    Text("Каждому новому файлу при сортировке — короткая подпись по-английски в комментарии Spotlight: «📋 Spec — notch app for AI agents», «💿 Installer — Docker Desktop». Видно в ⌘I и в колонке «Комментарии», ищется через ⌘Пробел.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if tagger.pending > 0 {
                            ProgressView().controlSize(.small)
                            Text("Осталось \(tagger.pending), помечено \(tagger.tagged)").foregroundStyle(.secondary)
                        } else if tagger.tagged > 0 {
                            Text("Помечено документов: \(tagger.tagged)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Подписать уже лежащие") { tagger.tagExisting(in: sorter.folder) }
                            .disabled(tagger.pending > 0)
                    }
                }
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

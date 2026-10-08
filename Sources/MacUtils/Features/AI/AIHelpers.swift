import AppKit
import Darwin
import PDFKit

// MARK: - «Загрузки»: папка для неизвестного типа

enum DownloadsAI {
    /// Предложить папку для расширения по именам файлов. Ответ — короткое английское имя папки.
    static func suggestFolder(ext: String, samples: [String], existing: [String]) async throws -> String {
        let prompt = """
        В папке «Загрузки» есть файлы с расширением .\(ext), например: \(samples.prefix(5).joined(separator: ", ")).
        Существующие папки: \(existing.joined(separator: ", ")).
        Куда их класть? Выбери подходящую существующую папку или придумай новую — одно-два английских слова.
        Ответь JSON: {"folder": "...", "why": "кратко по-русски"}
        """
        let json = try await Ollama.generateJSON(prompt)
        guard let folder = (json["folder"] as? String).flatMap({ AIParsing.fileName(from: $0, maxLength: 40) }) else {
            throw Ollama.Failure(errorDescription: "Модель не предложила папку")
        }
        return folder
    }
}

// MARK: - Теги документов

/// Теги Finder для документов в «Загрузках»: «Счёт», «Договор», «Билет»… по имени и тексту.
@MainActor
final class DocumentTagger: ObservableObject {
    static let shared = DocumentTagger()

    /// Сколько документов ещё в очереди и сколько получили тег.
    @Published private(set) var pending = 0
    @Published private(set) var tagged = 0

    nonisolated static let tags = ["Счёт", "Чек", "Договор", "Билет", "Выписка", "Резюме", "Справка", "ТЗ",
                                     "Презентация", "Инструкция", "Отчёт", "Заметки", "Статья"]
    nonisolated static let extensions: Set<String> = ["pdf", "txt", "rtf", "doc", "docx", "pages", "odt", "md"]

    private var queue: [URL] = []
    private var working = false

    func enqueue(_ url: URL) {
        guard Ollama.isOn(Pref.aiDownloadsTags), Self.extensions.contains(url.pathExtension.lowercased()) else { return }
        queue.append(url)
        pending = queue.count + (working ? 1 : 0)
        next()
    }

    /// Уже лежащие документы: «Загрузки» и папка Documents (без тех, у кого тег уже есть).
    func tagExisting(in downloads: URL) {
        tagged = 0
        let manager = FileManager.default
        for folder in [downloads, downloads.appendingPathComponent(DownloadsRules.Category.documents.rawValue)] {
            for url in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.tagNamesKey],
                                                         options: [.skipsHiddenFiles])) ?? [] {
                let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
                guard !url.lastPathComponent.hasPrefix("~$"), !tags.contains(where: Self.tags.contains) else { continue }
                enqueue(url)
            }
        }
    }

    private func next() {
        guard !working, !queue.isEmpty else { return }
        working = true
        let url = queue.removeFirst()
        Task {
            if let tag = try? await Self.classify(url) {
                Self.addTag(tag, to: url)
                tagged += 1
            }
            working = false
            pending = queue.count
            next()
        }
    }

    nonisolated static func classify(_ url: URL) async throws -> String? {
        let text = await Task.detached(priority: .utility) { extractText(url, limit: 1500) }.value
        let prompt = """
        Файл: «\(url.lastPathComponent)».
        Начало текста: \(text.isEmpty ? "(нет текста)" : text)
        К какому типу относится документ? Варианты: \(tags.joined(separator: ", ")).
        «ТЗ» — техническое задание или требования к проекту. Если ни один не подходит точно — «нет».
        Ответь JSON: {"tag": "..."}
        """
        let json = try await Ollama.generateJSON(prompt)
        let tag = (json["tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tags.first { $0.lowercased() == tag.lowercased() }
    }

    /// Цвет метки Finder: 1 серый, 2 зелёный, 3 фиолетовый, 4 синий, 5 жёлтый, 6 красный, 7 оранжевый.
    nonisolated static func color(for tag: String) -> Int {
        switch tag {
        case "Счёт", "Чек", "Выписка": return 6
        case "Договор", "Справка": return 7
        case "Билет": return 2
        case "ТЗ", "Отчёт": return 4
        case "Резюме", "Презентация": return 3
        case "Инструкция", "Статья": return 5
        default: return 1
        }
    }

    private static let tagsAttribute = "com.apple.metadata:_kMDItemUserTags"

    /// Тег с цветом (через NSURL цвет не задать — пишем атрибут Finder напрямую), прежние теги сохраняются.
    static func addTag(_ tag: String, to url: URL) {
        var entries: [String] = []
        let size = getxattr(url.path, tagsAttribute, nil, 0, 0, 0)
        if size > 0 {
            var data = Data(count: size)
            _ = data.withUnsafeMutableBytes { getxattr(url.path, tagsAttribute, $0.baseAddress, size, 0, 0) }
            entries = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? []
        }
        entries.removeAll { $0 == tag || $0.hasPrefix(tag + "\n") }
        entries.append("\(tag)\n\(color(for: tag))")
        guard let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) else { return }
        _ = data.withUnsafeBytes { setxattr(url.path, tagsAttribute, $0.baseAddress, data.count, 0, 0) }
        Log.ai.info("Тег «\(tag, privacy: .public)»: \(url.lastPathComponent, privacy: .public)")
    }

    /// Текст документа: PDF — первые страницы, остальное — через NSAttributedString.
    nonisolated static func extractText(_ url: URL, limit: Int) -> String {
        var text = ""
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: url) {
            for index in 0..<min(document.pageCount, 3) {
                text += (document.page(at: index)?.string ?? "") + "\n"
                if text.count > limit { break }
            }
        } else if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            text = attributed.string
        }
        let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(compact.prefix(limit))
    }
}

// MARK: - Имена снимков

enum ShotNamer {
    /// Короткое имя по распознанному тексту: «Счёт за интернет», «Ошибка сборки Xcode».
    static func name(for text: String, app: String) async throws -> String? {
        let prompt = """
        Это текст, распознанный на снимке экрана из программы «\(app)»:
        \(String(text.prefix(1200)))

        Придумай короткое понятное имя файла для этого снимка: 2–5 обычных слов через пробел,         на языке текста, без даты, расширения и подчёркиваний. Например: «Счёт за интернет», «Ошибка сборки Xcode».
        Ответь JSON: {"name": "..."}
        """
        let json = try await Ollama.generateJSON(prompt, maxTokens: 60)
        return (json["name"] as? String).flatMap { AIParsing.fileName(from: AIParsing.spaced($0), maxLength: 50) }
    }

    /// «Снимок экрана 2026-10-07 в 20.15.03.png» → «Счёт за интернет 20.15.03.png».
    static func renamed(_ url: URL, to name: String) -> URL? {
        let base = url.deletingPathExtension().lastPathComponent
        let time = base.range(of: #"\d{1,2}[.:]\d{2}[.:]\d{2}"#, options: .regularExpression).map { String(base[$0]) }
        var candidate = [name, time].compactMap { $0 }.joined(separator: " ")
        let folder = url.deletingLastPathComponent()
        let manager = FileManager.default
        var index = 2
        while manager.fileExists(atPath: folder.appendingPathComponent(candidate).appendingPathExtension(url.pathExtension).path) {
            candidate = "\(name) \(time ?? "") \(index)".replacingOccurrences(of: "  ", with: " ")
            index += 1
        }
        let target = folder.appendingPathComponent(candidate).appendingPathExtension(url.pathExtension)
        return (try? manager.moveItem(at: url, to: target)) != nil ? target : nil
    }
}

// MARK: - Поиск снимков по смыслу

@MainActor
final class SemanticShotSearch: ObservableObject {
    static let shared = SemanticShotSearch()

    @Published private(set) var expansions: [String: [String]] = [:]
    @Published private(set) var thinking = false
    private var task: Task<Void, Never>?

    /// Связанные слова для запроса (рус. и англ.) — с задержкой, пока печатают.
    func expand(_ query: String) {
        task?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Ollama.isOn(Pref.aiShotSearch), query.count >= 3, expansions[query] == nil else { return }
        task = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            thinking = true
            defer { thinking = false }
            let prompt = """
            Пользователь ищет снимок экрана по запросу «\(query)». На снимке распознан текст.
            Перечисли до 12 слов и коротких фраз, которые вероятно есть в ТЕКСТЕ на таком снимке: \
            синонимы и связанные термины на русском и английском (не слова «скриншот», «экран»). \
            Ответь JSON: {"words": ["...", "..."]}
            """
            guard let json = try? await Ollama.generateJSON(prompt), !Task.isCancelled else { return }
            let generic: Set<String> = ["скриншот", "screenshot", "снимок", "снимок экрана", "экран", "screen", "image",
                                        "изображение", "картинка", "фото", "photo", "текст", "text"]
            let words = (json["words"] as? [String] ?? []).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 3 && !generic.contains($0) }
            expansions[query] = Array(words.prefix(12))
        }
    }

    func words(for query: String) -> [String] {
        expansions[query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? []
    }

    nonisolated static func matches(_ record: ShotRecord, words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let text = record.text.lowercased()
        return words.contains { text.contains($0) }
    }
}

// MARK: - Диспетчер задач

@MainActor
final class ProcessExplainer: ObservableObject {
    static let shared = ProcessExplainer()

    struct Info: Codable, Equatable {
        var category: String
        var what: String
        var safe: String
        var why: String
    }

    @Published private(set) var infos: [String: Info] = [:]
    @Published private(set) var categories: [String: String] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published private(set) var categorizing = false
    @Published var error: String?

    static let categoryNames = ["Система", "Программа", "Фоновая служба", "Разработка", "Драйвер", "Неизвестно"]

    init() {
        if let data = UserDefaults.standard.data(forKey: "aiProcessCategories"),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            categories = saved
        }
    }

    nonisolated static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
    }

    func explain(_ row: ProcessRow) {
        guard infos[row.name] == nil, !busy.contains(row.name) else { return }
        busy.insert(row.name)
        let path = Self.path(of: row.pid) ?? "неизвестно"
        Task {
            defer { busy.remove(row.name) }
            let prompt = """
            Это запущенный процесс на Mac: имя «\(row.name)», исполняемый файл \(path), пользователь \(row.user), \
            процессор \(String(format: "%.0f", row.cpu)) %, память \(row.memory / 1_048_576) МБ.
            Объясни по-русски простыми словами: что это и можно ли его завершить без вреда.
            Ответь JSON: {"category": одно из [\(Self.categoryNames.joined(separator: ", "))], \
            "what": "1–2 предложения", "safe": "да" | "осторожно" | "нет", "why": "1 предложение"}
            """
            do {
                let json = try await Ollama.generateJSON(prompt)
                let info = Info(category: json["category"] as? String ?? "Неизвестно",
                                what: json["what"] as? String ?? "",
                                safe: (json["safe"] as? String ?? "осторожно").lowercased(),
                                why: json["why"] as? String ?? "")
                infos[row.name] = info
                categories[row.name] = info.category
                saveCategories()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Категории сразу для многих процессов — по именам, пачками.
    func categorize(_ rows: [ProcessRow]) {
        guard !categorizing else { return }
        let names = Array(Set(rows.map(\.name).filter { categories[$0] == nil })).sorted()
        guard !names.isEmpty else { return }
        categorizing = true
        Task {
            defer { categorizing = false }
            for chunk in stride(from: 0, to: min(names.count, 160), by: 40).map({ Array(names[$0..<min($0 + 40, names.count)]) }) {
                let prompt = """
                Разнеси процессы macOS по категориям: \(Self.categoryNames.joined(separator: ", ")).
                Процессы: \(chunk.joined(separator: ", "))
                Ответь JSON: {"имя процесса": "категория", ...}
                """
                do {
                    let json = try await Ollama.generateJSON(prompt)
                    for (name, value) in json {
                        if let category = value as? String, chunk.contains(name) { categories[name] = category }
                    }
                    saveCategories()
                } catch {
                    self.error = error.localizedDescription
                    return
                }
            }
        }
    }

    private func saveCategories() {
        if let data = try? JSONEncoder().encode(categories) { UserDefaults.standard.set(data, forKey: "aiProcessCategories") }
    }
}

// MARK: - Очистка диска

@MainActor
final class CleanupAdvisor: ObservableObject {
    static let shared = CleanupAdvisor()

    enum Verdict: String {
        case safe, careful, keep
    }

    struct Advice: Equatable {
        var verdict: Verdict
        var reason: String
    }

    @Published private(set) var advice: [URL: Advice] = [:]
    @Published private(set) var working = false
    @Published private(set) var progress: String?
    @Published var error: String?

    /// Известные места — сразу, без модели.
    nonisolated static func known(_ url: URL) -> Advice? {
        let path = url.path
        let rules: [(String, Verdict, String)] = [
            ("/Xcode/DerivedData", .safe, "Сборки Xcode — пересоберутся"),
            ("/Xcode/iOS DeviceSupport", .careful, "Скачается заново при подключении устройства"),
            ("/Xcode/Archives", .keep, "Архивы приложений для App Store"),
            ("/CoreSimulator/Caches", .safe, "Кэш симулятора — пересоздастся"),
            ("/Library/Logs/", .safe, "Журналы — нужны только для диагностики"),
            ("/DiagnosticReports", .safe, "Отчёты о сбоях — нужны только для диагностики"),
            ("/Caches/Homebrew", .safe, "Скачанные пакеты Homebrew — скачаются заново"),
            ("/Caches/pip", .safe, "Кэш pip — скачается заново"),
            ("/Caches/Yarn", .safe, "Кэш Yarn — скачается заново"),
            ("/.npm/_cacache", .safe, "Кэш npm — скачается заново"),
            ("/Caches/com.spotify.client", .careful, "Офлайн-музыка Spotify скачается заново"),
            ("/Caches/Google", .safe, "Кэш браузера — пересоздастся"),
            ("/Caches/com.apple.Safari", .safe, "Кэш Safari — пересоздастся"),
        ]
        for (fragment, verdict, reason) in rules where path.contains(fragment) {
            return Advice(verdict: verdict, reason: reason)
        }
        return nil
    }

    func review(_ items: [CleanupItem]) {
        guard !working else { return }
        let candidates = items.filter { $0.category != .trash && advice[$0.url] == nil }.sorted { $0.size > $1.size }
        for item in candidates {
            if let known = Self.known(item.url) { advice[item.url] = known }
        }
        let unknown = Array(candidates.filter { advice[$0.url] == nil }.prefix(30))
        guard !unknown.isEmpty else { return }
        working = true
        error = nil
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Task {
            defer { working = false; progress = nil }
            // По одному: короткий ответ на каждый — быстро и без путаницы между пунктами.
            for (index, item) in unknown.enumerated() {
                progress = "Разбираю \(index + 1) из \(unknown.count)…"
                let prompt = """
                При очистке диска macOS найдено: \(item.url.path.replacingOccurrences(of: home, with: "~")) \
                (\(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))).
                Можно ли удалить это в Корзину? "safe" — безопасно, пересоздастся само; "careful" — можно, но что-то \
                потеряется (настройки, офлайн-данные, долгая пересборка); "keep" — лучше не трогать.
                Ответь JSON: {"verdict": "safe", "reason": "до 8 слов по-русски, про ЭТУ папку"}
                """
                do {
                    let json = try await Ollama.generateJSON(prompt, maxTokens: 60)
                    if let verdict = Verdict(rawValue: (json["verdict"] as? String ?? "").lowercased()) {
                        advice[item.url] = Advice(verdict: verdict, reason: json["reason"] as? String ?? "")
                    }
                } catch {
                    self.error = error.localizedDescription
                    return
                }
            }
        }
    }
}

// MARK: - Полка

struct ShelfGroup: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var files: [URL]
}

enum ShelfGrouper {
    static func group(_ files: [URL]) async throws -> [ShelfGroup] {
        let list = files.enumerated().map { "\($0.offset + 1). \($0.element.lastPathComponent)" }.joined(separator: "\n")
        let prompt = """
        Сгруппируй эти файлы по смыслу (проект, тема, тип задачи). 2–5 групп, короткие русские подписи.
        \(list)
        Ответь JSON: {"groups": [{"title": "...", "files": [1, 2]}]}
        """
        let json = try await Ollama.generateJSON(prompt)
        var used = Set<Int>()
        var groups: [ShelfGroup] = []
        for entry in json["groups"] as? [[String: Any]] ?? [] {
            let indexes = (entry["files"] as? [Int] ?? []).filter { $0 >= 1 && $0 <= files.count && !used.contains($0) }
            guard !indexes.isEmpty else { continue }
            used.formUnion(indexes)
            groups.append(ShelfGroup(title: entry["title"] as? String ?? "Группа", files: indexes.map { files[$0 - 1] }))
        }
        let rest = files.indices.filter { !used.contains($0 + 1) }.map { files[$0] }
        if !rest.isEmpty { groups.append(ShelfGroup(title: "Другое", files: rest)) }
        return groups
    }
}

import AppKit
import Darwin
import PDFKit
import MUCore
import MUAudio
import MUTextEditor

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

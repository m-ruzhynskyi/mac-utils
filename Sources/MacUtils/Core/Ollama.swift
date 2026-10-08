import AppKit

/// Разбор ответов модели (без сети — для тестов).
enum AIParsing {
    /// Первый JSON-объект в ответе: модели любят обрамлять его текстом или ```json.
    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let data = Data(text[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Имя файла из ответа: 2–6 слов, без кавычек, точек и запрещённых символов.
    static func fileName(from answer: String, maxLength: Int = 60) -> String? {
        var line = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        line = line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'«»`.")))
        for bad in ["/", ":", "\\", "*", "?", "<", ">", "|"] { line = line.replacingOccurrences(of: bad, with: " ") }
        line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if line.count > maxLength { line = String(line.prefix(maxLength)).trimmingCharacters(in: .whitespaces) }
        return line.count >= 2 ? line : nil
    }

    /// Ответ «как есть» без обрамляющих кавычек и пояснений вида «Исправленный текст:».
    static func cleanedText(_ answer: String) -> String {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Исправленный текст:", "Corrected text:", "Виправлений текст:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count > 1, let first = text.first, let last = text.last,
           (first == "\"" && last == "\"") || (first == "«" && last == "»") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    /// «ТекстовыеЗаметки» / «Счёт_Киевстар» → «Текстовые Заметки» / «Счёт Киевстар».
    static func spaced(_ name: String) -> String {
        var result = ""
        var previous: Character?
        for char in name.replacingOccurrences(of: "_", with: " ") {
            if let previous, char.isUppercase, previous.isLowercase { result.append(" ") }
            result.append(char)
            previous = char
        }
        return result
    }

    /// Регистр и пробелы по краям — как в исходном тексте (модель часто их теряет).
    static func keepingEdges(of original: String, _ fixed: String) -> String {
        let leading = original.prefix { $0.isWhitespace }
        let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return leading + fixed.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
    }
}

/// Локальная модель через Ollama (http://localhost:11434). Ничего не уходит в интернет.
@MainActor
final class Ollama: ObservableObject {
    static let shared = Ollama()

    enum Status: Equatable {
        case unknown, checking, ready, noServer, noModel
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var models: [String] = []
    @Published private(set) var pullProgress: Double?

    static var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.ai) }
    static var model: String { UserDefaults.standard.string(forKey: Pref.aiModel) ?? "qwen2.5:7b" }
    private static var base: URL {
        URL(string: UserDefaults.standard.string(forKey: Pref.aiURL) ?? "") ?? URL(string: "http://localhost:11434")!
    }

    /// Функция включена и в настройках ИИ, и отдельным переключателем.
    static func isOn(_ key: String) -> Bool { enabled && UserDefaults.standard.bool(forKey: key) }

    /// Загрузить модель в память заранее — первый запрос не ждёт 3–5 секунд загрузки.
    private var warmedModel: String?

    func warmUp() {
        guard Self.enabled, warmedModel != Self.model else { return }
        warmedModel = Self.model
        var request = URLRequest(url: Self.base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": Self.model, "keep_alive": "30m"])
        URLSession.shared.dataTask(with: request).resume()
    }

    func refresh() {
        status = .checking
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: Self.base.appendingPathComponent("api/tags"))
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let names = (json?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
                models = names
                status = Self.has(Self.model, in: names) ? .ready : .noModel
                if status == .ready { warmUp() }
            } catch {
                models = []
                status = .noServer
            }
        }
    }

    static func has(_ model: String, in names: [String]) -> Bool {
        names.contains(model) || names.contains(model + ":latest")
    }

    /// Запуск Ollama.app, если сервер не отвечает.
    func launchServer() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
            ?? URL(fileURLWithPath: "/Applications/Ollama.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            refresh()
        }
    }

    /// Скачать выбранную модель (ollama pull) с прогрессом.
    func pull() {
        guard pullProgress == nil else { return }
        pullProgress = 0
        let model = Self.model
        Task {
            var request = URLRequest(url: Self.base.appendingPathComponent("api/pull"))
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
            request.timeoutInterval = 3600
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                for try await line in bytes.lines {
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let total = json["total"] as? Double, let done = json["completed"] as? Double, total > 0 {
                        pullProgress = done / total
                    }
                }
            } catch {
                Log.ai.error("Ollama pull: \(error.localizedDescription)")
            }
            pullProgress = nil
            refresh()
        }
    }

    // MARK: - Запросы

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// Один ответ модели. json — просить строго JSON (format: "json").
    nonisolated static func generate(_ prompt: String, system: String? = nil, json: Bool = false,
                                     temperature: Double = 0.2, timeout: TimeInterval = 90,
                                     context: Int? = nil, maxTokens: Int = 600) async throws -> String {
        let (base, model) = await MainActor.run { (Self.base, Self.model) }
        var body: [String: Any] = [
            "model": model, "prompt": prompt, "stream": false, "keep_alive": "30m",
            "options": context.map { ["temperature": temperature, "num_ctx": $0, "num_predict": maxTokens] }
                ?? ["temperature": temperature, "num_predict": maxTokens],
        ]
        if let system { body["system"] = system }
        if json { body["format"] = "json" }
        var request = URLRequest(url: base.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(errorDescription: "Ollama не отвечает — запустите Ollama")
        }
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let message = reply?["error"] as? String {
            throw Failure(errorDescription: message.contains("not found") ? "Модель \(model) не скачана" : message)
        }
        guard let text = reply?["response"] as? String else { throw Failure(errorDescription: "Пустой ответ модели") }
        return text
    }

    /// Ответ-JSON, разобранный в словарь.
    nonisolated static func generateJSON(_ prompt: String, system: String? = nil,
                                         maxTokens: Int = 600) async throws -> [String: Any] {
        let text = try await generate(prompt, system: system, json: true, maxTokens: maxTokens)
        guard let object = AIParsing.jsonObject(in: text) else { throw Failure(errorDescription: "Модель ответила не JSON") }
        return object
    }
}

import AppKit
import Darwin
import PDFKit
import MUCore

package enum ShotNamer {
    /// Короткое имя по распознанному тексту: «Счёт за интернет», «Ошибка сборки Xcode».
    package static func name(for text: String, app: String) async throws -> String? {
        BackgroundAIQueue.shared.enter()
        defer { BackgroundAIQueue.shared.leave() }
        let prompt = """
        Это текст, распознанный на снимке экрана из программы «\(app)»:
        \(String(text.prefix(1200)))

        Придумай короткое понятное имя файла для этого снимка: 2–5 обычных слов через пробел,         на языке текста, без даты, расширения и подчёркиваний. Например: «Счёт за интернет», «Ошибка сборки Xcode».
        Ответь JSON: {"name": "..."}
        """
        let json = try await Ollama.generateJSON(prompt, maxTokens: 60, background: true)
        return (json["name"] as? String).flatMap { AIParsing.fileName(from: AIParsing.spaced($0), maxLength: 50) }
    }

    /// «Снимок экрана 2026-10-07 в 20.15.03.png» → «Счёт за интернет 20.15.03.png».
    package static func renamed(_ url: URL, to name: String) -> URL? {
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
@MainActor
package final class SemanticShotSearch: ObservableObject {
    package static let shared = SemanticShotSearch()

    @Published package private(set) var expansions: [String: [String]] = [:]
    @Published package private(set) var thinking = false
    private var task: Task<Void, Never>?

    /// Связанные слова для запроса (рус. и англ.) — с задержкой, пока печатают.
    package func expand(_ query: String) {
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

    package func words(for query: String) -> [String] {
        expansions[query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] ?? []
    }

    package nonisolated static func matches(_ record: ShotRecord, words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        let text = record.text.lowercased()
        return words.contains { text.contains($0) }
    }
}

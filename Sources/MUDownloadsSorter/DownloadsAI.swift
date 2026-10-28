import AppKit
import Darwin
import PDFKit
import MUCore

package enum DownloadsAI {
    /// Предложить папку для расширения по именам файлов. Ответ — короткое английское имя папки.
    package static func suggestFolder(ext: String, samples: [String], existing: [String]) async throws -> String {
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
/// Теги Finder для документов в «Загрузках»: «Счёт», «Договор», «Билет»… по имени и тексту.
@MainActor
package final class DocumentTagger: ObservableObject {
    package static let shared = DocumentTagger()

    /// Сколько документов ещё в очереди и сколько получили описание.
    @Published package private(set) var pending = 0
    @Published package private(set) var tagged = 0

    /// Типы файлов и их значки (подписи — по-английски, коротко).
    package nonisolated static let types: [(name: String, emoji: String)] = [
        ("Invoice", "🧾"), ("Receipt", "🧾"), ("Contract", "📄"), ("Ticket", "🎫"), ("Statement", "🏦"),
        ("Resume", "👤"), ("Certificate", "📃"), ("Spec", "📋"), ("Slides", "📊"), ("Manual", "📘"),
        ("Report", "📈"), ("Notes", "📝"), ("Article", "📰"), ("Screenshot", "📸"), ("Photo", "🖼️"),
        ("Image", "🖼️"), ("Design", "🎨"), ("Installer", "💿"), ("App", "🧩"), ("Archive", "🗜️"),
        ("Video", "🎬"), ("Audio", "🎵"), ("Code", "💻"), ("Data", "📑"), ("Font", "🔤"),
    ]
    package nonisolated static let otherEmoji = "📁"
    package nonisolated static let textExtensions: Set<String> = ["pdf", "txt", "rtf", "doc", "docx", "pages", "odt", "md", "csv",
                                                          "json", "html", "swift", "py", "js", "ts"]
    package nonisolated static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"]

    private var queue: [URL] = []
    private var working = false

    package func enqueue(_ url: URL) {
        guard Ollama.isOn(Pref.aiDownloadsTags), !queue.contains(url) else { return }
        queue.append(url)
        BackgroundAIQueue.shared.enter()
        pending = queue.count + (working ? 1 : 0)
        next()
    }

    /// Всё, что уже лежит: корень «Загрузок», папки категорий и свои папки правил.
    /// Описанные раньше по-русски — переписываются.
    package func tagExisting(in downloads: URL) {
        tagged = 0
        let manager = FileManager.default
        let custom = DownloadsSorter.customRules.values.filter { !$0.hasPrefix("/") }
        let folders = [downloads] + (DownloadsRules.Category.allCases.map(\.rawValue) + custom)
            .map { downloads.appendingPathComponent($0, isDirectory: true) }
        for folder in Set(folders) {
            for url in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                         options: [.skipsHiddenFiles])) ?? [] {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if values?.isDirectory == true, values?.isPackage != true { continue }
                guard !url.lastPathComponent.hasPrefix("~$"), !DownloadsRules.isPartial(url), !Self.hasDescription(url) else { continue }
                enqueue(url)
            }
        }
    }

    private func next() {
        guard !working, !queue.isEmpty else { return }
        working = true
        let url = queue.removeFirst()
        Task {
            if let comment = try? await Self.describe(url) {
                Self.setComment(comment, for: url)
                tagged += 1
            }
            BackgroundAIQueue.shared.leave()
            working = false
            pending = queue.count
            next()
        }
    }

    /// «📋 Spec — notch app for AI agents».
    package nonisolated static func describe(_ url: URL) async throws -> String? {
        let ext = url.pathExtension.lowercased()
        let text = await Task.detached(priority: .utility) { () -> String in
            if textExtensions.contains(ext) { return extractText(url, limit: 1200) }
            if imageExtensions.contains(ext),
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 25_000_000,
               let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return String(TextRecognizer.recognize(image).prefix(800))
            }
            return ""
        }.value
        // Документ без текста (скан) — тип не угадать, не выдумываем.
        if textExtensions.contains(ext), text.count < 40 { return nil }
        let prompt = """
        File name: "\(url.lastPathComponent)".
        \(text.isEmpty ? "No text content available — judge by the name and extension." : "Content start: \(text)")
        1) Type — exactly one of: \(types.map(\.name).joined(separator: ", ")), or "none". \
        "Spec" = technical specification / requirements.
        2) Summary — 1 to 3 English words, the most specific name (product, company, project), no type word, no period.
        Answer JSON: {"type": "...", "summary": "..."}
        """
        let json = try await Ollama.generateJSON(prompt, maxTokens: 60, background: true)
        let type = (json["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        var summary = (json["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Только латиница и не длиннее 3 слов; иначе — без описания.
        if summary.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil { summary = "" }
        // Тип уже стоит впереди — не повторяем его в описании.
        for filler in ["technical specification for ", "technical specification of ", "technical requirements for ",
                       "technical specification", "technical requirements", "specification for "]
            where summary.lowercased().hasPrefix(filler) {
            summary = String(summary.dropFirst(filler.count))
        }
        summary = summary.split(separator: " ").prefix(3).joined(separator: " ")
        return comment(type: types.first { $0.name.lowercased() == type }, summary: summary)
    }

    package nonisolated static func comment(type: (name: String, emoji: String)?, summary: String) -> String? {
        let summary = summary.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        switch (type, summary.isEmpty) {
        case let (type?, false): return "\(type.emoji) \(type.name) — \(summary)"
        case let (type?, true): return "\(type.emoji) \(type.name)"
        case (nil, false): return "\(otherEmoji) \(summary)"
        case (nil, true): return nil
        }
    }

    nonisolated private static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"

    package nonisolated static func comment(of url: URL) -> String? {
        let size = getxattr(url.path, commentAttribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(url.path, commentAttribute, $0.baseAddress, size, 0, 0) }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? String
    }

    package nonisolated static func hasDescription(_ url: URL) -> Bool {
        guard let comment = comment(of: url) else { return false }
        // Старые русские описания переписываем.
        return (types.map(\.emoji) + [otherEmoji]).contains { comment.hasPrefix($0) }
            && comment.range(of: "\\p{Cyrillic}", options: .regularExpression) == nil
    }

    /// Комментарий Spotlight (⌘I → «Комментарии»): через Finder, чтобы он был виден и в окне свойств;
    /// если Finder недоступен — напрямую в атрибут, который читает Spotlight.
    package static func setComment(_ comment: String, for url: URL) {
        let escaped = { (text: String) in text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "tell application \"Finder\" to set comment of (POSIX file \"\(escaped(url.path))\" as alias) to \"\(escaped(comment))\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if error != nil || Self.comment(of: url) != comment,
           let data = try? PropertyListSerialization.data(fromPropertyList: comment, format: .binary, options: 0) {
            _ = data.withUnsafeBytes { setxattr(url.path, commentAttribute, $0.baseAddress, data.count, 0, 0) }
        }
        Log.ai.info("Описание: \(url.lastPathComponent, privacy: .public)")
    }

    /// Текст документа: PDF — первые страницы, остальное — через NSAttributedString.
    package nonisolated static func extractText(_ url: URL, limit: Int) -> String {
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

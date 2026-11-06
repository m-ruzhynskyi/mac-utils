import AppKit
import CryptoKit
import Foundation

/// Разбор вывода whisper-cli (без процесса — для тестов).
package enum WhisperOutput {
    /// JSON из `whisper-cli -oj`: реплики с началом в миллисекундах.
    package static func lines(fromJSON data: Data, speaker: String) -> [TranscriptLine] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let segments = json["transcription"] as? [[String: Any]] else { return [] }
        return segments.compactMap { segment in
            let text = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNoise(text) else { return nil }
            let from = (segment["offsets"] as? [String: Any])?["from"] as? Double ?? 0
            return TranscriptLine(start: from / 1000, speaker: speaker, text: text)
        }
    }

    /// Типичные «галлюцинации» Whisper на тишине и музыке.
    package static func isNoise(_ text: String) -> Bool {
        let lower = text.lowercased()
        let noise = ["[музыка]", "[music]", "(музыка)", "субтитры", "продолжение следует", "дякую за перегляд",
                     "спасибо за просмотр", "thank you for watching", "[blank_audio]", "[тишина]"]
        return noise.contains { lower.contains($0) } || lower.allSatisfy { !$0.isLetter }
    }

    /// «progress = 37%» из stderr whisper-cli.
    package static func progress(in line: String) -> Int? {
        guard let range = line.range(of: #"progress\s*=\s*(\d+)%"#, options: .regularExpression) else { return nil }
        return Int(line[range].filter(\.isNumber))
    }

    /// ru_RU → ru, auto → auto.
    package static func language(_ setting: String) -> String {
        setting == "auto" ? "auto" : String(setting.prefix(2))
    }
}

/// Локальная расшифровка Whisper (whisper.cpp из Homebrew + модель large-v3-turbo).
/// Понимает украинский, русский и английский, сама определяет язык и ставит знаки препинания.
@MainActor
package final class Whisper: ObservableObject {
    package static let shared = Whisper()

    @Published package private(set) var downloadProgress: Double?
    @Published package private(set) var installing = false
    @Published package private(set) var message: String?

    package nonisolated static let modelName = "ggml-large-v3-turbo-q5_0.bin"
    package nonisolated static let vadName = "ggml-silero-v5.1.2.bin"
    /// Ревизии HuggingFace закреплены коммитом (не `main`), SHA-256 файлов — из метаданных этих ревизий (lfs.oid): файл, подменённый
    /// на сервере или по дороге, не пройдёт проверку и не дойдёт до `whisper-cli`.
    package nonisolated static let modelRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    package nonisolated static let vadRevision = "9ffd54a1e1ee413ddf265af9913beaf518d1639b"
    package nonisolated static let modelSHA256 = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    package nonisolated static let vadSHA256 = "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
    package nonisolated static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(modelRevision)/\(modelName)")!
    package nonisolated static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/\(vadRevision)/\(vadName)")!

    /// SHA-256 файла потоком (модель ~550 МБ в память не грузим).
    package nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    package nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Utils/whisper", isDirectory: true)
    }

    package nonisolated static var binary: URL? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    package nonisolated static var model: URL? {
        let url = folder.appendingPathComponent(modelName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    package nonisolated static var vad: URL? {
        let url = folder.appendingPathComponent(vadName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    package nonisolated static var isReady: Bool { binary != nil && model != nil }

    package nonisolated static var brew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Установка

    /// whisper.cpp через Homebrew (если нет) и модель (~550 МБ).
    package func install() {
        guard !installing else { return }
        installing = true
        message = nil
        Task {
            defer { installing = false }
            if Self.binary == nil {
                guard let brew = Self.brew else {
                    message = "Нужен Homebrew (brew.sh), затем: brew install whisper-cpp"
                    return
                }
                message = "Устанавливаю whisper.cpp…"
                let status = await Self.run(brew, ["install", "whisper-cpp"])
                guard status == 0, Self.binary != nil else {
                    message = "Не удалось установить whisper.cpp. В Терминале: brew install whisper-cpp"
                    return
                }
            }
            do {
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                if Self.vad == nil { try await download(Self.vadURL, to: Self.folder.appendingPathComponent(Self.vadName), sha256: Self.vadSHA256) }
                if Self.model == nil {
                    message = "Скачиваю модель…"
                    try await download(Self.modelURL, to: Self.folder.appendingPathComponent(Self.modelName), sha256: Self.modelSHA256)
                }
                message = nil
            } catch {
                message = "Не удалось скачать модель: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }

    private func download(_ source: URL, to target: URL, sha256 expected: String) async throws {
        downloadProgress = 0
        defer { downloadProgress = nil }
        let delegate = DownloadDelegate { value in
            Task { @MainActor in Whisper.shared.downloadProgress = value }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Transcriber.Failure(errorDescription: "Сервер вернул ошибку")
        }
        let actual = try await Task.detached(priority: .utility) { try Self.sha256(of: temporary) }.value
        guard actual == expected else {
            try? FileManager.default.removeItem(at: temporary)
            throw Transcriber.Failure(errorDescription: "Файл модели не прошёл проверку SHA-256")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
    }

    nonisolated private static func run(_ executable: URL, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["HOMEBREW_NO_AUTO_UPDATE": "1"]) { $1 }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
    }

    // MARK: - Расшифровка

    /// Дорожка → 16 кГц моно WAV → whisper-cli → реплики. progress — проценты.
    package nonisolated static func transcribe(_ url: URL, speaker: String, language: String,
                                       progress: @escaping @Sendable (Int) -> Void) async throws -> [TranscriptLine] {
        guard let binary, let model else { throw Transcriber.Failure(errorDescription: "Whisper не установлен") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacUtils-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let wav = work.appendingPathComponent("audio.wav")
        guard await run(URL(fileURLWithPath: "/usr/bin/afconvert"),
                        ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", url.path, wav.path]) == 0 else {
            throw Transcriber.Failure(errorDescription: "Не удалось подготовить звук для Whisper")
        }
        let output = work.appendingPathComponent("out")
        var arguments = ["-m", model.path, "-f", wav.path, "-l", WhisperOutput.language(language),
                         "-t", "\(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))",
                         "-oj", "-of", output.path, "-np", "-pp"]
        // VAD пропускает тишину: быстрее и без выдуманных фраз на паузах.
        if let vad { arguments += ["--vad", "--vad-model", vad.path] }

        let status: Int32 = await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                // Конец потока: снимаем обработчик, иначе он крутится без остановки до завершения процесса.
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                guard let line = String(data: data, encoding: .utf8) else { return }
                if let value = WhisperOutput.progress(in: line) { progress(value) }
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: process.terminationStatus)
            }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
        guard status == 0, let data = try? Data(contentsOf: output.appendingPathExtension("json")) else {
            throw Transcriber.Failure(errorDescription: "Whisper завершился с ошибкой (\(status))")
        }
        return WhisperOutput.lines(fromJSON: data, speaker: speaker)
    }
}

/// Прогресс скачивания модели.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    package let onProgress: @Sendable (Double) -> Void

    package init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    package func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    package func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

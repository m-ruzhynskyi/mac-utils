import AVFoundation
import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import Speech
import SwiftUI

/// Реплика расшифровки: кто и когда.
struct TranscriptLine: Equatable {
    var start: Double
    var speaker: String
    var text: String
}

/// Склейка и форматирование расшифровки (без UI — для тестов).
enum MeetingText {
    /// Реплики двух дорожек по времени; соседние реплики одного человека — вместе.
    static func merge(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        for line in lines.sorted(by: { $0.start < $1.start }) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = result.last, last.speaker == line.speaker, line.start - last.start < 60 {
                last.text += " " + text
                result[result.count - 1] = last
            } else {
                result.append(TranscriptLine(start: line.start, speaker: line.speaker, text: text))
            }
        }
        return result
    }

    static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func format(_ lines: [TranscriptLine]) -> String {
        lines.map { "[\(timestamp($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// Длинную расшифровку режем на куски по строкам, чтобы влезло в контекст модели.
    static func chunks(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// Запись созвона: звук системы (собеседники) и микрофон (вы) — отдельными дорожками,
/// затем локальная расшифровка и отчёт локальной моделью: итог, решения, задачи.
@MainActor
final class MeetingRecorder: NSObject, ObservableObject {
    static let shared = MeetingRecorder()

    struct Meeting: Identifiable, Hashable {
        let folder: URL
        var id: URL { folder }
        var title: String { folder.lastPathComponent }
        var report: URL { folder.appendingPathComponent("Отчёт.md") }
        var transcript: URL { folder.appendingPathComponent("Расшифровка.txt") }
        var hasReport: Bool { FileManager.default.fileExists(atPath: report.path) }
        var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcript.path) }
    }

    enum State: Equatable {
        case idle
        case recording(since: Date)
        case processing(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var lastError: String?

    private var stream: SCStream?
    private var writer: MeetingWriter?
    private var folder: URL?
    private var hud: NSPanel?

    static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Встречи", isDirectory: true)
    }

    func sync() {
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.meeting)
        if UserDefaults.standard.bool(forKey: Pref.meetings) {
            center.register(id: HotKeyID.meeting, keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) {
                MeetingRecorder.shared.toggle()
            }
        }
        reload()
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        meetings = folders.filter { $0.hasDirectoryPath }.map(Meeting.init).sorted { $0.title > $1.title }
    }

    func toggle() {
        switch state {
        case .idle: start()
        case .recording: stop()
        case .processing: break
        }
    }

    // MARK: - Запись

    func start() {
        guard state == .idle else { return }
        lastError = nil
        Task {
            do {
                try await begin()
                state = .recording(since: Date())
                showHUD()
                Toast.show("Записываю встречу. Остановить — ⌃⌥M", symbol: "record.circle", tint: .red)
            } catch {
                Log.audio.error("Встреча: не началась: \(error.localizedDescription, privacy: .public)")
                lastError = "Не удалось начать запись: \(error.localizedDescription)"
                Toast.show("Нет разрешения «Запись экрана» или микрофона", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    private func begin() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display,
                                     excludingApplications: content.applications.filter { $0.processID == ownPID },
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        // Видео не нужно — минимальный кадр раз в секунду.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        var mic = false
        if #available(macOS 15.0, *), UserDefaults.standard.bool(forKey: Pref.meetingsMicrophone) {
            config.captureMicrophone = true
            mic = true
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let folder = Self.root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writer = try MeetingWriter(folder: folder, microphone: mic)
        let stream = SCStream(filter: filter, configuration: config, delegate: writer)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        if #available(macOS 15.0, *), mic {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        try await stream.startCapture()
        self.stream = stream
        self.writer = writer
        self.folder = folder
    }

    func stop() {
        guard case .recording = state, let stream, let writer, let folder else { return }
        self.stream = nil
        self.writer = nil
        hud?.orderOut(nil)
        hud = nil
        state = .processing("Сохраняю запись…")
        Task {
            try? await stream.stopCapture()
            await writer.finish()
            reload()
            await process(Meeting(folder: folder))
        }
    }

    // MARK: - Готовый файл

    /// Расшифровать готовую запись (Zoom, Telegram, диктофон — аудио или видео).
    func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.prompt = "Расшифровать"
        panel.message = "Выберите запись встречи — аудио или видео"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url, state == .idle else { return }
        lastError = nil
        state = .processing("Готовлю звук…")
        Task {
            do {
                let folder = Self.root.appendingPathComponent(source.deletingPathExtension().lastPathComponent, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await Self.extractAudio(from: source, to: folder.appendingPathComponent("Собеседники.m4a"))
                reload()
                await process(Meeting(folder: folder))
            } catch {
                state = .idle
                lastError = "Не удалось прочитать звук: \(error.localizedDescription)"
            }
        }
    }

    /// Звуковая дорожка в M4A (из видео тоже).
    nonisolated static func extractAudio(from source: URL, to target: URL) async throws {
        try? FileManager.default.removeItem(at: target)
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if #available(macOS 15.0, *) {
            try await export.export(to: target, as: .m4a)
        } else {
            export.outputURL = target
            export.outputFileType = .m4a
            await export.export()
            if let error = export.error { throw error }
        }
    }

    // MARK: - Расшифровка и отчёт

    func process(_ meeting: Meeting) async {
        let tracks: [(file: String, speaker: String)] = [("Собеседники.m4a", "Собеседники"), ("Я.m4a", "Я")]
        do {
            var lines: [TranscriptLine] = []
            for track in tracks {
                let url = meeting.folder.appendingPathComponent(track.file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                state = .processing("Расшифровываю: \(track.speaker.lowercased())…")
                lines += try await Transcriber.transcribe(url, speaker: track.speaker)
            }
            Log.audio.info("Встреча: \(lines.count) реплик")
            let transcript = MeetingText.format(MeetingText.merge(lines))
            guard !transcript.isEmpty else {
                Log.audio.info("Встреча: речи не найдено")
                state = .idle
                lastError = "В записи не нашлось речи"
                Toast.show("В записи не нашлось речи", symbol: "waveform.slash", tint: .orange)
                return
            }
            try transcript.write(to: meeting.transcript, atomically: true, encoding: .utf8)
            if Ollama.isOn(Pref.meetingsReport) {
                state = .processing("Готовлю отчёт…")
                let report = try await Self.report(for: transcript)
                try ("# Встреча \(meeting.title)\n\n" + report).write(to: meeting.report, atomically: true, encoding: .utf8)
            }
            state = .idle
            reload()
            let target = meeting.hasReport ? meeting.report : meeting.transcript
            Toast.show(meeting.hasReport ? "Отчёт о встрече готов" : "Расшифровка готова", symbol: "doc.text.fill",
                       action: Toast.Action(title: "Открыть") { NSWorkspace.shared.open(target) })
        } catch {
            Log.audio.error("Встреча: \(error.localizedDescription, privacy: .public)")
            state = .idle
            lastError = error.localizedDescription
            reload()
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    static let reportSystem = """
    Ты секретарь встречи. По расшифровке созвона составь отчёт на русском в Markdown строго с разделами:
    ## Итог — 3–6 предложений о сути.
    ## Решения — что решили (без галочек, например «- Релиз в пятницу»).
    ## Задачи — только поручения: «- [ ] кто: что (срок, если назван)».
    ## Открытые вопросы — что осталось нерешённым.
    Пиши только то, что есть в расшифровке; если раздел пуст — «нет». «Я» — владелец записи.
    """

    /// Длинные встречи — сначала конспект по частям, затем общий отчёт.
    nonisolated static func report(for transcript: String) async throws -> String {
        let parts = MeetingText.chunks(transcript, limit: 12_000)
        if parts.count == 1 {
            return try await Ollama.generate(transcript, system: reportSystem, temperature: 0.2, timeout: 600, context: 16_384, maxTokens: 1500)
        }
        var notes: [String] = []
        for (index, part) in parts.enumerated() {
            let note = try await Ollama.generate(
                part, system: "Кратко законспектируй эту часть созвона (\(index + 1) из \(parts.count)) по-русски: "
                    + "о чём говорили, решения, задачи с исполнителями и сроками.",
                temperature: 0.2, timeout: 600, context: 16_384, maxTokens: 1500)
            notes.append("Часть \(index + 1):\n\(note)")
        }
        return try await Ollama.generate(notes.joined(separator: "\n\n"), system: reportSystem,
                                         temperature: 0.2, timeout: 600, context: 16_384, maxTokens: 1500)
    }

    // MARK: - Индикатор записи

    private func showHUD() {
        guard let screen = NSScreen.main else { return }
        let host = FirstMouseHostingView(rootView: MeetingHUD(recorder: self))
        let size = host.fittingSize
        let panel = HUDPanel(contentRect: NSRect(x: screen.visibleFrame.maxX - size.width - 16,
                                                 y: screen.visibleFrame.maxY - size.height - 12,
                                                 width: size.width, height: size.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.orderFrontRegardless()
        hud = panel
    }
}

private struct MeetingHUD: View {
    @ObservedObject var recorder: MeetingRecorder

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 9, height: 9)
            if case .recording(let since) = recorder.state {
                Text(since, style: .timer).monospacedDigit().font(.callout)
            }
            Button { recorder.stop() } label: { Image(systemName: "stop.fill") }
                .buttonStyle(.borderless)
                .help("Остановить и расшифровать (⌃⌥M)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .padding(2)
    }
}

// MARK: - Файлы дорожек

/// Две дорожки M4A с общей шкалой времени: звук системы и микрофон.
/// AVAudioFile пишет каждый кусок синхронно — ничего не теряется (AVAssetWriter в реальном
/// времени пропускал куски, когда был занят, и речь распознавалась обрывками).
final class MeetingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "macutils.meeting")
    private let urls: [SCStreamOutputType: URL]
    private var files: [SCStreamOutputType: AVAudioFile] = [:]
    private var start: CMTime?
    private var finished = false

    init(folder: URL, microphone: Bool) throws {
        var urls: [SCStreamOutputType: URL] = [.audio: folder.appendingPathComponent("Собеседники.m4a")]
        if #available(macOS 15.0, *), microphone { urls[.microphone] = folder.appendingPathComponent("Я.m4a") }
        self.urls = urls
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid, let url = urls[type],
              let description = sampleBuffer.formatDescription,
              let buffer = Self.pcm(from: sampleBuffer, description: description) else { return }
        let pts = sampleBuffer.presentationTimeStamp
        if start == nil { start = pts }
        do {
            if files[type] == nil {
                let format = buffer.format
                let file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVEncoderBitRateKey: 96_000,
                ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                files[type] = file
                // Дорожка началась позже другой — дополняем тишиной, чтобы реплики совпадали по времени.
                let lead = (pts - start!).seconds
                if lead > 0.05, let silence = AVAudioPCMBuffer(pcmFormat: format,
                                                               frameCapacity: AVAudioFrameCount(lead * format.sampleRate)) {
                    silence.frameLength = silence.frameCapacity
                    try file.write(from: silence)
                }
            }
            try files[type]?.write(from: buffer)
        } catch {
            Log.audio.error("Встреча: запись звука: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// CMSampleBuffer → AVAudioPCMBuffer (копия данных).
    private static func pcm(from sampleBuffer: CMSampleBuffer, description: CMFormatDescription) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.audio.error("Встреча: поток остановлен: \(error.localizedDescription, privacy: .public)")
    }

    func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finished = true
                // AVAudioFile закрывается и дописывает заголовок при освобождении.
                self.files.removeAll()
                continuation.resume()
            }
        }
    }
}

// MARK: - Локальная расшифровка

enum Transcriber {
    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static var locale: Locale {
        Locale(identifier: UserDefaults.standard.string(forKey: Pref.meetingsLanguage) ?? "ru_RU")
    }

    /// Расшифровка на устройстве: SpeechAnalyzer (macOS 26+), иначе SFSpeechRecognizer без сети.
    static func transcribe(_ url: URL, speaker: String) async throws -> [TranscriptLine] {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return try await analyze(url, speaker: speaker)
        }
        #endif
        return try await recognize(url, speaker: speaker)
    }

    #if compiler(>=6.2)
    /// SpeechTranscriber (лучше для длинной речи), а если язык он не знает (русский, украинский) —
    /// DictationTranscriber. Оба работают на устройстве.
    @available(macOS 26.0, *)
    private static func analyze(_ url: URL, speaker: String) async throws -> [TranscriptLine] {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                           attributeOptions: [.audioTimeRange])
            return try await run(module, results: module.results.map { ($0.range.start.seconds, String($0.text.characters)) },
                                 url: url, speaker: speaker)
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure(errorDescription: "Язык \(Self.locale.identifier) не поддерживается расшифровкой")
        }
        let module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                          reportingOptions: [], attributeOptions: [.audioTimeRange])
        return try await run(module, results: module.results.map { ($0.range.start.seconds, String($0.text.characters)) },
                             url: url, speaker: speaker)
    }

    @available(macOS 26.0, *)
    private static func run<Results: AsyncSequence & Sendable>(_ module: any SpeechModule, results: Results,
                                                               url: URL, speaker: String) async throws -> [TranscriptLine]
        where Results.Element == (Double, String) {
        // Языковая модель Apple скачивается один раз и дальше работает без сети.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: url)
        let collect = Task {
            var lines: [TranscriptLine] = []
            for try await (start, text) in results {
                lines.append(TranscriptLine(start: start, speaker: speaker, text: text))
            }
            return lines
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }
    #endif

    private static func recognize(_ url: URL, speaker: String) async throws -> [TranscriptLine] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure(errorDescription: "Нет разрешения на распознавание речи") }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw Failure(errorDescription: "Локальная расшифровка для этого языка недоступна")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    let lines = result.bestTranscription.segments.map {
                        TranscriptLine(start: $0.timestamp, speaker: speaker, text: $0.substring)
                    }
                    continuation.resume(returning: MeetingText.merge(lines))
                }
            }
        }
    }
}

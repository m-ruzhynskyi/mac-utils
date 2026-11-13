import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech
import MUCore
import MUCopilot

/// Настоящее слушание подсказчика: звук программы звонка (ScreenCaptureKit, только звук) и микрофон (с подавлением эха)
/// идут потоком в расшифровку на устройстве, две дорожки с метками «собеседник» / «вы».
/// Работает только между `start()` и `stop()`; `stop()` закрывает поток, микрофон и расшифровку — индикатор микрофона гаснет.
/// Ничего не пишется на диск.
@MainActor
final class LiveCopilotListener: NSObject, CopilotListening {
    var onFailure: (@MainActor (String) -> Void)?

    private var stream: SCStream?
    private var microphone: EchoFreeMicrophone?
    private var system: StreamingTranscriber?
    private var mine: StreamingTranscriber?
    private var tap: SystemAudioTap?
    private var task: Task<Void, Never>?
    private var generation = 0

    func start(language: String?, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {
        guard #available(macOS 26.0, *) else { throw CopilotError.notConnected("Расшифровка на устройстве (нужна macOS 26)") }
        generation += 1
        let mine = generation
        let locale = Locale(identifier: CopilotLocale.identifier(for: language))
        let system = StreamingTranscriber(locale: locale) { text in
            Task { @MainActor in onUtterance(Utterance(.other, text)) }
        }
        let me = StreamingTranscriber(locale: locale) { text in
            Task { @MainActor in onUtterance(Utterance(.me, text)) }
        }
        self.system = system
        self.mine = me
        // Всё долгое (модель, поток звука) — вне главного потока; ошибки приходят в `onFailure`.
        task = Task { [weak self] in
            do {
                try await system.start()
                try await me.start()
                guard let self, self.generation == mine, !Task.isCancelled else { return }
                try await self.beginCapture(system: system, mine: me)
            } catch {
                guard let self, self.generation == mine, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func beginCapture(system: StreamingTranscriber, mine: StreamingTranscriber) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CopilotError.noDisplay }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ownPID },
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        let tap = SystemAudioTap(transcriber: system) { [weak self] message in
            Task { @MainActor in self?.fail(message) }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: tap)
        try stream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: tap.queue)
        // Микрофон — с подавлением эха: голоса собеседников из динамиков не попадают в «вас».
        let mic = EchoFreeMicrophone { buffer, _ in mine.append(buffer) }
        try mic.start()
        do { try await stream.startCapture() } catch { mic.stop(); throw error }
        self.tap = tap
        self.stream = stream
        self.microphone = mic
        Log.ai.info("Подсказчик: слушаю звук звонка и микрофон")
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        microphone?.stop()
        microphone = nil
        let stream = self.stream
        self.stream = nil
        tap = nil
        Task { try? await stream?.stopCapture() }
        system?.finish()
        mine?.finish()
        system = nil
        mine = nil
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }
}

/// Принимает звук программ из ScreenCaptureKit и отдаёт в расшифровку.
private final class SystemAudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "mac-utils.copilot.system-audio")
    private let transcriber: StreamingTranscriber
    private let onFailure: @Sendable (String) -> Void

    init(transcriber: StreamingTranscriber, onFailure: @escaping @Sendable (String) -> Void) {
        self.transcriber = transcriber
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return }
        transcriber.append(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onFailure("Звук звонка остановился: \(error.localizedDescription)")
    }
}

/// Потоковая расшифровка на устройстве (SpeechAnalyzer, macOS 26): буферы звука → готовые фразы.
/// Для языков, которых нет у SpeechTranscriber (русский, украинский), — DictationTranscriber, как в записи встреч.
final class StreamingTranscriber: @unchecked Sendable {
    private let locale: Locale
    private let onText: @Sendable (String) -> Void
    private let lock = NSLock()
    /// `AsyncStream<AnalyzerInput>.Continuation` (тип доступен с macOS 26, поэтому хранится как `Any`).
    private var typed: Any?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var finishBlock: (@Sendable () -> Void)?
    private var accepting = false

    init(locale: Locale, onText: @escaping @Sendable (String) -> Void) {
        self.locale = locale
        self.onText = onText
    }

    func start() async throws {
        guard #available(macOS 26.0, *) else { throw CopilotError.notConnected("Расшифровка на устройстве (нужна macOS 26)") }
        try await startModern()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard #available(macOS 26.0, *) else { return }
        appendModern(buffer)
    }

    func finish() {
        lock.lock(); accepting = false; let block = finishBlock; finishBlock = nil; lock.unlock()
        block?()
    }

    // MARK: macOS 26

    @available(macOS 26.0, *)
    private func startModern() async throws {
        let module: any SpeechModule
        let results: AsyncThrowingStream<String, Error>
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let m = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
            module = m
            results = Self.texts(m.results.map { String($0.text.characters) })
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let m = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [], attributeOptions: [])
            module = m
            results = Self.texts(m.results.map { String($0.text.characters) })
        } else {
            throw CopilotError.notConnected("Язык \(locale.identifier) для расшифровки")
        }
        // Языковая модель Apple скачивается один раз, дальше работает без сети.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)
        let onText = self.onText
        let reader = Task {
            do {
                for try await text in results {
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { onText(t) }
                }
            } catch {}
        }
        lock.lock()
        self.targetFormat = format
        self.typed = continuation
        self.accepting = true
        self.finishBlock = {
            continuation.finish()
            reader.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
        lock.unlock()
    }

    @available(macOS 26.0, *)
    private var typedContinuation: AsyncStream<AnalyzerInput>.Continuation? { typed as? AsyncStream<AnalyzerInput>.Continuation }

    @available(macOS 26.0, *)
    private func appendModern(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting, let continuation = typedContinuation else { lock.unlock(); return }
        let target = targetFormat
        var converted = buffer
        if let target, target != buffer.format {
            if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
            if let converter, let out = Self.convert(buffer, with: converter, to: target) { converted = out } else { lock.unlock(); return }
        }
        lock.unlock()
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error || out.frameLength == 0 ? nil : out
    }

    private static func texts<S: AsyncSequence & Sendable>(_ source: S) -> AsyncThrowingStream<String, Error> where S.Element == String {
        AsyncThrowingStream { c in
            let task = Task {
                do { for try await t in source { c.yield(t) }; c.finish() } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

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
    var onActivity: (@MainActor () -> Void)?

    private var stream: SCStream?
    private var microphone: EchoFreeMicrophone?
    private var system: StreamingTranscriber?
    private var mine: StreamingTranscriber?
    private var tap: SystemAudioTap?
    private var task: Task<Void, Never>?
    private var generation = 0

    func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {
        guard #available(macOS 26.0, *) else { throw CopilotError.notConnected("Расшифровка на устройстве (нужна macOS 26)") }
        generation += 1
        let mine = generation
        let locale = Locale(identifier: CopilotLocale.identifier(for: language))
        let system = StreamingTranscriber(locale: locale, reactToPauses: reactToPauses) { text, span in
            Task { @MainActor in onUtterance(Utterance(.other, text, spoke: span)) }
        }
        let me = StreamingTranscriber(locale: locale, reactToPauses: reactToPauses) { text, span in
            Task { @MainActor in onUtterance(Utterance(.me, text, spoke: span)) }
        }
        let activity: @Sendable () -> Void = { [weak self] in Task { @MainActor in self?.onActivity?() } }
        system.onActivity = activity
        me.onActivity = activity
        self.system = system
        self.mine = me
        // Всё долгое (модель, поток звука) — вне главного потока; ошибки приходят в `onFailure`.
        task = Task { [weak self] in
            do {
                try await system.start()
                guard self?.generation == mine, !Task.isCancelled else { return }
                try await me.start()
                guard let self, self.generation == mine, !Task.isCancelled else { return }
                try await self.beginCapture(system: system, mine: me, token: mine)
            } catch {
                guard let self, self.generation == mine, !Task.isCancelled else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    /// `token` — номер включения. Между `await` подсказчик могли выключить (`stop()` увеличил `generation`): тогда всё,
    /// что успели открыть, закрывается здесь же — иначе микрофон и звук остались бы открыты при выключенном подсказчике.
    private func beginCapture(system: StreamingTranscriber, mine: StreamingTranscriber, token: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard generation == token else { return }
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
        // Сразу в свойства: `stop()` во время `startCapture` закроет микрофон.
        self.microphone = mic
        self.tap = tap
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            if generation == token { mic.stop(); microphone = nil; self.stream = nil; self.tap = nil }
            throw error
        }
        guard generation == token else {
            // Выключили, пока поток запускался: `stop()` мог позвать stopCapture раньше, чем он запустился.
            try? await stream.stopCapture()
            withExtendedLifetime(tap) {}
            return
        }
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
    private let onText: @Sendable (String, SpeechSpan?) -> Void
    /// Промежуточный текст изменился: кто-то говорит.
    var onActivity: (@Sendable () -> Void)?
    private let lock = NSLock()
    /// `AsyncStream<AnalyzerInput>.Continuation` (тип доступен с macOS 26, поэтому хранится как `Any`).
    private var typed: Any?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var finishBlock: (@Sendable () -> Void)?
    private var accepting = false
    /// `finish()` уже вызван: запуск, который ещё шёл (скачивание модели, старт анализатора), сам всё закроет.
    private var closed = false

    private let reactToPauses: Bool
    private var settler = VolatileSettler()
    private var ticker: Task<Void, Never>?

    init(locale: Locale, reactToPauses: Bool, onText: @escaping @Sendable (String, SpeechSpan?) -> Void) {
        self.locale = locale
        self.reactToPauses = reactToPauses
        self.onText = onText
    }

    /// SpeechAnalyzer — только в SDK macOS 26 (Swift 6.2+): на CI с SDK macOS 15 этот код не собирается, как и в записи встреч.
    func start() async throws {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return try await startModern() }
        #endif
        throw CopilotError.notConnected("Расшифровка на устройстве (нужна macOS 26)")
    }

    /// Модель расшифровки для языка уже установлена (проверка без скачивания: реплей не меняет систему).
    static func modelInstalled(for locale: Locale) async -> Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
                let m = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                return await AssetInventory.status(forModules: [m]) == .installed
            }
            if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
                let m = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
                return await AssetInventory.status(forModules: [m]) == .installed
            }
        }
        #endif
        return false
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { appendModern(buffer) }
        #endif
    }

    func finish() {
        lock.lock(); closed = true; accepting = false; let block = finishBlock; finishBlock = nil; let ticker = self.ticker; self.ticker = nil; lock.unlock()
        ticker?.cancel()
        block?()
    }

    // MARK: macOS 26

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func startModern() async throws {
        let module: any SpeechModule
        let results: AsyncThrowingStream<(String, Bool), Error>
        // С реакцией на паузу просим и промежуточный текст: он приходит раньше финала.
        let reporting: Set<SpeechTranscriber.ReportingOption> = reactToPauses ? [.volatileResults, .fastResults] : []
        let dictationReporting: Set<DictationTranscriber.ReportingOption> = reactToPauses ? [.volatileResults, .frequentFinalization] : []
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let m = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: reporting, attributeOptions: [])
            module = m
            results = Self.texts(m.results.map { (String($0.text.characters), $0.isFinal) })
        } else if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            let m = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: dictationReporting, attributeOptions: [])
            module = m
            results = Self.texts(m.results.map { (String($0.text.characters), $0.isFinal) })
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
        let reader = Task { [weak self] in
            do {
                for try await (text, isFinal) in results { self?.receive(text, isFinal: isFinal) }
            } catch {}
        }
        let ticker: Task<Void, Never>? = reactToPauses ? Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self else { return }
                self.tick()
            }
        } : nil
        lock.lock()
        if closed {
            // Подсказчик выключили, пока шёл запуск: ничего не оставляем работать.
            lock.unlock()
            continuation.finish()
            reader.cancel()
            ticker?.cancel()
            await analyzer.cancelAndFinishNow()
            return
        }
        self.ticker = ticker
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

    #endif

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

    /// Текст от расшифровки: без реакции на паузу — только финалы; с ней — новые слова после паузы ≥ 0,7 с и остаток финала.
    /// `date` — момент прихода текста; в реплее аудиофайлов время виртуальное.
    func receive(_ text: String, isFinal: Bool, at date: Date = Date()) {
        var out: String?
        var span: SpeechSpan?
        if !reactToPauses {
            if isFinal { out = text }
        } else {
            lock.lock()
            if isFinal { out = settler.final(text); span = settler.lastSpan } else { settler.volatile(text, at: date) }
            lock.unlock()
            if !isFinal { onActivity?() }
        }
        if let t = out?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { onText(t, span) }
    }

    func tick(at date: Date = Date()) {
        lock.lock(); let out = settler.tick(at: date); let span = settler.lastSpan; lock.unlock()
        if let out, !out.isEmpty { onText(out, span) }
    }

    private static func texts<S: AsyncSequence & Sendable>(_ source: S) -> AsyncThrowingStream<(String, Bool), Error> where S.Element == (String, Bool) {
        AsyncThrowingStream { c in
            let task = Task {
                do { for try await t in source { c.yield(t) }; c.finish() } catch { c.finish(throwing: error) }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
}

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

    var onListenFailure: (@MainActor (CopilotListenFailure) -> Void)?

    /// Как идёт расшифровка (для самопроверки): путь, язык, установлена ли модель SpeechAnalyzer.
    var transcription: (path: CopilotTranscriptionPath?, language: String, modelInstalled: Bool?)? {
        system.map { ($0.path, $0.language, $0.modelInstalled) }
    }
    /// Открыты ли микрофон и звук звонка (самопроверка после выключения).
    var isCapturing: Bool { microphone != nil || stream != nil }

    func start(language: String?, reactToPauses: Bool, onUtterance: @escaping @MainActor (Utterance) -> Void) throws {
        // Микрофон уже запрещён — сразу понятная причина. Не спрошен — Mac спросит сам, когда человек включает подсказчика.
        if Permissions.microphone == .denied { throw CopilotListenFailure.microphoneDenied }
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
        let broke: @Sendable (CopilotListenFailure) -> Void = { [weak self] reason in Task { @MainActor in self?.fail(reason) } }
        system.onActivity = activity
        me.onActivity = activity
        system.onFailure = broke
        me.onFailure = broke
        self.system = system
        self.mine = me
        // Всё долгое (разрешения, модель, поток звука) — вне главного потока; ошибки приходят в `onListenFailure`.
        task = Task { [weak self] in
            do {
                if Permissions.microphone == .notAsked, !(await AVCaptureDevice.requestAccess(for: .audio)) {
                    throw CopilotListenFailure.microphoneDenied
                }
                try await system.start()
                guard self?.generation == mine, !Task.isCancelled else { return }
                try await me.start()
                guard let self, self.generation == mine, !Task.isCancelled else { return }
                try await self.beginCapture(system: system, mine: me, token: mine)
            } catch {
                guard let self, self.generation == mine, !Task.isCancelled else { return }
                self.fail(error as? CopilotListenFailure ?? .other(error.localizedDescription))
            }
        }
    }

    /// `token` — номер включения. Между `await` подсказчик могли выключить (`stop()` увеличил `generation`): тогда всё,
    /// что успели открыть, закрывается здесь же — иначе микрофон и звук остались бы открыты при выключенном подсказчике.
    private func beginCapture(system: StreamingTranscriber, mine: StreamingTranscriber, token: Int) async throws {
        // Звук звонка — через «Запись экрана и системного звука»: нет доступа — понятная причина, а не текст ошибки системы.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CGPreflightScreenCaptureAccess() ? error : CopilotListenFailure.screenAudioDenied
        }
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
            Task { @MainActor in self?.fail(.other(message)) }
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

    private func fail(_ reason: CopilotListenFailure) {
        stop()
        if let onListenFailure { onListenFailure(reason) } else { onFailure?(reason.message) }
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

/// Потоковая расшифровка на устройстве: буферы звука → готовые фразы.
/// - SpeechAnalyzer (macOS 26, сборка на SDK 26): SpeechTranscriber, а для языков, которых у него нет (русский, украинский), —
///   DictationTranscriber, как в записи встреч. Модель только проверяется: скачивается по кнопке «Загрузить» (`downloadModel`).
/// - Запасной путь: SFSpeechRecognizer только на устройстве (`requiresOnDeviceRecognition`, без облака) — если кода SpeechAnalyzer
///   нет в сборке (так было в 1.11.1: SDK 15.5), его модель не скачана или он не знает язык.
/// Выбор — `CopilotTranscriptionPath.choose`.
final class StreamingTranscriber: @unchecked Sendable {
    private let locale: Locale
    private let onText: @Sendable (String, SpeechSpan?) -> Void
    /// Промежуточный текст изменился: кто-то говорит.
    var onActivity: (@Sendable () -> Void)?
    /// Расшифровка сама остановилась (запасной путь не перезапускается).
    var onFailure: (@Sendable (CopilotListenFailure) -> Void)?
    private let lock = NSLock()
    /// `AsyncStream<AnalyzerInput>.Continuation` (тип доступен с macOS 26, поэтому хранится как `Any`).
    private var typed: Any?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var finishBlock: (@Sendable () -> Void)?
    private var accepting = false
    /// `finish()` уже вызван: запуск, который ещё шёл (старт анализатора), сам всё закроет.
    private var closed = false

    private let reactToPauses: Bool
    private var settler = VolatileSettler()
    private var ticker: Task<Void, Never>?

    // Запасной путь (SFSpeechRecognizer).
    private var recognizer: SFSpeechRecognizer?
    private var sfRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sfTask: SFSpeechRecognitionTask?
    private var sfRestarts: [Date] = []

    /// Выбранный путь после `start()`; язык — код (ru, uk, en…); модель SpeechAnalyzer установлена (nil — не проверялась).
    private(set) var path: CopilotTranscriptionPath?
    private(set) var modelInstalled: Bool?
    var language: String { Self.languageCode(locale) }

    init(locale: Locale, reactToPauses: Bool, onText: @escaping @Sendable (String, SpeechSpan?) -> Void) {
        self.locale = locale
        self.reactToPauses = reactToPauses
        self.onText = onText
    }

    static func languageCode(_ locale: Locale) -> String { locale.language.languageCode?.identifier ?? locale.identifier }

    /// Код SpeechAnalyzer есть в этой сборке (SDK macOS 26, Swift 6.2+) и система — macOS 26+.
    static var analyzerBuilt: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    func start() async throws {
        let model = await Self.modelState(for: locale)
        modelInstalled = model.map { $0 == .installed }
        let onDevice = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
        switch CopilotTranscriptionPath.choose(analyzerBuilt: Self.analyzerBuilt, model: model, onDeviceSFSpeech: onDevice,
                                               language: language) {
        case .failure(let reason):
            throw reason
        case .success(let chosen):
            path = chosen
            Log.ai.info("Подсказчик: расшифровка — \(chosen.rawValue, privacy: .public), язык \(self.language, privacy: .public), модель \(model.map { "\($0)" } ?? "нет", privacy: .public)")
            switch chosen {
            case .speechAnalyzer:
                #if compiler(>=6.2)
                if #available(macOS 26.0, *) { try await startModern() }
                #endif
            case .sfSpeech:
                try await startSFSpeech()
            }
        }
    }

    /// Состояние модели SpeechAnalyzer для языка (без скачивания). nil — SpeechAnalyzer в сборке нет или язык он не знает.
    static func modelState(for locale: Locale) async -> CopilotTranscriptionPath.ModelState? {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let module = await module(for: locale, reactToPauses: false) {
            switch await AssetInventory.status(forModules: [module]) {
            case .installed: return .installed
            case .downloading: return .downloading
            case .supported: return .downloadable
            default: return .unsupported
            }
        }
        #endif
        return nil
    }

    /// Модель расшифровки для языка уже установлена (проверка без скачивания: реплей не меняет систему).
    static func modelInstalled(for locale: Locale) async -> Bool { await modelState(for: locale) == .installed }

    /// Скачать модель SpeechAnalyzer для языка — только по кнопке «Загрузить» (один раз, дальше всё на Mac).
    static func downloadModel(for locale: Locale) async throws {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let module = await module(for: locale, reactToPauses: false) {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
            return
        }
        #endif
        throw CopilotListenFailure.languageUnsupported(language: languageCode(locale))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        switch path {
        case .sfSpeech: appendSFSpeech(buffer)
        case .speechAnalyzer:
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) { appendModern(buffer) }
            #endif
        case nil: break
        }
    }

    func finish() {
        lock.lock(); closed = true; accepting = false; let block = finishBlock; finishBlock = nil; let ticker = self.ticker; self.ticker = nil; lock.unlock()
        ticker?.cancel()
        block?()
    }

    private func startTicker() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard let self else { return }
                self.tick()
            }
        }
    }

    // MARK: SpeechAnalyzer (macOS 26)

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func module(for locale: Locale, reactToPauses: Bool) async -> (any SpeechModule)? {
        // С реакцией на паузу просим и промежуточный текст: он приходит раньше финала.
        let reporting: Set<SpeechTranscriber.ReportingOption> = reactToPauses ? [.volatileResults, .fastResults] : []
        let dictationReporting: Set<DictationTranscriber.ReportingOption> = reactToPauses ? [.volatileResults, .frequentFinalization] : []
        if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: reporting, attributeOptions: [])
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                        reportingOptions: dictationReporting, attributeOptions: [])
        }
        return nil
    }

    @available(macOS 26.0, *)
    private func startModern() async throws {
        guard let module = await Self.module(for: locale, reactToPauses: reactToPauses) else {
            throw CopilotListenFailure.languageUnsupported(language: language)
        }
        let results: AsyncThrowingStream<(String, Bool), Error>
        if let m = module as? SpeechTranscriber {
            results = Self.texts(m.results.map { (String($0.text.characters), $0.isFinal) })
        } else if let m = module as? DictationTranscriber {
            results = Self.texts(m.results.map { (String($0.text.characters), $0.isFinal) })
        } else {
            throw CopilotListenFailure.languageUnsupported(language: language)
        }
        // Модель не скачивается здесь: путь выбран только при установленной (`CopilotTranscriptionPath.choose`).
        let analyzer = SpeechAnalyzer(modules: [module])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: input)
        let reader = Task { [weak self] in
            do {
                for try await (text, isFinal) in results { self?.receive(text, isFinal: isFinal) }
            } catch {}
        }
        let ticker: Task<Void, Never>? = reactToPauses ? startTicker() : nil
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

    // MARK: Запасной путь: SFSpeechRecognizer на устройстве

    /// Разрешение «Распознавание речи» спрашивается здесь — только когда человек сам включает подсказчика.
    private func startSFSpeech() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        guard status == .authorized else { throw CopilotListenFailure.speechDenied }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw CopilotListenFailure.languageUnsupported(language: language)
        }
        lock.lock()
        if closed { lock.unlock(); return }
        self.recognizer = recognizer
        beginSFTask()
        // Промежуточный текст SFSpeech накапливается за весь сеанс: новые слова отдаёт пауза (`VolatileSettler`) — всегда.
        ticker = startTicker()
        accepting = true
        finishBlock = { [weak self] in self?.endSFSpeech() }
        lock.unlock()
    }

    /// Новый сеанс распознавания (под `lock`). Сеанс кончается финалом или ошибкой (у SFSpeech есть предел длины) — тогда следующий.
    private func beginSFTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        sfRequest = request
        converter = nil
        targetFormat = request.nativeAudioFormat
        sfTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result { self.receive(result.bestTranscription.formattedString, isFinal: result.isFinal, settle: true) }
            if error != nil || result?.isFinal == true { self.restartSF(after: request, failed: error != nil) }
        }
    }

    private func restartSF(after request: SFSpeechAudioBufferRecognitionRequest, failed: Bool) {
        lock.lock()
        guard accepting, !closed, request === sfRequest else { lock.unlock(); return }
        request.endAudio()
        let now = Date()
        sfRestarts = sfRestarts.filter { now.timeIntervalSince($0) < 10 } + [now]
        // Ошибка за ошибкой (нет модели, система отказала) — не крутимся, а говорим.
        if failed, sfRestarts.count > 3 {
            lock.unlock()
            finish()
            onFailure?(.other("Распознавание речи на Mac остановилось — включите подсказчика ещё раз"))
            return
        }
        beginSFTask()
        lock.unlock()
    }

    private func appendSFSpeech(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard accepting, let request = sfRequest else { lock.unlock(); return }
        var converted = buffer
        if let target = targetFormat, target != buffer.format {
            if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: target) }
            if let converter, let out = Self.convert(buffer, with: converter, to: target) { converted = out } else { lock.unlock(); return }
        }
        lock.unlock()
        request.append(converted)
    }

    private func endSFSpeech() {
        lock.lock()
        let request = sfRequest, task = sfTask
        sfRequest = nil; sfTask = nil; recognizer = nil
        lock.unlock()
        request?.endAudio()
        task?.cancel()
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

    /// Текст от расшифровки: без реакции на паузу — только финалы; с ней (и всегда у SFSpeech, `settle`) — новые слова
    /// после паузы ≥ 0,7 с и остаток финала. `date` — момент прихода текста; в реплее аудиофайлов время виртуальное.
    func receive(_ text: String, isFinal: Bool, at date: Date = Date(), settle: Bool = false) {
        var out: String?
        var span: SpeechSpan?
        if !reactToPauses, !settle {
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

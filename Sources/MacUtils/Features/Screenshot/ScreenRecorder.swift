import AVFoundation
@preconcurrency import CoreMedia
import AppKit
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import MUCore
import MUDesign
import MUAudio

/// «Запись»: видео выделенной области из режима снимка (MP4 или GIF).
/// Кадры идут из SCStream с sourceRect; MP4 пишет AVAssetWriter (H.264),
/// GIF собирается из MP4 после остановки.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {
    private(set) static var current: ScreenRecorder?

    enum Format: String, CaseIterable, Identifiable {
        case mp4, gif
        var id: String { rawValue }
        var title: String { self == .mp4 ? "Видео MP4" : "GIF" }
    }

    @Published private(set) var elapsed: TimeInterval = 0

    private let rect: NSRect
    private let screen: NSScreen
    private let format: Format
    private var stream: SCStream?
    private var echoFree: EchoFreeMicrophone?
    private var writer: RecordingWriter?
    private var started = Date()
    private var timer: Timer?
    private var borderPanel: NSPanel?
    private var filterDisplayID: CGDirectDisplayID?

    /// Заголовок своих окон, которые должны попасть в запись (рисунки поверх экрана).
    static let recordedWindowTitle = "MacUtils.Recorded"

    /// Свои окна (рамка, HUD, уведомления) в запись не попадают — кроме рисунков поверх экрана.
    private static func filter(content: SCShareableContent, display: SCDisplay) -> SCContentFilter {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        let shown = content.windows.filter {
            $0.owningApplication?.processID == ownPID && $0.title == recordedWindowTitle
        }
        return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: shown)
    }

    /// Появились или исчезли рисунки поверх экрана — обновить, что пишем.
    func refreshFilter() {
        guard let stream, let displayID = filterDisplayID else { return }
        Task {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
            try? await stream.updateContentFilter(Self.filter(content: content, display: display))
        }
    }
    private var hudPanel: NSPanel?
    private var keyTap: EventTap?
    private var finishing = false
    private var gifWarned = false

    private init(rect: NSRect, screen: NSScreen, format: Format) {
        self.rect = rect
        self.screen = screen
        self.format = format
        super.init()
    }

    // MARK: - Старт

    static func start(rect: NSRect) {
        guard current == nil else { return }
        let center = NSPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }) ?? NSScreen.main,
              let displayID = screen.displayID else { return }
        let defaults = UserDefaults.standard
        let format = Format(rawValue: defaults.string(forKey: Pref.recordingFormat) ?? "") ?? .mp4
        let recorder = ScreenRecorder(rect: rect.intersection(screen.frame).integral, screen: screen, format: format)
        current = recorder
        Task { @MainActor in
            do {
                try await recorder.begin(displayID: displayID)
            } catch {
                Log.capture.error("Запись: не удалось начать: \(error.localizedDescription, privacy: .public)")
                recorder.teardown()
                Toast.show("Не удалось начать запись: \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    private func begin(displayID: CGDirectDisplayID) async throws {
        let defaults = UserDefaults.standard
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.noDisplay
        }
        filterDisplayID = displayID
        let filter = Self.filter(content: content, display: display)

        let scale = screen.backingScaleFactor
        let fps = format == .gif ? 15 : max(15, min(60, defaults.integer(forKey: Pref.recordingFPS)))
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        // H.264 требует чётные размеры.
        config.width = Int(rect.width * scale) / 2 * 2
        config.height = Int(rect.height * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = defaults.bool(forKey: Pref.recordingCursor)
        config.queueDepth = 6
        let wantsAudio = format == .mp4 && defaults.bool(forKey: Pref.recordingAudio)
        config.capturesAudio = wantsAudio
        config.excludesCurrentProcessAudio = true
        let wantsMic = format == .mp4 && defaults.bool(forKey: Pref.recordingMicrophone)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacUtils-\(UUID().uuidString).mp4")
        let writer = try RecordingWriter(url: url, width: config.width, height: config.height,
                                         audio: wantsAudio, microphone: wantsMic)
        // Любой сбой до старта захвата: временный .mp4 уже создан — удаляем, иначе мусор копится в temp.
        var echoFree: EchoFreeMicrophone?
        do {
            try await startCapture(writer: writer, config: config, filter: filter, wantsAudio: wantsAudio,
                                   wantsMic: wantsMic, echoFree: &echoFree)
        } catch {
            echoFree?.stop()
            writer.discard()
            throw error
        }
        self.echoFree = echoFree
        self.writer = writer
        Log.capture.info("Запись: старт \(config.width)×\(config.height) @\(fps) fps, \(self.format.rawValue, privacy: .public)")

        started = Date()
        gifWarned = false
        showPanels()
        startKeyTap()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func startCapture(writer: RecordingWriter, config: SCStreamConfiguration, filter: SCContentFilter,
                              wantsAudio: Bool, wantsMic: Bool, echoFree: inout EchoFreeMicrophone?) async throws {
        // Микрофон — с подавлением эха, иначе звук системы из динамиков попадает в него ещё раз.
        if wantsMic {
            let candidate = EchoFreeMicrophone { [weak writer] buffer, pts in
                guard let built = EchoFreeMicrophone.sampleBuffer(buffer, at: pts) else { return }
                let sample = UncheckedSendable(built)
                writer?.queue.async { writer?.appendMicrophone(sample.value) }
            }
            do {
                try candidate.start()
                echoFree = candidate
            } catch {
                Log.capture.error("Запись: подавление эха недоступно: \(error.localizedDescription, privacy: .public)")
                if #available(macOS 15.0, *) { config.captureMicrophone = true }
            }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: writer)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if wantsAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
        if #available(macOS 15.0, *), wantsMic, echoFree == nil {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    @objc private func tick() {
        elapsed = Date().timeIntervalSince(started)
        guard format == .gif else { return }
        switch GIFPolicy.check(elapsed: elapsed, warned: gifWarned) {
        case .none: break
        case .warn:
            gifWarned = true
            Toast.show("GIF длиннее \(Int(GIFPolicy.warnAfter)) с получится тяжёлым — для долгой записи лучше MP4. Остановится на \(Int(GIFPolicy.maxDuration)) с",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .stop:
            stop()
        }
    }

    // MARK: - Стоп

    func stop() {
        guard !finishing, let stream, let writer else { return }
        finishing = true
        teardownUI()
        echoFree?.stop()
        echoFree = nil
        Task { @MainActor in
            try? await stream.stopCapture()
            let frames = await writer.finish()
            Log.capture.info("Запись: стоп, кадров \(frames)")
            defer { self.teardown() }
            guard frames > 0 else {
                try? FileManager.default.removeItem(at: writer.url)
                Toast.show("Запись пуста: кадры не пришли", symbol: "exclamationmark.triangle.fill", tint: .orange)
                return
            }
            await self.deliver(writer.url)
        }
    }

    /// Отмена записи кнопкой HUD: запись удаляется, поэтому сначала спрашиваем.
    /// Пока открыто окно подтверждения, Esc принадлежит ему (глобальный перехват не должен останавливать запись под ним).
    private var confirmingCancel = false

    func confirmCancel() {
        guard !finishing, !confirmingCancel else { return }
        confirmingCancel = true
        defer { confirmingCancel = false }
        let alert = NSAlert()
        alert.messageText = "Удалить запись?"
        alert.informativeText = "Записанное будет удалено без возможности восстановления. Чтобы сохранить, нажмите «Стоп» (или Esc)."
        alert.addButton(withTitle: "Продолжить запись")
        alert.addButton(withTitle: "Удалить запись")
        alert.buttons[0].keyEquivalent = "\u{1b}"  // Esc = «Продолжить запись»
        alert.buttons[1].hasDestructiveAction = true
        ScreenOutput.activateApp()
        if alert.runModal() == .alertSecondButtonReturn { cancel() }
    }

    func cancel() {
        guard !finishing else { return }
        finishing = true
        teardownUI()
        let stream = self.stream, writer = self.writer
        echoFree?.stop()
        echoFree = nil
        Task { @MainActor in
            try? await stream?.stopCapture()
            if let writer {
                _ = await writer.finish()
                try? FileManager.default.removeItem(at: writer.url)
            }
            self.teardown()
            Toast.show("Запись отменена", symbol: "xmark.circle.fill", tint: .secondary)
        }
    }

    private func teardownUI() {
        timer?.invalidate()
        timer = nil
        keyTap?.stop()
        keyTap = nil
        borderPanel?.orderOut(nil)
        hudPanel?.orderOut(nil)
        borderPanel = nil
        hudPanel = nil
    }

    private func teardown() {
        teardownUI()
        stream = nil
        writer = nil
        if Self.current === self { Self.current = nil }
    }

    // MARK: - Результат

    private func deliver(_ temp: URL) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let folder = Self.writableFolder()
        let base = "Запись экрана \(formatter.string(from: Date()))"
        do {
            let destination: URL
            // Умная папка: видео тоже по дням и программам и видно в «Мои снимки».
            let library = ScreenshotLibrary.shared
            if format == .gif {
                destination = library.destination(fileName: base + ".gif", root: folder)
                let toast = Toast.show("Создаю GIF… 0 %", symbol: "photo.stack", tint: .purple, sticky: true)
                do {
                    try await GIFMaker.make(from: temp, to: destination, fps: 15, maxWidth: 960) { percent in
                        Task { @MainActor in Toast.updateText("Создаю GIF… \(percent) %", token: toast) }
                    }
                } catch {
                    Toast.dismiss(token: toast)
                    // GIF не вышел — запись не теряем: сохраняем исходный MP4.
                    let fallback = library.destination(fileName: base + ".mp4", root: folder)
                    try? FileManager.default.removeItem(at: destination)
                    guard Self.saveFallback(temp, to: fallback) else { throw error }
                    library.add(fallback, image: nil, app: library.captureApp)
                    Log.capture.error("GIF не собрался, сохранён MP4: \(error.localizedDescription, privacy: .public)")
                    Toast.show("GIF не получился — сохранил как MP4", symbol: "exclamationmark.triangle.fill", tint: .orange,
                               action: Toast.Action(title: "Показать в Finder") {
                                   NSWorkspace.shared.activateFileViewerSelecting([fallback])
                               })
                    return
                }
                Toast.dismiss(token: toast)
                try? FileManager.default.removeItem(at: temp)
            } else {
                destination = library.destination(fileName: base + ".mp4", root: folder)
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            library.add(destination, image: nil, app: library.captureApp)
            // Файлом в буфер обмена: вставляется в чаты и Finder.
            let copy = UserDefaults.standard.bool(forKey: Pref.recordingCopy)
            if copy {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.writeObjects([destination as NSURL])
            }
            // MP4 — сразу посмотреть в плеере Mac Utils; GIF — показать в Finder.
            let action = format == .gif
                ? Toast.Action(title: "Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                : Toast.Action(title: "Открыть в плеере") { PlayerWindowController.open([destination]) }
            Toast.show(copy ? "Запись сохранена и скопирована" : "Запись сохранена", symbol: "record.circle", tint: .red,
                       action: action)
        } catch {
            Toast.show("Не удалось сохранить запись: \(error.localizedDescription)",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    /// Перенести временный MP4 к пользователю; не вышло — удалить его, чтобы не копить мусор в temp.
    nonisolated static func saveFallback(_ temp: URL, to destination: URL) -> Bool {
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    /// Папка из настроек, если в неё можно писать; иначе — Рабочий стол.
    private static func writableFolder() -> URL {
        let manager = FileManager.default
        let folder = Pref.recordingDirectory
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
           manager.isWritableFile(atPath: folder.path) {
            return folder
        }
        let desktop = manager.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        Log.capture.error("Запись: папка недоступна: \(folder.path, privacy: .public)")
        Toast.show("Папка для видео недоступна — сохраняю на Рабочий стол",
                   symbol: "exclamationmark.triangle.fill", tint: .orange)
        return desktop
    }

    // MARK: - Клавиши и панели

    private func startKeyTap() {
        let tap = EventTap(types: [.keyDown]) { [weak self] _, event in
            guard let self else { return true }
            // Esc нажимают в любой программе постоянно (закрыть диалог, выйти из полноэкранного режима),
            // поэтому он только останавливает запись с сохранением, а не удаляет её. Клавиша идёт дальше в приложение.
            if event.getIntegerValueField(.keyboardEventKeycode) == 53, !self.confirmingCancel { // Esc
                self.stop()
            }
            return true
        }
        if !tap.start() { Log.capture.error("Запись: нет перехвата клавиш") }
        keyTap = tap
    }

    private func showPanels() {
        let border = NSPanel(contentRect: rect.insetBy(dx: -3, dy: -3),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        border.isOpaque = false
        border.backgroundColor = .clear
        border.ignoresMouseEvents = true
        border.hasShadow = false
        border.level = .statusBar
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 3).strokeBorder(Color.red, lineWidth: 2))
        border.orderFrontRegardlessOnScreen()
        borderPanel = border

        let host = FirstMouseHostingView(rootView: RecordingHUD(recorder: self))
        let size = host.fittingSize
        let hud = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.level = .statusBar
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = host
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < visible.minY + 8 { origin.y = rect.maxY + 12 }
        if origin.y + size.height > visible.maxY { origin.y = rect.minY + 12 }
        origin.x = min(max(visible.minX + 8, origin.x), visible.maxX - size.width - 8)
        hud.setFrameOrigin(origin)
        hud.orderFrontRegardlessOnScreen()
        hudPanel = hud
    }
}

enum RecordingError: LocalizedError {
    case noDisplay, writer

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "дисплей не найден"
        case .writer: return "не удалось создать файл записи"
        }
    }
}

private struct RecordingHUD: View {
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        RecordingHUDContent(elapsed: recorder.elapsed, cancel: { recorder.confirmCancel() }, stop: { recorder.stop() })
    }
}

/// Индикатор записи экрана: «ЗАПИСЬ» с пульсирующей точкой, время, «Отмена» и «Стоп». Значения готовые, без модели.
struct RecordingHUDContent: View {
    let elapsed: TimeInterval
    let cancel: () -> Void
    let stop: () -> Void

    var body: some View {
        LiveIndicator(.recording, since: Date().addingTimeInterval(-elapsed)) {
            Button("Отмена", action: cancel)
                .buttonStyle(.graphite(.ghost, size: .compact))
                .help("Удалить запись (с подтверждением)")
            Button("Стоп", action: stop)
                .buttonStyle(.graphite(.danger, size: .compact))
                .help("Сохранить запись: ⌘⇧X или Esc")
        }
        .padding(4)
    }
}

// MARK: - Запись в файл

/// Принимает кадры SCStream на своей очереди и пишет MP4 (H.264 + AAC).
final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    let queue = DispatchQueue(label: "macutils.recording")

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let microphone: AVAssetWriterInput?
    private var sessionStarted = false
    private var finished = false
    private var frames = 0

    init(url: URL, width: Int, height: Int, audio wantsAudio: Bool, microphone wantsMic: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 6),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw RecordingError.writer }
        writer.add(video)

        func audioInput(channels: Int = 2) -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        audio = wantsAudio ? audioInput() : nil
        microphone = wantsMic ? audioInput(channels: 1) : nil
        for input in [audio, microphone].compactMap({ $0 }) where writer.canAdd(input) {
            writer.add(input)
        }
        super.init()
        guard writer.startWriting() else {
            let error = writer.error ?? RecordingError.writer
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid, writer.status == .writing else { return }
        switch type {
        case .screen:
            // Пропускаем кадры без изменений и служебные.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStarted = true
            }
            if video.isReadyForMoreMediaData, video.append(sampleBuffer) { frames += 1 }
        case .audio:
            if sessionStarted, let audio, audio.isReadyForMoreMediaData { audio.append(sampleBuffer) }
        default:
            appendMicrophone(sampleBuffer)
        }
    }

    /// Вызывается на queue.
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard !finished, sessionStarted, let microphone, microphone.isReadyForMoreMediaData else { return }
        microphone.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("Запись: поток остановлен: \(error.localizedDescription, privacy: .public)")
    }

    /// Захват не стартовал: закрыть писатель и удалить временный файл.
    func discard() {
        queue.sync {
            finished = true
            if writer.status == .writing { writer.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Закрывает файл; возвращает число записанных кадров.
    func finish() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                self.finished = true
                guard self.sessionStarted, self.writer.status == .writing else {
                    self.writer.cancelWriting()
                    continuation.resume(returning: 0)
                    return
                }
                self.video.markAsFinished()
                self.audio?.markAsFinished()
                self.microphone?.markAsFinished()
                let frames = self.frames
                self.writer.finishWriting {
                    continuation.resume(returning: self.writer.status == .completed ? frames : 0)
                }
            }
        }
    }
}

// MARK: - GIF

enum GIFMaker {
    /// Кадры из видео с шагом 1/fps, ширина не больше maxWidth, бесконечный повтор.
    static func make(from video: URL, to destination: URL, fps: Int, maxWidth: CGFloat,
                     progress: (@Sendable (Int) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxWidth, height: 10_000)

        let count = max(1, Int(duration * Double(fps)))
        guard let gif = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString,
                                                        count, nil) else { throw RecordingError.writer }
        CGImageDestinationSetProperties(gif, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)],
        ] as CFDictionary
        var lastPercent = -1
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) / Double(fps), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            CGImageDestinationAddImage(gif, image, frameProperties)
            let percent = GIFPolicy.percent(done: index + 1, total: count)
            if percent != lastPercent { lastPercent = percent; progress?(percent) }
        }
        guard CGImageDestinationFinalize(gif) else { throw RecordingError.writer }
    }
}

/// Правила GIF-записи: предупреждение, предел длительности, проценты прогресса.
enum GIFPolicy {
    /// После скольких секунд записи предупреждаем, что GIF получится тяжёлым.
    static let warnAfter: TimeInterval = 30
    /// Дольше GIF не пишем: запись останавливается и сохраняется (15 кадров/с × 960 px — сотни МБ).
    static let maxDuration: TimeInterval = 90

    enum Action: Equatable { case none, warn, stop }

    static func check(elapsed: TimeInterval, warned: Bool) -> Action {
        if elapsed >= maxDuration { return .stop }
        if elapsed >= warnAfter, !warned { return .warn }
        return .none
    }

    /// Проценты 0…100 для «Создаю GIF… N %».
    static func percent(done: Int, total: Int) -> Int {
        guard total > 0 else { return 100 }
        return min(100, max(0, done * 100 / total))
    }
}

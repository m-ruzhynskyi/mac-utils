// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import AppKit
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

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
    private var writer: RecordingWriter?
    private var started = Date()
    private var timer: Timer?
    private var borderPanel: NSPanel?
    private var hudPanel: NSPanel?
    private var keyTap: EventTap?
    private var finishing = false

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
        // Свои окна (рамка, HUD, уведомления) в запись не попадают.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

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
        var wantsMic = false
        if #available(macOS 15.0, *), format == .mp4, defaults.bool(forKey: Pref.recordingMicrophone) {
            config.captureMicrophone = true
            wantsMic = true
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacUtils-\(UUID().uuidString).mp4")
        let writer = try RecordingWriter(url: url, width: config.width, height: config.height,
                                         audio: wantsAudio, microphone: wantsMic)
        let stream = SCStream(filter: filter, configuration: config, delegate: writer)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if wantsAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
        if #available(macOS 15.0, *), wantsMic {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        try await stream.startCapture()
        self.writer = writer
        self.stream = stream
        Log.capture.info("Запись: старт \(config.width)×\(config.height) @\(fps) fps, \(self.format.rawValue, privacy: .public)")

        started = Date()
        showPanels()
        startKeyTap()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        elapsed = Date().timeIntervalSince(started)
    }

    // MARK: - Стоп

    func stop() {
        guard !finishing, let stream, let writer else { return }
        finishing = true
        teardownUI()
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

    func cancel() {
        guard !finishing else { return }
        finishing = true
        teardownUI()
        let stream = self.stream, writer = self.writer
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
        let folder = Pref.screenshotDirectory
        let base = "Запись экрана \(formatter.string(from: Date()))"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination: URL
            if format == .gif {
                destination = folder.appendingPathComponent(base + ".gif")
                try await GIFMaker.make(from: temp, to: destination, fps: 15, maxWidth: 960)
                try? FileManager.default.removeItem(at: temp)
            } else {
                destination = folder.appendingPathComponent(base + ".mp4")
                try FileManager.default.moveItem(at: temp, to: destination)
            }
            // Файлом в буфер обмена: вставляется в чаты и Finder.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([destination as NSURL])
            Toast.show("Запись сохранена и скопирована", symbol: "record.circle", tint: .red,
                       action: Toast.Action(title: "Показать в Finder") {
                           NSWorkspace.shared.activateFileViewerSelecting([destination])
                       })
        } catch {
            Toast.show("Не удалось сохранить запись: \(error.localizedDescription)",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    // MARK: - Клавиши и панели

    private func startKeyTap() {
        let tap = EventTap(types: [.keyDown]) { [weak self] _, event in
            guard let self else { return true }
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { // Esc
                self.cancel()
                return false
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
        border.orderFrontRegardless()
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
        hud.orderFrontRegardless()
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
        HStack(spacing: 12) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            Text(timeString)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Button("Отмена") { recorder.cancel() }
                .help("Esc")
            Button("Стоп") { recorder.stop() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help("⌘⇧X")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(4)
    }

    private var timeString: String {
        let seconds = Int(recorder.elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
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

        func audioInput() -> AVAssetWriterInput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            return input
        }
        audio = wantsAudio ? audioInput() : nil
        microphone = wantsMic ? audioInput() : nil
        for input in [audio, microphone].compactMap({ $0 }) where writer.canAdd(input) {
            writer.add(input)
        }
        super.init()
        guard writer.startWriting() else { throw writer.error ?? RecordingError.writer }
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
            if sessionStarted, let microphone, microphone.isReadyForMoreMediaData { microphone.append(sampleBuffer) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.capture.error("Запись: поток остановлен: \(error.localizedDescription, privacy: .public)")
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
    static func make(from video: URL, to destination: URL, fps: Int, maxWidth: CGFloat) async throws {
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
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) / Double(fps), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            CGImageDestinationAddImage(gif, image, frameProperties)
        }
        guard CGImageDestinationFinalize(gif) else { throw RecordingError.writer }
    }
}

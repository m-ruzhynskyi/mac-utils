import AVFoundation
import CoreVideo
import Foundation
import MUCore

/// Состояние конвейера для строки состояния и окна отладки.
package struct GazeStats: Equatable, Sendable {
    package var fps = 0.0
    /// Обработка кадра, мс (сглаженное среднее).
    package var processingMs = 0.0
    /// От снимка камерой до готового кадра, мс.
    package var latencyMs = 0.0
    package var faceFound = false
    package var weight = 0.0
    package var state: GazeState = []
    package init() {}
}

/// Обработка кадра: Vision + Iris → GazeController → EyeRenderer на CPU в копии кадра → Syphon и окно отладки.
/// Всё — на одной очереди; кадр ~8–11 мс на M3 (720p / 1080p).
final class GazePipeline {
    let queue = DispatchQueue(label: "com.mruzhynskyi.macutils.gaze.pipeline", qos: .userInteractive)

    private let tracker: FaceTracker
    private let controller: GazeController
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var times: [Double] = []
    private var stats = GazeStats()
    private let lock = NSLock()

    /// Выключить правку, но продолжать отдавать кадры (отладка: сравнение).
    var bypass = false
    /// Готовый кадр: (кадр камеры, кадр после правки). На очереди конвейера.
    var onFrame: ((CVPixelBuffer, CVPixelBuffer) -> Void)?
    /// Положение радужки для калибровки (nil — глаз не видно). На очереди конвейера.
    var onMeasure: ((Vec2?) -> Void)?

    init(iris: IrisModel?, settings: GazeSettings) {
        tracker = FaceTracker(iris: iris)
        controller = GazeController(settings: settings)
    }

    var snapshot: GazeStats { lock.lock(); defer { lock.unlock() }; return stats }

    func update(settings: GazeSettings) { queue.async { self.controller.settings = settings } }

    func reset() { queue.async { self.controller.reset(); self.tracker.reset(); self.times = [] } }

    func process(_ sample: CMSampleBuffer) {
        guard let input = CMSampleBufferGetImageBuffer(sample) else { return }
        let started = CACurrentMediaTime()
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let face = tracker.track(input)
        let out = controller.step(time: pts, face: face)
        let measured: Vec2? = face?.eyes.contains(where: { $0.shape != nil }) == true && !out.state.contains(.blink) ? out.measured : nil
        onMeasure?(measured)

        guard let output = makeBuffer(like: input) else { return }
        copy(input, to: output)
        if !bypass, !out.edits.isEmpty {
            CVPixelBufferLockBaseAddress(output, [])
            let view = PixelView(base: CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self),
                                 width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output),
                                 rowBytes: CVPixelBufferGetBytesPerRow(output))
            EyeRenderer.render(out.edits, into: view)
            CVPixelBufferUnlockBaseAddress(output, [])
        }
        onFrame?(input, output)

        let now = CACurrentMediaTime()
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        times.append(now)
        times.removeAll { now - $0 > 1 }
        lock.lock()
        stats.fps = Double(times.count)
        stats.processingMs = stats.processingMs * 0.9 + (now - started) * 1000 * 0.1
        if pts > 0, hostNow > pts, hostNow - pts < 1 { stats.latencyMs = stats.latencyMs * 0.9 + (hostNow - pts) * 1000 * 0.1 }
        stats.faceFound = face != nil
        stats.weight = out.weight
        stats.state = out.state
        lock.unlock()
    }

    private func makeBuffer(like input: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        if pool == nil || poolSize != (w, h) {
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ] as CFDictionary, &p)
            pool = p; poolSize = (w, h)
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess else { return nil }
        return out
    }

    private func copy(_ src: CVPixelBuffer, to dst: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(dst, []) }
        let h = CVPixelBufferGetHeight(src), sr = CVPixelBufferGetBytesPerRow(src), dr = CVPixelBufferGetBytesPerRow(dst)
        let s = CVPixelBufferGetBaseAddress(src)!, d = CVPixelBufferGetBaseAddress(dst)!
        if sr == dr { memcpy(d, s, sr * h) } else { for y in 0..<h { memcpy(d + y * dr, s + y * sr, min(sr, dr)) } }
    }
}

/// Запись «до | после» рядом в один файл (H.264, без звука) — для разбора. Кадры подаются с очереди конвейера.
final class GazeRecorder {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int
    private var start: CFTimeInterval?
    let url: URL
    let seconds: Double
    private(set) var finished = false

    init(url: URL, width: Int, height: Int, seconds: Double = 10) throws {
        self.url = url; self.width = width; self.height = height; self.seconds = seconds
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width * 2, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width * 2, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
    }

    /// Добавить пару кадров. Возвращает true, когда запись закончена (10 с).
    func append(before: CVPixelBuffer, after: CVPixelBuffer, completion: @escaping (URL) -> Void) -> Bool {
        guard !finished else { return true }
        let now = CACurrentMediaTime()
        if start == nil { start = now }
        let t = now - start!
        if t >= seconds {
            finished = true
            input.markAsFinished()
            writer.finishWriting { [url] in DispatchQueue.main.async { completion(url) } }
            return true
        }
        guard input.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool,
              CVPixelBufferGetWidth(before) == width, CVPixelBufferGetHeight(before) == height else { return false }
        var combined: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &combined) == kCVReturnSuccess, let combined else { return false }
        CVPixelBufferLockBaseAddress(combined, [])
        let d = CVPixelBufferGetBaseAddress(combined)!, dr = CVPixelBufferGetBytesPerRow(combined)
        for (k, src) in [before, after].enumerated() {
            CVPixelBufferLockBaseAddress(src, .readOnly)
            let s = CVPixelBufferGetBaseAddress(src)!, sr = CVPixelBufferGetBytesPerRow(src)
            for y in 0..<height { memcpy(d + y * dr + k * width * 4, s + y * sr, width * 4) }
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        CVPixelBufferUnlockBaseAddress(combined, [])
        adaptor.append(combined, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        return false
    }
}

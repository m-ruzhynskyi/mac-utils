import CoreVideo
import Foundation

/// Куда идёт готовый кадр (вызывается на очереди конвейера): Syphon, окно отладки, запись «до | после»,
/// замеры для калибровки. Всё общее с главным потоком — под замком.
final class GazeFrameSink: @unchecked Sendable {
    private let syphon: SyphonServer
    private let lock = NSLock()
    private var debugFrames: ((CVPixelBuffer, CVPixelBuffer) -> Void)?
    private var recorder: GazeRecorder?
    private var pendingRecording: (url: URL, done: (URL?) -> Void)?
    private var collecting: GazeCalibrationRecorder.Step?
    private var samples: [(GazeCalibrationRecorder.Step, Vec2?)] = []

    init(syphon: SyphonServer) { self.syphon = syphon }

    func setDebugFrames(_ f: ((CVPixelBuffer, CVPixelBuffer) -> Void)?) { lock.withLock { debugFrames = f } }

    /// Запись 10 с: файл создаётся по первому кадру (нужен размер). `done` — на главном потоке, nil — не вышло.
    func requestRecording(to url: URL, done: @escaping (URL?) -> Void) { lock.withLock { pendingRecording = (url, done) } }

    func startCollecting(_ step: GazeCalibrationRecorder.Step?) { lock.withLock { collecting = step } }

    func takeSamples() -> [(GazeCalibrationRecorder.Step, Vec2?)] {
        lock.withLock { defer { samples = [] }; return samples }
    }

    func handle(before: CVPixelBuffer, after: CVPixelBuffer) {
        syphon.publish(after)
        lock.lock()
        let debug = debugFrames
        if let p = pendingRecording {
            pendingRecording = nil
            do {
                recorder = try GazeRecorder(url: p.url, width: CVPixelBufferGetWidth(before), height: CVPixelBufferGetHeight(before))
                recorderDone = p.done
            } catch {
                DispatchQueue.main.async { p.done(nil) }
            }
        }
        let rec = recorder
        lock.unlock()
        debug?(before, after)
        if let rec, rec.append(before: before, after: after, completion: { [weak self] url in
            guard let self else { return }
            let done = self.lock.withLock { () -> ((URL?) -> Void)? in defer { self.recorderDone = nil }; return self.recorderDone }
            done?(url)
        }) {
            lock.withLock { if recorder === rec { recorder = nil } }
        }
    }

    private var recorderDone: ((URL?) -> Void)?

    /// Выключение посреди записи: дописать то, что есть. Вызывается после остановки камеры.
    func finishRecording() {
        let (rec, done) = lock.withLock { () -> (GazeRecorder?, ((URL?) -> Void)?) in
            defer { recorder = nil; recorderDone = nil; pendingRecording = nil }
            return (recorder, recorderDone)
        }
        if let rec { rec.finish { url in done?(url) } } else { done?(nil) }
    }

    func measure(_ g: Vec2?) {
        lock.withLock { if let step = collecting { samples.append((step, g)) } }
    }
}

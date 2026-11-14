import AppKit
import AVFoundation
import Combine
import MUCore

/// «Взгляд в камеру»: камера → поправка взгляда → Syphon («Mac Utils · Взгляд») → OBS → «OBS Virtual Camera».
/// Включается только вручную и только до выхода из Mac Utils (состояние не сохраняется). Камера открыта, пока включено.
@MainActor
package final class GazeService: ObservableObject {
    package static let shared = GazeService()
    package static let syphonName = "Mac Utils · Взгляд"

    package enum Status: Equatable {
        case off, starting, running
        case cameraDenied, noCamera
        case failed(String)
    }

    package enum Calibration: Equatable {
        case idle
        case collecting(GazeCalibrationRecorder.Step, progress: Double)
        case done(GazeCalibrationRecorder.Result)
        case failed(String)
    }

    @Published package private(set) var isOn = false
    @Published package private(set) var status: Status = .off
    @Published package private(set) var stats = GazeStats()
    /// Сколько кадров в секунду забирает OBS (0 — OBS не подключён).
    @Published package private(set) var obsFPS = 0.0
    @Published package private(set) var calibration: Calibration = .idle
    @Published package private(set) var cameraName: String?
    /// Модель Iris не нашлась или не скомпилировалась — работает запасной поиск радужки (хуже).
    @Published package private(set) var preciseEyes = true
    /// Face Landmarker загрузился (веки точнее на узких и широко раскрытых глазах).
    @Published package private(set) var preciseLids = true
    @Published package private(set) var recording = false
    @Published package private(set) var lastRecording: URL?

    private var camera: GazeCamera?
    private var pipeline: GazePipeline?
    private var syphon: SyphonServer?
    private var sink: GazeFrameSink?
    private var statsTimer: Timer?
    private var calibrationTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?

    /// Отладка: правки поверх настроек (ползунки окна отладки), не сохраняются.
    package var debugOverrides: ((inout GazeSettings) -> Void)? { didSet { applySettings() } }
    /// Отладка: кадры «до/после» для окна (на очереди конвейера).
    package var debugFrames: ((CVPixelBuffer, CVPixelBuffer) -> Void)? { didSet { sink?.setDebugFrames(debugFrames) } }
    /// Отладка: правка выключена, кадры идут как есть.
    package var bypass = false { didSet { pipeline?.bypass = bypass } }
    /// Свежее состояние конвейера (не раз в полсекунды, как `stats`) — для индикатора на кадре в отладке.
    package var liveStats: GazeStats? { pipeline?.snapshot }

    private init() {}

    // MARK: - Включение

    package func setOn(_ on: Bool) { on ? turnOn() : turnOff() }

    private func turnOn() {
        guard !isOn else { return }
        isOn = true
        status = .starting
        switch Permissions.camera {
        case .granted: start()
        case .denied: status = .cameraDenied; isOn = false
        case .notAsked:
            Permissions.requestCamera { [weak self] granted in
                MainActor.assumeIsolated {
                    guard let self, self.isOn else { return }
                    if granted { self.start() } else { self.status = .cameraDenied; self.isOn = false }
                }
            }
        }
    }

    private func start() {
        var iris: IrisModel?
        do {
            if let url = try IrisModel.compiledURL() { iris = try IrisModel(compiledURL: url) }
        } catch {
            Log.gaze.error("iris model: \(String(describing: error), privacy: .public)")
        }
        preciseEyes = iris != nil
        var faceMesh: FaceMeshModel?
        do {
            if let url = try FaceMeshModel.compiledURL() { faceMesh = try FaceMeshModel(compiledURL: url) }
        } catch {
            Log.gaze.error("face mesh model: \(String(describing: error), privacy: .public)")
        }
        preciseLids = faceMesh != nil
        Log.gaze.info("models: iris \(iris != nil, privacy: .public) faceMesh \(faceMesh != nil, privacy: .public)")
        let pipeline = GazePipeline(iris: iris, faceMesh: faceMesh, settings: Self.settingsFromPrefs())
        pipeline.bypass = bypass
        let syphon = SyphonServer(name: Self.syphonName)
        let sink = GazeFrameSink(syphon: syphon)
        sink.setDebugFrames(debugFrames)
        pipeline.onFrame = { before, after in sink.handle(before: before, after: after) }
        pipeline.onMeasure = { g in sink.measure(g) }
        let camera = GazeCamera(queue: pipeline.queue) { [weak pipeline] sample in pipeline?.process(sample) }
        do {
            try camera.start()
        } catch GazeCamera.StartError.noCamera {
            status = .noCamera; isOn = false; return
        } catch {
            status = .failed("Камера не открылась"); isOn = false; return
        }
        syphon.start()
        self.pipeline = pipeline; self.syphon = syphon; self.sink = sink; self.camera = camera
        cameraName = camera.deviceName
        status = .running
        applySettings()
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
    }

    private func turnOff() {
        guard isOn || camera != nil else { return }
        isOn = false
        camera?.stop()
        syphon?.stop()
        statsTimer?.invalidate()
        calibrationTask?.cancel()
        if case .collecting = calibration { calibration = .idle }
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        camera = nil; pipeline = nil; syphon = nil; sink = nil; statsTimer = nil; defaultsObserver = nil
        recording = false
        status = .off
        stats = .init(); obsFPS = 0
    }

    /// Выход из Mac Utils: камера закрывается, сервер Syphon уходит из списка OBS.
    package func shutdown() { turnOff() }

    // MARK: - Настройки

    package static func settingsFromPrefs(_ d: UserDefaults = .standard) -> GazeSettings {
        var s = GazeSettings()
        switch d.string(forKey: Pref.gazeTarget) {
        case "below": s.target = .slightlyBelow
        case "point": s.target = .point(yaw: d.double(forKey: Pref.gazePointYaw), pitch: d.double(forKey: Pref.gazePointPitch))
        default: s.target = .camera
        }
        s.freedom = GazeFreedom(rawValue: d.string(forKey: Pref.gazeFreedom) ?? "") ?? .normal
        // Сохранённое значение — через то же правило: старые калибровки (до GAZE-34) могли записать почти ноль.
        if d.object(forKey: Pref.gazeScreenLift) != nil {
            s.calibration.screenLift = GazeCalibration.liftAfterCalibration(d.double(forKey: Pref.gazeScreenLift))
        }
        if d.object(forKey: Pref.gazeStrength) != nil {
            s.strength = min(max(d.double(forKey: Pref.gazeStrength), GazeSettings.strengthRange.lowerBound), GazeSettings.strengthRange.upperBound)
        }
        s.calibration.bias.x = d.double(forKey: Pref.gazeBiasX)
        return s
    }

    private func applySettings() {
        var s = Self.settingsFromPrefs()
        debugOverrides?(&s)
        pipeline?.update(settings: s)
    }

    private func refreshStats() {
        guard let pipeline else { return }
        stats = pipeline.snapshot
        obsFPS = (syphon?.frameClientCount ?? 0) > 0 ? stats.fps : 0
    }

    // MARK: - Калибровка «в камеру / на середину экрана»

    package func startCalibration() {
        guard status == .running, let sink else { return }
        calibrationTask?.cancel()
        _ = sink.takeSamples()
        calibrationTask = Task { @MainActor [weak self] in
            for step in [GazeCalibrationRecorder.Step.camera, .screen] {
                // 1 с — перевести взгляд, затем 1,5 с сбора.
                self?.calibration = .collecting(step, progress: 0)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                sink.startCollecting(step)
                let ticks = 15
                for i in 1...ticks {
                    try? await Task.sleep(nanoseconds: UInt64(GazeCalibrationRecorder.stepSeconds / Double(ticks) * 1e9))
                    if Task.isCancelled { sink.startCollecting(nil); return }
                    self?.calibration = .collecting(step, progress: Double(i) / Double(ticks))
                }
                sink.startCollecting(nil)
            }
            self?.finishCalibration(samples: sink.takeSamples())
        }
    }

    package func cancelCalibration() {
        calibrationTask?.cancel()
        sink?.startCollecting(nil)
        calibration = .idle
    }

    private func finishCalibration(samples: [(GazeCalibrationRecorder.Step, Vec2?)]) {
        var rec = GazeCalibrationRecorder()
        for (step, g) in samples { rec.add(g, step: step) }
        switch rec.result() {
        case let .success(r):
            UserDefaults.standard.set(r.screenLift, forKey: Pref.gazeScreenLift)
            UserDefaults.standard.set(r.biasX, forKey: Pref.gazeBiasX)
            UserDefaults.standard.set(true, forKey: Pref.gazeCalibrated)
            calibration = .done(r)
            Log.gaze.info("calibration: lift \(r.screenLift, privacy: .public) measured \(r.measuredLift, privacy: .public) biasX \(r.biasX, privacy: .public)")
        case let .failure(f):
            calibration = .failed(Self.message(f))
        }
    }

    package static func message(_ f: GazeCalibrationRecorder.Failure) -> String {
        switch f {
        case .notEnoughSamples(.camera): return "Не удалось разглядеть глаза, пока вы смотрели в камеру. Сядьте лицом к свету и повторите."
        case .notEnoughSamples(.screen): return "Не удалось разглядеть глаза, пока вы смотрели на экран. Повторите."
        case .unstable(.camera): return "Взгляд двигался, пока вы смотрели в камеру. Повторите и смотрите в одну точку."
        case .unstable(.screen): return "Взгляд двигался, пока вы смотрели на экран. Повторите и смотрите в одну точку."
        }
    }

    package func resetCalibration() {
        UserDefaults.standard.removeObject(forKey: Pref.gazeScreenLift)
        UserDefaults.standard.removeObject(forKey: Pref.gazeBiasX)
        UserDefaults.standard.set(false, forKey: Pref.gazeCalibrated)
        calibration = .idle
    }

    // MARK: - Отладка: запись 10 с «до | после»

    /// Папка записей отладки: ~/Movies/Mac Utils.
    package static var recordingsFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Mac Utils", isDirectory: true)
    }

    package func recordDebugClip() {
        guard status == .running, !recording, let sink else { return }
        let dir = Self.recordingsFolder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = dir.appendingPathComponent("Взгляд — отладка \(f.string(from: Date())).mov")
        recording = true
        sink.requestRecording(to: url) { [weak self] result in
            MainActor.assumeIsolated {
                self?.recording = false
                self?.lastRecording = result
            }
        }
    }
}

import Foundation

/// Калибровка «посмотрите в камеру» → «посмотрите в середину экрана». Чистая логика: собирает положения радужки
/// (в долях полуширины глаза, ось y — вниз) и считает, насколько экран ниже камеры и где «в камеру» по горизонтали.
package struct GazeCalibrationRecorder: Sendable {
    package enum Step: Equatable, Sendable { case camera, screen }

    package enum Failure: Error, Equatable, Sendable {
        /// Мало кадров с найденными глазами (моргания и потеря лица не считаются).
        case notEnoughSamples(Step)
        /// Взгляд гулял: разброс больше допустимого.
        case unstable(Step)
    }

    package struct Result: Equatable, Sendable {
        /// Положение радужки при взгляде в камеру по горизонтали.
        package var biasX: Double
        /// Насколько радужку поднимать, чтобы взгляд со середины экрана стал взглядом в камеру (> 0 — экран ниже камеры).
        package var screenLift: Double

        package init(biasX: Double, screenLift: Double) { self.biasX = biasX; self.screenLift = screenLift }

        /// Тот же подъём в градусах взгляда — для подписи в настройках.
        package func screenAngleDegrees(gainY: Double = GazeCalibration().gainY) -> Double {
            asin(min(max(screenLift / gainY, -1), 1)) * 180 / .pi
        }
    }

    /// Сколько секунд смотреть в каждую точку.
    package static let stepSeconds = 1.5
    /// Минимум кадров с глазами на шаг (из ~45 при 30 к/с).
    package static let minSamples = 20
    /// Допустимый разброс (медианное отклонение), доли полуширины глаза.
    package static let maxSpread = 0.06
    /// Пределы подъёма: камера над экраном ноутбука — 0,05…0,25; камера ниже экрана — до −0,18.
    package static let liftRange = -0.18...0.25

    package private(set) var camera: [Vec2] = []
    package private(set) var screen: [Vec2] = []

    package init() {}

    package mutating func add(_ gaze: Vec2?, step: Step) {
        guard let gaze else { return }
        switch step {
        case .camera: camera.append(gaze)
        case .screen: screen.append(gaze)
        }
    }

    package func result() -> Swift.Result<Result, Failure> {
        for (step, samples) in [(Step.camera, camera), (.screen, screen)] {
            guard samples.count >= Self.minSamples else { return .failure(.notEnoughSamples(step)) }
            if Self.spread(samples) > Self.maxSpread { return .failure(.unstable(step)) }
        }
        let cam = Self.median(camera), scr = Self.median(screen)
        let lift = min(max(scr.y - cam.y, Self.liftRange.lowerBound), Self.liftRange.upperBound)
        return .success(Result(biasX: cam.x, screenLift: lift))
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func median(_ p: [Vec2]) -> Vec2 { Vec2(median(p.map(\.x)), median(p.map(\.y))) }

    /// Медианное отклонение от медианы (устойчиво к одиночным выбросам — саккаде, полуморганию).
    static func spread(_ p: [Vec2]) -> Double {
        let m = median(p)
        return median(p.map { ($0 - m).length })
    }
}

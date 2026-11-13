import Foundation

/// Куда должны смотреть глаза. Углы в градусах относительно направления «в камеру»: yaw вправо на кадре, pitch вверх.
package enum GazeTarget: Equatable, Codable, Sendable {
    case camera
    /// Чуть ниже камеры — как будто человек смотрит на верх экрана рядом с камерой.
    case slightlyBelow
    case point(yaw: Double, pitch: Double)

    package static let slightlyBelowPitch = -4.0

    package var angles: (yaw: Double, pitch: Double) {
        switch self {
        case .camera: return (0, 0)
        case .slightlyBelow: return (0, Self.slightlyBelowPitch)
        case let .point(yaw, pitch): return (yaw, pitch)
        }
    }
}

/// «Свобода движения»: сколько своих движений глаз остаётся и сколько добавляется мелких.
package enum GazeFreedom: String, CaseIterable, Codable, Sendable {
    case low, normal, high

    package var parameters: FreedomParameters {
        switch self {
        case .low: return FreedomParameters(keepGain: 0.25, keepRadius: 0.05, microAmplitude: 0.02, microInterval: 0.9...2.2, driftAmplitude: 0.006)
        case .normal: return FreedomParameters(keepGain: 0.45, keepRadius: 0.10, microAmplitude: 0.035, microInterval: 0.6...1.6, driftAmplitude: 0.010)
        case .high: return FreedomParameters(keepGain: 0.65, keepRadius: 0.18, microAmplitude: 0.05, microInterval: 0.4...1.2, driftAmplitude: 0.014)
        }
    }
}

/// Все величины — в долях полуширины глаза (≈ 15 мм у взрослого).
package struct FreedomParameters: Equatable, Sendable {
    /// Какая доля собственного быстрого движения глаз (отклонения от медленной базовой точки) сохраняется.
    package var keepGain: Double
    /// Предел сохранённого движения — это «круг» на макете.
    package var keepRadius: Double
    /// Размах синтезированных микросаккад.
    package var microAmplitude: Double
    /// Пауза между микросаккадами, с.
    package var microInterval: ClosedRange<Double>
    /// Медленный дрейф между микросаккадами.
    package var driftAmplitude: Double
}

/// Пороги и скорости. Значения по умолчанию подобраны на прототипе.
package struct GazeLimits: Equatable, Sendable {
    /// Поворот головы, при котором поправка выключается, и при котором включается обратно (гистерезис), градусы.
    package var headYawOff = 25.0, headYawOn = 20.0
    /// Камера ноутбука над экраном: голова к камере наклонена на 15–20° всегда, это и есть главный случай.
    package var headPitchOff = 30.0, headPitchOn = 25.0
    /// Если человек смотрит дальше этого от цели (доли полуширины), поправка выключается: например, смотрит на другой монитор.
    package var maxCorrection = 0.85, maxCorrectionOn = 0.7
    /// Предел сдвига радужки по осям глаза. Вертикаль меньше: веко следует за взглядом, и сильный сдвиг вверх заметен.
    package var maxShiftX = 0.45, maxShiftY = 0.18
    /// Подъём радужки вверх вместе с веком (A v2) — до 0,25 полуширины.
    package var maxLift = 0.25
    /// Видимая высота радужки к её диаметру: ниже Off правки нет, выше On — полная (A v3, по точным векам).
    /// По выборке w1–w6: медиана у открытых глаз 0,80–0,92, у почти закрытых (взгляд вниз) 0,65.
    package static let narrowEyeOff = 0.55, narrowEyeOn = 0.85
    /// Плавное выключение и включение, с.
    package var fadeSeconds = 0.35
    /// Как быстро поправка уходит на время моргания и возвращается, с.
    package var blinkFadeSeconds = 0.06
    /// Моргание: раскрытие меньше этой доли от обычного.
    package var blinkRatio = 0.6
    /// Медленная базовая точка взгляда, с: от неё считаются «свои» быстрые движения.
    package var baselineSeconds = 0.8
    package init() {}
}

/// Связь углов с положением радужки в глазу. По геометрии (глазное яблоко ~12 мм, полуширина глаза ~15 мм) — 0,8;
/// по клипу, где человек смотрит в камеру и крутит головой, — 0,57 (с шумом измерения, занижено). Взято среднее.
package struct GazeCalibration: Equatable, Sendable {
    package var gainX = 0.7, gainY = 0.4
    /// Знак, с которым поворот головы (yaw, pitch Vision) переходит в нужный сдвиг радужки для взгляда в камеру.
    package var headYawSign = -1.0, headPitchSign = -1.0
    /// Положение радужки при взгляде прямо в камеру при прямой голове. Верхнее веко прикрывает радужку,
    /// поэтому её центр выше середины раскрытия. В продукте — однократная калибровка «посмотрите в камеру».
    package var bias = Vec2(0, -0.12)
    /// Насколько ниже камеры экран, на который человек смотрит (сдвиг радужки вверх, доли полуширины).
    /// Камера над экраном ноутбука, взгляд в середину экрана — 10–20°; 0,15 ≈ 0,4·sin(22°) с учётом того,
    /// что веко поднимается вместе с радужкой. В продукте — из калибровки «посмотрите в камеру / на экран».
    package var screenLift = 0.15
    /// Какую долю вертикального сдвига радужки повторяет верхнее веко.
    package var lidFollow = 0.8
    package init() {}

    /// Вертикальный сдвиг для цели: экран ниже камеры, поэтому для взгляда в камеру радужку поднимаем.
    /// Измерить взгляд вниз надёжно нельзя (веко опускается вместе с радужкой), поэтому сдвиг относительный.
    package func verticalShift(target: GazeTarget) -> Double {
        -(screenLift + gainY * sin(target.angles.pitch * .pi / 180))
    }

    /// Где должна быть радужка (в долях полуширины), чтобы смотреть на `target` при повороте головы `headYaw`/`headPitch`.
    package func irisPosition(target: GazeTarget, headYaw: Double, headPitch: Double) -> Vec2 {
        let a = target.angles
        let yaw = (a.yaw + headYawSign * headYaw) * .pi / 180
        // pitch вверх → радужка вверх (y вниз, поэтому минус).
        let pitch = (a.pitch + headPitchSign * headPitch) * .pi / 180
        return bias + Vec2(gainX * sin(yaw), -gainY * sin(pitch))
    }
}

package struct GazeSettings: Equatable, Sendable {
    package var target: GazeTarget = .camera
    package var freedom: GazeFreedom = .normal
    package var limits = GazeLimits()
    package var calibration = GazeCalibration()
    /// Брать точную форму глаза (веки и радужку из модели), если она есть. Выключение — только для сравнения в отладке.
    package var useEyeShape = true
    package init(target: GazeTarget = .camera, freedom: GazeFreedom = .normal) {
        self.target = target; self.freedom = freedom
    }
}

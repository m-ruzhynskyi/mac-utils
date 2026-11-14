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
    /// Предел сдвига радужки по осям глаза. По горизонтали — только лёгкая доводка к центру (GAZE-35): сдвиг вбок на
    /// 8–11 px при взгляде в сторону давал клин и двойной край радужки (CHK-3, B 97–112). Камера над экраном — главное
    /// расхождение по вертикали.
    package var maxShiftX = 0.10, maxShiftY = 0.18
    /// Доводка по горизонтали гаснет, когда взгляд дальше этого от цели (доли полуширины): смотрит на край экрана —
    /// радужку к центру не тянем.
    package var horizontalFull = 0.10, horizontalOff = 0.22
    /// Подъём радужки вверх вместе с веком (A v2) — до 0,25 полуширины; с ползунком «Сила» выше 100 % — до 0,32.
    package var maxLift = 0.25, maxLiftStrong = 0.32
    /// Взгляд в сторону: радужка дальше `sideGazeFull` от середины глаза (доли полуширины) — правка слабеет,
    /// дальше `sideGazeOff` — выключена. Радужка у уголка частью под веком, сдвиг даёт клин и размытие.
    /// По записям пользователя (GAZE-35): взгляд в экран — |x| ≤ 0,2; на записи B взгляд вбок 0,33–0,36 был с полной
    /// правкой и грубыми артефактами при прежних 0,38…0,55.
    package var sideGazeFull = 0.24, sideGazeOff = 0.40
    /// Нижнее веко при подъёме радужки: закрывает такую долю открывшегося под ней белка, но не больше `maxLowerRaise`
    /// полуширины. Вместо растяжки низа радужки вниз («яйцо», CHK-3).
    package var lowerLidFollow = 0.5, maxLowerRaise = 0.10
    /// Видимая высота радужки к её диаметру: ниже Off правки нет, выше On — полная (A v3, по точным векам).
    /// По выборке w1–w6: медиана у открытых глаз 0,80–0,92, у почти закрытых (взгляд вниз) 0,65. На живой записи (очки,
    /// взгляд в экран ноутбука) — 0,70–0,80 при хорошо видной радужке: прежние 0,55…0,85 срезали там 20–40 % поправки.
    package static let narrowEyeOff = 0.45, narrowEyeOn = 0.70
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
    /// Камера над экраном ноутбука, взгляд в середину экрана — 10–15°: радужка (глазное яблоко ~12 мм, полуширина
    /// глаза ~15 мм) смещается на 0,8·sin(12…15°) ≈ 0,17–0,21. Берём 0,22: прежние 0,15 давали 4–5 px на 1080p —
    /// на живой проверке «изменений не видно». Калибровка может только увеличить (см. `liftAfterCalibration`).
    package var screenLift = GazeCalibration.defaultScreenLift
    package static let defaultScreenLift = 0.22
    /// Сдвиг радужки на радиан поворота глаза, доли полуширины: глазное яблоко ~12 мм / полуширина глаза ~15 мм.
    package static let eyeballGain = 0.8
    /// Какую долю вертикального сдвига радужки повторяет верхнее веко.
    package var lidFollow = 0.8
    package init() {}

    /// Подъём после калибровки. По радужке вертикаль меряется плохо: веко опускается вместе с ней, и разница
    /// «камера − экран» выходит заниженной (живая проверка: 0,017 при явном взгляде в экран). Поэтому для камеры над
    /// экраном калибровка может подъём только увеличить; заметно отрицательный — камера ниже экрана, берём как есть.
    package static func liftAfterCalibration(_ measured: Double) -> Double {
        measured < -0.05 ? max(measured, -0.18) : min(max(measured, defaultScreenLift), 0.30)
    }

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
    /// Ползунок «Сила»: множитель всего сдвига, 0…1,5.
    package var strength = 1.0
    package static let strengthRange = 0.0...1.5
    /// Брать точную форму глаза (веки и радужку из модели), если она есть. Выключение — только для сравнения в отладке.
    package var useEyeShape = true
    /// Веки из Face Landmarker (если модель есть). Выключение — только для сравнения в отладке (тогда веки от Iris).
    package var useFaceMesh = true
    package init(target: GazeTarget = .camera, freedom: GazeFreedom = .normal) {
        self.target = target; self.freedom = freedom
    }
}

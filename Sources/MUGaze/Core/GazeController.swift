import Foundation

/// Один глаз на кадре: рамка по контуру века и найденная радужка (nil — не нашлась).
package struct EyeInput: Equatable, Sendable {
    package var frame: EyeFrame
    package var iris: Vec2?
    /// Точная форма глаза (A v3). Если есть — рамка, веки и радужка берутся из неё (после сглаживания).
    package var shape: EyeShape?
    package init(frame: EyeFrame, iris: Vec2?, shape: EyeShape? = nil) { self.frame = frame; self.iris = iris; self.shape = shape }
}

/// Лицо на кадре. Повороты головы — в градусах, как отдаёт детектор.
package struct FaceInput: Equatable, Sendable {
    package var headYaw: Double
    package var headPitch: Double
    package var eyes: [EyeInput]
    package init(headYaw: Double, headPitch: Double, eyes: [EyeInput]) {
        self.headYaw = headYaw; self.headPitch = headPitch; self.eyes = eyes
    }
}

/// Почему поправка сейчас ослаблена (для отладки и подсказок в интерфейсе).
package struct GazeState: OptionSet, Sendable, Hashable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }
    package static let noFace = GazeState(rawValue: 1)
    package static let headTurned = GazeState(rawValue: 2)
    package static let blink = GazeState(rawValue: 4)
    package static let irisLost = GazeState(rawValue: 8)
    package static let lookingFarAway = GazeState(rawValue: 16)
    /// Глаз прищурен или опущен: переносить почти нечего, правка ослаблена.
    package static let narrowEyes = GazeState(rawValue: 32)
    /// Радужка у самого уголка (сильный взгляд в сторону): сдвигать её — тёмный клин и размытие, правка ослаблена.
    package static let sideGaze = GazeState(rawValue: 64)
}

/// Что сейчас применено к кадру — для индикатора в отладке и для разбора записей.
package struct GazeApplied: Equatable, Sendable {
    /// Сдвиг радужки в пикселях кадра (среднее по глазам, в осях глаза): x — вбок (+ вправо на кадре), y — вверх (+).
    package var pixels = Vec2.zero
    /// Итоговая сила 0…1+ (включение, моргание, узкие глаза, взгляд в сторону и ползунок «Сила»).
    package var strength = 0.0
    /// Множители по отдельности: узкие глаза и взгляд в сторону (1 — не ослаблено).
    package var openFactor = 1.0
    package var sideFactor = 1.0
    /// Положение радужки в глазу по горизонтали, доли полуширины (больший по модулю из двух глаз).
    package var irisSide = 0.0
    /// Положение радужек по горизонтали отдельно (слева на кадре, справа), доли полуширины: для разбора сведения глаз.
    package var eyeX: [Double] = []
    /// Видимый сдвиг (px, оси как у `pixels`): центр видимой части радужки после правки минус до неё. Верх радужки
    /// уходит под веко, поэтому он меньше `pixels` — именно его видит зритель (CHK-3, п. 6).
    package var visiblePixels = Vec2.zero
    package init() {}
}

package struct GazeOutput: Sendable {
    /// Сила поправки 0…1 (уже с плавными включением и выключением).
    package var weight: Double
    /// Итоговый сдвиг радужки в долях полуширины (с учётом `weight`).
    package var shift: Vec2
    /// Сдвиги для отрисовки, по одному на глаз (A v1: плавный сдвиг без века).
    package var warps: [EyeWarp]
    /// Правки для отрисовки A v2: радужка целиком, веко вместе с ней, вертикаль относительно экрана.
    package var edits: [EyeEdit] = []
    /// Измеренное положение радужки (сглаженное), куда она должна попасть, и куда попадёт.
    package var measured: Vec2?
    package var target: Vec2
    package var state: GazeState
    package var applied = GazeApplied()
}

/// Логика «Взгляда в камеру» без кадров и детекторов: по положению радужки и повороту головы решает,
/// на сколько сдвинуть радужку. Вызывается раз на кадр.
package final class GazeController {
    package var settings: GazeSettings

    private var gazeFilter = OneEuroFilter()
    private var baseline: ExpSmoother
    private var micro: MicroSaccades
    private var mainFade = Fade(0)
    private var blinkFade = Fade(1)
    private var openBaseline: Double?
    private var lastTime: Double?
    private var lastShift = Vec2.zero
    private var lastEyes: [EyeFrame] = []
    private var eyeFilters: [OneEuroFilter] = [OneEuroFilter(), OneEuroFilter()]
    private var lastIris: [Vec2?] = [nil, nil]
    private var lastShiftV2 = Vec2.zero
    private var shapeSmoothers = [EyeShapeSmoother(), EyeShapeSmoother()]
    private var lastShapes: [EyeShape?] = [nil, nil]
    private var headOff = false
    private var farOff = false
    private var sideSmooth: Double?

    package init(settings: GazeSettings = GazeSettings(), seed: UInt64 = 0x6A2E) {
        self.settings = settings
        baseline = ExpSmoother(tau: settings.limits.baselineSeconds)
        micro = MicroSaccades(seed: seed)
    }

    package func reset() {
        gazeFilter.reset(); baseline.reset(); mainFade = Fade(0); blinkFade = Fade(1)
        openBaseline = nil; lastTime = nil; lastShift = .zero; lastEyes = []; headOff = false; farOff = false; sideSmooth = nil
        eyeFilters = [OneEuroFilter(), OneEuroFilter()]; lastIris = [nil, nil]; lastShiftV2 = .zero
        shapeSmoothers = [EyeShapeSmoother(), EyeShapeSmoother()]; lastShapes = [nil, nil]
    }

    /// `time` — время кадра в секундах, `face` — nil, если лица нет.
    package func step(time: Double, face rawFace: FaceInput?) -> GazeOutput {
        let L = settings.limits
        let dt = lastTime.map { min(max(time - $0, 0), 0.25) } ?? 0
        lastTime = time
        // Точная форма глаза: сглаживаем и подставляем вместо рамки и радужки от детектора.
        var face = rawFace
        if !settings.useEyeShape, var f = face {
            f.eyes = f.eyes.map { EyeInput(frame: $0.frame, iris: $0.iris, shape: nil) }
            face = f
        }
        if var f = face {
            for k in f.eyes.indices.prefix(2) {
                guard let sh = f.eyes[k].shape else { shapeSmoothers[k].reset(); lastShapes[k] = nil; continue }
                let sm = shapeSmoothers[k].filter(sh, dt: dt)
                lastShapes[k] = sm
                f.eyes[k] = EyeInput(frame: sm.frame(axis: f.eyes[k].frame.ex), iris: sm.iris, shape: sm)
            }
            face = f
        } else {
            shapeSmoothers = [EyeShapeSmoother(), EyeShapeSmoother()]
        }
        var state: GazeState = []

        guard let face, !face.eyes.isEmpty else {
            state.insert(.noFace)
            mainFade.advance(toward: 0, dt: dt, duration: L.fadeSeconds)
            if mainFade.linear == 0 { gazeFilter.reset(); baseline.reset() }
            return output(weight: mainFade.value * blinkFade.value, shift: lastShift, target: .zero, state: state)
        }
        lastEyes = face.eyes.map(\.frame)

        // Поворот головы с гистерезисом.
        let yaw = abs(face.headYaw), pitch = abs(face.headPitch)
        if headOff { headOff = yaw > L.headYawOn || pitch > L.headPitchOn }
        else { headOff = yaw > L.headYawOff || pitch > L.headPitchOff }
        if headOff { state.insert(.headTurned) }

        // Моргание: раскрытие заметно меньше обычного для этого человека. Берём меньшее из сглаженного и сырого:
        // на быстром закрытии сглаживание формы отстаёт на кадр, и правка шла полной на первом кадре моргания (CHK-3, п. 3).
        let smoothOpen = face.eyes.map(\.frame.openness).reduce(0, +) / Double(face.eyes.count)
        let openness = min(smoothOpen, rawOpenness(rawFace, axes: face.eyes.map(\.frame.ex)) ?? smoothOpen)
        if let base = openBaseline {
            if smoothOpen > base * 0.8 { openBaseline = base + (smoothOpen - base) * (1 - exp(-dt / 2.0)) }
        } else {
            openBaseline = smoothOpen
        }
        let blink = openness < (openBaseline ?? openness) * L.blinkRatio
        if blink { state.insert(.blink) }

        // Положение радужки: среднее по глазам, в долях полуширины.
        let measures = face.eyes.compactMap { e in e.iris.map { e.frame.local($0) } }
        if measures.isEmpty { state.insert(.irisLost) }
        let measuring = !blink && !measures.isEmpty
        let target = settings.calibration.irisPosition(target: settings.target, headYaw: face.headYaw, headPitch: face.headPitch)

        var shift = lastShift
        var shiftV2 = lastShiftV2
        if measuring {
            // Каждая радужка отдельно — для переноса радужки целиком (A v2): её край должен совпасть с настоящим.
            for (k, e) in face.eyes.prefix(2).enumerated() {
                if e.shape != nil { lastIris[k] = e.iris; continue } // уже сглажено вместе с формой
                if let iris = e.iris { lastIris[k] = e.frame.image(eyeFilters[k].filter(e.frame.local(iris), dt: dt)) }
            }
            let raw = measures.reduce(Vec2.zero, +) / Double(measures.count)
            let g = gazeFilter.filter(raw, dt: dt)
            let base = baseline.update(g, dt: dt)
            let p = settings.freedom.parameters
            let keep = ((g - base) * p.keepGain).clampedLength(p.keepRadius)
            let desired = target + keep + micro.offset(at: time, parameters: p)
            shift = desired - g
            // По горизонтали — только доводка рядом с целью; смотрит в сторону — радужку к центру не тянем.
            shift.x *= 1 - smoothstep(L.horizontalFull, L.horizontalOff, abs(g.x - target.x))
            shift.x = min(max(shift.x, -L.maxShiftX), L.maxShiftX)
            shift.y = min(max(shift.y, -L.maxShiftY), L.maxShiftY)
            // A v2: горизонталь та же, вертикаль — подъём «экран ниже камеры» плюс свои движения и микросаккады.
            let vertical = settings.calibration.verticalShift(target: settings.target) + (desired.y - target.y)
            shiftV2 = Vec2(shift.x, min(max(vertical, -L.maxLift), L.maxShiftY))
            lastShiftV2 = shiftV2
            let away = (base - target).length
            farOff = farOff ? away > L.maxCorrectionOn : away > L.maxCorrection
            lastShift = shift
        }
        if farOff { state.insert(.lookingFarAway) }

        // Во время моргания поправка держится прежней (её гасит blinkFade); радужка потеряна без моргания — плавно выключаем.
        let active = !headOff && !farOff && gazeFilter.current != nil && (measuring || blink)
        mainFade.advance(toward: active ? 1 : 0, dt: dt, duration: L.fadeSeconds)
        // Закрытие — сразу в этом кадре (иначе тёмный «горб» радужки над веком), открытие — плавно.
        if blink { blinkFade = Fade(0) } else { blinkFade.advance(toward: 1, dt: dt, duration: L.blinkFadeSeconds) }
        var out = output(weight: mainFade.value * blinkFade.value, shift: shift, target: target, state: state)
        let side = sideFactor(face: face, dt: dt, frozen: blink)
        out.applied.irisSide = side.position
        out.applied.eyeX = face.eyes.prefix(2).map { e in e.iris.map { e.frame.local($0).x } ?? .nan }
        out.edits = edits(weight: out.weight, shift: shiftV2, face: face, rawFace: rawFace, sideFactor: side.factor, applied: &out.applied)
        if out.applied.openFactor < 0.9 { out.state.insert(.narrowEyes) }
        if side.factor < 0.9 { out.state.insert(.sideGaze) }
        return out
    }

    /// Взгляд сильно в сторону: радужка у уголка, часть её под углом века. Тянуть её к центру — тёмный клин
    /// и размазанная радужка (живая проверка GAZE-33), поэтому правка плавно гаснет от `sideGazeFull` до `sideGazeOff`.
    /// Сглажено во времени, чтобы на саккаде в сторону и обратно не было рывка.
    private func sideFactor(face: FaceInput, dt: Double, frozen: Bool) -> (factor: Double, position: Double) {
        let L = settings.limits
        // В моргании радужка закрытого глаза ненадёжна: фактор держим прежним, без «пульса» после моргания.
        if frozen, let held = sideSmooth { return (held, 0) }
        let positions = face.eyes.prefix(2).compactMap { e in e.iris.map { e.frame.local($0).x - settings.calibration.bias.x } }
        guard let side = positions.max(by: { abs($0) < abs($1) }) else { return (sideSmooth ?? 1, 0) }
        let raw = 1 - smoothstep(L.sideGazeFull, L.sideGazeOff, abs(side))
        // Гаснет быстро (радужка уже у уголка), возвращается медленнее.
        let tau = raw < (sideSmooth ?? raw) ? 0.06 : 0.25
        let next = sideSmooth.map { $0 + (raw - $0) * (1 - exp(-dt / tau)) } ?? raw
        sideSmooth = next
        return (next, side)
    }

    /// Насколько глаз открыт для правки (по точным векам): видимая высота радужки к её диаметру.
    /// Узкая щель (прищур, улыбка, сильный взгляд вниз) — переносить нечего, правка плавно гаснет.
    static func openFactor(_ shape: EyeShape, frame: EyeFrame) -> Double {
        let lids = shape.lidCurves(in: frame)
        let u = (shape.iris - frame.center).dot(frame.ex)
        let open = lids.bottom(u) - lids.top(u)
        return smoothstep(GazeLimits.narrowEyeOff, GazeLimits.narrowEyeOn, open / max(2 * shape.irisRadius, 1))
    }

    /// Раскрытие по несглаженным формам (как `EyeFrame.openness`), nil — форм нет.
    private func rawOpenness(_ raw: FaceInput?, axes: [Vec2]) -> Double? {
        guard let raw, settings.useEyeShape else { return nil }
        let values = raw.eyes.prefix(2).enumerated().compactMap { k, e in e.shape.map { $0.frame(axis: k < axes.count ? axes[k] : e.frame.ex).openness } }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private func edits(weight rawWeight: Double, shift rawShift: Vec2, face: FaceInput, rawFace: FaceInput?, sideFactor: Double, applied: inout GazeApplied) -> [EyeEdit] {
        // Одинаково для обоих глаз, чтобы взгляд не расходился. Сырая форма не даёт сглаживанию опоздать на кадр,
        // когда глаз быстро закрывается.
        let opens = face.eyes.prefix(2).compactMap { e in e.shape.map { Self.openFactor($0, frame: e.frame) } }
        var open = opens.min() ?? 1
        if let raw = rawFace, settings.useEyeShape {
            let rawOpen = raw.eyes.prefix(2).enumerated().compactMap { k, e in
                e.shape.map { Self.openFactor($0, frame: $0.frame(axis: k < face.eyes.count ? face.eyes[k].frame.ex : e.frame.ex)) }
            }.min()
            // Только заметное падение (не шум формы): глаз закрывается быстрее, чем догоняет сглаживание.
            if let r = rawOpen, r < open - 0.15 { open = r }
        }
        applied.openFactor = open; applied.sideFactor = sideFactor
        let L = settings.limits
        let weight = rawWeight * open * sideFactor
        guard weight > 0.01, settings.strength > 0.01 else { return [] }
        // «Сила» масштабирует сдвиг; пределы — после неё, чтобы ползунок не выводил радужку за веко.
        var s = rawShift * (weight * settings.strength)
        s.x = min(max(s.x, -L.maxShiftX), L.maxShiftX)
        s.y = min(max(s.y, -L.maxLiftStrong), L.maxShiftY)
        applied.strength = weight * settings.strength
        let eyes = face.eyes.prefix(2)
        applied.pixels = eyes.map { Vec2(s.x * $0.frame.halfWidth, -s.y * $0.frame.halfWidth) }.reduce(.zero, +) / Double(max(eyes.count, 1))
        let cal = settings.calibration
        let list: [EyeEdit] = face.eyes.prefix(2).enumerated().compactMap { k, e in
            guard var iris = lastIris[k] else { return nil }
            // На саккаде сглаженный центр отстаёт от радужки: вырезали бы круг не там, и край настоящей радужки остался
            // бы вторым контуром (запись B, кадр 172). Чем больше расхождение с сырым центром, тем ближе к сырому.
            if let sh = e.shape, let raw = rawFace?.eyes[safe: k]?.shape?.iris {
                let d = (raw - iris).length, r = sh.irisRadius
                iris = iris + (raw - iris) * smoothstep(0.05 * r, 0.15 * r, d)
            }
            let a = e.frame.halfWidth
            if let sh = e.shape {
                // Радиус с запасом на тёмный лимб: переносим радужку вместе с её краем.
                let lids = sh.lidCurves(in: e.frame), r = sh.irisRadius * 1.08 + 0.5, shift = e.frame.imageVector(s)
                // Нижнее веко чуть поднимается и закрывает часть белка, открывшегося под радужкой (без растяжки радужки).
                let gap = EyeEdit.lowerGap(for: e.frame, lids: lids, iris: iris, irisRadius: sh.irisRadius, shift: shift)
                let lower = min(gap * L.lowerLidFollow, L.maxLowerRaise * a)
                return EyeEdit(frame: e.frame, iris: iris, irisRadius: r, shift: shift, lidRaise: -s.y * cal.lidFollow * a, lids: lids, lowerRaise: lower)
            }
            return EyeEdit(frame: e.frame, iris: iris, irisRadius: IrisLocator.radiusRatio * a * 1.1,
                           shift: e.frame.imageVector(s), lidRaise: -s.y * cal.lidFollow * a)
        }
        if !list.isEmpty {
            applied.visiblePixels = list.map { e -> Vec2 in let v = e.visibleShift; return Vec2(v.x, -v.y) }.reduce(.zero, +) / Double(list.count)
        }
        return list
    }

    private func output(weight: Double, shift: Vec2, target: Vec2, state: GazeState) -> GazeOutput {
        let s = shift * weight
        let warps = weight > 0 ? lastEyes.map { EyeWarp(frame: $0, shift: $0.imageVector(s)) } : []
        return GazeOutput(weight: weight, shift: s, warps: warps, measured: gazeFilter.current, target: target, state: state)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

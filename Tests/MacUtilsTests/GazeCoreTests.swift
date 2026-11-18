import XCTest
@testable import MUGaze

/// Синтетический глаз: светлый эллипс-белок, тёмный диск-радужка, кожа вокруг.
private struct SyntheticEye: LumaSampler {
    var frame: EyeFrame
    var iris: Vec2
    var irisRadius: Double
    var glare: (center: Vec2, radius: Double)? = nil
    func luma(_ p: Vec2) -> Double {
        if let g = glare, (p - g.center).length < g.radius { return 1 }
        guard frame.contains(p) else { return 0.55 }
        return (p - iris).length <= irisRadius ? 0.15 : 0.85
    }
}

private func eyeFrame(center: Vec2 = Vec2(100, 100), halfWidth: Double = 20, open: Double = 0.4) -> EyeFrame {
    EyeFrame(center: center, ex: Vec2(1, 0), halfWidth: halfWidth, halfHeight: halfWidth * open)
}

private func face(irisLocal: Vec2, yaw: Double = 0, pitch: Double = 0, open: Double = 0.4, irisVisible: Bool = true) -> FaceInput {
    let eyes = [Vec2(100, 100), Vec2(180, 100)].map { c -> EyeInput in
        let f = eyeFrame(center: c, open: open)
        return EyeInput(frame: f, iris: irisVisible ? f.image(irisLocal) : nil)
    }
    return FaceInput(headYaw: yaw, headPitch: pitch, eyes: eyes)
}

/// Куда попадёт радужка после сдвига (в долях полуширины).
private func outputIris(_ out: GazeOutput, measured: Vec2) -> Vec2 { measured + out.shift }

final class GazeGeometryTests: XCTestCase {
    func testEyeFrameFitFromContour() throws {
        let contour = (0..<8).map { i -> Vec2 in
            let a = Double(i) / 8 * 2 * .pi
            return Vec2(50 + 20 * cos(a), 40 + 7 * sin(a))
        }
        let f = try XCTUnwrap(EyeFrame.fit(contour: contour, axis: Vec2(3, 0)))
        XCTAssertEqual(f.center.x, 50, accuracy: 1e-9)
        XCTAssertEqual(f.center.y, 40, accuracy: 1e-9)
        XCTAssertEqual(f.halfWidth, 20, accuracy: 1e-9)
        XCTAssertEqual(f.halfHeight, 7 * sin(2 * .pi * 2 / 8), accuracy: 1e-9)
        XCTAssertEqual(f.ey, Vec2(0, 1))
    }

    func testLocalImageRoundTripOnRotatedEye() {
        let f = EyeFrame(center: Vec2(10, 20), ex: Vec2(cos(0.3), sin(0.3)), halfWidth: 15, halfHeight: 5)
        let p = Vec2(17, 26)
        let back = f.image(f.local(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
    }

    func testWarpKeepsLidsAndCornersAndMovesIrisWhole() {
        let f = eyeFrame()
        let w = EyeWarp(frame: f, shift: Vec2(6, 0))
        XCTAssertEqual(w.weight(at: f.center), 1, accuracy: 1e-9)
        XCTAssertEqual(w.weight(at: f.image(Vec2(0.3, 0))), 1, accuracy: 1e-9)
        XCTAssertEqual(w.weight(at: f.image(Vec2(1.0, 0))), 0, accuracy: 1e-9, "уголок глаза не двигается")
        XCTAssertEqual(w.weight(at: f.center + Vec2(0, f.halfHeight * 1.31)), 0, accuracy: 1e-9, "веко над радужкой не двигается")
        XCTAssertEqual(w.weight(at: f.image(Vec2(0.6, 0)) + Vec2(0, f.halfHeight * 1.1)), 0, accuracy: 1e-9, "веко у уголка не двигается")
        let s = w.source(for: f.center + Vec2(6, 0))
        XCTAssertEqual(s.x, f.center.x, accuracy: 1e-9)
    }
}

final class GazeIrisLocatorTests: XCTestCase {
    func testFindsIrisWithinOnePixel() throws {
        let f = eyeFrame()
        for local in [Vec2(0, 0), Vec2(0.35, 0), Vec2(-0.4, 0.05), Vec2(0.2, -0.08)] {
            let truth = f.image(local)
            let img = SyntheticEye(frame: f, iris: truth, irisRadius: 8.4)
            let fit = try XCTUnwrap(IrisLocator.locate(in: f, image: img))
            // Часть диска под веком срезана, поэтому центр масс видимой части по вертикали смещается к середине глаза.
            XCTAssertEqual(fit.center.x, truth.x, accuracy: 1.0, "\(local)")
            XCTAssertEqual(fit.center.y, truth.y, accuracy: 1.5, "\(local)")
            XCTAssertGreaterThan(fit.contrast, 0.5)
        }
    }

    func testCatchlightInsideIrisDoesNotPullCenter() throws {
        let f = eyeFrame()
        let truth = f.image(Vec2(0.25, 0))
        let img = SyntheticEye(frame: f, iris: truth, irisRadius: 8.4, glare: (truth + Vec2(-3, -2), 2.2))
        let fit = try XCTUnwrap(IrisLocator.locate(in: f, image: img))
        XCTAssertEqual(fit.center.x, truth.x, accuracy: 1.0)
        XCTAssertEqual(fit.center.y, truth.y, accuracy: 1.5)
    }

    func testClosedEyeAndFlatEyeGiveNothing() {
        let closed = eyeFrame(open: 0.08)
        XCTAssertNil(IrisLocator.locate(in: closed, image: SyntheticEye(frame: closed, iris: closed.center, irisRadius: 8)))
        let f = eyeFrame()
        struct Flat: LumaSampler { func luma(_ p: Vec2) -> Double { 0.5 } }
        XCTAssertNil(IrisLocator.locate(in: f, image: Flat()), "без контраста радужки нет")
    }
}

final class GazeControllerTests: XCTestCase {
    private let fps = 30.0

    /// Прогоняет `seconds` секунд с постоянным взглядом и отдаёт выходы.
    private func run(_ c: GazeController, from t0: Double = 0, seconds: Double, face f: (Double) -> FaceInput?) -> [GazeOutput] {
        stride(from: t0, to: t0 + seconds, by: 1 / fps).map { c.step(time: $0, face: f($0)) }
    }

    func testLooksAtCameraWhenUserLooksAtScreen() {
        let c = GazeController(settings: GazeSettings(target: .camera, freedom: .low))
        let look = Vec2(0.06, 0.02) // чуть вправо и чуть вниз, на экран (вертикаль в пределах maxShiftY)
        let outs = run(c, seconds: 3) { _ in face(irisLocal: look) }
        let last = outs.suffix(30)
        XCTAssertEqual(last.last!.weight, 1, accuracy: 1e-9)
        for o in last {
            let iris = outputIris(o, measured: look)
            XCTAssertLessThan((iris - o.target).length, 0.06, "радужка у цели в пределах «свободы»")
        }
        // GAZE-35: смотрит на край экрана — по горизонтали к центру не тянем (клин и двойной край радужки).
        let side = GazeController(settings: GazeSettings(target: .camera, freedom: .low))
        let o = run(side, seconds: 3) { _ in face(irisLocal: Vec2(0.3, 0.02)) }.last!
        XCTAssertEqual(o.shift.x, 0, accuracy: 0.005)
        XCTAssertLessThan(abs(o.shift.y - outs.last!.shift.y), 0.01, "вертикаль та же")
    }

    func testSlightlyBelowAndCustomPointMoveTarget() {
        let cal = GazeCalibration()
        let cam = cal.irisPosition(target: .camera, headYaw: 0, headPitch: 0)
        let below = cal.irisPosition(target: .slightlyBelow, headYaw: 0, headPitch: 0)
        let right = cal.irisPosition(target: .point(yaw: 10, pitch: 0), headYaw: 0, headPitch: 0)
        XCTAssertGreaterThan(below.y, cam.y, "ниже камеры — радужка ниже (y вниз)")
        XCTAssertEqual(below.x, cam.x, accuracy: 1e-12)
        XCTAssertEqual(right.x - cam.x, cal.gainX * sin(10 * .pi / 180), accuracy: 1e-12)
    }

    func testHeadYawIsCompensatedByEyes() {
        let cal = GazeCalibration()
        let turned = cal.irisPosition(target: .camera, headYaw: 15, headPitch: 0)
        XCTAssertEqual(turned.x - cal.bias.x, -cal.gainX * sin(15 * .pi / 180), accuracy: 1e-12)
    }

    func testFreedomControlsSpread() {
        func spread(_ freedom: GazeFreedom) -> Double {
            let c = GazeController(settings: GazeSettings(freedom: freedom), seed: 7)
            // Человек бегает глазами по экрану: быстрые движения вокруг (0.3, 0.1).
            let outs = run(c, seconds: 12) { t in
                face(irisLocal: Vec2(0.3 + 0.12 * sin(t * 2.3) + 0.06 * sin(t * 7.1), 0.1 + 0.04 * sin(t * 3.7)))
            }
            let pts = outs.dropFirst(60).map { o in outputIris(o, measured: o.measured!) - o.target }
            let mean = pts.reduce(Vec2.zero, +) / Double(pts.count)
            return (pts.map { ($0 - mean).length * ($0 - mean).length }.reduce(0, +) / Double(pts.count)).squareRoot()
        }
        let low = spread(.low), normal = spread(.normal), high = spread(.high)
        XCTAssertLessThan(low, normal)
        XCTAssertLessThan(normal, high)
        XCTAssertLessThan(high, 0.25, "даже «много» держит взгляд около цели")
        XCTAssertGreaterThan(low, 0.005, "глаза не замирают")
    }

    func testNoFrameToFrameJitter() {
        let c = GazeController(seed: 3)
        var rng = SplitMix64(seed: 11)
        // Шум измерения радужки ±0,03 полуширины на каждом кадре.
        let outs = run(c, seconds: 6) { _ in face(irisLocal: Vec2(0.25 + 0.03 * (rng.unit() * 2 - 1), 0.1)) }
        var jumps: [Double] = []
        for (a, b) in zip(outs.dropFirst(45), outs.dropFirst(46)) {
            jumps.append((outputIris(b, measured: b.measured!) - outputIris(a, measured: a.measured!)).length)
        }
        jumps.sort()
        XCTAssertLessThan(jumps[jumps.count / 2], 0.01, "медианный шаг между кадрами — меньше 1% полуширины")
    }

    func testBlinkPassesUnchanged() {
        let c = GazeController()
        _ = run(c, seconds: 2) { _ in face(irisLocal: Vec2(0.3, 0.1)) }
        let blink = run(c, from: 2, seconds: 0.2) { _ in face(irisLocal: Vec2(0.3, 0.1), open: 0.08, irisVisible: false) }
        XCTAssertTrue(blink[0].state.contains(.blink))
        XCTAssertLessThan(blink[2].weight, 0.05, "к третьему кадру моргания поправки нет")
        let after = run(c, from: 2.2, seconds: 0.3) { _ in face(irisLocal: Vec2(0.3, 0.1)) }
        XCTAssertGreaterThan(after.last!.weight, 0.95, "после моргания поправка возвращается сразу")
    }

    func testHeadTurnFadesOutSmoothly() {
        let c = GazeController()
        _ = run(c, seconds: 2) { _ in face(irisLocal: Vec2(0.2, 0.1)) }
        let turned = run(c, from: 2, seconds: 1) { _ in face(irisLocal: Vec2(0.2, 0.1), yaw: 35) }
        XCTAssertTrue(turned[0].state.contains(.headTurned))
        let weights = turned.map(\.weight)
        XCTAssertGreaterThan(weights[2], 0.5, "не выключается рывком")
        XCTAssertEqual(weights.last!, 0, accuracy: 1e-9)
        for (a, b) in zip(weights, weights.dropFirst()) {
            XCTAssertLessThanOrEqual(b, a + 1e-12)
            XCTAssertLessThan(a - b, 0.25, "шаг выключения меньше четверти за кадр")
        }
    }

    func testHeadTurnHysteresis() {
        let c = GazeController()
        _ = run(c, seconds: 1) { _ in face(irisLocal: Vec2(0.2, 0.1), yaw: 30) }
        let o = c.step(time: 1.1, face: face(irisLocal: Vec2(0.2, 0.1), yaw: 22))
        XCTAssertTrue(o.state.contains(.headTurned), "между порогами остаётся выключенной")
        let back = run(c, from: 1.2, seconds: 1) { _ in face(irisLocal: Vec2(0.2, 0.1), yaw: 10) }
        XCTAssertGreaterThan(back.last!.weight, 0.99)
    }

    func testFaceLossFadesOutKeepingLastEyes() {
        let c = GazeController()
        _ = run(c, seconds: 2) { _ in face(irisLocal: Vec2(0.3, 0.1)) }
        let lost = run(c, from: 2, seconds: 0.6) { _ in nil }
        XCTAssertTrue(lost[0].state.contains(.noFace))
        XCTAssertGreaterThan(lost[1].weight, 0.5)
        XCTAssertEqual(lost[1].warps.count, 2, "пока гаснет, сдвиг рисуется по последним глазам")
        XCTAssertEqual(lost.last!.weight, 0, accuracy: 1e-9)
        XCTAssertTrue(lost.last!.warps.isEmpty)
    }

    func testLookingFarAwayTurnsOff() {
        let c = GazeController()
        let outs = run(c, seconds: 3) { _ in face(irisLocal: Vec2(0.95, 0.1)) }
        XCTAssertTrue(outs.last!.state.contains(.lookingFarAway))
        XCTAssertEqual(outs.last!.weight, 0, accuracy: 1e-9)
    }

    func testShiftIsClamped() {
        var s = GazeSettings()
        s.limits.maxCorrection = 10; s.limits.maxCorrectionOn = 10
        let c = GazeController(settings: s)
        let outs = run(c, seconds: 2) { _ in face(irisLocal: Vec2(0.8, -0.5)) }
        XCTAssertLessThanOrEqual(abs(outs.last!.shift.x), s.limits.maxShiftX + 1e-9)
        XCTAssertLessThanOrEqual(abs(outs.last!.shift.y), s.limits.maxShiftY + 1e-9)
    }

    func testMicroSaccadesDeterministicAndBounded() {
        let p = GazeFreedom.normal.parameters
        var a = MicroSaccades(seed: 42), b = MicroSaccades(seed: 42)
        var maxLen = 0.0, moved = 0
        var prev = Vec2.zero
        for i in 0..<900 {
            let t = Double(i) / 30
            let x = a.offset(at: t, parameters: p), y = b.offset(at: t, parameters: p)
            XCTAssertEqual(x, y)
            maxLen = max(maxLen, x.length)
            if (x - prev).length > 0.01 { moved += 1 }
            prev = x
        }
        XCTAssertLessThan(maxLen, p.microAmplitude + 4 * p.driftAmplitude)
        XCTAssertGreaterThan(moved, 10, "за 30 с есть заметные микросаккады")
    }
}

final class GazeV2Tests: XCTestCase {
    func testScreenLiftRaisesIrisAndLid() {
        let c = GazeController()
        var last: GazeOutput?
        for i in 0..<60 {
            let f = FaceInput(headYaw: 0, headPitch: 0, eyes: [Vec2(100, 100), Vec2(180, 100)].map { c0 -> EyeInput in
                let fr = EyeFrame(center: c0, ex: Vec2(1, 0), halfWidth: 20, halfHeight: 8)
                return EyeInput(frame: fr, iris: fr.image(Vec2(0.05, 0.1)))
            })
            last = c.step(time: Double(i) / 30, face: f)
        }
        let o = try! XCTUnwrap(last)
        XCTAssertEqual(o.edits.count, 2)
        for e in o.edits {
            XCTAssertLessThan(e.shift.y, -0.1 * 20 + 0.6, "радужка поднимается примерно на screenLift")
            XCTAssertGreaterThan(e.lidRaise, 0.1 * 20 * 0.8 - 0.6, "веко поднимается вместе с ней")
            XCTAssertEqual(e.lidRaise, -e.shift.y * 0.8, accuracy: 1e-9)
        }
    }

    func testLiftIsClamped() {
        var s = GazeSettings(); s.calibration.screenLift = 0.6
        let c = GazeController(settings: s)
        var o: GazeOutput?
        for i in 0..<60 {
            let fr = EyeFrame(center: Vec2(100, 100), ex: Vec2(1, 0), halfWidth: 20, halfHeight: 8)
            o = c.step(time: Double(i) / 30, face: FaceInput(headYaw: 0, headPitch: 0, eyes: [EyeInput(frame: fr, iris: fr.center)]))
        }
        XCTAssertGreaterThanOrEqual(o!.edits[0].shift.y, -s.limits.maxLift * 20 - 1e-9)
    }
}

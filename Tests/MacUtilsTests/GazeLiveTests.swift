import XCTest
@testable import MUGaze

/// GAZE-34: по живой проверке на камере пользователя — заметная поправка по умолчанию, «Сила», ослабление при
/// сильном взгляде в сторону, нижний край радужки, веки из Face Landmarker.
final class GazeLiveTests: XCTestCase {
    private func face(irisX: Double, irisY: Double = 0.05) -> FaceInput {
        FaceInput(headYaw: 0, headPitch: 0, eyes: [Vec2(100, 100), Vec2(180, 100)].map { c -> EyeInput in
            let fr = EyeFrame(center: c, ex: Vec2(1, 0), halfWidth: 20, halfHeight: 8)
            return EyeInput(frame: fr, iris: fr.image(Vec2(irisX, irisY)))
        })
    }

    private func settle(_ c: GazeController, irisX: Double = 0, seconds: Double = 2, from t0: Double = 0) -> GazeOutput {
        var o: GazeOutput?
        for i in 0..<Int(seconds * 30) { o = c.step(time: t0 + Double(i) / 30, face: face(irisX: irisX)) }
        return o!
    }

    // MARK: Заметная поправка по умолчанию

    func testDefaultLiftIsVisibleOnLaptop() {
        let o = settle(GazeController())
        // Полуширина 20 px → подъём 0,22 = 4,4 px (на живой записи 1080p полуширина ~30 px → ~7–8 px).
        XCTAssertEqual(o.applied.pixels.y, GazeCalibration.defaultScreenLift * 20, accuracy: 1.2)
        XCTAssertEqual(o.applied.strength, 1, accuracy: 0.01)
        XCTAssertTrue(o.state.isEmpty)
    }

    func testCalibrationNeverLowersLiftForCameraAboveScreen() {
        XCTAssertEqual(GazeCalibration.liftAfterCalibration(0.0166), GazeCalibration.defaultScreenLift, "живая проверка: намерено 0,017")
        XCTAssertEqual(GazeCalibration.liftAfterCalibration(0.27), 0.27)
        XCTAssertEqual(GazeCalibration.liftAfterCalibration(0.5), 0.30)
        XCTAssertEqual(GazeCalibration.liftAfterCalibration(-0.12), -0.12, "камера ниже экрана — как намерено")
        XCTAssertEqual(GazeCalibration.liftAfterCalibration(-0.4), -0.18)
        XCTAssertEqual(GazeCalibrationRecorder.Result(biasX: 0, screenLift: 0.22).screenAngleDegrees(), 16, accuracy: 1)
    }

    // MARK: «Сила»

    func testStrengthScalesShiftWithinLimits() {
        func lift(_ k: Double) -> Double {
            var s = GazeSettings(); s.strength = k
            return settle(GazeController(settings: s)).applied.pixels.y
        }
        let base = lift(1)
        XCTAssertEqual(lift(0.5), base * 0.5, accuracy: 0.3)
        XCTAssertEqual(lift(1.5), min(base * 1.5, GazeLimits().maxLiftStrong * 20 + 1), accuracy: 0.6)
        XCTAssertLessThanOrEqual(lift(1.5), GazeLimits().maxLiftStrong * 20 + 1.2, "радужка не уходит за веко")
        var s = GazeSettings(); s.strength = 0
        XCTAssertTrue(settle(GazeController(settings: s)).edits.isEmpty, "сила 0 — кадр без правки")
    }

    // MARK: Взгляд в сторону

    func testModerateSideGazeKeepsCorrection() {
        let o = settle(GazeController(), irisX: 0.2) // взгляд в экран на записях пользователя — |x| ≤ 0,2
        XCTAssertEqual(o.applied.sideFactor, 1, accuracy: 0.01)
        XCTAssertFalse(o.state.contains(.sideGaze))
        XCTAssertFalse(o.edits.isEmpty)
    }

    func testStrongSideGazeFadesOutSmoothlyAndComesBack() {
        let c = GazeController()
        _ = settle(c, irisX: 0.1)
        var prev = 1.0, maxJump = 0.0, t = 2.0
        // Радужка уходит к уголку за 0,3 с и стоит там 1 с.
        for i in 0..<40 {
            let x = 0.1 + 0.55 * min(Double(i) / 9, 1)
            let o = c.step(time: t, face: face(irisX: x)); t += 1.0 / 30
            maxJump = max(maxJump, abs(o.applied.sideFactor - prev)); prev = o.applied.sideFactor
            if i == 39 {
                XCTAssertLessThan(o.applied.sideFactor, 0.02)
                XCTAssertTrue(o.edits.isEmpty, "радужку у уголка не тянем")
                XCTAssertTrue(o.state.contains(.sideGaze))
            }
        }
        XCTAssertLessThan(maxJump, 0.35, "гаснет плавно, без рывка")
        var back: GazeOutput?
        for _ in 0..<45 { back = c.step(time: t, face: face(irisX: 0.1)); t += 1.0 / 30 }
        XCTAssertGreaterThan(back!.applied.sideFactor, 0.95, "возвращается за ~1 с")
        XCTAssertFalse(back!.edits.isEmpty)
    }

    // MARK: Нижний край радужки

    func testNoDownwardStretchWhenScleraShowsBelowIris() {
        let fr = EyeFrame(center: Vec2(100, 100), ex: Vec2(1, 0), halfWidth: 30, halfHeight: 12)
        let lids = LidCurves(halfWidth: 30, top: [-12, -12], bottom: [12, 12])
        // Широко раскрытый глаз: под радужкой 4 px белка — подъём честно открывает белок.
        XCTAssertEqual(EyeEdit.lowerGap(for: fr, lids: lids, iris: Vec2(100, 98), irisRadius: 10, shift: Vec2(0, -6)), 0)
        // Радужка уходит под веко на 1 px — растягиваем на недостающие 5 px.
        XCTAssertEqual(EyeEdit.lowerGap(for: fr, lids: lids, iris: Vec2(100, 103), irisRadius: 10, shift: Vec2(0, -6)), 5, accuracy: 1e-9)
    }

    // MARK: Face Landmarker

    func testFaceMeshEyeTakesLidsFromMeshAndIrisFromIrisModel() throws {
        var pts = [Vec2](repeating: Vec2(0, 0), count: 478)
        let e = EyeShape.faceMeshEyes[1]
        pts[e.corners.0] = Vec2(200, 100); pts[e.corners.1] = Vec2(260, 100)
        for (k, i) in e.upper.enumerated() { pts[i] = Vec2(205 + Double(k) * 7.5, 90) }
        for (k, i) in e.lower.enumerated() { pts[i] = Vec2(205 + Double(k) * 7.5, 110) }
        pts[e.iris] = Vec2(230, 100)
        for (k, i) in e.irisEdge.enumerated() { pts[i] = Vec2(230, 100) + [Vec2(9, 0), Vec2(0, -9), Vec2(-9, 0), Vec2(0, 9)][k] }
        let own = try XCTUnwrap(EyeShape.fromFaceMesh(pts, eye: 1, axis: Vec2(1, 0)))
        XCTAssertEqual(own.iris, Vec2(230, 100)); XCTAssertEqual(own.irisRadius, 9, accuracy: 1e-9)
        XCTAssertEqual(own.upper.count, 9); XCTAssertEqual(own.cornerA, Vec2(200, 100)); XCTAssertEqual(own.cornerB, Vec2(260, 100))
        let mixed = try XCTUnwrap(EyeShape.fromFaceMesh(pts, eye: 1, iris: (Vec2(232, 101), 11), axis: Vec2(1, 0)))
        XCTAssertEqual(mixed.iris, Vec2(232, 101)); XCTAssertEqual(mixed.irisRadius, 11)
        // Ось глаз в другую сторону — веки разворачиваются (A — левее по оси).
        let flipped = try XCTUnwrap(EyeShape.fromFaceMesh(pts, eye: 1, axis: Vec2(-1, 0)))
        XCTAssertEqual(flipped.cornerA, Vec2(260, 100))
        XCTAssertNil(EyeShape.fromFaceMesh(Array(pts.prefix(100)), eye: 0, axis: Vec2(1, 0)))
    }

    // MARK: Камера и отладка

    func testCameraOutputIsScaledTo720pOnlyFor16x9() {
        XCTAssertTrue(GazeCamera.outputSize(width: 1920, height: 1080)! == (1280, 720), "живая проверка: камера отдала 1080p")
        XCTAssertNil(GazeCamera.outputSize(width: 1280, height: 720))
        XCTAssertNil(GazeCamera.outputSize(width: 1920, height: 1440), "4:3 не растягиваем")
    }

    func testDebugOverlaySaysWhatAndWhy() {
        var s = GazeStats()
        s.faceFound = true
        s.applied.pixels = Vec2(-1.4, 9.2); s.applied.visiblePixels = Vec2(-1.2, 7.6); s.applied.strength = 0.78; s.applied.openFactor = 0.78
        s.state = [.narrowEyes]
        let text = GazeDebugWindowController.overlayText(s)
        XCTAssertTrue(text.contains("видно: 8 px вверх"), text)
        XCTAssertTrue(text.contains("радужка +9 px"), text)
        XCTAssertTrue(text.contains("1 px вбок"), text)
        XCTAssertTrue(text.contains("сила 0.78"), text)
        XCTAssertTrue(text.contains("ослаблена: узкие глаза ×0.78"), text)
        s.state = []
        XCTAssertTrue(GazeDebugWindowController.overlayText(s).contains("не ослаблена"))
    }
}

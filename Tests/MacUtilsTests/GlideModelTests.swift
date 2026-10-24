import XCTest
@testable import MacUtils
@testable import MUSmoothScroll
@testable import MUTextEditor

final class GlideModelTests: XCTestCase {
    /// Прогоняет кадры по 120 Гц, пока модель не успокоится; возвращает сумму отданных пикселей и число кадров.
    private func run(_ model: inout GlideModel, duration: Double = 0.35, maxFrames: Int = 5000) -> (y: Int, x: Int, frames: Int) {
        var y = 0, x = 0, frames = 0
        while !model.isIdle && frames < maxFrames {
            let step = model.step(dt: 1.0 / 120.0, duration: duration)
            y += Int(step.y); x += Int(step.x)
            frames += 1
        }
        return (y, x, frames)
    }

    // MARK: колесо

    func testNotchPixelsScaleWithSpeed() {
        var model = GlideModel()
        let one = model.notchPixels(dy: 1, dx: 0, now: 100, speed: 1)
        XCTAssertEqual(one.y, 50)
        var fast = GlideModel()
        XCTAssertEqual(fast.notchPixels(dy: -2, dx: 1, now: 100, speed: 2).y, -200)
        XCTAssertEqual(fast.streak, 0)
    }

    func testFastWheelAccelerates() {
        var model = GlideModel()
        var last = 0.0
        for i in 0..<5 {
            last = model.notchPixels(dy: 1, dx: 0, now: 100 + Double(i) * 0.05, speed: 1).y
        }
        XCTAssertEqual(model.streak, 4)
        XCTAssertEqual(last, 50 * (1 + 4 * 0.12), accuracy: 0.0001)
    }

    func testStreakIsCappedAndResetsAfterPause() {
        var model = GlideModel()
        for i in 0..<40 { _ = model.notchPixels(dy: 1, dx: 0, now: 100 + Double(i) * 0.05, speed: 1) }
        XCTAssertEqual(model.streak, 15, "потолок разгона")
        let capped = model.notchPixels(dy: 1, dx: 0, now: 103, speed: 1)
        XCTAssertEqual(model.streak, 0, "после паузы разгон сброшен")
        XCTAssertEqual(capped.y, 50)
        var again = GlideModel()
        for i in 0..<40 { _ = again.notchPixels(dy: 1, dx: 0, now: 100 + Double(i) * 0.05, speed: 1) }
        XCTAssertEqual(again.notchPixels(dy: 1, dx: 0, now: 102.05, speed: 1).y, 50 * (1 + 15 * 0.12), accuracy: 0.0001)
    }

    // MARK: остаток

    func testSameDirectionAccumulates() {
        var model = GlideModel()
        model.add(y: 100, x: 0)
        model.add(y: 50, x: 0)
        XCTAssertEqual(model.remainingY, 150)
        XCTAssertFalse(model.isIdle)
    }

    func testDirectionChangeDropsOldRemainder() {
        var model = GlideModel()
        model.add(y: 300, x: 40)
        model.add(y: -50, x: 0)
        XCTAssertEqual(model.remainingY, -50, "остаток прошлого направления гасится сразу")
        XCTAssertEqual(model.remainingX, 40, "другая ось не затронута")
    }

    func testRemainderIsCapped() {
        var model = GlideModel()
        for _ in 0..<1000 { model.add(y: 560, x: -560) }
        XCTAssertEqual(model.remainingY, GlideModel.maxRemaining)
        XCTAssertEqual(model.remainingX, -GlideModel.maxRemaining)
        let result = run(&model)
        XCTAssertLessThan(result.frames, 5000, "прокрутка заканчивается, а не катится бесконечно")
    }

    func testHugeInputDoesNotOverflowInt32() {
        var model = GlideModel()
        model.add(y: 1e300, x: -1e300)
        let step = model.step(dt: 1, duration: 1.5)
        XCTAssertLessThanOrEqual(abs(Int(step.y)), Int(GlideModel.maxRemaining))
        XCTAssertLessThanOrEqual(abs(Int(step.x)), Int(GlideModel.maxRemaining))
    }

    func testZeroInputKeepsModelIdle() {
        var model = GlideModel()
        model.add(y: 0, x: 0)
        XCTAssertTrue(model.isIdle)
        let step = model.step(dt: 1.0 / 120.0, duration: 0.35)
        XCTAssertEqual([step.y, step.x], [0, 0])
    }

    // MARK: кадры

    func testEmitsEverythingWithoutDrift() {
        for input in [137.0, 500.0, 1.0, 7.5, 2400.0] {
            var model = GlideModel()
            model.add(y: input, x: 0)
            let total = run(&model)
            XCTAssertLessThanOrEqual(abs(Double(total.y) - input), 0.5, "вход \(input), отдано \(total.y)")
            XCTAssertEqual(total.x, 0)
        }
    }

    func testBothAxesAndNegativeDirection() {
        var model = GlideModel()
        model.add(y: -400, x: 250)
        let total = run(&model)
        XCTAssertLessThanOrEqual(abs(Double(total.y) + 400), 0.5)
        XCTAssertLessThanOrEqual(abs(Double(total.x) - 250), 0.5)
    }

    func testNeverOvershootsOrReverses() {
        var model = GlideModel()
        model.add(y: 600, x: 0)
        var sum = 0
        while !model.isIdle {
            let step = model.step(dt: 1.0 / 120.0, duration: 0.35)
            XCTAssertGreaterThanOrEqual(step.y, 0, "прокрутка вниз не откатывается назад")
            sum += Int(step.y)
            XCTAssertLessThanOrEqual(sum, 600)
        }
    }

    func testFinishesWithinReasonableTime() {
        var model = GlideModel()
        model.add(y: 2000, x: 0)
        let total = run(&model, duration: 0.35)
        XCTAssertLessThan(Double(total.frames) / 120, 2.0, "затухание укладывается в пару секунд")
        var slow = GlideModel()
        slow.add(y: 2000, x: 0)
        XCTAssertGreaterThan(run(&slow, duration: 1.5).frames, total.frames, "длиннее время — дольше скольжение")
    }

    func testDurationIsClamped() {
        var zero = GlideModel(), tiny = GlideModel(), huge = GlideModel(), maxed = GlideModel()
        for model in [0, 1, 2, 3] { _ = model }
        zero.add(y: 500, x: 0); tiny.add(y: 500, x: 0); huge.add(y: 500, x: 0); maxed.add(y: 500, x: 0)
        XCTAssertEqual(zero.step(dt: 1.0 / 120, duration: 0).y, tiny.step(dt: 1.0 / 120, duration: 0.08).y, "0 → минимум 0.08")
        XCTAssertEqual(huge.step(dt: 1.0 / 120, duration: 99).y, maxed.step(dt: 1.0 / 120, duration: 1.5).y, "99 → максимум 1.5")
    }

    func testFrameTimeIsClamped() {
        var stalled = GlideModel(), limit = GlideModel(), instant = GlideModel(), floor = GlideModel()
        stalled.add(y: 500, x: 0); limit.add(y: 500, x: 0); instant.add(y: 500, x: 0); floor.add(y: 500, x: 0)
        XCTAssertEqual(stalled.step(dt: 5, duration: 0.35).y, limit.step(dt: 1.0 / 30, duration: 0.35).y, "зависший кадр не выбрасывает всё сразу")
        XCTAssertEqual(instant.step(dt: 0, duration: 0.35).y, floor.step(dt: 1.0 / 240, duration: 0.35).y)
        XCTAssertGreaterThan(stalled.remainingY, 0)
    }

    func testFractionalPixelsAreCarriedNotLost() {
        var model = GlideModel()
        model.add(y: 0.4, x: 0)
        var sum = 0
        for _ in 0..<10 { sum += Int(model.step(dt: 1.0 / 120, duration: 0.35).y) }
        XCTAssertLessThanOrEqual(sum, 1)
        model.add(y: 3.6, x: 0)
        let total = run(&model)
        XCTAssertLessThan(abs(Double(sum + total.y) - 4.0), 1.0)
    }

    func testResetStopsEverything() {
        var model = GlideModel()
        model.add(y: 700, x: 300)
        _ = model.step(dt: 1.0 / 120, duration: 0.35)
        model.reset()
        XCTAssertTrue(model.isIdle)
        let step = model.step(dt: 1.0 / 120, duration: 0.35)
        XCTAssertEqual([step.y, step.x], [0, 0], "остаток и дробные доли сброшены")
    }
}

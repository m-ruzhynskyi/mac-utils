import XCTest
@testable import MUGaze

/// Синтетический кадр: кожа, белок в эллипсе век, тёмная радужка с мягким краем, тёмная линия века над глазом.
private final class SyntheticFrame {
    let w = 200, h = 120
    var px: [UInt8]
    let frame = EyeFrame(center: Vec2(100, 60), ex: Vec2(1, 0), halfWidth: 20, halfHeight: 8)
    let iris: Vec2
    let r = 8.4

    init(irisLocal: Vec2) {
        iris = frame.center + irisLocal
        px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = Vec2(Double(x) + 0.5, Double(y) + 0.5)
                var v = 150.0
                let d = p - frame.center
                let g = max(0, 1 - (d.x / frame.halfWidth) * (d.x / frame.halfWidth))
                let top = -frame.halfHeight * g.squareRoot(), bottom = frame.halfHeight * g.squareRoot()
                if abs(d.x) < frame.halfWidth && d.y > top && d.y < bottom {
                    let ir = (p - iris).length
                    v = 230 - 190 * (1 - smoothstep(r - 0.5, r + 0.5, ir))
                } else if abs(d.x) < frame.halfWidth && d.y <= top && d.y > top - 1.5 {
                    v = 50 // край века, ресницы
                }
                for k in 0..<3 { px[(y * w + x) * 4 + k] = UInt8(v) }
                px[(y * w + x) * 4 + 3] = 255
            }
        }
    }

    func render(_ e: EyeEdit) {
        px.withUnsafeMutableBufferPointer { b in
            EyeRenderer.render([e], into: PixelView(base: b.baseAddress!, width: w, height: h, rowBytes: w * 4))
        }
    }

    func value(_ x: Int, _ y: Int) -> Double { Double(px[(y * w + x) * 4]) }

    /// Центр и площадь тёмного (радужка) внутри прямоугольника глаза.
    func dark() -> (center: Vec2, area: Double) {
        var sum = Vec2.zero, area = 0.0
        for y in 30..<90 { for x in 70..<130 {
            let p = Vec2(Double(x) + 0.5, Double(y) + 0.5)
            guard frame.contains(p) else { continue } // ресницы над глазом не считаем
            let k = max(0, (200 - value(x, y)) / 160)
            if value(x, y) < 140 { sum += p * k; area += k }
        } }
        return (sum / area, area)
    }

    /// Тёмный отрезок (радужка) в строке: центр и ширина по уровню 135 с линейной интерполяцией.
    func span(row y: Int) -> (center: Double, width: Double) {
        var cross: [Double] = []
        for x in 71..<129 {
            let a = value(x, y), b = value(x + 1, y)
            if (a - 135) * (b - 135) < 0 { cross.append(Double(x) + 0.5 + (135 - a) / (b - a)) }
        }
        return ((cross.first! + cross.last!) / 2, cross.last! - cross.first!)
    }

    /// Самый резкий перепад по горизонтали в строке через центр радужки.
    func edgeSharpness(row y: Int) -> Double {
        var best = 0.0
        for x in 71..<129 { best = max(best, abs(value(x + 1, y) - value(x, y))) }
        return best
    }
}

final class GazeEyeRendererTests: XCTestCase {
    private let f = EyeFrame(center: Vec2(100, 60), ex: Vec2(1, 0), halfWidth: 20, halfHeight: 8)

    func testNoEditIsIdentity() {
        let e = EyeEdit(frame: f, iris: Vec2(103, 60), irisRadius: 9, shift: .zero, lidRaise: 0)
        for y in stride(from: 40.5, to: 75, by: 1.0) { for x in stride(from: 75.5, to: 125, by: 1.0) {
            let (q, _) = e.source(for: Vec2(x, y))
            XCTAssertEqual(q.x, x, accuracy: 1e-6); XCTAssertEqual(q.y, y, accuracy: 1e-6)
        } }
    }

    func testIrisMovesRigidly() {
        let iris = Vec2(104, 61), s = Vec2(-4, -1.5)
        let e = EyeEdit(frame: f, iris: iris, irisRadius: 9, shift: s, lidRaise: 0)
        for dy in stride(from: -3.0, through: 3.0, by: 1.5) { for dx in stride(from: -7.0, through: 7.0, by: 1.75) {
            let p = iris + s + Vec2(dx, dy)
            let (q, blend) = e.source(for: p)
            XCTAssertNil(blend)
            XCTAssertEqual(q.x, p.x - s.x, accuracy: 1e-9); XCTAssertEqual(q.y, p.y - s.y, accuracy: 1e-9)
        } }
    }

    func testIrisAlwaysSampledFromVisiblePart() {
        // Веко поднимается сильнее радужки: открывшийся верх радужки берётся только из видимого (отражение или ближайшая строка).
        let fr = EyeFrame(center: Vec2(100, 60), ex: Vec2(1, 0), halfWidth: 20, halfHeight: 6)
        let iris = Vec2(101, 61)
        let e = EyeEdit(frame: fr, iris: iris, irisRadius: 8.4, shift: Vec2(0, -2), lidRaise: 3)
        let newIris = iris + Vec2(0, -2)
        var checked = 0
        for y in stride(from: 45.5, to: 70, by: 0.5) { for x in stride(from: 90.5, to: 112, by: 0.5) {
            let p = Vec2(x, y), l = e.local(p)
            guard (p - newIris).length < 8.4 - 0.75, l.y >= e.newTop(l.x), l.y < e.bottom(l.x) else { continue }
            XCTAssertTrue(e.visibleBefore(e.local(e.source(for: p).0)), "\(p)"); checked += 1
        } }
        XCTAssertGreaterThan(checked, 100)
    }

    func testUpperLidMovesUpContinuously() {
        let L = 3.0
        let e = EyeEdit(frame: f, iris: Vec2(100, 62), irisRadius: 8.4, shift: Vec2(0, -3.75), lidRaise: L)
        let newTop = f.center.y - f.halfHeight - L
        let above = e.source(for: Vec2(100, newTop - 0.01)).0
        XCTAssertEqual(above.y, f.center.y - f.halfHeight - 0.01, accuracy: 0.02, "край века переезжает на L вверх")
        // У уголка подъёма нет.
        let corner = e.source(for: Vec2(119.9, 60 - 0.5)).0
        XCTAssertEqual(corner.y, 59.5, accuracy: 0.2)
        // Высоко над веком (за складкой) ничего не двигается.
        let brow = Vec2(100, newTop - EyeEdit.lidReach * f.halfWidth - 1)
        XCTAssertEqual(e.source(for: brow).0, brow)
    }

    func testOutsideEyeUntouched() {
        let e = EyeEdit(frame: f, iris: Vec2(104, 61), irisRadius: 9, shift: Vec2(-5, -2), lidRaise: 2)
        for p in [Vec2(100, 69), Vec2(60, 60), Vec2(140, 55), Vec2(100, 90)] {
            XCTAssertEqual(e.source(for: p).0, p, "\(p)")
        }
    }

    func testScleraNeverShowsSecondIris() {
        let iris = Vec2(106, 61)
        let e = EyeEdit(frame: f, iris: iris, irisRadius: 8.4, shift: Vec2(-6, -2), lidRaise: 1.6)
        let newIris = iris + Vec2(-6, -2)
        for y in stride(from: 50.5, to: 70, by: 0.5) { for x in stride(from: 80.5, to: 120, by: 0.5) {
            let p = Vec2(x, y)
            guard (p - newIris).length > 8.4 + 1.25 else { continue } // за полосой сглаживания края
            let l = e.local(p)
            // У нижнего века правка намеренно сходит на исходные пиксели — там проверять нечего.
            guard abs(l.x) < 20, l.y < e.bottom(l.x) - EyeEdit.lowerLidBlend, l.y >= e.newTop(l.x) else { continue }
            // Не изнутри старой радужки — или из подложки, где старой радужки нет (залита белком).
            for (q, _, layer) in e.layeredSources(for: p) where layer == .original {
                XCTAssertGreaterThanOrEqual((q - iris).length, 8.4, "\(p)")
            }
        } }
    }

    func testRenderKeepsIrisSizeAndSharpness() {
        let img = SyntheticFrame(irisLocal: Vec2(5, 0))
        let before = img.span(row: 60), sharp0 = img.edgeSharpness(row: 60)
        img.render(EyeEdit(frame: img.frame, iris: img.iris, irisRadius: 9.2, shift: Vec2(-4.5, 0), lidRaise: 0))
        let after = img.span(row: 60), sharp1 = img.edgeSharpness(row: 60)
        XCTAssertEqual(after.center - before.center, -4.5, accuracy: 0.3)
        XCTAssertEqual(after.width, before.width, accuracy: 0.5, "радужка не сжимается")
        XCTAssertGreaterThan(sharp1, sharp0 * 0.85, "край радужки остаётся резким")
    }

    func testRenderLiftsIrisAndLid() {
        let img = SyntheticFrame(irisLocal: Vec2(0, 2.5)) // смотрит вниз: верх радужки под веком
        XCTAssertEqual((35..<60).first { img.value(100, $0) < 80 }, 51)
        let before = img.dark()
        let lift = 3.0
        img.render(EyeEdit(frame: img.frame, iris: img.iris, irisRadius: 9.2, shift: Vec2(0, -lift), lidRaise: 0.8 * lift))
        let after = img.dark()
        XCTAssertLessThan(after.center.y, before.center.y - 1.5, "радужка поднялась")
        XCTAssertGreaterThanOrEqual(after.area, before.area * 0.97, "радужка не уменьшилась")
        // Край века (тёмная линия) в середине поднялся примерно на 0,8·lift.
        // Линия ресниц в 1 px при дробном сдвиге делится на две строки, поэтому порог мягче.
        func lashRow() -> Int? { (35..<60).first { img.value(100, $0) < 125 } }
        XCTAssertLessThanOrEqual(lashRow() ?? 99, 51 - 2, "край века поднялся на ~0,8·lift = 2,4 px")
    }
}

final class GazeEyeShapeTests: XCTestCase {
    /// 71 точка MediaPipe: 0…8 нижнее веко, 9…15 верхнее; остальное не важно.
    private func mpContour(reversed: Bool) -> [Vec2] {
        var lower = (0...8).map { i -> Vec2 in let u = -20 + 5 * Double(i); return Vec2(100 + u, 60 + 6 * (1 - (u / 20) * (u / 20)).squareRoot()) }
        var upper = (1...7).map { i -> Vec2 in let u = -20 + 5 * Double(i); return Vec2(100 + u, 60 - 7 * (1 - (u / 20) * (u / 20)).squareRoot()) }
        if reversed { lower.reverse(); upper.reverse() }
        return lower + upper + Array(repeating: Vec2(0, 0), count: 55)
    }

    func testFromMediaPipeOrdersByAxisAndFitsFrame() throws {
        for rev in [false, true] {
            let iris = [Vec2(103, 61), Vec2(111, 61), Vec2(103, 53), Vec2(95, 61), Vec2(103, 69)]
            let sh = try XCTUnwrap(EyeShape.fromMediaPipe(contour: mpContour(reversed: rev), iris: iris, axis: Vec2(1, 0)))
            XCTAssertLessThan(sh.cornerA.x, sh.cornerB.x)
            XCTAssertEqual(sh.irisRadius, 8, accuracy: 1e-9)
            let f = sh.frame(axis: Vec2(1, 0))
            XCTAssertEqual(f.center.x, 100, accuracy: 1e-9); XCTAssertEqual(f.halfWidth, 20, accuracy: 1e-9)
            let lids = sh.lidCurves(in: f)
            XCTAssertEqual(lids.top(0), -7, accuracy: 0.3); XCTAssertEqual(lids.bottom(0), 6, accuracy: 0.3)
            XCTAssertEqual(lids.top(-20), 0, accuracy: 1e-9, "в уголке веки сходятся")
        }
    }

    func testSmootherKillsJitterButFollowsMotion() {
        var sm = EyeShapeSmoother()
        var rng = SplitMix64(seed: 5)
        let base = EyeShape.fromMediaPipe(contour: mpContour(reversed: false),
                                          iris: [Vec2(103, 61), Vec2(111, 61), Vec2(103, 53), Vec2(95, 61), Vec2(103, 69)], axis: Vec2(1, 0))!
        func jitter(_ s: EyeShape, _ dx: Double) -> EyeShape {
            func j(_ p: Vec2) -> Vec2 { p + Vec2(dx + (rng.unit() - 0.5) * 1.2, (rng.unit() - 0.5) * 1.2) }
            return EyeShape(cornerA: j(s.cornerA), cornerB: j(s.cornerB), upper: s.upper.map(j), lower: s.lower.map(j), iris: j(s.iris), irisRadius: s.irisRadius)
        }
        var prev: Vec2?, steps: [Double] = []
        for i in 0..<120 { // неподвижная голова, шум ±0,6 px
            let out = sm.filter(jitter(base, 0), dt: 1 / 30)
            if let p = prev, i > 30 { steps.append((out.iris - p).length) }
            prev = out.iris
        }
        XCTAssertLessThan(steps.reduce(0, +) / Double(steps.count), 0.12, "край радужки почти не дрожит")
        // Голова поехала на 3 px за кадр — фильтр догоняет, отставание мало.
        var out = base
        for i in 1...30 { out = sm.filter(jitter(base, Double(i) * 3), dt: 1 / 30) }
        XCTAssertEqual(out.iris.x, base.iris.x + 90, accuracy: 4)
    }
}

final class GazeLidRefinerTests: XCTestCase {
    /// Кожа 0,7 сверху, край ресниц (тёмная полоса) на настоящем веке y = 54, ниже белок 0,85.
    private struct LidImage: LumaSampler {
        let lidY: Double
        func luma(_ p: Vec2) -> Double {
            if p.y < lidY - 1.5 { return 0.7 }
            if p.y < lidY + 0.5 { return 0.2 }
            return 0.85
        }
    }

    func testMovesUpperLidDownToRealEdge() {
        let upper = (0...8).map { Vec2(80 + 5 * Double($0), $0 == 0 || $0 == 8 ? 60 : 50) } // модель поставила веко на 50
        let shape = EyeShape(cornerA: upper.first!, cornerB: upper.last!, upper: upper, lower: upper.map { $0 + Vec2(0, 12) },
                             iris: Vec2(100, 58), irisRadius: 10)
        let out = LidRefiner.refineUpper(shape, axis: Vec2(1, 0), image: LidImage(lidY: 54))
        for i in 2...6 { XCTAssertEqual(out.upper[i].y, 52.5, accuracy: 1.0, "\(i): край ресниц ≈ 52,5–53,5") }
        XCTAssertEqual(out.upper[0], shape.upper[0], "уголки не двигаются")
    }

    func testFlatImageLeavesLidAlone() {
        struct Flat: LumaSampler { func luma(_ p: Vec2) -> Double { 0.6 } }
        let upper = (0...8).map { Vec2(80 + 5 * Double($0), 50) }
        let shape = EyeShape(cornerA: upper.first!, cornerB: upper.last!, upper: upper, lower: upper, iris: Vec2(100, 55), irisRadius: 10)
        XCTAssertEqual(LidRefiner.refineUpper(shape, axis: Vec2(1, 0), image: Flat()).upper, upper)
    }
}

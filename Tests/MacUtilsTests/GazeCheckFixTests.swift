import CoreVideo
import XCTest
@testable import MUGaze

/// GAZE-35: по независимым проверкам GAZE-34 (CHK-2, CHK-3, ревью #213) — белок без швов и заплаток, круглая
/// радужка, правка гаснет с первого кадра моргания, видимый сдвиг в индикаторе, Syphon без падения и без очереди.
final class GazeCheckFixTests: XCTestCase {
    // MARK: Синтетический глаз: кожа 150, белок с перепадом слева 200 → справа 240, радужка 50 с мягким краем.

    private struct Eye {
        let w = 200, h = 120
        var px: [UInt8]
        let frame: EyeFrame
        let lids: LidCurves
        let iris: Vec2
        let r: Double

        init(irisLocal: Vec2, halfHeight: Double = 10, r: Double = 8.5) {
            frame = EyeFrame(center: Vec2(100, 60), ex: Vec2(1, 0), halfWidth: 24, halfHeight: halfHeight)
            let us = stride(from: -24.0, through: 24.0, by: 3).map { $0 }
            lids = LidCurves(halfWidth: 24, top: us.map { -halfHeight * max(0, 1 - ($0 / 24) * ($0 / 24)).squareRoot() },
                             bottom: us.map { halfHeight * max(0, 1 - ($0 / 24) * ($0 / 24)).squareRoot() })
            iris = frame.center + irisLocal
            self.r = r
            px = [UInt8](repeating: 0, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let p = Vec2(Double(x) + 0.5, Double(y) + 0.5), d = p - frame.center
                var v = 150.0
                if abs(d.x) < 24, d.y > lids.top(d.x), d.y < lids.bottom(d.x) {
                    let sclera = 220 + 20 * d.x / 24
                    v = sclera - (sclera - 50) * (1 - smoothstep(r - 0.6, r + 0.6, (p - iris).length))
                }
                for k in 0..<3 { px[(y * w + x) * 4 + k] = UInt8(v.rounded()) }
                px[(y * w + x) * 4 + 3] = 255
            } }
        }

        func edit(shift: Vec2, lidRaise: Double, lowerRaise: Double = 0) -> EyeEdit {
            EyeEdit(frame: frame, iris: iris, irisRadius: r * 1.08 + 0.5, shift: shift, lidRaise: lidRaise, lids: lids, lowerRaise: lowerRaise)
        }

        mutating func render(_ e: EyeEdit) {
            px.withUnsafeMutableBufferPointer { b in
                EyeRenderer.render([e], into: PixelView(base: b.baseAddress!, width: w, height: h, rowBytes: w * 4))
            }
        }

        func value(_ x: Int, _ y: Int) -> Double { Double(px[(y * w + x) * 4]) }
    }

    func testScleraUnderLiftedIrisHasNoSeamNoPatchesAndNoOldIris() {
        // Взгляд вверх-вбок (B 52, 157–186): радужка у верхнего века и в стороне, поднимаем на 5 px.
        var eye = Eye(irisLocal: Vec2(-7, 1), halfHeight: 11)
        let shift = Vec2(0, -5)
        eye.render(eye.edit(shift: shift, lidRaise: 4))
        let newIris = eye.iris + shift
        var checked = 0
        for y in 50..<72 {
            var prev: Double?
            for x in 78..<122 {
                let p = Vec2(Double(x) + 0.5, Double(y) + 0.5), l = p - eye.frame.center
                // У самых век (2,5 px) цвет смешивается с кожей века — там проверять нечего.
                guard abs(l.x) < 22, l.y > eye.lids.top(l.x) + 2.5, l.y < eye.lids.bottom(l.x) - 2.5 else { prev = nil; continue }
                guard (p - newIris).length > eye.r + 1.5 else { prev = nil; continue }
                let v = eye.value(x, y)
                XCTAssertGreaterThan(v, 185, "белок, а не старая радужка (\(x), \(y))")
                if let prev { XCTAssertLessThan(abs(v - prev), 8, "без шва и ступенек по строке (\(x), \(y))") }
                prev = v; checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 150)
        // По столбцу под радужкой — тоже без ступенек (прежний поиск «строки с белком» давал горизонтальный край блока).
        let cx = Int(newIris.x)
        var last: Double?
        for y in Int(newIris.y + eye.r + 2)..<Int(eye.frame.center.y + eye.lids.bottom(newIris.x - 100) - 2.5) {
            let v = eye.value(cx, y)
            if let last { XCTAssertLessThan(abs(v - last), 8, "столбец под радужкой, y \(y)") }
            last = v
        }
    }

    func testLiftedIrisStaysRoundNoEgg() {
        // Низ радужки под нижним веком на 2 px, подъём 6 px: раньше низ тянулся вниз «яйцом».
        var eye = Eye(irisLocal: Vec2(0, 3.5), halfHeight: 10)
        let shift = Vec2(0, -6)
        eye.render(eye.edit(shift: shift, lidRaise: 4.8, lowerRaise: 1.5))
        let newIris = eye.iris + shift
        // Тёмное в столбце центра — не ниже нового низа радужки (+1 px на мягкий край).
        let cx = Int(newIris.x)
        let lowestDark = (40..<80).last { eye.value(cx, $0) < 135 } ?? 0
        XCTAssertLessThanOrEqual(Double(lowestDark) + 0.5, newIris.y + eye.r + 1.0, "низ радужки не растянут")
        // Ширина радужки на высоте центра не изменилась.
        func width(_ y: Int) -> Int { (60..<140).filter { eye.value($0, y) < 135 }.count }
        XCTAssertEqual(Double(width(Int(newIris.y))), 2 * eye.r, accuracy: 2)
    }

    func testLowerLidSampledFromCleanPlateNoDarkArc() {
        // Радужка касается нижнего века; после подъёма у века под ней не остаётся тёмной дуги.
        var eye = Eye(irisLocal: Vec2(2, 2.5), halfHeight: 10)
        let e = eye.edit(shift: Vec2(0, -5), lidRaise: 4, lowerRaise: 1)
        eye.render(e)
        let newIris = eye.iris + Vec2(0, -5)
        for x in Int(newIris.x - 4)...Int(newIris.x + 4) {
            let u = Double(x) + 0.5 - 100
            let nb = e.newBottom(u)
            // Строка над новым краем века, за пределами новой радужки.
            let y = Int(60 + nb - 1.6)
            guard (Vec2(Double(x) + 0.5, Double(y) + 0.5) - newIris).length > eye.r + 1.5 else { continue }
            // Белок 220 с краем века (кожа 150) рядом; тёмная дуга от низа старой радужки была бы ~50–100.
            XCTAssertGreaterThan(eye.value(x, y), 145, "у нижнего века белок, не тёмная дуга (x \(x))")
        }
    }

    func testVisibleShiftCountsOnlyVisiblePart() {
        let eye = Eye(irisLocal: Vec2(0, -1), halfHeight: 8)
        // Верх радужки под веком, веко не поднимаем: видимый центр поднимается меньше сдвига.
        let still = eye.edit(shift: Vec2(0, -6), lidRaise: 0).visibleShift
        XCTAssertLessThan(-still.y, 5.5)
        XCTAssertGreaterThan(-still.y, 1)
        // Веко идёт за радужкой — видимый подъём ближе к сдвигу.
        let follow = eye.edit(shift: Vec2(0, -6), lidRaise: 6).visibleShift
        XCTAssertGreaterThan(-follow.y, -still.y + 0.5)
        XCTAssertEqual(eye.edit(shift: .zero, lidRaise: 0).visibleShift.length, 0, accuracy: 1e-9)
    }

    // MARK: Уточнение центра радужки

    func testIrisRefinerFindsTrueCenterAtSideGaze() {
        struct Img: LumaSampler {
            let c: Vec2
            func luma(_ p: Vec2) -> Double { (p - c).length < 9 ? 0.25 : 0.85 }
        }
        let shape = EyeShape(cornerA: Vec2(70, 60), cornerB: Vec2(130, 60),
                             upper: (0...8).map { Vec2(70 + 7.5 * Double($0), 60 - 11 * sin(Double($0) / 8 * .pi)) },
                             lower: (0...8).map { Vec2(70 + 7.5 * Double($0), 60 + 11 * sin(Double($0) / 8 * .pi)) },
                             iris: Vec2(96, 60), irisRadius: 9)
        let frame = shape.frame(axis: Vec2(1, 0))
        // Модель ошиблась к середине глаза на 4 px.
        let out = IrisRefiner.refine(shape, frame: frame, image: Img(c: Vec2(92, 60)))
        XCTAssertEqual(out.iris.x, 92, accuracy: 0.8)
        XCTAssertEqual(out.iris.y, 60, accuracy: 1.5)
        struct Flat: LumaSampler { func luma(_ p: Vec2) -> Double { 0.6 } }
        XCTAssertEqual(IrisRefiner.refine(shape, frame: frame, image: Flat()).iris, shape.iris, "ровная картинка — центр не трогаем")
    }

    // MARK: Моргание и взгляд в сторону

    private func shapeFace(open h: Double, irisX: Double = 0) -> FaceInput {
        let eyes = [Vec2(100, 100), Vec2(180, 100)].map { c -> EyeInput in
            let up = (0...8).map { k -> Vec2 in let t = Double(k) / 8; return c + Vec2(-20 + 40 * t, -h * sin(t * .pi)) }
            let lo = (0...8).map { k -> Vec2 in let t = Double(k) / 8; return c + Vec2(-20 + 40 * t, h * sin(t * .pi)) }
            let sh = EyeShape(cornerA: c + Vec2(-20, 0), cornerB: c + Vec2(20, 0), upper: up, lower: lo, iris: c + Vec2(irisX * 20, 1), irisRadius: 7)
            return EyeInput(frame: sh.frame(axis: Vec2(1, 0)), iris: sh.iris, shape: sh)
        }
        return FaceInput(headYaw: 0, headPitch: 0, eyes: eyes)
    }

    func testCorrectionIsOffOnFirstBlinkFrame() {
        let c = GazeController()
        var t = 0.0
        for _ in 0..<60 { _ = c.step(time: t, face: shapeFace(open: 9)); t += 1.0 / 30 }
        XCTAssertFalse(c.step(time: t, face: shapeFace(open: 9)).edits.isEmpty)
        t += 1.0 / 30
        // Один кадр — глаз почти закрыт (B 187: open 1.00 → 0.00 только на следующем кадре).
        let first = c.step(time: t, face: shapeFace(open: 2))
        XCTAssertTrue(first.edits.isEmpty, "на первом кадре моргания правки нет")
        XCTAssertTrue(first.state.contains(.blink))
    }

    func testSideFactorHeldDuringBlink() {
        let c = GazeController()
        var t = 0.0
        for _ in 0..<60 { _ = c.step(time: t, face: shapeFace(open: 9)); t += 1.0 / 30 }
        // В моргании модель дала радужку у уголка — фактор «взгляд в сторону» не падает.
        for _ in 0..<4 { _ = c.step(time: t, face: shapeFace(open: 1.5, irisX: 0.7)); t += 1.0 / 30 }
        var after: GazeOutput?
        for _ in 0..<6 { after = c.step(time: t, face: shapeFace(open: 9)); t += 1.0 / 30 }
        XCTAssertGreaterThan(after!.applied.sideFactor, 0.99, "после моргания без «пульса»")
    }

    func testControllerRaisesLowerLidInsteadOfStretchingIris() throws {
        let c = GazeController()
        var t = 0.0, o: GazeOutput?
        // Нижнее веко закрывает низ радужки на 1 px — после подъёма веко чуть поднимается.
        for _ in 0..<60 { o = c.step(time: t, face: shapeFace(open: 7)); t += 1.0 / 30 }
        let e = try XCTUnwrap(o?.edits.first)
        XCTAssertGreaterThan(e.lowerRaise, 0.2)
        XCTAssertLessThanOrEqual(e.lowerRaise, GazeLimits().maxLowerRaise * e.frame.halfWidth + 1e-9)
        XCTAssertGreaterThan(o!.applied.visiblePixels.y, 1, "видимый подъём в индикаторе")
        XCTAssertLessThanOrEqual(o!.applied.visiblePixels.y, o!.applied.pixels.y + 0.5)
    }

    // MARK: Syphon

    private func buffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        return pb!
    }

    func testPublishAfterStopThenReleaseDoesNotTrap() {
        // Ревью #213 п. 3: кадр после stop() держал сервер, deinit шёл на его же очереди и делал queue.sync — SIGTRAP.
        var server: SyphonServer? = SyphonServer(name: "test", broadcasts: false)
        server!.start()
        server!.stop()
        server!.publish(buffer())
        weak var weakServer = server
        server = nil
        let done = expectation(description: "очередь отработала")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertNil(weakServer)
    }

    func testBusyServerKeepsOnlyLatestFrame() {
        // Ревью #213 п. 4: если OBS подвис, кадры не копятся в очереди — остаётся только последний.
        let server = SyphonServer(name: "test", broadcasts: false)
        server.start()
        defer { server.stop() }
        let release = DispatchSemaphore(value: 0)
        server.queue.async { release.wait() } // «подвисший» клиент держит очередь сервера
        let b = buffer()
        for _ in 0..<60 { server.publish(b) }
        release.signal()
        server.queue.sync {}
        server.queue.sync {}
        XCTAssertEqual(server.framesCopied, 1, "60 кадров за время простоя → один, последний")
        XCTAssertEqual(SyphonServer.frameSendTimeout, 0.05, accuracy: 1e-9)
    }
}

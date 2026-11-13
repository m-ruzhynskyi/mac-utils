import XCTest
import MUCore
@testable import MUGaze

final class GazeCalibrationTests: XCTestCase {
    private func samples(_ c: Vec2, n: Int, jitter: Double, seed: UInt64) -> [Vec2] {
        var rng = SplitMix64(seed: seed)
        return (0..<n).map { _ in c + Vec2((rng.unit() - 0.5) * 2 * jitter, (rng.unit() - 0.5) * 2 * jitter) }
    }

    func testLaptopCameraAboveScreen() throws {
        var r = GazeCalibrationRecorder()
        samples(Vec2(0.04, -0.05), n: 40, jitter: 0.02, seed: 1).forEach { r.add($0, step: .camera) }
        samples(Vec2(0.03, 0.10), n: 40, jitter: 0.02, seed: 2).forEach { r.add($0, step: .screen) }
        let res = try r.result().get()
        XCTAssertEqual(res.screenLift, 0.15, accuracy: 0.02)
        XCTAssertEqual(res.biasX, 0.04, accuracy: 0.02)
        XCTAssertEqual(res.screenAngleDegrees(), asin(0.15 / 0.4) * 180 / .pi, accuracy: 3)
    }

    func testBlinksAndMissingEyesAreIgnoredButTooFewFail() {
        var r = GazeCalibrationRecorder()
        for i in 0..<45 { r.add(i % 3 == 0 ? nil : Vec2(0, 0), step: .camera) } // 30 годных
        for _ in 0..<45 { r.add(nil, step: .screen) }
        XCTAssertEqual(r.camera.count, 30)
        XCTAssertEqual(r.result().failure, .notEnoughSamples(.screen))
    }

    func testWanderingGazeIsRejected() {
        var r = GazeCalibrationRecorder()
        samples(Vec2(0, 0), n: 40, jitter: 0.3, seed: 3).forEach { r.add($0, step: .camera) }
        samples(Vec2(0, 0.1), n: 40, jitter: 0.01, seed: 4).forEach { r.add($0, step: .screen) }
        XCTAssertEqual(r.result().failure, .unstable(.camera))
    }

    func testLiftIsClampedForExtremeAnswers() throws {
        var r = GazeCalibrationRecorder()
        samples(Vec2(0, -0.2), n: 30, jitter: 0.01, seed: 5).forEach { r.add($0, step: .camera) }
        samples(Vec2(0, 0.4), n: 30, jitter: 0.01, seed: 6).forEach { r.add($0, step: .screen) }
        XCTAssertEqual(try r.result().get().screenLift, GazeCalibrationRecorder.liftRange.upperBound)
    }
}

final class GazeSyphonTests: XCTestCase {
    func testServerUUIDAndDescriptionMatchSyphon() {
        let uuid = SyphonProtocol.makeServerUUID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        XCTAssertEqual(uuid, "info.v002.Syphon.11111111-2222-3333-4444-555555555555")
        let d = SyphonProtocol.description(uuid: uuid, name: "Mac Utils · Взгляд", appName: "Mac Utils")
        XCTAssertEqual(d["SyphonServerDescriptionDictionaryVersionKey"] as? NSNumber, 0, "OBS принимает только версию 0")
        XCTAssertEqual(d["SyphonServerDescriptionUUIDKey"] as? String, uuid)
        XCTAssertEqual(d["SyphonServerDescriptionNameKey"] as? String, "Mac Utils · Взгляд")
        let surfaces = d["SyphonServerDescriptionSurfacesKey"] as? [[String: String]]
        XCTAssertEqual(surfaces, [["SyphonSurfaceType": "SyphonSurfaceTypeIOSurface"]], "OBS ищет поверхность IOSurface")
        XCTAssertTrue(PropertyListSerialization.propertyList(d, isValidFor: .binary), "уходит distributed notification — только plist")
    }

    func testMessagesRoundTripThroughKeyedArchiver() {
        let data = SyphonProtocol.encode("info.v002.Syphon.client" as NSString)
        XCTAssertEqual(SyphonProtocol.decodeClientUUID(data), "info.v002.Syphon.client")
        XCTAssertEqual(SyphonProtocol.decodeSurfaceID(SyphonProtocol.encode(NSNumber(value: UInt32(42)))), 42)
        XCTAssertNil(SyphonProtocol.encode(nil), "новый кадр — без данных")
        XCTAssertNil(SyphonProtocol.decodeClientUUID(Data([1, 2, 3])))
    }

    func testRegistryRepliesLikeSyphonServer() {
        var r = SyphonClientRegistry()
        XCTAssertEqual(r.handle(.addClientForInfo, client: "a", hasSurface: false), [], "поверхности ещё нет — номер пришлём позже")
        XCTAssertEqual(r.handle(.addClientForInfo, client: "b", hasSurface: true), [.sendSurfaceID(to: "b")])
        XCTAssertEqual(r.handle(.addClientForFrames, client: "b", hasSurface: true), [.sendNewFrame(to: "b")])
        XCTAssertTrue(r.hasFrameClients)
        _ = r.handle(.removeClientForFrames, client: "b", hasSurface: true)
        XCTAssertFalse(r.hasFrameClients)
        _ = r.handle(.addClientForFrames, client: "a", hasSurface: true)
        r.drop("a")
        XCTAssertEqual(r.info, ["b"]); XCTAssertTrue(r.frames.isEmpty)
    }

    func testMessageNumbersAreSyphons() {
        XCTAssertEqual(SyphonProtocol.ToServer.addClientForInfo.rawValue, 0)
        XCTAssertEqual(SyphonProtocol.ToServer.addClientForFrames.rawValue, 1)
        XCTAssertEqual(SyphonProtocol.ToServer.removeClientForInfo.rawValue, 2)
        XCTAssertEqual(SyphonProtocol.ToServer.removeClientForFrames.rawValue, 3)
        XCTAssertEqual(SyphonProtocol.ToClient.newFrame.rawValue, 1)
        XCTAssertEqual(SyphonProtocol.ToClient.updateSurfaceID.rawValue, 2)
        XCTAssertEqual(SyphonProtocol.ToClient.retireServer.rawValue, 3)
    }
}

final class GazeProductTests: XCTestCase {
    func testVirtualCamerasAreNeverUsedAsInput() {
        XCTAssertTrue(GazeCamera.isVirtual(name: "OBS Virtual Camera", model: "obs-virtual-camera"))
        XCTAssertTrue(GazeCamera.isVirtual(name: "Snap Camera", model: ""))
        XCTAssertFalse(GazeCamera.isVirtual(name: "Камера FaceTime HD", model: "FaceTime HD Camera"))
        XCTAssertFalse(GazeCamera.isVirtual(name: "iPhone (камера Continuity)", model: "iPhone15,2"))
    }

    @MainActor
    func testSettingsFromPrefs() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "gaze-tests-\(UUID().uuidString)"))
        var s = GazeService.settingsFromPrefs(d)
        XCTAssertEqual(s.target, .camera); XCTAssertEqual(s.freedom, .normal)
        XCTAssertEqual(s.calibration.screenLift, GazeCalibration().screenLift, "без калибровки — подъём по умолчанию")
        d.set("point", forKey: Pref.gazeTarget); d.set(6.0, forKey: Pref.gazePointYaw); d.set(-3.0, forKey: Pref.gazePointPitch)
        d.set("high", forKey: Pref.gazeFreedom); d.set(0.21, forKey: Pref.gazeScreenLift); d.set(0.03, forKey: Pref.gazeBiasX)
        s = GazeService.settingsFromPrefs(d)
        XCTAssertEqual(s.target, .point(yaw: 6, pitch: -3)); XCTAssertEqual(s.freedom, .high)
        XCTAssertEqual(s.calibration.screenLift, 0.21); XCTAssertEqual(s.calibration.bias.x, 0.03)
    }

    @MainActor
    func testFeatureIsOffAtLaunch() {
        XCTAssertFalse(GazeService.shared.isOn, "включается только вручную")
        XCTAssertEqual(GazeService.shared.status, .off)
    }

    func testModelResourceIsShippedWithLicense() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let models = root.appendingPathComponent("Resources/Models")
        XCTAssertTrue(FileManager.default.fileExists(atPath: models.appendingPathComponent("IrisLandmarks.mlpackage/Manifest.json").path))
        let license = try String(contentsOf: models.appendingPathComponent("IrisLandmarks-LICENSE.txt"), encoding: .utf8)
        XCTAssertTrue(license.contains("Apache License"))
        let build = try String(contentsOf: root.appendingPathComponent("build.sh"), encoding: .utf8)
        XCTAssertTrue(build.contains("Resources/Models"), "build.sh кладёт модель в бандл")
    }
}

private extension Result {
    var failure: Failure? { if case let .failure(f) = self { return f }; return nil }
}

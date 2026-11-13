import AVFoundation
import CoreVideo
import IOSurface
import XCTest
@testable import MUGaze

/// Клиент Syphon внутри теста: свой порт, принимает сообщения сервера.
private final class FakeSyphonClient {
    let uuid = "info.v002.Syphon.test-client-\(UUID().uuidString)"
    private(set) var port: CFMessagePort?
    private let lock = NSLock()
    private var messages: [(Int32, Data?)] = []
    let queue = DispatchQueue(label: "fake-syphon-client")

    init() {
        var ctx = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, uuid as CFString, { _, msgid, data, info in
            let me = Unmanaged<FakeSyphonClient>.fromOpaque(info!).takeUnretainedValue()
            me.lock.withLock { me.messages.append((msgid, data as Data?)) }
            return nil
        }, &ctx, nil)
        CFMessagePortSetDispatchQueue(port!, queue)
    }

    func send(_ type: SyphonProtocol.ToServer, to server: String) -> Int32 {
        let remote = CFMessagePortCreateRemote(nil, server as CFString)!
        defer { CFMessagePortInvalidate(remote) }
        return CFMessagePortSendRequest(remote, type.rawValue, SyphonProtocol.encode(uuid as NSString)! as CFData, 1, 0, nil, nil)
    }

    func wait(for type: SyphonProtocol.ToClient, timeout: Double = 2) -> Data?? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let m = lock.withLock({ messages.first { $0.0 == type.rawValue } }) { return .some(m.1) }
            usleep(10_000)
        }
        return nil
    }

    deinit { if let port { CFMessagePortInvalidate(port) } }
}

final class GazeSyphonLoopbackTests: XCTestCase {
    func testClientReceivesSurfaceAndFrames() throws {
        let server = SyphonServer(name: "test", broadcasts: false)
        server.start()
        defer { server.stop() }
        let client = FakeSyphonClient()
        XCTAssertEqual(client.send(.addClientForInfo, to: server.uuid), kCFMessagePortSuccess)
        XCTAssertEqual(client.send(.addClientForFrames, to: server.uuid), kCFMessagePortSuccess)

        // Кадр 64×32: левая половина красная, правая синяя (BGRA).
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<32 { for x in 0..<64 { let p = base + y * rb + x * 4; p[0] = x < 32 ? 0 : 255; p[1] = 0; p[2] = x < 32 ? 255 : 0; p[3] = 255 } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        server.publish(buffer)

        let idData = try XCTUnwrap(client.wait(for: .updateSurfaceID), "сервер прислал номер поверхности")
        let id = try XCTUnwrap(SyphonProtocol.decodeSurfaceID(idData))
        XCTAssertNotNil(client.wait(for: .newFrame), "и «новый кадр»")
        let surface = try XCTUnwrap(IOSurfaceLookup(id), "поверхность глобальная — открывается по номеру, как в OBS")
        XCTAssertEqual(IOSurfaceGetPixelFormat(surface), kCVPixelFormatType_32BGRA, "формат задан явно (иначе OBS Metal видит 0×0)")
        XCTAssertEqual(IOSurfaceGetWidth(surface), 64)
        IOSurfaceLock(surface, .readOnly, nil)
        let s = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self), srb = IOSurfaceGetBytesPerRow(surface)
        XCTAssertEqual(s[10 * srb + 5 * 4 + 2], 255, "красный слева")
        XCTAssertEqual(s[10 * srb + 50 * 4 + 0], 255, "синий справа")
        IOSurfaceUnlock(surface, .readOnly, nil)
        XCTAssertEqual(server.frameClientCount, 1, "строка «OBS получает картинку» видит клиента")
    }
}

/// Сквозной прогон конвейера на видеоклипе (без камеры): MU_GAZE_CLIP=<mp4> MU_GAZE_MODEL=<mlpackage>.
final class GazePipelineClipTests: XCTestCase {
    func testPipelineOnClip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let clip = env["MU_GAZE_CLIP"], let model = env["MU_GAZE_MODEL"] else { throw XCTSkip("нужны MU_GAZE_CLIP и MU_GAZE_MODEL") }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("gaze-test-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let compiled = try XCTUnwrap(IrisModel.compiledURL(package: URL(fileURLWithPath: model), cacheDirectory: cache))
        let pipeline = GazePipeline(iris: try IrisModel(compiledURL: compiled), settings: GazeSettings())
        var outputs = 0
        pipeline.onFrame = { _, _ in outputs += 1 }
        let asset = AVURLAsset(url: URL(fileURLWithPath: clip))
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        reader.add(out); reader.startReading()
        var frames = 0, faces = 0, active = 0
        while let sample = out.copyNextSampleBuffer() {
            pipeline.process(sample)
            frames += 1
            let s = pipeline.snapshot
            if s.faceFound { faces += 1 }
            if s.weight > 0.5 { active += 1 }
        }
        let s = pipeline.snapshot
        print(String(format: "GAZE-CLIP frames %d faces %d active %d processing %.1f ms", frames, faces, active, s.processingMs))
        XCTAssertEqual(outputs, frames, "каждый кадр выходит, с поправкой или без")
        XCTAssertGreaterThan(faces, frames * 8 / 10)
        XCTAssertGreaterThan(active, frames / 2)
        #if !DEBUG
        // Скорость имеет смысл только в оптимизированной сборке (в отладочной отрисовка на CPU в 6–8 раз медленнее).
        XCTAssertLessThan(s.processingMs, 33, "укладываемся в 30 к/с")
        #endif
    }
}

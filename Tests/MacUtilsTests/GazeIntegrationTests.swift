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
        var settings = GazeSettings()
        if let v = env["MU_GAZE_LIFT"].flatMap(Double.init) { settings.calibration.screenLift = v }
        if let v = env["MU_GAZE_STRENGTH"].flatMap(Double.init) { settings.strength = v }
        if env["MU_GAZE_IRIS_LIDS"] == "1" { settings.useFaceMesh = false }
        // Face Landmarker — если задан пакет (MU_GAZE_FACEMESH), иначе веки от Iris.
        let faceMesh = try env["MU_GAZE_FACEMESH"].flatMap { try FaceMeshModel.compiledURL(package: URL(fileURLWithPath: $0), cacheDirectory: cache) }
            .map { try FaceMeshModel(compiledURL: $0) }
        let pipeline = GazePipeline(iris: try IrisModel(compiledURL: compiled), faceMesh: faceMesh, settings: settings)
        // Разбор записи: MU_GAZE_DUMP=<папка> — видео «после» и строка на кадр (что применено и почему ослаблено).
        let dump = env["MU_GAZE_DUMP"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        var writer: ClipWriter?
        var csv = "frame,t,face,weight,strength,open,side,irisSide,px_x,px_up,state,xL,xR\n"
        var faces: [FaceInput?] = []
        if dump != nil { pipeline.onFace = { faces.append($0) } }
        var outputs = 0
        pipeline.onFrame = { _, after in
            outputs += 1
            if let dump {
                if writer == nil { writer = try? ClipWriter(url: dump.appendingPathComponent("after.mp4"), like: after) }
                writer?.append(after)
            }
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: clip))
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        reader.add(out); reader.startReading()
        var frames = 0, found = 0, active = 0
        while let sample = out.copyNextSampleBuffer() {
            pipeline.process(sample)
            frames += 1
            let s = pipeline.snapshot
            let a = s.applied
            csv += String(format: "%d,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.2f,%.2f,%d,%.3f,%.3f\n", frames - 1, Double(frames - 1) / 30, s.faceFound ? 1 : 0,
                          s.weight, a.strength, a.openFactor, a.sideFactor, a.irisSide, a.pixels.x, a.pixels.y, s.state.rawValue,
                          a.eyeX.first ?? .nan, a.eyeX.dropFirst().first ?? .nan)
            if s.faceFound { found += 1 }
            if s.weight > 0.5 { active += 1 }
        }
        if let dump {
            writer?.finish()
            try csv.write(to: dump.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
            let shapes = faces.map { f in f?.eyes.map { $0.shape } }
            try JSONEncoder().encode(shapes).write(to: dump.appendingPathComponent("shapes.json"))
        }
        if reader.status == .failed { print("GAZE-CLIP reader error: \(String(describing: reader.error))") }
        let s = pipeline.snapshot
        print(String(format: "GAZE-CLIP frames %d faces %d active %d processing %.1f ms", frames, found, active, s.processingMs))
        XCTAssertEqual(outputs, frames, "каждый кадр выходит, с поправкой или без")
        XCTAssertGreaterThan(found, frames * 8 / 10)
        XCTAssertGreaterThan(active, frames / 2)
        #if !DEBUG
        // Скорость имеет смысл только в оптимизированной сборке (в отладочной отрисовка на CPU в 6–8 раз медленнее).
        XCTAssertLessThan(s.processingMs, 33, "укладываемся в 30 к/с")
        #endif
    }
}

/// Запись кадров «после» для разбора (только тесты): H.264, 30 к/с по номеру кадра.
private final class ClipWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var index = 0

    init(url: URL, like buffer: CVPixelBuffer) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: CVPixelBufferGetWidth(buffer), AVVideoHeightKey: CVPixelBufferGetHeight(buffer),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000]])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
    }

    func append(_ buffer: CVPixelBuffer) {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        index += 1
    }

    func finish() {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}

import AVFoundation
import Network
import VideoToolbox
import XCTest
@testable import MacUtils
@testable import MUAudio

/// Стенды памяти долгой трансляции: синтетические данные, локальный WebSocket-сервер, который не читает
/// (медленная сеть), без захвата экрана, звука и окон. Время ускорено: 10 минут трансляции — за секунды.
/// Память — `phys_footprint` процесса тестов: смотрим прирост за прогон.
enum MemoryProbe {
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func megabytes(_ bytes: Int) -> String { String(format: "%.1f МБ", Double(bytes) / 1_048_576) }
}

/// Локальный WebSocket-сервер: принимает соединение и ничего не читает — как зритель на очень медленной сети.
final class StalledWebSocketServer: @unchecked Sendable {
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "stand.ws")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
        }
    }

    func start() async throws -> UInt16 {
        listener.start(queue: queue)
        for _ in 0..<200 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() {
        connections.forEach { $0.cancel() }
        listener.cancel()
    }
}

final class ShareMemoryStandTests: XCTestCase {
    /// 0,1 с звука трансляции (24 кГц моно, Int16) — каждый пакет новый, как в жизни.
    private func audioPacket(_ index: Int) -> Data {
        ShareProtocol.audioPacket((0..<2_400).map { Float(sin(Double($0 + index) * 0.05)) * 0.3 })
    }

    private func settle() async throws { try await Task.sleep(nanoseconds: 1_500_000_000) }

    /// Ведущий: 10 минут звука в сокет к зрителю, который не читает. Было — `socket.send` на каждый пакет (без предела),
    /// стало — `ShareAudioSender`.
    func testStandHostAudioStalledNetwork() async throws {
        for bounded in [false, true] {
            let server = try StalledWebSocketServer()
            let port = try await server.start()
            let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
            socket.resume()
            try await socket.send(.string("hello"))
            var packets: [Data]? = (0..<6_000).map(audioPacket)
            try await settle()
            let before = MemoryProbe.footprint()
            let sender = ShareAudioSender(limit: bounded ? ShareAudioSender.defaultLimit : .max) { data, done in
                socket.send(.data(data)) { _ in done() }
            }
            for packet in packets! { sender.send(packet) }
            packets = nil
            try await settle()
            let grown = MemoryProbe.footprint() - before
            print("STAND host-audio \(bounded ? "стало" : "было"): 10 мин звука, зритель не читает — прирост \(MemoryProbe.megabytes(grown)), в очереди \(sender.pending / 1024) КБ, отброшено \(sender.dropped)")
            if bounded { XCTAssertLessThan(sender.pending, ShareAudioSender.defaultLimit + 5_000) }
            socket.cancel(with: .goingAway, reason: nil)
            server.stop()
            try await settle()
        }
    }

    /// Зритель: 10 минут звука, а проигрыватель не тратит буферы (движок остановлен системой).
    func testStandViewerAudioNotConsumed() async throws {
        for bounded in [false, true] {
            let player = SharePlayer(silent: true, limit: bounded ? SharePlayer.defaultLimit : .max, catchUp: bounded ? SharePlayer.defaultCatchUp : .max)
            var payloads: [Data]? = (0..<6_000).map { Data(audioPacket($0).dropFirst()) }
            try await settle()
            let before = MemoryProbe.footprint()
            for payload in payloads! { player.play(payload) }
            payloads = nil
            try await settle()
            let grown = MemoryProbe.footprint() - before
            print("STAND viewer-audio \(bounded ? "стало" : "было"): 10 мин звука без проигрывания — прирост \(MemoryProbe.megabytes(grown)), в очереди \(Int(player.queuedSeconds)) с")
            if bounded { XCTAssertLessThanOrEqual(player.queuedSeconds, 1.01) }
            player.stop()
            try await settle()
        }
    }

    /// Зритель: 10 минут видео 30 к/с в слой, который не показывается.
    func testStandViewerVideoNotDisplayed() async throws {
        let packets = try await syntheticStream(frames: 90)
        let player = H264Player()
        let source = NSObject()
        player.attach(source)
        try await settle()
        let before = MemoryProbe.footprint()
        for index in 0..<18_000 { player.play(packets[index % packets.count], from: source) }
        try await settle()
        try await settle()
        let grown = MemoryProbe.footprint() - before
        print("STAND viewer-video: 10 мин видео в невидимый слой — прирост \(MemoryProbe.megabytes(grown))")
        player.attach(nil)
    }

    /// Пакеты H.264 от нашего кодера: шум, 1280×720, ключевой в начале.
    private func syntheticStream(frames: Int) async throws -> [Data] {
        let collected = UncheckedBox<[Data]>([])
        let lock = NSLock()
        let encoder = H264Encoder { data, key in
            var packet = Data([H264Packet.type, key ? 1 : 0])
            packet.append(data)
            lock.lock(); collected.value.append(packet); lock.unlock()
        }
        var random = PlayerTestRandom(5)
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt64.self)
            for index in 0..<(CVPixelBufferGetBytesPerRow(pixels) * 720 / 8) { base[index] = random.next() }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            if frame % 30 == 0 { encoder.requestKeyFrame() }
            while !encoder.encode(pixels, at: CMTime(value: CMTimeValue(frame), timescale: 30)) {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        for _ in 0..<200 where collected.value.count < frames { try await Task.sleep(nanoseconds: 10_000_000) }
        encoder.invalidate()
        return collected.value
    }
}

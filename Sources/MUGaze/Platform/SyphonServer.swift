import AppKit
import CoreVideo
import Foundation
import IOSurface
import MUCore

/// Свой сервер Syphon: кадр — глобальная IOSurface 32BGRA, клиенты — через CFMessagePort, объявление — distributed
/// notifications. В OBS он виден как источник «Syphon Client» с именем `name`. Совместимость проверяется на живом OBS.
final class SyphonServer {
    let name: String
    let uuid = SyphonProtocol.makeServerUUID()
    private let queue = DispatchQueue(label: "com.mruzhynskyi.macutils.gaze.syphon", qos: .userInteractive)
    private var port: CFMessagePort?
    private var registry = SyphonClientRegistry()
    private var senders: [String: CFMessagePort] = [:]
    private var surface: IOSurface?
    private var running = false
    private let lock = NSLock()
    private var _frameClients = 0

    /// `broadcasts: false` — без объявлений на всю систему (тесты): клиент должен знать UUID.
    private let broadcasts: Bool

    init(name: String, broadcasts: Bool = true) { self.name = name; self.broadcasts = broadcasts }

    deinit { stop() }

    /// Сколько клиентов забирает кадры (OBS) — для строки состояния.
    var frameClientCount: Int { lock.lock(); defer { lock.unlock() }; return _frameClients }

    private var description: [String: Any] {
        let appName = NSRunningApplication.current.localizedName ?? ProcessInfo.processInfo.processName
        return SyphonProtocol.description(uuid: uuid, name: name, appName: appName)
    }

    func start() {
        queue.sync {
            guard !running else { return }
            var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: CFMessagePortCallBack = { _, msgid, data, info in
                guard let info else { return nil }
                let server = Unmanaged<SyphonServer>.fromOpaque(info).takeUnretainedValue()
                server.receive(msgid: msgid, data: data as Data?)
                return nil
            }
            var shouldFree: DarwinBoolean = false
            guard let p = CFMessagePortCreateLocal(nil, uuid as CFString, callback, &context, &shouldFree) else {
                Log.gaze.error("syphon: port create failed")
                return
            }
            CFMessagePortSetDispatchQueue(p, queue)
            port = p
            running = true
        }
        guard broadcasts else { return }
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(announceRequested), name: .init(SyphonProtocol.announceRequest), object: nil)
        announce(SyphonProtocol.announce)
        Log.gaze.info("syphon: started")
    }

    func stop() {
        var wasRunning = false
        queue.sync {
            guard running else { return }
            wasRunning = true
            for client in registry.info { send(.retireServer, nil, to: client) }
            registry.removeAll()
            senders.values.forEach { CFMessagePortInvalidate($0) }
            senders.removeAll()
            if let port { CFMessagePortInvalidate(port) }
            port = nil
            surface = nil
            running = false
            setFrameClients(0)
        }
        guard wasRunning, broadcasts else { return }
        DistributedNotificationCenter.default().removeObserver(self)
        announce(SyphonProtocol.retire)
        Log.gaze.info("syphon: stopped")
    }

    @objc private func announceRequested(_ note: Notification) { announce(SyphonProtocol.announce) }

    private func announce(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(.init(name), object: uuid, userInfo: description, deliverImmediately: true)
    }

    /// Новый кадр: копия в поверхность сервера и «новый кадр» подписчикам. Вызывается с очереди конвейера.
    func publish(_ buffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        queue.async { [self] in
            guard running else { return }
            if surface == nil || surface!.width != w || surface!.height != h {
                // Ключ строкой: kIOSurfaceIsGlobal объявлен устаревшим, но Syphon и OBS открывают поверхность по номеру,
                // а это работает только для глобальной. Формат пикселя задаём явно — без него OBS (Metal) видит 0×0.
                let props: [String: Any] = [
                    "IOSurfaceIsGlobal": true,
                    kIOSurfaceWidth as String: w, kIOSurfaceHeight as String: h,
                    kIOSurfacePixelFormat as String: kCVPixelFormatType_32BGRA,
                    kIOSurfaceBytesPerElement as String: 4,
                ]
                surface = IOSurface(properties: [IOSurfacePropertyKey: Any](uniqueKeysWithValues: props.map { (IOSurfacePropertyKey(rawValue: $0.key), $0.value) }))
                if let id = surface.map({ IOSurfaceGetID($0) }) {
                    for client in registry.info { send(.updateSurfaceID, NSNumber(value: id), to: client) }
                }
            }
            guard let surface else { return }
            surface.lock(options: [], seed: nil)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let src = CVPixelBufferGetBaseAddress(buffer)!, srb = CVPixelBufferGetBytesPerRow(buffer)
            let dst = surface.baseAddress, drb = surface.bytesPerRow
            for y in 0..<h { memcpy(dst + y * drb, src + y * srb, min(srb, drb, w * 4)) }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            surface.unlock(options: [], seed: nil)
            for client in registry.frames { send(.newFrame, nil, to: client) }
        }
    }

    // MARK: - Сообщения (на `queue`)

    private func receive(msgid: Int32, data: Data?) {
        guard let message = SyphonProtocol.ToServer(rawValue: msgid), let client = SyphonProtocol.decodeClientUUID(data) else { return }
        let replies = registry.handle(message, client: client, hasSurface: surface != nil)
        if message == .removeClientForInfo, !registry.frames.contains(client) { dropSender(client) }
        for reply in replies {
            switch reply {
            case let .sendSurfaceID(to): if let s = surface { send(.updateSurfaceID, NSNumber(value: IOSurfaceGetID(s)), to: to) }
            case let .sendNewFrame(to): send(.newFrame, nil, to: to)
            }
        }
        setFrameClients(registry.frames.count)
        Log.gaze.info("syphon: client message \(msgid, privacy: .public), frame clients \(self.registry.frames.count, privacy: .public)")
    }

    private func send(_ type: SyphonProtocol.ToClient, _ payload: (any NSObject & NSSecureCoding)?, to client: String) {
        let remote: CFMessagePort
        if let existing = senders[client], CFMessagePortIsValid(existing) {
            remote = existing
        } else {
            guard let created = CFMessagePortCreateRemote(nil, client as CFString) else { drop(client); return }
            senders[client] = created
            remote = created
        }
        let data = SyphonProtocol.encode(payload).map { $0 as CFData }
        let result = CFMessagePortSendRequest(remote, type.rawValue, data, 1.0, 0, nil, nil)
        if result == kCFMessagePortIsInvalid { drop(client) }
    }

    private func drop(_ client: String) {
        registry.drop(client)
        dropSender(client)
        setFrameClients(registry.frames.count)
    }

    private func dropSender(_ client: String) {
        if let s = senders.removeValue(forKey: client) { CFMessagePortInvalidate(s) }
    }

    private func setFrameClients(_ n: Int) { lock.lock(); _frameClients = n; lock.unlock() }
}

import Foundation
import Network

// MARK: - Пара

/// Связанный ПК: адрес, ключ ПК и имя. Ключ устройства Mac хранит `ShareIdentity`, здесь — только ключ ПК.
package struct LinkPair: Codable, Equatable, Sendable {
    package var host: String
    package var pcKey: String
    package var pcName: String
    package var pairedAt: Date
    package init(host: String, pcKey: String, pcName: String, pairedAt: Date = Date()) {
        self.host = host; self.pcKey = pcKey; self.pcName = pcName; self.pairedAt = pairedAt
    }
}

package protocol LinkPairStorage: Sendable {
    func load() -> LinkPair?
    func save(_ pair: LinkPair) throws
    func clear() throws
}

/// `~/Library/Application Support/Mac Utils/mu-link.json`, права 0600 (секретов нет, но чужим знать адрес ПК незачем).
package struct FileLinkPairStorage: LinkPairStorage {
    package let url: URL
    package init(url: URL) { self.url = url }

    package static var standard: FileLinkPairStorage {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Utils", isDirectory: true)
        return FileLinkPairStorage(url: folder.appendingPathComponent("mu-link.json"))
    }

    package func load() -> LinkPair? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LinkPair.self, from: data)
    }

    package func save(_ pair: LinkPair) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try encoder.encode(pair).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    package func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Пара в памяти: тесты и самопроверка (настоящие настройки не трогаются).
package final class MemoryLinkPairStorage: LinkPairStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var pair: LinkPair?
    package init(_ pair: LinkPair? = nil) { self.pair = pair }
    package func load() -> LinkPair? { lock.withLock { pair } }
    package func save(_ pair: LinkPair) throws { lock.withLock { self.pair = pair } }
    package func clear() throws { lock.withLock { pair = nil } }
}

// MARK: - Соединение WebSocket (Network.framework)

/// Одно соединение WebSocket поверх `NWConnection`: текстовые кадры, закрытие с кодом. Все колбэки — на `queue`.
/// Клиент Mac только подключается; слушающая сторона (`LinkTwinServer`) есть только в самопроверке и тестах, на 127.0.0.1.
package final class LinkConnection: @unchecked Sendable {
    package let connection: NWConnection
    private let queue: DispatchQueue
    package var onReady: (() -> Void)?
    package var onText: ((String) -> Void)?
    /// Конец соединения: код закрытия от другой стороны (если пришёл) и описание ошибки сети.
    package var onClose: ((_ code: UInt16?, _ error: String?) -> Void)?
    private var finished = false
    private var closeCode: UInt16?

    package static func websocketParameters() -> NWParameters {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = LinkWire.maxFrameBytes
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return parameters
    }

    /// Исходящее подключение (клиент Mac).
    package convenience init(url: URL, queue: DispatchQueue) {
        self.init(NWConnection(to: .url(url), using: Self.websocketParameters()), queue: queue)
    }

    /// Входящее (двойник ПК).
    package init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    package func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.onReady?(); self.receive()
            // `waiting` — подключиться не вышло (ПК выключен, порт закрыт): повторяет не Network.framework, а клиент.
            case .waiting(let error): self.finish(error: Self.describe(error))
            case .failed(let error): self.finish(error: Self.describe(error))
            case .cancelled: self.finish(error: nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    package func send(_ text: String) {
        guard !finished else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    /// Закрыть с кодом: кадр close, затем разрыв.
    package func close(code: UInt16 = LinkWire.Close.normal) {
        guard !finished else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code == LinkWire.Close.normal ? .protocolCode(.normalClosure) : .privateCode(code)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
        // Если другая сторона не читает — не ждём.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connection.cancel() }
    }

    /// Разрыв без кадра close (обрыв сети в тестах).
    package func cancel() { connection.cancel() }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.finished else { return }
            if let error { self.finish(error: Self.describe(error)); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                if let data { self.onText?(String(decoding: data, as: UTF8.self)) }
            case .close?:
                self.closeCode = metadata.map { Self.code($0.closeCode) }
                self.connection.cancel()
                return
            default: break // двоичные кадры в версии 1 игнорируются, ping/pong отвечает Network.framework
            }
            if !self.finished { self.receive() }
        }
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        let handler = onClose
        onClose = nil; onText = nil; onReady = nil
        connection.cancel()
        handler?(closeCode, error)
    }

    private static func code(_ c: NWProtocolWebSocket.CloseCode) -> UInt16 {
        switch c {
        case .protocolCode(let p): return p.rawValue
        case .applicationCode(let v), .privateCode(let v): return v
        @unknown default: return 0
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return "\(code)"
        case .dns(let code): return "dns \(code)"
        default: return "\(error)"
        }
    }
}

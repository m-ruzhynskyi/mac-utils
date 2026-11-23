import CryptoKit
import Foundation

/// Протокол MU Link, версия 1. Описание — `docs/mu-link-protocol.md` (одинаковый файл в ветках Mac и Windows),
/// общие векторы — `Tests/Fixtures/mu-link/vectors.json`.
package enum LinkWire {
    package static let version = 1
    package static let port: UInt16 = 47130
    package static let path = "/mu-link"
    /// Пульс: Mac шлёт `ping` раз в 5 с; без единого кадра 15 с связь считается потерянной.
    package static let pingInterval: TimeInterval = 5
    package static let silenceTimeout: TimeInterval = 15
    package static let handshakeTimeout: TimeInterval = 10
    /// Пауза перед повтором: 1, 2, 5, 10, 30, 30… с. Сбрасывается после `ready`.
    package static let retryDelays: [TimeInterval] = [1, 2, 5, 10, 30]
    /// Самый длинный текстовый кадр.
    package static let maxFrameBytes = 1 << 20

    /// Коды закрытия WebSocket.
    package enum Close {
        package static let normal: UInt16 = 1000
        package static let protocolError: UInt16 = 4400
        package static let auth: UInt16 = 4401
        package static let pairing: UInt16 = 4403
        package static let timeout: UInt16 = 4408
        package static let replaced: UInt16 = 4409
    }

    /// `ws://<host>:47130/mu-link`; IPv6 — в скобках. nil — пустой или кривой адрес.
    package static func url(host rawHost: String, port: UInt16 = port) -> URL? {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        guard !host.isEmpty, !host.contains("/"), !host.contains(" ") else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return URL(string: "ws://\(bracketed):\(port)\(path)")
    }
}

// MARK: - Кадры

/// `hello`: Mac → ПК и ПК → Mac (у ПК ещё `paired` и `sig`).
package struct LinkHello: Equatable, Sendable {
    package var role: String
    package var app: String
    package var version: String
    package var name: String
    package var caps: [String]
    package var pub: String
    package var nonce: String
    package var paired: Bool?
    package var sig: String?
    package var v: Int = LinkWire.version

    package init(role: String, app: String, version: String, name: String, caps: [String] = [], pub: String, nonce: String,
                 paired: Bool? = nil, sig: String? = nil, v: Int = LinkWire.version) {
        self.role = role; self.app = app; self.version = version; self.name = name; self.caps = caps
        self.pub = pub; self.nonce = nonce; self.paired = paired; self.sig = sig; self.v = v
    }
}

/// Питание ПК. В версии 1 ПК всегда отдаёт `unknown`: данные ДБЖ — отдельная задача.
package struct LinkPower: Equatable, Sendable {
    package enum Source: String, Sendable { case ac, battery, unknown }
    package var source: Source
    package var percent: Int?
    package var minutesLeft: Int?
    package init(source: Source = .unknown, percent: Int? = nil, minutesLeft: Int? = nil) {
        self.source = source; self.percent = percent; self.minutesLeft = minutesLeft
    }
}

/// `status` от ПК.
package struct LinkStatus: Equatable, Sendable {
    package var name: String
    package var os: String
    /// Сколько работает Windows, секунды.
    package var uptime: Int
    package var app: String
    package var version: String
    package var power: LinkPower
    package init(name: String, os: String, uptime: Int, app: String, version: String, power: LinkPower = LinkPower()) {
        self.name = name; self.os = os; self.uptime = uptime; self.app = app; self.version = version; self.power = power
    }
}

package enum LinkMessage: Equatable, Sendable {
    case hello(LinkHello)
    case auth(sig: String)
    case pair(proof: String, sig: String)
    case paired(proof: String)
    case ready
    case ping(t: Int64)
    case pong(t: Int64)
    case status(LinkStatus)
    case error(code: String, message: String, attemptsLeft: Int?, retryAfter: Int?)
    /// Незнакомый тип (новая версия протокола): игнорируется, связь не рвётся.
    case unknown(type: String)

    package var type: String {
        switch self {
        case .hello: return "hello"
        case .auth: return "auth"
        case .pair: return "pair"
        case .paired: return "paired"
        case .ready: return "ready"
        case .ping: return "ping"
        case .pong: return "pong"
        case .status: return "status"
        case .error: return "error"
        case .unknown(let type): return type
        }
    }
}

/// Разобранный кадр: версия отправителя, `id` и сообщение.
package struct LinkFrame: Equatable, Sendable {
    package var v: Int
    package var id: String
    package var message: LinkMessage
    package init(v: Int = LinkWire.version, id: String, message: LinkMessage) { self.v = v; self.id = id; self.message = message }
}

package enum LinkDecodeError: Error, Equatable {
    /// Не JSON-объект, нет `type`/`v`, слишком большой кадр или у знакомого типа нет обязательного поля.
    case malformed(String)
}

package enum LinkCodec {
    /// Новый `id` кадра: 8 случайных байт в hex.
    package static func newID() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    package static func decode(_ text: String) throws -> LinkFrame {
        guard text.utf8.count <= LinkWire.maxFrameBytes else { throw LinkDecodeError.malformed("слишком большой кадр") }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let o = object as? [String: Any] else {
            throw LinkDecodeError.malformed("не JSON-объект")
        }
        guard let type = o["type"] as? String, !type.isEmpty else { throw LinkDecodeError.malformed("нет type") }
        guard let v = int(o["v"]) else { throw LinkDecodeError.malformed("нет v") }
        let id = (o["id"] as? String).map { String($0.prefix(64)) } ?? ""
        func str(_ key: String) throws -> String {
            guard let s = o[key] as? String else { throw LinkDecodeError.malformed("\(type): нет \(key)") }
            return s
        }
        let message: LinkMessage
        switch type {
        case "hello":
            message = .hello(LinkHello(role: try str("role"), app: (o["app"] as? String) ?? "", version: (o["version"] as? String) ?? "",
                                       name: (o["name"] as? String) ?? "", caps: (o["caps"] as? [Any])?.compactMap { $0 as? String } ?? [],
                                       pub: try str("pub"), nonce: try str("nonce"), paired: o["paired"] as? Bool,
                                       sig: o["sig"] as? String, v: v))
        case "auth": message = .auth(sig: try str("sig"))
        case "pair": message = .pair(proof: try str("proof"), sig: try str("sig"))
        case "paired": message = .paired(proof: try str("proof"))
        case "ready": message = .ready
        case "ping": message = .ping(t: int64(o["t"]) ?? 0)
        case "pong": message = .pong(t: int64(o["t"]) ?? 0)
        case "status":
            let p = o["power"] as? [String: Any]
            let power = LinkPower(source: (p?["source"] as? String).flatMap(LinkPower.Source.init(rawValue:)) ?? .unknown,
                                  percent: int(p?["percent"]), minutesLeft: int(p?["minutesLeft"]))
            message = .status(LinkStatus(name: (o["name"] as? String) ?? "", os: (o["os"] as? String) ?? "",
                                         uptime: int(o["uptime"]) ?? 0, app: (o["app"] as? String) ?? "",
                                         version: (o["version"] as? String) ?? "", power: power))
        case "error":
            message = .error(code: (o["code"] as? String) ?? "protocol", message: (o["message"] as? String) ?? "",
                             attemptsLeft: int(o["attemptsLeft"]), retryAfter: int(o["retryAfter"]))
        default: message = .unknown(type: type)
        }
        return LinkFrame(v: v, id: id, message: message)
    }

    package static func encode(_ frame: LinkFrame) -> String {
        var o: [String: Any] = ["v": frame.v, "type": frame.message.type, "id": frame.id]
        switch frame.message {
        case .hello(let h):
            o.merge(["role": h.role, "app": h.app, "version": h.version, "name": h.name, "caps": h.caps, "pub": h.pub, "nonce": h.nonce]) { $1 }
            if let paired = h.paired { o["paired"] = paired }
            if let sig = h.sig { o["sig"] = sig }
        case .auth(let sig): o["sig"] = sig
        case let .pair(proof, sig): o["proof"] = proof; o["sig"] = sig
        case .paired(let proof): o["proof"] = proof
        case .ready, .unknown: break
        case .ping(let t), .pong(let t): o["t"] = t
        case .status(let s):
            o.merge(["name": s.name, "os": s.os, "uptime": s.uptime, "app": s.app, "version": s.version,
                     "power": ["source": s.power.source.rawValue, "percent": s.power.percent as Any? ?? NSNull(),
                               "minutesLeft": s.power.minutesLeft as Any? ?? NSNull()]]) { $1 }
        case let .error(code, message, attemptsLeft, retryAfter):
            o["code"] = code; o["message"] = message
            if let attemptsLeft { o["attemptsLeft"] = attemptsLeft }
            if let retryAfter { o["retryAfter"] = retryAfter }
        }
        let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    package static func encode(_ message: LinkMessage, id: String = newID()) -> String {
        encode(LinkFrame(id: id, message: message))
    }

    /// Целое из JSON: `NSNumber` без дробной части (`true`/`false` не считаются числом).
    private static func int(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d.isFinite, d.rounded() == d, abs(d) < 9e15 else { return nil }
        return Int(d)
    }

    private static func int64(_ value: Any?) -> Int64? { int(value).map(Int64.init) }
}

// MARK: - Криптография

/// Подпись устройства: публичный ключ Ed25519 и подпись канонической строки `mu-link/1`.
/// В приложении — `ShareIdentity` (ключ трансляции), в тестах и двойнике — `LinkKey`.
package protocol LinkSigner: Sendable {
    var publicKey: String { get }
    func sign(link message: String) -> String
}

/// Ключ Ed25519 в памяти (двойник ПК, самопроверка, тесты).
package struct LinkKey: LinkSigner {
    private let key: Curve25519.Signing.PrivateKey
    package init() { key = Curve25519.Signing.PrivateKey() }
    /// Из 32-байтного seed (векторы тестов).
    package init?(seed: Data) {
        guard let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { return nil }
        key = k
    }
    package var publicKey: String { LinkCrypto.base64url(key.publicKey.rawRepresentation) }
    package func sign(link message: String) -> String {
        LinkCrypto.base64url((try? key.signature(for: Data(message.utf8))) ?? Data())
    }
}

package enum LinkCrypto {
    package enum Kind: String { case server, client, pairMac = "pair-mac", pairPC = "pair-pc" }

    /// `mu-link/1\n<kind>\n<macPub>\n<pcPub>\n<clientNonce>\n<serverNonce>`.
    package static func message(_ kind: Kind, macPub: String, pcPub: String, clientNonce: String, serverNonce: String) -> String {
        "mu-link/1\n\(kind.rawValue)\n\(macPub)\n\(pcPub)\n\(clientNonce)\n\(serverNonce)"
    }

    /// Проверка подписи Ed25519; любая ошибка — false.
    package static func verify(pub: String, sig: String, message: String) -> Bool {
        guard pub.utf8.count == 43, let pubData = data(fromBase64url: pub), pubData.count == 32,
              let sigData = data(fromBase64url: sig), sigData.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else { return false }
        return key.isValidSignature(sigData, for: Data(message.utf8))
    }

    /// Доказательство кода: HMAC-SHA256 строки ключом «6 цифр кода» (UTF-8), base64url.
    package static func proof(code: String, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(code.utf8)))
        return base64url(Data(mac))
    }

    /// Сравнение доказательств за постоянное время.
    package static func proofMatches(_ proof: String, code: String, message: String) -> Bool {
        guard let given = data(fromBase64url: proof), given.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: Data(message.utf8),
                                                      using: SymmetricKey(data: Data(code.utf8)))
    }

    /// 32 случайных байта в base64url.
    package static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64url(Data(bytes))
    }

    /// Код сопряжения: 6 цифр, равномерно.
    package static func newCode() -> String { String(format: "%06d", Int.random(in: 0...999_999)) }

    /// Отпечаток `a1b2-c3d4-e5f6-0718`: первые 8 байт SHA-256 публичного ключа (как у share).
    package static func fingerprint(_ pub: String) -> String? {
        guard let raw = data(fromBase64url: pub), raw.count == 32 else { return nil }
        let hex = SHA256.hash(data: raw).prefix(8).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: 16, by: 4).map { i in
            String(hex[hex.index(hex.startIndex, offsetBy: i)..<hex.index(hex.startIndex, offsetBy: i + 4)])
        }.joined(separator: "-")
    }

    package static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Строго: только алфавит base64url, без `=` и пробелов.
    package static func data(fromBase64url text: String) -> Data? {
        guard !text.isEmpty, text.utf8.count % 4 != 1,
              text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F })
        else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

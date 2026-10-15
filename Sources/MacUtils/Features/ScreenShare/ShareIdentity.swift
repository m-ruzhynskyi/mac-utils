import CryptoKit
import Foundation
import os
import Security

/// Хранилище 32 байт приватного ключа. В приложении — Keychain, в тестах — память.
protocol ShareKeyStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

struct KeychainError: Error, CustomStringConvertible {
    let status: OSStatus
    var description: String { "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)") (\(status))" }
}

/// Обычная login keychain (data-protection keychain требует entitlement, которого нет у самоподписанного сертификата).
struct KeychainKeyStore: ShareKeyStore {
    static let service = "com.mruzhynskyi.macutils.share-identity"
    static let account = "ed25519-v1"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account,
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    func save(_ data: Data) throws {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Ключ Ed25519 для трансляции (протокол v2, см. .audit/auth-design.md §2). Создаётся лениво при первом обращении.
/// Приватный ключ наружу не отдаётся: подписываются только канонические строки протокола.
final class ShareIdentity: @unchecked Sendable {
    static let shared = ShareIdentity(store: KeychainKeyStore())
    private static let log = Logger(subsystem: "com.mruzhynskyi.macutils", category: "share-identity")

    private let store: ShareKeyStore
    private let lock = NSLock()
    private var cached: Curve25519.Signing.PrivateKey?
    /// false: Keychain недоступен, ключ живёт только в памяти до выхода из приложения.
    private(set) var isPersistent = true

    init(store: ShareKeyStore) { self.store = store }

    // MARK: - Ключ

    private func key() -> Curve25519.Signing.PrivateKey {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let key = loadOrCreate()
        cached = key
        return key
    }

    private func loadOrCreate() -> Curve25519.Signing.PrivateKey {
        do {
            if let data = try store.load() {
                if let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) { return key }
                // Элемент есть, но испорчен: пользоваться им нельзя, заменяем.
                Self.log.error("Ключ трансляции в Keychain испорчен (\(data.count) байт), создаю новый")
                try store.delete()
            }
            let key = Curve25519.Signing.PrivateKey()
            try store.save(key.rawRepresentation)
            return key
        } catch {
            // Отказ в доступе или заблокированная связка: не затираем существующий ключ, работаем с временным.
            Self.log.error("Не удалось сохранить ключ трансляции: \(String(describing: error), privacy: .public)")
            isPersistent = false
            return Curve25519.Signing.PrivateKey()
        }
    }

    /// Новый ключ вместо текущего (старый стирается из Keychain). Новый ID задаёт вызывающий («Сменить ID»).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        do { try store.delete() } catch {
            Self.log.error("Не удалось удалить ключ трансляции: \(String(describing: error), privacy: .public)")
        }
        isPersistent = true
        let key = Curve25519.Signing.PrivateKey()
        do { try store.save(key.rawRepresentation) } catch {
            Self.log.error("Не удалось сохранить новый ключ трансляции: \(String(describing: error), privacy: .public)")
            isPersistent = false
        }
        cached = key
    }

    // MARK: - Публичные данные

    /// Публичный ключ, base64url без `=` (43 символа).
    var publicKey: String { Self.base64url(key().publicKey.rawRepresentation) }
    /// Отпечаток `a1b2-c3d4-e5f6-0718`.
    var fingerprint: String { Self.fingerprint(ofPublicKey: key().publicKey.rawRepresentation) }

    // MARK: - Подписи

    func sign(host roomId: String, nonce: String) -> String {
        sign(Self.hostMessage(roomId: roomId, nonce: nonce))
    }

    func sign(viewer roomId: String, viewerId: String, rid: String, nonce: String) -> String {
        sign(Self.viewerMessage(roomId: roomId, viewerId: viewerId, rid: rid, nonce: nonce))
    }

    func sign(status myId: String, ts: Int64, ids: [String]) -> String {
        sign(Self.statusMessage(myId: myId, ts: ts, ids: ids))
    }

    func sign(accept roomId: String, viewerPub: String, rid: String) -> String {
        sign(Self.acceptMessage(roomId: roomId, viewerPub: viewerPub, rid: rid))
    }

    private func sign(_ message: String) -> String {
        // Ed25519 детерминирован, ошибок подписи у CryptoKit для этого вызова нет.
        let signature = (try? key().signature(for: Data(message.utf8))) ?? Data()
        return Self.base64url(signature)
    }

    // MARK: - Статические (без состояния)

    static func verify(pub: String, sig: String, message: String) -> Bool {
        guard let pubData = data(fromBase64url: pub), pubData.count == 32,
              let sigData = data(fromBase64url: sig), sigData.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else { return false }
        return key.isValidSignature(sigData, for: Data(message.utf8))
    }

    static func fingerprint(ofPublicKey raw: Data) -> String {
        let hex = SHA256.hash(data: raw).prefix(8).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: 16, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// Отпечаток по публичному ключу в base64url; nil, если это не ключ.
    static func fingerprint(ofBase64urlKey pub: String) -> String? {
        guard let raw = data(fromBase64url: pub), raw.count == 32 else { return nil }
        return fingerprint(ofPublicKey: raw)
    }

    // Канонические строки (UTF-8, поля через \n, домен в начале). roomId подставляет клиент сам.
    static func hostMessage(roomId: String, nonce: String) -> String {
        "mu-share/v2\nhost\n\(roomId)\n\(nonce)"
    }

    static func viewerMessage(roomId: String, viewerId: String, rid: String, nonce: String) -> String {
        "mu-share/v2\nviewer\n\(roomId)\n\(viewerId)\n\(rid)\n\(nonce)"
    }

    static func statusMessage(myId: String, ts: Int64, ids: [String]) -> String {
        "mu-share/v2\nstatus\n\(myId)\n\(ts)\n\(ids.joined(separator: ","))"
    }

    static func acceptMessage(roomId: String, viewerPub: String, rid: String) -> String {
        "mu-share/v2\naccept\n\(roomId)\n\(viewerPub)\n\(rid)"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Строго: только алфавит base64url, без `=` и пробелов.
    static func data(fromBase64url text: String) -> Data? {
        guard text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }),
              text.utf8.count % 4 != 1 else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // MARK: - Короткие обращения к общему ключу

    static var publicKey: String { shared.publicKey }
    static var fingerprint: String { shared.fingerprint }
    static func reset() { shared.reset() }
}

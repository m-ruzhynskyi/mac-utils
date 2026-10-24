import CryptoKit
import Foundation
import os
import Security

/// Хранилище 32 байт приватного ключа. В приложении — файл (с переносом из Keychain), в тестах — память.
package protocol ShareKeyStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

package struct KeychainError: Error, CustomStringConvertible {
    package let status: OSStatus
    package var description: String { "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)") (\(status))" }
}

/// Файл с ключом в «Application Support/Mac Utils», доступ только у владельца (0600, папка 0700).
/// Keychain для этого не годится: у приложения с самоподписанным сертификатом (без Team ID) доступ к элементу
/// привязан к хешу конкретной сборки (`partition_id cdhash:…`), и после каждого обновления macOS снова просит пароль.
package struct FileKeyStore: ShareKeyStore {
    package let url: URL

    package static var standard: FileKeyStore {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Utils", isDirectory: true)
        return FileKeyStore(url: folder.appendingPathComponent("share-identity.key"))
    }

    package func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    package func save(_ data: Data) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Сначала временный файл с правами 0600, потом атомарная замена: ключ ни на миг не лежит открытым или наполовину.
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    package func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// Файл — основное хранилище; ключ из Keychain (1.5.0–1.5.1) переносится в него один раз, чтобы ID не сменился.
/// Перенос может в последний раз спросить пароль связки. Элемент Keychain не удаляется: удаление тоже спросило бы пароль,
/// а после переноса его больше никто не читает.
package struct MigratingKeyStore: ShareKeyStore {
    package let primary: ShareKeyStore
    package let legacy: ShareKeyStore
    package let defaults: UserDefaults
    package static let migratedKey = "shareKeyMigratedFromKeychain"

    package func load() throws -> Data? {
        if let data = try primary.load() { return data }
        guard !defaults.bool(forKey: Self.migratedKey) else { return nil }
        // Ошибка чтения Keychain (отменили запрос пароля) пробрасывается: попробуем при следующем запуске.
        let data = try legacy.load()
        if let data { try primary.save(data) }
        defaults.set(true, forKey: Self.migratedKey)
        return data
    }

    package func save(_ data: Data) throws {
        try primary.save(data)
        // Новый ключ уже в файле: старый из Keychain подхватывать нельзя (иначе «Сменить ID» откатился бы).
        defaults.set(true, forKey: Self.migratedKey)
    }

    package func delete() throws {
        try primary.delete()
        defaults.set(true, forKey: Self.migratedKey)
    }
}

/// Обычная login keychain (data-protection keychain требует entitlement, которого нет у самоподписанного сертификата).
/// Только для переноса ключа, сохранённого версиями 1.5.0–1.5.1.
package struct KeychainKeyStore: ShareKeyStore {
    package static let service = "com.mruzhynskyi.macutils.share-identity"
    package static let account = "ed25519-v1"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: Self.account,
         kSecAttrSynchronizable as String: false]
    }

    package func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }

    package func save(_ data: Data) throws {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    package func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// Ключ Ed25519 для трансляции (протокол v2, см. .audit/auth-design.md §2). Создаётся лениво при первом обращении.
/// Приватный ключ наружу не отдаётся: подписываются только канонические строки протокола.
package final class ShareIdentity: @unchecked Sendable {
    package static let shared = ShareIdentity(store: MigratingKeyStore(primary: FileKeyStore.standard, legacy: KeychainKeyStore(),
                                                               defaults: .standard))
    private static let log = Logger(subsystem: "com.mruzhynskyi.macutils", category: "share-identity")

    private let store: ShareKeyStore
    private let lock = NSLock()
    private var cached: Curve25519.Signing.PrivateKey?
    /// false: Keychain недоступен, ключ живёт только в памяти до выхода из приложения.
    private var persistent = true

    /// Явное состояние хранилища ключа. Читать его можно до первой подписи: ключ при этом загружается.
    package enum Availability: Equatable { case persistent, keychainUnavailable }

    /// Текст для пользователя, когда ключ сохранить нельзя и проверка ключом выключена.
    package static let keychainUnavailableMessage = "Нет доступа к Связке ключей, проверка ключа выключена"

    package var availability: Availability {
        _ = key()
        lock.lock(); defer { lock.unlock() }
        return persistent ? .persistent : .keychainUnavailable
    }

    /// false — Keychain недоступен: временный ключ нельзя показывать relay (он закрепил бы ID за выброшенным ключом).
    package var isPersistent: Bool { availability == .persistent }

    package init(store: ShareKeyStore) { self.store = store }

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
                Self.log.error("Ключ трансляции испорчен (\(data.count) байт), создаю новый")
                try store.delete()
            }
            let key = Curve25519.Signing.PrivateKey()
            try store.save(key.rawRepresentation)
            return key
        } catch {
            // Отказ в доступе или заблокированная связка: не затираем существующий ключ, работаем с временным.
            Self.log.error("Не удалось сохранить ключ трансляции: \(String(describing: error), privacy: .public)")
            persistent = false
            return Curve25519.Signing.PrivateKey()
        }
    }

    /// Новый ключ вместо текущего (старый стирается). Новый ID задаёт вызывающий («Сменить ID»).
    package func reset() {
        lock.lock(); defer { lock.unlock() }
        do { try store.delete() } catch {
            Self.log.error("Не удалось удалить ключ трансляции: \(String(describing: error), privacy: .public)")
        }
        persistent = true
        let key = Curve25519.Signing.PrivateKey()
        do { try store.save(key.rawRepresentation) } catch {
            Self.log.error("Не удалось сохранить новый ключ трансляции: \(String(describing: error), privacy: .public)")
            persistent = false
        }
        cached = key
    }

    // MARK: - Публичные данные

    /// Публичный ключ, base64url без `=` (43 символа).
    package var publicKey: String { Self.base64url(key().publicKey.rawRepresentation) }
    /// Отпечаток `a1b2-c3d4-e5f6-0718`.
    package var fingerprint: String { Self.fingerprint(ofPublicKey: key().publicKey.rawRepresentation) }

    // MARK: - Подписи

    package func sign(host roomId: String, nonce: String) -> String {
        sign(Self.hostMessage(roomId: roomId, nonce: nonce))
    }

    package func sign(viewer roomId: String, viewerId: String, rid: String, nonce: String) -> String {
        sign(Self.viewerMessage(roomId: roomId, viewerId: viewerId, rid: rid, nonce: nonce))
    }

    package func sign(status myId: String, ts: Int64, ids: [String]) -> String {
        sign(Self.statusMessage(myId: myId, ts: ts, ids: ids))
    }

    package func sign(accept roomId: String, viewerPub: String, rid: String) -> String {
        sign(Self.acceptMessage(roomId: roomId, viewerPub: viewerPub, rid: rid))
    }

    private func sign(_ message: String) -> String {
        // Ed25519 детерминирован, ошибок подписи у CryptoKit для этого вызова нет.
        let signature = (try? key().signature(for: Data(message.utf8))) ?? Data()
        return Self.base64url(signature)
    }

    // MARK: - Статические (без состояния)

    /// Вид публичного ключа устройства. Ed25519 — Mac и приложение для Windows (32 байта); P-256 ECDSA — страница
    /// ретранслятора (браузер, Windows-клиент без своего ключа): WebCrypto отдаёт его несжатым (65 байт, `04‖x‖y`),
    /// подпись — `r‖s` по 32 байта, хеш SHA-256 (алгоритм `es256` в протоколе).
    package enum KeyKind: Equatable { case ed25519, p256 }

    package static func keyKind(ofPublicKey raw: Data) -> KeyKind? {
        if raw.count == 32 { return .ed25519 }
        if raw.count == 65, raw.first == 0x04, (try? P256.Signing.PublicKey(x963Representation: raw)) != nil { return .p256 }
        return nil
    }

    /// Вид ключа в base64url (строго: 43 символа для Ed25519, 87 для P-256); nil — это не ключ.
    package static func keyKind(ofBase64urlKey pub: String) -> KeyKind? {
        guard pub.utf8.count == 43 || pub.utf8.count == 87, let raw = data(fromBase64url: pub) else { return nil }
        return keyKind(ofPublicKey: raw)
    }

    package static func verify(pub: String, sig: String, message: String) -> Bool {
        guard let kind = keyKind(ofBase64urlKey: pub), let pubData = data(fromBase64url: pub),
              let sigData = data(fromBase64url: sig), sigData.count == 64 else { return false }
        switch kind {
        case .ed25519:
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pubData) else { return false }
            return key.isValidSignature(sigData, for: Data(message.utf8))
        case .p256:
            guard let key = try? P256.Signing.PublicKey(x963Representation: pubData),
                  let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sigData) else { return false }
            return key.isValidSignature(signature, for: Data(message.utf8))
        }
    }

    package static func fingerprint(ofPublicKey raw: Data) -> String {
        let hex = SHA256.hash(data: raw).prefix(8).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: 16, by: 4).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// Отпечаток по публичному ключу в base64url (Ed25519 или P-256, как у relay: SHA-256 сырых байт); nil, если это не ключ.
    package static func fingerprint(ofBase64urlKey pub: String) -> String? {
        guard keyKind(ofBase64urlKey: pub) != nil, let raw = data(fromBase64url: pub) else { return nil }
        return fingerprint(ofPublicKey: raw)
    }

    // Канонические строки (UTF-8, поля через \n, домен в начале). roomId подставляет клиент сам.
    package static func hostMessage(roomId: String, nonce: String) -> String {
        "mu-share/v2\nhost\n\(roomId)\n\(nonce)"
    }

    package static func viewerMessage(roomId: String, viewerId: String, rid: String, nonce: String) -> String {
        "mu-share/v2\nviewer\n\(roomId)\n\(viewerId)\n\(rid)\n\(nonce)"
    }

    package static func statusMessage(myId: String, ts: Int64, ids: [String]) -> String {
        "mu-share/v2\nstatus\n\(myId)\n\(ts)\n\(ids.joined(separator: ","))"
    }

    package static func acceptMessage(roomId: String, viewerPub: String, rid: String) -> String {
        "mu-share/v2\naccept\n\(roomId)\n\(viewerPub)\n\(rid)"
    }

    package static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Строго: только алфавит base64url, без `=` и пробелов.
    package static func data(fromBase64url text: String) -> Data? {
        guard text.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }),
              text.utf8.count % 4 != 1 else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    // MARK: - Короткие обращения к общему ключу

    package static var publicKey: String { shared.publicKey }
    package static var fingerprint: String { shared.fingerprint }
    package static func reset() { shared.reset() }
}

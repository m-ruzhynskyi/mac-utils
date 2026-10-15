import CryptoKit
import XCTest
@testable import MacUtils

/// Общие векторы раздела 9 .audit/auth-design.md: те же значения должны совпасть в auth.js (R1) и Windows (W1).
/// Seed 0x01…0x20, roomId 1234567890, viewerId 9876543210, rid 00000000-0000-4000-8000-000000000000, nonce — 32 нулевых байта.
final class ShareIdentityTests: XCTestCase {
    private final class MemoryStore: ShareKeyStore {
        var data: Data?
        var failLoad = false
        var failSave = false
        var saves = 0
        func load() throws -> Data? { if failLoad { throw KeychainError(status: -25308) }; return data }
        func save(_ data: Data) throws { if failSave { throw KeychainError(status: -25308) }; saves += 1; self.data = data }
        func delete() throws { data = nil }
    }

    static let seed = Data((1...32).map { UInt8($0) })
    static let room = "1234567890", viewerId = "9876543210"
    static let rid = "00000000-0000-4000-8000-000000000000"
    static let nonce = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    static let pub = "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"
    static let fp = "65b6-0673-d6ed-884b"

    private func fixed() -> (ShareIdentity, MemoryStore) {
        let store = MemoryStore()
        store.data = Self.seed
        return (ShareIdentity(store: store), store)
    }

    func testPublicKeyAndFingerprintVector() {
        let (identity, _) = fixed()
        XCTAssertEqual(identity.publicKey, Self.pub)
        XCTAssertEqual(identity.publicKey.count, 43)
        XCTAssertEqual(identity.fingerprint, Self.fp)
        XCTAssertEqual(ShareIdentity.fingerprint(ofBase64urlKey: Self.pub), Self.fp)
    }

    func testCanonicalStrings() {
        XCTAssertEqual(ShareIdentity.hostMessage(roomId: Self.room, nonce: Self.nonce),
                       "mu-share/v2\nhost\n1234567890\n\(Self.nonce)")
        XCTAssertEqual(ShareIdentity.viewerMessage(roomId: Self.room, viewerId: Self.viewerId, rid: Self.rid, nonce: Self.nonce),
                       "mu-share/v2\nviewer\n1234567890\n9876543210\n\(Self.rid)\n\(Self.nonce)")
        XCTAssertEqual(ShareIdentity.statusMessage(myId: Self.room, ts: 1760000000000, ids: [Self.viewerId, Self.room]),
                       "mu-share/v2\nstatus\n1234567890\n1760000000000\n9876543210,1234567890")
        XCTAssertEqual(ShareIdentity.acceptMessage(roomId: Self.room, viewerPub: Self.pub, rid: Self.rid),
                       "mu-share/v2\naccept\n1234567890\n\(Self.pub)\n\(Self.rid)")
    }

    /// Подписи Ed25519 из Node (RFC 8032, детерминированные): CryptoKit подписывает недетерминированно,
    /// поэтому побайтно сравнить собственную подпись с вектором нельзя. Проверяем перекрёстно:
    /// чужая эталонная подпись проходит `verify`, а наша подпись проходит проверку по тому же `pub`.
    static let vectors: [(name: String, message: String, sig: String)] = [
        ("host", "mu-share/v2\nhost\n1234567890\n\(nonce)",
         "x9MgCzYW402REdrI5TCh0L9nulcDS2OWlJXamB6Dlkdl96FvdoTvI5R-si1e5RCKCc6w-k1TKaAY_stmB4jUDQ"),
        ("viewer", "mu-share/v2\nviewer\n1234567890\n9876543210\n\(rid)\n\(nonce)",
         "jkWqO6B7KzZaHhkf-WpoT8K5OF8P7SrLFq_9I-j_8eUaphvOL4NSS7Afl5rsM2aDlN8Fd8cXPjCS0a4qMqDyAA"),
        ("status", "mu-share/v2\nstatus\n1234567890\n1760000000000\n9876543210,1234567890",
         "Qj7Zd93qxbtdJzIGhmEUD7ConlCIU3-IlRVCiq4yiH4y5xY7RmnEugENnktUWxzQroMDbGt7eC2ePC_rbYGFDw"),
        ("accept", "mu-share/v2\naccept\n1234567890\n\(pub)\n\(rid)",
         "S2NdQNkrRNHogvIyB1I8GycN4wLgz6img5dzbGj5mtnYBRcq9moqek6TzQchQiPSpsU96p2joGBA49nBpc9YCw"),
    ]

    func testReferenceSignaturesVerify() {
        for vector in Self.vectors {
            XCTAssertTrue(ShareIdentity.verify(pub: Self.pub, sig: vector.sig, message: vector.message), vector.name)
            XCTAssertEqual(vector.sig.count, 86)
        }
    }

    func testOwnSignaturesMatchCanonicalMessages() {
        let (identity, _) = fixed()
        let own = [
            identity.sign(host: Self.room, nonce: Self.nonce),
            identity.sign(viewer: Self.room, viewerId: Self.viewerId, rid: Self.rid, nonce: Self.nonce),
            identity.sign(status: Self.room, ts: 1760000000000, ids: [Self.viewerId, Self.room]),
            identity.sign(accept: Self.room, viewerPub: Self.pub, rid: Self.rid),
        ]
        for (vector, sig) in zip(Self.vectors, own) {
            XCTAssertEqual(sig.count, 86, vector.name)
            XCTAssertTrue(ShareIdentity.verify(pub: Self.pub, sig: sig, message: vector.message), vector.name)
        }
    }

    func testVerify() {
        let (identity, _) = fixed()
        let message = ShareIdentity.hostMessage(roomId: Self.room, nonce: Self.nonce)
        let sig = identity.sign(host: Self.room, nonce: Self.nonce)
        XCTAssertTrue(ShareIdentity.verify(pub: Self.pub, sig: sig, message: message))
        var flipped = Array(sig)
        flipped[10] = flipped[10] == "A" ? "B" : "A"
        // другая комната, другая роль, испорченные данные
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: sig, message: ShareIdentity.hostMessage(roomId: "1234567891", nonce: Self.nonce)))
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: sig,
                                            message: ShareIdentity.viewerMessage(roomId: Self.room, viewerId: Self.viewerId, rid: Self.rid, nonce: Self.nonce)))
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: String(flipped), message: message))
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: sig + "=", message: message))
        XCTAssertFalse(ShareIdentity.verify(pub: "", sig: sig, message: message))
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: "", message: message))
        XCTAssertFalse(ShareIdentity.verify(pub: "не-ключ", sig: sig, message: message))
        let other = Curve25519.Signing.PrivateKey()
        XCTAssertFalse(ShareIdentity.verify(pub: ShareIdentity.base64url(other.publicKey.rawRepresentation), sig: sig, message: message))
    }

    func testBase64urlRoundTripAndStrictness() {
        let bytes = Data([0xfb, 0xff, 0xfe, 0x00, 0x10])
        let text = ShareIdentity.base64url(bytes)
        XCTAssertEqual(text, "-__-ABA")
        XCTAssertEqual(ShareIdentity.data(fromBase64url: text), bytes)
        XCTAssertNil(ShareIdentity.data(fromBase64url: "ab+/"))
        XCTAssertNil(ShareIdentity.data(fromBase64url: "ab=="))
        XCTAssertNil(ShareIdentity.data(fromBase64url: "a"))
        XCTAssertNil(ShareIdentity.data(fromBase64url: "ab cd"))
    }

    func testKeyIsCreatedLazilyAndPersisted() {
        let store = MemoryStore()
        let identity = ShareIdentity(store: store)
        XCTAssertNil(store.data, "ключ не создаётся до первого обращения")
        let pub = identity.publicKey
        XCTAssertEqual(store.data?.count, 32)
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(identity.publicKey, pub)
        XCTAssertEqual(ShareIdentity(store: store).publicKey, pub, "после перезапуска ключ тот же")
        XCTAssertEqual(store.saves, 1)
        XCTAssertTrue(identity.isPersistent)
    }

    func testResetCreatesNewKeyAndReplacesStored() {
        let (identity, store) = fixed()
        XCTAssertEqual(identity.publicKey, Self.pub)
        identity.reset()
        XCTAssertNotEqual(identity.publicKey, Self.pub)
        XCTAssertNotEqual(store.data, Self.seed)
        XCTAssertEqual(store.data?.count, 32)
        XCTAssertEqual(ShareIdentity(store: store).publicKey, identity.publicKey)
    }

    func testCorruptStoredKeyIsReplaced() {
        let store = MemoryStore()
        store.data = Data([1, 2, 3])
        let identity = ShareIdentity(store: store)
        XCTAssertEqual(identity.publicKey.count, 43)
        XCTAssertEqual(store.data?.count, 32)
    }

    func testKeychainFailureDoesNotOverwriteAndFallsBackToMemory() {
        let store = MemoryStore()
        store.data = Self.seed
        store.failLoad = true
        let identity = ShareIdentity(store: store)
        let pub = identity.publicKey
        XCTAssertEqual(pub.count, 43)
        XCTAssertNotEqual(pub, Self.pub)
        XCTAssertFalse(identity.isPersistent)
        XCTAssertEqual(store.data, Self.seed, "существующий ключ не затирается при сбое чтения")
        XCTAssertEqual(identity.publicKey, pub, "в рамках запуска ключ стабилен")

        let failing = MemoryStore()
        failing.failSave = true
        let second = ShareIdentity(store: failing)
        XCTAssertEqual(second.publicKey, second.publicKey)
        XCTAssertFalse(second.isPersistent)
    }

    func testFingerprintFormat() {
        let fp = ShareIdentity.fingerprint(ofPublicKey: Data(repeating: 7, count: 32))
        XCTAssertNotNil(fp.range(of: "^[0-9a-f]{4}(-[0-9a-f]{4}){3}$", options: .regularExpression))
        XCTAssertNil(ShareIdentity.fingerprint(ofBase64urlKey: "abc"))
    }
}

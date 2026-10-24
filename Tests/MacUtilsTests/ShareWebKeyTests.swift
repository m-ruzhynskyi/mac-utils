import CryptoKit
import XCTest
@testable import MacUtils
@testable import MUCore
@testable import MUAudio
@testable import MUScreenShare

/// Ключ P-256 страницы ретранслятора (браузер, клиент для Windows без своего ключа): формат WebCrypto, проверка подписи
/// и «Всегда разрешать» для такого зрителя. Векторы получены WebCrypto в node (`subtle.generateKey ECDSA P-256`,
/// `exportKey("raw")`, `sign({name: "ECDSA", hash: "SHA-256"})`) — тот же формат, что у Chromium.
@MainActor
final class ShareWebKeyTests: XCTestCase {
    // Несжатый ключ `04‖x‖y` (65 байт) в base64url — как его шлёт страница и пересылает relay.
    private static let pub = "BK1H5QVZNCQWmcES3aR1RxCCT91WfBPbnlodGX1242h9H2MhNSUQQdobILH3qM5WSCXFP5oWy76pGRm4o_u16lI"
    private static let fp = "9c19-9a6a-8e58-5b22"
    private static let message = "mu-share/v2\nviewer\n1234567890\n9876543210\n0b7a6c1e-1111-4222-8333-944445555666\nAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    /// Подпись `r‖s` с s < n/2 и с s > n/2: WebCrypto «высокий» s не нормализует, проверка обязана принимать оба.
    private static let lowS = "0eB2dQyy84xGE56-nwkx7mEunQr0By2g_QIGyuQsOehnoo5_BWIkLl1rwAe89wNE8IlpEEmZvOt5gNtaSD2zLQ"
    private static let highS = "lI0Amkz_ebsGYxy4Ers7NT9QJhIWcSJBpzdL6Id58PztZGQVHqRcUdHxThPpZvhza--io5pbBNxRuchjf4NsUg"
    private static let accept = "mu-share/v2\naccept\n1234567890\n\(pub)\nrid-1"
    private static let acceptSig = "wk0WqLyo_vrd7sjtHySNTDKbWR5eTB6hbUhlTWXKjIGVh-svMjsaP5N1TrEhm9G91DIL1IjzOJr3AlVpO7A_8w"
    /// Тот же ключ с испорченной координатой y (точка не на кривой) и в сжатом виде (33 байта): не принимаются.
    private static let offCurve = "BK1H5QVZNCQWmcES3aR1RxCCT91WfBPbnlodGX1242h9H2MhNSUQQdobILH3qM5WSCXFP5oWy76pGRm4o_u16lM"
    private static let compressed = "Aq1H5QVZNCQWmcES3aR1RxCCT91WfBPbnlodGX1242h9"
    // Ed25519 из общих векторов (seed 0x01…0x20).
    private static let edPub = "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"

    // MARK: - Формат и подпись

    func testWebCryptoKeyIsRecognised() {
        XCTAssertEqual(ShareIdentity.keyKind(ofBase64urlKey: Self.pub), .p256)
        XCTAssertEqual(ShareIdentity.keyKind(ofBase64urlKey: Self.edPub), .ed25519)
        XCTAssertTrue(ShareHistory.isPublicKey(Self.pub))
        XCTAssertTrue(ShareHistory.isPublicKey(Self.edPub), "старый формат по-прежнему ключ")
        XCTAssertEqual(ShareIdentity.fingerprint(ofBase64urlKey: Self.pub), Self.fp, "отпечаток как у relay и страницы")
    }

    func testMalformedP256KeysAreRejected() {
        for bad in [Self.offCurve, Self.compressed, String(Self.pub.dropLast()), Self.pub + "A", Self.pub + "=",
                    "C" + Self.pub.dropFirst(), // первый байт не 0x04
                    String(repeating: "A", count: 87)] {
            XCTAssertNil(ShareIdentity.keyKind(ofBase64urlKey: bad), bad)
            XCTAssertFalse(ShareHistory.isPublicKey(bad), bad)
            XCTAssertNil(ShareIdentity.fingerprint(ofBase64urlKey: bad), bad)
        }
    }

    func testVerifiesWebCryptoSignatures() {
        XCTAssertTrue(ShareIdentity.verify(pub: Self.pub, sig: Self.lowS, message: Self.message))
        XCTAssertTrue(ShareIdentity.verify(pub: Self.pub, sig: Self.highS, message: Self.message))
        XCTAssertTrue(ShareIdentity.verify(pub: Self.pub, sig: Self.acceptSig, message: Self.accept))
    }

    func testRejectsWrongP256Signatures() {
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: Self.lowS, message: Self.message + "x"), "другое сообщение")
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: Self.acceptSig, message: Self.message), "подпись другой строки")
        XCTAssertFalse(ShareIdentity.verify(pub: Self.offCurve, sig: Self.lowS, message: Self.message))
        XCTAssertFalse(ShareIdentity.verify(pub: Self.edPub, sig: Self.lowS, message: Self.message), "подпись P-256 под ключом Ed25519")
        // DER вместо r‖s (длина другая) и испорченный байт.
        let raw = ShareIdentity.data(fromBase64url: Self.lowS)!
        let der = try! P256.Signing.ECDSASignature(rawRepresentation: raw).derRepresentation
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: ShareIdentity.base64url(der), message: Self.message))
        var flipped = raw
        flipped[10] ^= 1
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: ShareIdentity.base64url(flipped), message: Self.message))
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: "", message: Self.message))
    }

    func testEd25519StillVerifies() {
        let store = MemoryStore()
        store.data = Data((1...32).map { UInt8($0) })
        let identity = ShareIdentity(store: store)
        XCTAssertEqual(identity.publicKey, Self.edPub)
        let sig = identity.sign(accept: "1234567890", viewerPub: Self.pub, rid: "rid-1")
        XCTAssertTrue(ShareIdentity.verify(pub: Self.edPub, sig: sig, message: Self.accept))
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: sig, message: Self.accept), "подпись Ed25519 под ключом P-256")
    }

    // MARK: - «Всегда разрешать» для зрителя со страницы

    private final class MemoryStore: ShareKeyStore {
        var data: Data?
        func load() throws -> Data? { data }
        func save(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    private var savedHistory: Data?

    override func setUp() {
        // ShareHistory пишет в UserDefaults.standard (см. ShareHistoryTrustTests): значение сохраняем и возвращаем как было.
        savedHistory = UserDefaults.standard.data(forKey: Pref.shareHistory)
        UserDefaults.standard.removeObject(forKey: Pref.shareHistory)
    }

    override func tearDown() {
        if let savedHistory { UserDefaults.standard.set(savedHistory, forKey: Pref.shareHistory) }
        else { UserDefaults.standard.removeObject(forKey: Pref.shareHistory) }
    }

    private var viewerID: String { ShareCode.myID == "5550001112" ? "5550001113" : "5550001112" }

    /// Запрос, как его присылает relay после проверки подписи es256 и привязки ID зрителя к ключу.
    private func request(pub: String? = nil, idVerified: Bool = true, rid: String) -> ShareRequest? {
        ShareRequest.parse(["type": "request", "viewer": viewerID, "name": "Windows", "rid": rid, "v": 2,
                            "auth": "key", "pub": pub ?? Self.pub, "fp": Self.fp, "idVerified": idVerified, "self": false])
    }

    private func trust(_ history: ShareHistory) -> ShareTrust {
        ShareTrust(isTrusted: { history.isTrusted(id: $0, pub: $1) },
                   needsKeyConfirmation: { history.needsKeyConfirmation(id: $0) },
                   canTrust: { ShareHistory.canTrust($0) })
    }

    func testAllowAlwaysThenNextConnectionIsAcceptedWithoutAsking() throws {
        let history = ShareHistory()
        let first = try XCTUnwrap(request(rid: "rid-1"))
        XCTAssertEqual(first.auth, .key)
        XCTAssertEqual(first.fp, Self.fp)

        guard case .ask(let prompt) = ShareRules.decide(first, trust: trust(history)) else { return XCTFail("первый раз спрашиваем") }
        XCTAssertEqual(prompt.kind, .normal)
        XCTAssertTrue(prompt.allowAlways, "у зрителя с ключом страницы есть «Всегда разрешать»")
        let accepted = ShareRules.apply(.allowAlways, to: first, prompt: prompt) { id, name, pub in
            history.trust(id, name: name, pub: pub)
        }
        XCTAssertTrue(accepted)

        // Следующее подключение с того же устройства (новый rid, тот же ключ) — без вопроса, и после перезапуска тоже.
        let second = try XCTUnwrap(request(rid: "rid-2"))
        XCTAssertEqual(ShareRules.decide(second, trust: trust(history)), .accept)
        XCTAssertEqual(ShareRules.decide(second, trust: trust(ShareHistory())), .accept)
    }

    func testTrustedWebViewerIsStillAskedWithOtherKeyOrUnverifiedID() throws {
        let history = ShareHistory()
        history.trust(viewerID, name: "Windows", pub: Self.pub)
        // Тот же ID, но другое устройство (другой ключ): снова вопрос.
        let other = try XCTUnwrap(request(pub: Self.edPub, rid: "rid-3"))
        guard case .ask = ShareRules.decide(other, trust: trust(history)) else { return XCTFail("чужой ключ принят") }
        // Ключ тот же, но ID за ним не закреплён (relay: idVerified false) — вопрос без «Всегда».
        let unverified = try XCTUnwrap(request(idVerified: false, rid: "rid-4"))
        guard case .ask(let prompt) = ShareRules.decide(unverified, trust: trust(history)) else { return XCTFail("неподтверждённый ID принят") }
        XCTAssertFalse(prompt.allowAlways)
    }

    func testMalformedWebKeyFallsBackToUnverifiedRequest() throws {
        // Битый ключ — как у зрителя без ключа: вопрос каждый раз, «Всегда» нет.
        let bad = try XCTUnwrap(request(pub: Self.offCurve, rid: "rid-5"))
        XCTAssertEqual(bad.auth, .none)
        guard case .ask(let prompt) = ShareRules.decide(bad, trust: trust(ShareHistory())) else { return XCTFail() }
        XCTAssertEqual(prompt.kind, .legacy)
        XCTAssertFalse(prompt.allowAlways)
    }

    func testHostSignsAcceptForWebViewer() throws {
        let store = MemoryStore()
        store.data = Data((1...32).map { UInt8($0) })
        let identity = ShareIdentity(store: store)
        let viewer = try XCTUnwrap(request(rid: "rid-1"))
        let sig = try XCTUnwrap(ShareRules.hostSignature(for: viewer, roomId: "1234567890", identity: identity))
        XCTAssertTrue(ShareIdentity.verify(pub: identity.publicKey, sig: sig, message: Self.accept))
    }
}

import XCTest
@testable import MacUtils

/// Чистая логика протокола mu-share-2 на Mac: правило решения хоста, разбор сообщений, рукопожатие, тексты ошибок.
@MainActor
final class ScreenShareV2Tests: XCTestCase {
    private final class MemoryStore: ShareKeyStore {
        var data: Data?
        func load() throws -> Data? { data }
        func save(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    // Ключ из общих векторов (seed 0x01…0x20) и второй, чужой.
    private static let pub = "ebVWLo_mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ"
    private func identity(seed: UInt8? = nil) -> ShareIdentity {
        let store = MemoryStore()
        store.data = seed.map { Data(repeating: $0, count: 32) } ?? Data((1...32).map { UInt8($0) })
        return ShareIdentity(store: store)
    }
    private var otherPub: String { identity(seed: 9).publicKey }

    private func keyed(viewer: String = "9876543210", pub: String? = nil, idVerified: Bool = true, isSelf: Bool = false,
                       rid: String? = "rid-1") -> ShareRequest {
        ShareRequest(viewer: viewer, name: "Петя", rid: rid, auth: .key, pub: pub ?? Self.pub,
                     fp: ShareIdentity.fingerprint(ofBase64urlKey: pub ?? Self.pub), idVerified: idVerified, isSelf: isSelf)
    }

    private func legacy(viewer: String = "9876543210") -> ShareRequest {
        ShareRequest(viewer: viewer, name: "Вася", rid: "rid-2", auth: .none, pub: nil, fp: nil, idVerified: false, isSelf: false)
    }

    private func trust(trusted: Set<String> = [], needsConfirmation: Set<String> = [], canTrust: Bool = true) -> ShareTrust {
        ShareTrust(isTrusted: { id, pub in trusted.contains("\(id)|\(pub)") },
                   needsKeyConfirmation: { needsConfirmation.contains($0) },
                   canTrust: { _ in canTrust })
    }

    // MARK: правило решения (раздел 4.2)

    func testSelfWithKeyIsAcceptedWithoutAsking() {
        XCTAssertEqual(ShareRules.decide(keyed(isSelf: true), trust: trust()), .accept)
    }

    func testSelfFlagWithoutKeyIsNotTrusted() {
        var request = legacy()
        request.isSelf = true
        guard case .ask(let prompt) = ShareRules.decide(request, trust: trust()) else { return XCTFail("запрос без ключа принят") }
        XCTAssertEqual(prompt.kind, .legacy)
    }

    func testTrustedIDAndSameKeyIsAccepted() {
        let rules = trust(trusted: ["9876543210|\(Self.pub)"])
        XCTAssertEqual(ShareRules.decide(keyed(), trust: rules), .accept)
    }

    func testTrustedIDWithAnotherKeyAsksInsteadOfAccepting() {
        let rules = trust(trusted: ["9876543210|\(Self.pub)"])
        guard case .ask(let prompt) = ShareRules.decide(keyed(pub: otherPub), trust: rules) else { return XCTFail("чужой ключ принят") }
        XCTAssertEqual(prompt.kind, .normal)
        XCTAssertTrue(prompt.allowAlways)
    }

    func testLegacyRequestIsNeverAutoAcceptedAndHasNoAlwaysAllow() {
        // Даже если тот же ID «доверен по ключу» — запрос без ключа решает человек.
        let rules = trust(trusted: ["9876543210|\(Self.pub)"], needsConfirmation: ["9876543210"])
        guard case .ask(let prompt) = ShareRules.decide(legacy(), trust: rules) else { return XCTFail("legacy принят автоматически") }
        XCTAssertEqual(prompt.kind, .legacy)
        XCTAssertFalse(prompt.allowAlways)
        XCTAssertTrue(prompt.notes.contains { $0.contains("не подтверждена") })
    }

    func testOldTrustedIDNeedsOneKeyConfirmation() {
        guard case .ask(let prompt) = ShareRules.decide(keyed(), trust: trust(needsConfirmation: ["9876543210"])) else {
            return XCTFail("миграция: автоприёма быть не должно")
        }
        XCTAssertEqual(prompt.kind, .confirmKey)
        XCTAssertTrue(prompt.allowAlways)
        XCTAssertTrue(prompt.notes.contains { $0.contains("подтвердите один раз") })
    }

    func testUnverifiedIDIsFlaggedButKeyedRequestStillAsks() {
        guard case .ask(let prompt) = ShareRules.decide(keyed(idVerified: false), trust: trust()) else { return XCTFail() }
        XCTAssertTrue(prompt.notes.contains { $0.contains("ID не подтверждён") })
    }

    func testAlwaysAllowHiddenWhenIDCannotBeTrusted() {
        guard case .ask(let prompt) = ShareRules.decide(keyed(viewer: ""), trust: trust(canTrust: false)) else { return XCTFail() }
        XCTAssertFalse(prompt.allowAlways)
        XCTAssertTrue(prompt.notes.contains { $0.contains("нет корректного ID") })
    }

    func testApplyRemembersKeyOnlyWhenAllowed() {
        var remembered: [String] = []
        let request = keyed()
        let allowed = ShareDecision.Prompt(kind: .normal, allowAlways: true, notes: [])
        XCTAssertTrue(ShareRules.apply(.allowAlways, to: request, prompt: allowed) { id, _, pub in remembered.append("\(id)|\(pub)") })
        XCTAssertEqual(remembered, ["9876543210|\(Self.pub)"])

        remembered = []
        let denied = ShareDecision.Prompt(kind: .legacy, allowAlways: false, notes: [])
        XCTAssertTrue(ShareRules.apply(.allowAlways, to: legacy(), prompt: denied) { id, _, pub in remembered.append("\(id)|\(pub)") })
        XCTAssertTrue(ShareRules.apply(.allowAlways, to: request, prompt: denied) { id, _, pub in remembered.append("\(id)|\(pub)") })
        XCTAssertTrue(remembered.isEmpty, "запоминание без права «Всегда разрешать»")
        XCTAssertTrue(ShareRules.apply(.allowOnce, to: request, prompt: allowed) { _, _, _ in XCTFail("allowOnce ничего не запоминает") })
        XCTAssertFalse(ShareRules.apply(.decline, to: request, prompt: allowed) { _, _, _ in XCTFail() })
    }

    func testHostSignatureVerifiesAgainstHostKey() throws {
        let host = identity()
        let request = keyed(pub: otherPub, rid: "00000000-0000-4000-8000-000000000000")
        let sig = try XCTUnwrap(ShareRules.hostSignature(for: request, roomId: "1234567890", identity: host))
        let message = ShareIdentity.acceptMessage(roomId: "1234567890", viewerPub: otherPub, rid: "00000000-0000-4000-8000-000000000000")
        XCTAssertTrue(ShareIdentity.verify(pub: host.publicKey, sig: sig, message: message))
        XCTAssertFalse(ShareIdentity.verify(pub: host.publicKey, sig: sig,
                                            message: ShareIdentity.acceptMessage(roomId: "1234567891", viewerPub: otherPub, rid: "00000000-0000-4000-8000-000000000000")))
        XCTAssertNil(ShareRules.hostSignature(for: legacy(), roomId: "1234567890", identity: host))
        XCTAssertNil(ShareRules.hostSignature(for: keyed(rid: nil), roomId: "1234567890", identity: host))
    }

    // MARK: разбор запроса

    func testParseKeyedRequest() throws {
        let json: [String: Any] = ["type": "request", "v": 2, "viewer": "9876543210", "name": "Петя", "rid": "r1", "auth": "key",
                                   "pub": Self.pub, "fp": "ignored", "idVerified": true, "self": false]
        let request = try XCTUnwrap(ShareRequest.parse(json))
        XCTAssertEqual(request.auth, .key)
        XCTAssertEqual(request.pub, Self.pub)
        XCTAssertEqual(request.fp, "65b6-0673-d6ed-884b", "отпечаток считаем сами, не берём из сообщения")
        XCTAssertTrue(request.idVerified)
        XCTAssertFalse(request.isSelf)
        XCTAssertEqual(request.queueKey, "r1")
    }

    func testParseTreatsMissingOrBrokenAuthAsUnverified() throws {
        let plain = try XCTUnwrap(ShareRequest.parse(["type": "request", "viewer": "1111111111", "name": "x", "rid": "r"]))
        XCTAssertEqual(plain.auth, .none)
        XCTAssertNil(plain.pub)
        let badKey = try XCTUnwrap(ShareRequest.parse(["type": "request", "viewer": "1", "auth": "key", "pub": "short", "self": true, "idVerified": true]))
        XCTAssertEqual(badKey.auth, .none)
        XCTAssertFalse(badKey.isSelf)
        XCTAssertFalse(badKey.idVerified)
        let none = try XCTUnwrap(ShareRequest.parse(["type": "request", "auth": "none", "self": true]))
        XCTAssertFalse(none.isSelf, "self без ключа не считается")
        XCTAssertEqual(none.queueKey, "id:")
        XCTAssertNil(ShareRequest.parse(["type": "viewers"]))
    }

    func testParseLimitsNameLength() throws {
        let request = try XCTUnwrap(ShareRequest.parse(["type": "request", "name": String(repeating: "я", count: 500)]))
        XCTAssertEqual(request.name.count, 60)
    }

    // MARK: ретранслятор

    func testParseVersion() {
        XCTAssertEqual(ShareRelay.parseVersion(Data(#"{"commit":"x","protocols":["mu-share-1","mu-share-2"],"auth":"optional"}"#.utf8)), .keyed)
        XCTAssertEqual(ShareRelay.parseVersion(Data(#"{"protocols":["mu-share-1"]}"#.utf8)), .legacy)
        XCTAssertNil(ShareRelay.parseVersion(Data("<html>".utf8)))
        XCTAssertNil(ShareRelay.parseVersion(Data(#"{"commit":"x"}"#.utf8)))
    }

    func testTokenIsKeyedOnlyForRelaysThatAnnouncedIt() {
        ShareRelay.resetCache()
        defer { ShareRelay.resetCache() }
        let url = URL(string: "wss://relay.example.com/room/1234567890?role=host")!
        XCTAssertEqual(ShareRelay.token(for: url), "mu-share-1")
        ShareRelay.remember(.keyed, server: "https://relay.example.com/")
        XCTAssertEqual(ShareRelay.token(for: url), "mu-share-2")
        XCTAssertEqual(ShareRelay.token(for: URL(string: "https://other.example.com/status")!), "mu-share-1")
        ShareRelay.remember(.legacy, server: "relay.example.com")
        XCTAssertEqual(ShareRelay.token(for: url), "mu-share-1")
        XCTAssertEqual(ShareCode.request(url).value(forHTTPHeaderField: "X-MacUtils-Client"), "mu-share-1")
        XCTAssertEqual(ShareCode.request(url, token: "mu-share-2").value(forHTTPHeaderField: "X-MacUtils-Client"), "mu-share-2")
    }

    func testVersionURL() {
        XCTAssertEqual(ShareRelay.versionURL(server: "wss://relay.example.com//")?.absoluteString, "https://relay.example.com/version")
        XCTAssertEqual(ShareRelay.versionURL(server: "http://localhost:8787")?.absoluteString, "http://localhost:8787/version")
        XCTAssertEqual(ShareRelay.versionURL(server: "relay.example.com")?.absoluteString, "https://relay.example.com/version")
        XCTAssertEqual(ShareRelay.key(forServer: "https://Relay.Example.com:8443/"), "relay.example.com:8443")
    }

    // MARK: рукопожатие

    func testStepsOfHandshake() {
        XCTAssertEqual(ShareHandshake.step(["type": "challenge", "v": 2, "nonce": "N"]), .sendAuth(nonce: "N"))
        XCTAssertEqual(ShareHandshake.step(["type": "authed", "v": 2, "fp": "a1b2-c3d4-e5f6-0718", "claimed": true]),
                       .done(.authed(fp: "a1b2-c3d4-e5f6-0718", keyed: true)))
        XCTAssertEqual(ShareHandshake.step(["type": "authed", "v": 2, "mode": "off"]), .done(.authed(fp: nil, keyed: false)),
                       "AUTH_MODE=off: authed без проверки принимается")
        XCTAssertEqual(ShareHandshake.step(["type": "viewers"]), .ignore)
        guard case .done(.refused(let code, let message)) = ShareHandshake.step(["type": "error", "code": "id-claimed", "message": "RELAY"]) else {
            return XCTFail()
        }
        XCTAssertEqual(code, "id-claimed")
        XCTAssertTrue(message.contains("Получить новый ID"))
        guard case .done(.refused(_, let broken)) = ShareHandshake.step(["type": "challenge"]) else { return XCTFail("challenge без nonce") }
        XCTAssertFalse(broken.isEmpty)
    }

    func testAuthMessagesCarryVerifiableSignatures() throws {
        let me = identity()
        let hostJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(
            ShareHandshake.hostAuthMessage(identity: me, roomId: "1234567890", nonce: "AAAA")).utf8)) as? [String: Any])
        XCTAssertEqual(hostJSON["type"] as? String, "auth")
        XCTAssertEqual(hostJSON["v"] as? Int, 2)
        XCTAssertEqual(hostJSON["alg"] as? String, "ed25519")
        XCTAssertEqual(hostJSON["pub"] as? String, Self.pub)
        XCTAssertTrue(ShareIdentity.verify(pub: Self.pub, sig: try XCTUnwrap(hostJSON["sig"] as? String),
                                           message: ShareIdentity.hostMessage(roomId: "1234567890", nonce: "AAAA")))
        let viewerJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(
            ShareHandshake.viewerAuthMessage(identity: me, roomId: "1234567890", viewerId: "9876543210", rid: "R", nonce: "N")).utf8)) as? [String: Any])
        XCTAssertTrue(ShareIdentity.verify(pub: Self.pub, sig: try XCTUnwrap(viewerJSON["sig"] as? String),
                                           message: ShareIdentity.viewerMessage(roomId: "1234567890", viewerId: "9876543210", rid: "R", nonce: "N")))
        XCTAssertFalse(ShareIdentity.verify(pub: Self.pub, sig: try XCTUnwrap(viewerJSON["sig"] as? String),
                                            message: ShareIdentity.hostMessage(roomId: "1234567890", nonce: "N")), "подпись зрителя не годится для хоста")
        XCTAssertEqual(ShareHandshake.releaseMessage, #"{"type":"release"}"#)
    }

    // MARK: тексты, ответ хоста

    func testErrorTexts() {
        for code in ["id-claimed", "id-format", "replaced", "rate-limited", "auth-timeout", "bad-signature", "upgrade-required"] {
            XCTAssertFalse(ShareErrorText.message(code: code).isEmpty, code)
        }
        XCTAssertEqual(ShareErrorText.message(code: "новый-код", relayMessage: "Текст сервера"), "Текст сервера")
        XCTAssertTrue(ShareErrorText.message(code: "новый-код").contains("новый-код"))
        XCTAssertTrue(ShareErrorText.needsNewID("id-claimed"))
        XCTAssertTrue(ShareErrorText.needsNewID("id-format"))
        XCTAssertFalse(ShareErrorText.needsNewID("rate-limited"))
        XCTAssertFalse(ShareErrorText.needsNewID("replaced"))
        XCTAssertEqual(ScreenShare.connectionMessage(0), "Нет связи с сервером трансляции")
        XCTAssertEqual(ScreenShare.connectionMessage(429), ShareErrorText.message(code: "rate-limited"))
        XCTAssertEqual(ScreenShare.connectionMessage(500), "Сервер ответил 500")
    }

    // MARK: Keychain недоступен (M5)

    private final class LockedStore: ShareKeyStore {
        var saves = 0
        func load() throws -> Data? { throw KeychainError(status: -25308) }
        func save(_ data: Data) throws { saves += 1 }
        func delete() throws {}
    }

    func testTemporaryKeyIsNeverUsedForKeyedProtocol() {
        let locked = ShareIdentity(store: LockedStore())
        XCTAssertFalse(ShareHandshake.useKeys(capability: .keyed, identity: locked), "relay с ключами, но Keychain закрыт — только mu-share-1")
        XCTAssertFalse(ShareHandshake.useKeys(capability: .legacy, identity: locked))
        XCTAssertFalse(ShareHandshake.useKeys(capability: nil, identity: locked))
        let healthy = identity()
        XCTAssertTrue(ShareHandshake.useKeys(capability: .keyed, identity: healthy))
        XCTAssertFalse(ShareHandshake.useKeys(capability: .legacy, identity: healthy))
        XCTAssertFalse(ShareHandshake.useKeys(capability: nil, identity: healthy))
    }

    func testNothingIsSignedWithTemporaryKey() {
        let locked = ShareIdentity(store: LockedStore())
        XCTAssertNil(ShareHandshake.hostAuthMessage(identity: locked, roomId: "1234567890", nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
                     "ответ на challenge хоста не формируется")
        XCTAssertNil(ShareHandshake.viewerAuthMessage(identity: locked, roomId: "1234567890", viewerId: "9876543210",
                                                      rid: "r", nonce: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
                     "ответ на challenge зрителя не формируется")
        XCTAssertNil(ShareRules.hostSignature(for: keyed(), roomId: "1234567890", identity: locked), "подпись принятия тоже")
        XCTAssertNotNil(ShareRules.hostSignature(for: keyed(), roomId: "1234567890", identity: identity()))
    }

    func testAnswerMessageCarriesHostSignatureOnlyWhenGiven() throws {
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(
            ScreenShare.answerMessage(viewer: "9876543210", accept: true, rid: "r1")).utf8)) as? [String: Any])
        XCTAssertNil(plain["hostSig"])
        XCTAssertEqual(plain["rid"] as? String, "r1")
        let signed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(
            ScreenShare.answerMessage(viewer: "9876543210", accept: true, rid: "r1", hostSig: "SIG")).utf8)) as? [String: Any])
        XCTAssertEqual(signed["hostSig"] as? String, "SIG")
        XCTAssertEqual(signed["type"] as? String, "accept")
    }

    func testQueuePluralForms() {
        XCTAssertEqual(ShareRequestQueueView.requests(1), "запрос")
        XCTAssertEqual(ShareRequestQueueView.requests(2), "запроса")
        XCTAssertEqual(ShareRequestQueueView.requests(5), "запросов")
        XCTAssertEqual(ShareRequestQueueView.requests(11), "запросов")
        XCTAssertEqual(ShareRequestQueueView.requests(21), "запрос")
        XCTAssertEqual(ShareRequestQueueView.requests(22), "запроса")
    }

    func testQueueDeduplicatesAndRemovesByKey() {
        let queue = ShareRequestQueue()
        let request = keyed(rid: "same")
        let prompt = ShareDecision.Prompt(kind: .normal, allowAlways: true, notes: [])
        var answers: [ShareAnswer] = []
        let item = ShareRequestQueue.Item(request: request, prompt: prompt) { answers.append($0) }
        XCTAssertTrue(queue.add(item))
        XCTAssertFalse(queue.add(item), "тот же запрос второй раз не добавляется")
        XCTAssertTrue(queue.add(.init(request: keyed(rid: "other"), prompt: prompt) { answers.append($0) }))
        XCTAssertEqual(queue.items.count, 2)
        queue.remove(key: "other")
        XCTAssertEqual(queue.items.map(\.id), ["same"])
        queue.answer(item, .allowOnce)
        queue.answer(item, .allowOnce)
        XCTAssertEqual(answers, [.allowOnce], "на один запрос — один ответ")
        XCTAssertTrue(queue.items.isEmpty)
    }
}

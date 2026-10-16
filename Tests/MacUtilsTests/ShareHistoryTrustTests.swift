import XCTest
@testable import MacUtils

/// B1: «Всегда разрешать» не должно делать доверенными свой ID, пустой и невалидные ID (иначе возвращается C1).
///
/// БЛОКЕР ТЕСТИРУЕМОСТИ: `ShareHistory` читает и пишет `UserDefaults.standard` (init и `save()`), а `ShareCode.myID`
/// при первом обращении создаёт ID там же. Подменить хранилище нельзя, поэтому тесты сохраняют значение ключа
/// `Pref.shareHistory` и возвращают его точно как было (в том числе «ключа не было»). Правильно: `ShareHistory(defaults:)`.
@MainActor
final class ShareHistoryTrustTests: XCTestCase {
    private var savedData: Data?

    override func setUp() {
        savedData = UserDefaults.standard.data(forKey: Pref.shareHistory)
        UserDefaults.standard.removeObject(forKey: Pref.shareHistory)
    }

    override func tearDown() {
        if let savedData { UserDefaults.standard.set(savedData, forKey: Pref.shareHistory) }
        else { UserDefaults.standard.removeObject(forKey: Pref.shareHistory) }
    }

    private var otherID: String { ShareCode.myID == "5550001112" ? "5550001113" : "5550001112" }

    func testOwnIDCannotBecomeTrusted() {
        let history = ShareHistory()
        history.trust(ShareCode.myID, name: "Я")
        XCTAssertFalse(history.isTrusted(ShareCode.myID))
        XCTAssertFalse(history.trustedEntries.contains { $0.id == ShareCode.myID })
    }

    func testEmptyAndInvalidIDsCannotBecomeTrusted() {
        let history = ShareHistory()
        for id in ["", " ", "abc", "123", "12345678901", "12345 67890", "1234567890\n"] {
            history.trust(id, name: "x")
            XCTAssertFalse(history.isTrusted(id), "\(id.debugDescription) стал доверенным")
        }
        XCTAssertTrue(history.trustedEntries.isEmpty)
    }

    /// Низкая серьёзность: `ShareCode.normalized` берёт `isNumber`, а relay (`\\d`) принимает только ASCII,
    /// поэтому такой «доверенный» ID никогда не совпадёт с настоящим зрителем, но в списке окажется.
    func testNonASCIIDigitsAreNotAValidID() {
        let history = ShareHistory()
        history.trust("١٢٣٤٥٦٧٨٩٠", name: "x")
        XCTAssertFalse(history.isTrusted("١٢٣٤٥٦٧٨٩٠"))
    }

    func testValidForeignIDCanStillBeTrustedAndUntrusted() {
        let history = ShareHistory()
        history.trust(otherID, name: "Коллега")
        XCTAssertTrue(history.isTrusted(otherID))
        history.untrust(otherID)
        XCTAssertFalse(history.isTrusted(otherID))
    }

    func testIsTrustedRefusesOwnAndEmptyIDEvenIfPersisted() throws {
        let entries = [ShareHistory.Entry(id: ShareCode.myID, name: "Я", lastSeen: Date(), trusted: true),
                       ShareHistory.Entry(id: "", name: "Аноним", lastSeen: Date(), trusted: true)]
        UserDefaults.standard.set(try JSONEncoder().encode(entries), forKey: Pref.shareHistory)
        let history = ShareHistory()
        XCTAssertFalse(history.isTrusted(ShareCode.myID))
        XCTAssertFalse(history.isTrusted(""))
    }

    func testLoadingHistoryClearsTrustedFlagForOwnAndInvalidIDs() throws {
        let entries = [ShareHistory.Entry(id: ShareCode.myID, name: "Я", lastSeen: Date(), trusted: true),
                       ShareHistory.Entry(id: "", name: "Аноним", lastSeen: Date(), trusted: true),
                       ShareHistory.Entry(id: "abc", name: "Мусор", lastSeen: Date(), trusted: true),
                       ShareHistory.Entry(id: otherID, name: "Коллега", lastSeen: Date(), trusted: true)]
        UserDefaults.standard.set(try JSONEncoder().encode(entries), forKey: Pref.shareHistory)
        let history = ShareHistory()
        XCTAssertEqual(history.trustedEntries.map(\.id), [otherID], "доверие должно остаться только у валидного чужого ID")
        XCTAssertTrue(history.isTrusted(otherID))
    }

    // MARK: - Протокол v2: доверие по ключу (M3, .audit/auth-design.md §10.4)

    private final class MemoryStore: ShareKeyStore {
        var data: Data?
        init(_ data: Data?) { self.data = data }
        func load() throws -> Data? { data }
        func save(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    /// Ключ из общих векторов §9: seed 0x01…0x20.
    private let identity = ShareIdentity(store: MemoryStore(Data((1...32).map { UInt8($0) })))
    private var pub: String { identity.publicKey }
    private let otherPub = ShareIdentity(store: MemoryStore(Data(repeating: 7, count: 32))).publicKey

    /// Три чужих 10-значных ID (не свой).
    private var ids: [String] {
        Array(["5550001112", "5550001113", "5550001114", "5550001115"].filter { $0 != ShareCode.myID }.prefix(3))
    }

    /// История в том виде, как её записывала 1.4.0: синтезированный Encodable, даты — секунды от 2001-01-01,
    /// `label` без значения не пишется, новых полей нет.
    func testHistoryFrom140DecodesWithoutLoss() throws {
        let json = """
        [{"id":"\(ids[0])","name":"MacBook Пети","label":"Петя — работа","lastSeen":782000000.5,"trusted":true,"incomingOnly":false},
         {"id":"\(ids[1])","name":"Гость","lastSeen":781000000,"trusted":true,"incomingOnly":true},
         {"id":"\(ids[2])","name":"","lastSeen":780000000,"trusted":false,"incomingOnly":false}]
        """
        UserDefaults.standard.set(Data(json.utf8), forKey: Pref.shareHistory)
        let history = ShareHistory()
        XCTAssertEqual(history.entries.count, 3, "старая история не должна теряться при чтении")
        let first = try XCTUnwrap(history.entries.first { $0.id == ids[0] })
        XCTAssertEqual(first.name, "MacBook Пети")
        XCTAssertEqual(first.label, "Петя — работа")
        XCTAssertEqual(first.lastSeen, Date(timeIntervalSinceReferenceDate: 782000000.5))
        XCTAssertTrue(first.trusted)
        XCTAssertFalse(first.incomingOnly)
        XCTAssertNil(first.key)
        XCTAssertNil(first.hostKey)
        XCTAssertNil(first.keyConfirmedAt)
        XCTAssertTrue(try XCTUnwrap(history.entries.first { $0.id == ids[1] }).incomingOnly)
        XCTAssertEqual(history.visitedEntries.map(\.id), [ids[0], ids[2]])

        // Доверие по ID работает как раньше (до M2), но ключом не подтверждено.
        XCTAssertTrue(history.isTrusted(ids[0]))
        XCTAssertTrue(history.needsKeyConfirmation(id: ids[0]))
        XCTAssertFalse(history.isTrusted(id: ids[0], pub: pub))
        XCTAssertFalse(history.needsKeyConfirmation(id: ids[2]), "недоверенному подтверждать нечего")

        // Перезапись сохраняет всё прочитанное.
        history.rename(ids[2], to: "Новая подпись")
        let reloaded = ShareHistory()
        XCTAssertEqual(reloaded.entries.count, 3)
        XCTAssertEqual(reloaded.entries.first { $0.id == ids[0] }, first)
        XCTAssertEqual(reloaded.label(for: ids[2]), "Новая подпись")
    }

    func testKeyedTrustRequiresSameKey() {
        let history = ShareHistory()
        history.trust(ids[0], name: "Коллега", pub: pub)
        XCTAssertTrue(history.isTrusted(id: ids[0], pub: pub))
        XCTAssertFalse(history.isTrusted(id: ids[0], pub: otherPub), "тот же ID с чужим ключом — не доверенный")
        XCTAssertFalse(history.isTrusted(id: ids[1], pub: pub), "тот же ключ под другим ID — не доверенный")
        XCTAssertTrue(history.isTrusted(ids[0]), "старый метод видит доверие до перехода ScreenShare (M2)")
        XCTAssertFalse(history.needsKeyConfirmation(id: ids[0]))
        XCTAssertNotNil(history.entries.first { $0.id == ids[0] }?.keyConfirmedAt)
        XCTAssertEqual(ShareHistory().entries.first { $0.id == ids[0] }?.key, pub, "ключ сохраняется")

        // Подтверждение старого доверенного: ключ записывается, окно больше не нужно.
        history.trust(ids[1], name: "Старый")
        XCTAssertTrue(history.needsKeyConfirmation(id: ids[1]))
        history.trust(ids[1], name: "Старый", pub: otherPub)
        XCTAssertFalse(history.needsKeyConfirmation(id: ids[1]))
        XCTAssertTrue(history.isTrusted(id: ids[1], pub: otherPub))
    }

    func testUntrustDropsKeySoLegacyTrustCannotRestoreIt() {
        let history = ShareHistory()
        history.visited(ids[0], name: "Коллега")
        history.trust(ids[0], name: "Коллега", pub: pub)
        history.untrust(ids[0])
        XCTAssertFalse(history.isTrusted(id: ids[0], pub: pub))
        XCTAssertNil(history.entries.first { $0.id == ids[0] }?.key)
        history.trust(ids[0], name: "Коллега")
        XCTAssertFalse(history.isTrusted(id: ids[0], pub: pub), "доверие без ключа не возвращает старый ключ")
        XCTAssertTrue(history.needsKeyConfirmation(id: ids[0]))
    }

    func testKeyedTrustRefusesOwnInvalidIDsAndBadKeys() {
        let history = ShareHistory()
        for id in [ShareCode.myID, "", "123456", "١٢٣٤٥٦٧٨٩٠", "12345678901"] {
            history.trust(id, name: "x", pub: pub)
            XCTAssertFalse(history.isTrusted(id: id, pub: pub), "\(id.debugDescription) стал доверенным")
        }
        let tail = String(pub.dropFirst())
        let badKeys: [String] = ["", String(pub.dropLast()), pub + "A", pub + "=", "+" + tail, " " + tail,
                                 String(repeating: "A", count: 42) + "\n"]
        for bad in badKeys {
            history.trust(ids[0], name: "x", pub: bad)
            XCTAssertFalse(history.isTrusted(id: ids[0], pub: bad), "ключ \(bad.debugDescription) принят")
        }
        XCTAssertTrue(history.trustedEntries.isEmpty)
        XCTAssertFalse(history.needsKeyConfirmation(id: ShareCode.myID))
    }

    func testLoadingDropsMalformedKeys() throws {
        var bad = ShareHistory.Entry(id: ids[0], name: "a", lastSeen: Date(), trusted: true)
        bad.key = "не ключ"
        bad.keyConfirmedAt = Date()
        bad.hostKey = String(repeating: "A", count: 44)
        var good = ShareHistory.Entry(id: ids[1], name: "b", lastSeen: Date(), trusted: true)
        good.key = pub
        good.hostKey = otherPub
        UserDefaults.standard.set(try JSONEncoder().encode([bad, good]), forKey: Pref.shareHistory)
        let history = ShareHistory()
        let loadedBad = try XCTUnwrap(history.entries.first { $0.id == ids[0] })
        XCTAssertNil(loadedBad.key)
        XCTAssertNil(loadedBad.keyConfirmedAt)
        XCTAssertNil(loadedBad.hostKey)
        XCTAssertTrue(history.needsKeyConfirmation(id: ids[0]), "битый ключ = доверие без ключа, нужно подтверждение")
        XCTAssertTrue(history.isTrusted(id: ids[1], pub: pub))
        XCTAssertEqual(history.hostKey(for: ids[1]), otherPub)
    }

    func testPinHost() {
        let history = ShareHistory()
        history.visited(ids[0], name: "Ведущий")
        history.pinHost(id: ids[0], key: pub)
        XCTAssertEqual(history.hostKey(for: ids[0]), pub)
        history.pinHost(id: ids[0], key: "мусор")
        XCTAssertEqual(history.hostKey(for: ids[0]), pub, "негодный ключ не перезаписывает закреплённый")
        history.pinHost(id: "123456", key: pub)
        XCTAssertNil(history.hostKey(for: "123456"))
        XCTAssertFalse(history.entries.contains { $0.id == "123456" })
        XCTAssertFalse(history.entries.first { $0.id == ids[0] }?.incomingOnly ?? true, "pinning не меняет историю посещений")
    }

    /// N2 (ревью этапа C): ведущий больше не подтверждает ключ — зритель забывает старый ключ, иначе круг без выхода.
    func testUnpinHostForgetsKeyWithoutCreatingEntries() {
        let history = ShareHistory()
        history.visited(ids[0], name: "Ведущий")
        history.pinHost(id: ids[0], key: pub)
        history.unpinHost(id: ids[0])
        XCTAssertNil(history.hostKey(for: ids[0]))
        XCTAssertTrue(history.entries.contains { $0.id == ids[0] }, "запись о посещении остаётся")
        history.unpinHost(id: ids[1])
        XCTAssertFalse(history.entries.contains { $0.id == ids[1] }, "для неизвестного ID записи не создаётся")
        history.unpinHost(id: "123456")
        XCTAssertFalse(history.entries.contains { $0.id == "123456" })
    }

    // MARK: - N7: история читается поэлементно

    func testOneBrokenEntryIsSkippedAndTheRestSurvives() throws {
        let json = """
        [{"id":"\(ids[0])","name":"Первый","lastSeen":782000000,"trusted":true,"incomingOnly":false},
         {"id":"\(ids[1])","name":"Без даты","trusted":false,"incomingOnly":false},
         "строка вместо объекта",
         {"id":42,"name":"Число вместо ID","lastSeen":1},
         null,
         {"id":"\(ids[2])","name":"Третий","lastSeen":780000000,"trusted":false,"incomingOnly":false,"newField":{"a":1}}]
        """
        UserDefaults.standard.set(Data(json.utf8), forKey: Pref.shareHistory)
        let history = ShareHistory()
        XCTAssertEqual(history.entries.map(\.id), [ids[0], ids[2]], "испорченные пропущены, порядок и остальные сохранены")
        XCTAssertTrue(history.isTrusted(ids[0]))
        XCTAssertEqual(history.entries.first { $0.id == ids[2] }?.name, "Третий", "неизвестные поля не мешают")
        // Первый save() не теряет то, что прочиталось.
        history.rename(ids[2], to: "Подпись")
        XCTAssertEqual(ShareHistory().entries.map(\.id), [ids[0], ids[2]])
    }

    func testBrokenElementsStillGetSanitized() throws {
        let json = """
        [{"id":"\(ids[0])","name":"A","lastSeen":1,"trusted":true,"incomingOnly":false,"key":"мусор","hostKey":"тоже"},
         {"id":"123456","name":"Короткий","lastSeen":1,"trusted":true,"incomingOnly":false},
         {"name":"нет id"}]
        """
        let entries = ShareHistory.decodeEntries(Data(json.utf8))
        XCTAssertEqual(entries.map(\.id), [ids[0], "123456"])
        XCTAssertNil(entries[0].key)
        XCTAssertNil(entries[0].hostKey)
        XCTAssertFalse(entries[1].trusted, "6-значный ID доверенным быть не может")
    }

    func testNotAnArrayOrEmptyDataGivesEmptyHistory() {
        for text in ["{}", "\"x\"", "42", "", "[", "[]"] {
            XCTAssertEqual(ShareHistory.decodeEntries(Data(text.utf8)), [], text)
        }
        UserDefaults.standard.set(Data("{\"id\":1}".utf8), forKey: Pref.shareHistory)
        XCTAssertTrue(ShareHistory().entries.isEmpty)
    }

    func testAllElementsBrokenGivesEmptyHistoryWithoutCrash() {
        XCTAssertEqual(ShareHistory.decodeEntries(Data(#"[1,2,"3",{"a":1},[]]"#.utf8)), [])
    }

    // MARK: - N8: Снять доверие не стирает pinning

    func testUntrustKeepsHostKeyOfIncomingOnlyEntry() {
        let history = ShareHistory()
        history.trust(ids[0], name: "", pub: pub)
        history.pinHost(id: ids[0], key: otherPub)
        XCTAssertTrue(history.entries.first { $0.id == ids[0] }?.incomingOnly ?? false, "запись создана только доверием")
        history.untrust(ids[0])
        XCTAssertEqual(history.hostKey(for: ids[0]), otherPub, "pinning сохранился")
        XCTAssertFalse(history.isTrusted(ids[0]))
        XCTAssertNil(history.entries.first { $0.id == ids[0] }?.key)
        XCTAssertFalse(history.visitedEntries.contains { $0.id == ids[0] }, "в списке посещений она не появляется")
        XCTAssertEqual(ShareHistory().hostKey(for: ids[0]), otherPub, "и после перезапуска")
    }

    func testUntrustStillRemovesIncomingOnlyEntryWithoutPin() {
        let history = ShareHistory()
        history.trust(ids[0], name: "", pub: pub)
        history.untrust(ids[0])
        XCTAssertFalse(history.entries.contains { $0.id == ids[0] })
    }

    func testViewerOrderVisitedBeforePinKeepsPinThroughUntrust() {
        let history = ShareHistory()
        history.visited(ids[0], name: "Ведущий")   // порядок зрителя в ScreenShare.swift: visited(), затем pinHost()
        history.pinHost(id: ids[0], key: pub)
        history.trust(ids[0], name: "", pub: otherPub)
        history.untrust(ids[0])
        XCTAssertEqual(history.hostKey(for: ids[0]), pub)
        XCTAssertTrue(history.visitedEntries.contains { $0.id == ids[0] })
    }

    func testVisitedAfterPinHostAlsoKeepsPin() {
        let history = ShareHistory()
        history.pinHost(id: ids[0], key: pub)      // pin раньше visited(): запись создана как incomingOnly
        history.visited(ids[0], name: "Ведущий")
        XCTAssertEqual(history.hostKey(for: ids[0]), pub)
        XCTAssertFalse(history.entries.first { $0.id == ids[0] }?.incomingOnly ?? true, "visited делает её посещённой")
    }

    // MARK: - N3: ответы на подписанный POST /status

    func testSignedStatusActions() {
        typealias A = ShareHistory.SignedStatusAction
        XCTAssertEqual(ShareHistory.signedStatusAction(status: 200, parsed: true), A.use)
        XCTAssertEqual(ShareHistory.signedStatusAction(status: 200, parsed: false), A.rememberUnsupportedThenGet, "200 без карты — старый relay")
        for status in [403, 404, 405] {
            XCTAssertEqual(ShareHistory.signedStatusAction(status: status, parsed: false), A.rememberUnsupportedThenGet, "\(status)")
        }
        // F4: 403 not-owner (ID ещё не привязан) — не «навсегда только GET», а повтор позже.
        XCTAssertEqual(ShareHistory.signedStatusAction(status: 403, parsed: false, error: "not-owner"), A.getOnceRetryLater)
        XCTAssertEqual(ShareHistory.signedStatusAction(status: 403, parsed: false, error: "other"), A.rememberUnsupportedThenGet)
        XCTAssertEqual(ShareHistory.signedStatusAction(status: 403, parsed: false), A.rememberUnsupportedThenGet)
        XCTAssertEqual(ShareHistory.signedStatusAction(status: 404, parsed: false, error: "not-owner"), A.rememberUnsupportedThenGet)
        XCTAssertEqual(ShareHistory.statusErrorCode(Data(#"{"error":"not-owner"}"#.utf8)), "not-owner")
        XCTAssertNil(ShareHistory.statusErrorCode(Data("<html>".utf8)))
        XCTAssertNil(ShareHistory.statusErrorCode(Data(#"{"error":5}"#.utf8)))
        XCTAssertGreaterThan(ShareHistory.notOwnerRetryDelay, 0)
        XCTAssertLessThanOrEqual(ShareHistory.notOwnerRetryDelay, 600)
        XCTAssertEqual(ShareHistory.signedStatusAction(status: 429, parsed: false), A.skipTick, "лимит: тик пропускается, GET не добавляется")
        for status in [0, 400, 401, 413, 500, 502, 503] {
            XCTAssertEqual(ShareHistory.signedStatusAction(status: status, parsed: false), A.getOnce, "\(status)")
        }
    }

    func testUnsupportedMemoIsPerServerAndPerID() {
        let a = ShareHistory.signedStatusKey(server: "https://relay.example", myID: "1111111111")
        XCTAssertNotEqual(a, ShareHistory.signedStatusKey(server: "https://other.example", myID: "1111111111"))
        XCTAssertNotEqual(a, ShareHistory.signedStatusKey(server: "https://relay.example", myID: "2222222222"), "после «Получить новый ID» подпись пробуется снова")
        XCTAssertEqual(a, ShareHistory.signedStatusKey(server: "https://relay.example", myID: "1111111111"))
    }

    // MARK: - /status

    func testStatusIDsAreTenDigitNewestTwenty() {
        let now = Date()
        var entries = (0..<25).map { i in
            ShareHistory.Entry(id: String(format: "77700000%02d", i), name: "", lastSeen: now.addingTimeInterval(Double(-i)))
        }
        entries.append(.init(id: "123456", name: "", lastSeen: now.addingTimeInterval(10)))
        entries.append(.init(id: "١٢٣٤٥٦٧٨٩٠", name: "", lastSeen: now.addingTimeInterval(10)))
        let result = ShareHistory.statusIDs(entries.shuffled())
        XCTAssertEqual(result, (0..<20).map { String(format: "77700000%02d", $0) })
    }

    func testSignedStatusRequest() throws {
        let request = try XCTUnwrap(ShareHistory.statusRequest(server: "wss://relay.example.com//", myID: "1234567890",
                                                               ids: ids, identity: identity, ts: 1_760_000_000_000))
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/status")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let header = ShareCode.request(URL(string: "https://x")!).value(forHTTPHeaderField: "X-MacUtils-Client")
        XCTAssertNotNil(header)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-MacUtils-Client"), header)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["v", "id", "pub", "ts", "ids", "sig"])
        XCTAssertEqual(body["v"] as? Int, 2)
        XCTAssertEqual(body["id"] as? String, "1234567890")
        XCTAssertEqual(body["pub"] as? String, pub)
        XCTAssertEqual((body["ts"] as? NSNumber)?.int64Value, 1_760_000_000_000)
        XCTAssertEqual(body["ids"] as? [String], ids)
        let sig = try XCTUnwrap(body["sig"] as? String)
        let message = ShareIdentity.statusMessage(myId: "1234567890", ts: 1_760_000_000_000, ids: ids)
        XCTAssertTrue(message.hasPrefix("mu-share/v2\nstatus\n"))
        XCTAssertTrue(ShareIdentity.verify(pub: pub, sig: sig, message: message))
        XCTAssertFalse(ShareIdentity.verify(pub: pub, sig: sig,
                                            message: ShareIdentity.statusMessage(myId: "1234567890", ts: 1_760_000_000_001, ids: ids)))

        XCTAssertNil(ShareHistory.statusRequest(server: "wss://relay.example.com", myID: "1234567890", ids: [], identity: identity))
        XCTAssertEqual(ShareHistory.statusRequest(server: "ws://localhost:8787", myID: "1234567890", ids: ids,
                                                  identity: identity)?.url?.absoluteString, "http://localhost:8787/status")
    }

    func testParseLive() {
        let ids = ["1111111111", "2222222222"]
        let full = Data(#"{"1111111111":true,"2222222222":false}"#.utf8)
        XCTAssertEqual(ShareHistory.parseLive(full, ids: ids, complete: true), ["1111111111"])
        // Старый relay на POST: тело не читает и отвечает {} — это «не понял», а не «никого нет».
        XCTAssertNil(ShareHistory.parseLive(Data("{}".utf8), ids: ids, complete: true))
        XCTAssertEqual(ShareHistory.parseLive(Data("{}".utf8), ids: ids), [])
        XCTAssertNil(ShareHistory.parseLive(Data("not json".utf8), ids: ids))
        XCTAssertEqual(ShareHistory.parseLive(Data(#"{"1111111111":true,"9999999999":true}"#.utf8), ids: ids),
                       ["1111111111"], "чужие ID из ответа не попадают в эфир")
    }
}

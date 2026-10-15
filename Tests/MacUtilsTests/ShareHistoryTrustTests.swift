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
}

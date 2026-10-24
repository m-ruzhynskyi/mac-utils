import XCTest
@testable import MacUtils
@testable import MUScreenShare

/// Ключ трансляции в файле и однократный перенос из Keychain (1.5.2: Keychain просил пароль после каждого обновления).
final class ShareKeyStoreTests: XCTestCase {
    private final class MemoryStore: ShareKeyStore {
        var data: Data?
        var loads = 0
        var failLoad = false
        init(_ data: Data? = nil) { self.data = data }
        func load() throws -> Data? {
            loads += 1
            if failLoad { throw KeychainError(status: errSecUserCanceled) }
            return data
        }
        func save(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    private var folder: URL!
    private var defaults: UserDefaults!
    private let suite = "ShareKeyStoreTests"

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("share-key-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        defaults.removePersistentDomain(forName: suite)
    }

    private var fileStore: FileKeyStore { FileKeyStore(url: folder.appendingPathComponent("share-identity.key")) }

    func testFileStoreRoundTripWithOwnerOnlyPermissions() throws {
        let store = fileStore
        XCTAssertNil(try store.load())
        try store.save(Data(repeating: 7, count: 32))
        XCTAssertEqual(try store.load(), Data(repeating: 7, count: 32))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: folder.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try store.save(Data(repeating: 9, count: 32))
        XCTAssertEqual(try store.load(), Data(repeating: 9, count: 32), "замена существующего ключа")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "временный файл не остаётся")
        try store.delete()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.delete(), "удалять нечего — не ошибка")
    }

    func testKeychainKeyMigratesOnceAndKeepsId() throws {
        let legacy = MemoryStore(Data(repeating: 1, count: 32))
        let store = MigratingKeyStore(primary: fileStore, legacy: legacy, defaults: defaults)
        XCTAssertEqual(try store.load(), Data(repeating: 1, count: 32))
        XCTAssertEqual(try fileStore.load(), Data(repeating: 1, count: 32), "ключ перенесён в файл")
        XCTAssertEqual(try store.load(), Data(repeating: 1, count: 32))
        XCTAssertEqual(legacy.loads, 1, "Keychain читается один раз: дальше пароль не спрашивается")
    }

    func testNoKeychainKeyMeansNoFurtherKeychainReads() throws {
        let legacy = MemoryStore()
        let store = MigratingKeyStore(primary: fileStore, legacy: legacy, defaults: defaults)
        XCTAssertNil(try store.load())
        XCTAssertNil(try store.load())
        XCTAssertEqual(legacy.loads, 1)
    }

    func testCancelledKeychainPromptIsRetriedNextTime() throws {
        let legacy = MemoryStore(Data(repeating: 1, count: 32))
        legacy.failLoad = true
        let store = MigratingKeyStore(primary: fileStore, legacy: legacy, defaults: defaults)
        XCTAssertThrowsError(try store.load(), "ключ не теряется молча: ShareIdentity работает с временным")
        legacy.failLoad = false
        XCTAssertEqual(try store.load(), Data(repeating: 1, count: 32))
    }

    func testResetDoesNotResurrectKeychainKey() throws {
        let legacy = MemoryStore(Data(repeating: 1, count: 32))
        let store = MigratingKeyStore(primary: fileStore, legacy: legacy, defaults: defaults)
        try store.delete()
        XCTAssertNil(try store.load(), "после «Сменить ID» старый ключ из Keychain не возвращается")
        try store.save(Data(repeating: 2, count: 32))
        XCTAssertEqual(try store.load(), Data(repeating: 2, count: 32))
        XCTAssertEqual(legacy.loads, 0)
    }

    func testIdentityKeepsKeyAcrossInstances() throws {
        let legacy = MemoryStore()
        let first = ShareIdentity(store: MigratingKeyStore(primary: fileStore, legacy: legacy, defaults: defaults))
        let pub = first.publicKey
        let second = ShareIdentity(store: MigratingKeyStore(primary: fileStore, legacy: legacy, defaults: defaults))
        XCTAssertEqual(second.publicKey, pub)
    }
}

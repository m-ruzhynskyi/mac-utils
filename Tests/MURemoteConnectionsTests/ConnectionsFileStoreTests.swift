@testable import MURemoteConnections
import XCTest

@MainActor
final class ConnectionsFileStoreTests: XCTestCase {
    private var dir: URL!
    private var store: ConnectionsFileStore?
    private let logger = RecordingLogger()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        store?.stop()
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(_ path: URL?, sheet: String? = nil, reader: ConnectionsFileStore.Reader? = nil) -> ConnectionsFileStore {
        let settings = InMemoryConnectionsSettings(filePath: path?.path, sheetName: sheet)
        let s = reader.map { ConnectionsFileStore(settings: settings, logger: logger, retryDelay: 0.01, debounce: 0.05, reader: $0) }
            ?? ConnectionsFileStore(settings: settings, logger: logger, retryDelay: 0.01, debounce: 0.05)
        store = s
        return s
    }

    /// Ждёт, пока состояние хранилища не станет нужным.
    private func wait(_ s: ConnectionsFileStore, timeout: TimeInterval = 5, until condition: @escaping (ConnectionsFileStore) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(s), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(s), "состояние: \(s.state), записей: \(s.snapshot.records.count)")
    }

    func testNoFile() async {
        let s = makeStore(nil)
        s.start()
        XCTAssertEqual(s.state, .noFile)
        XCTAssertEqual(s.snapshot.records, [])
    }

    func testLoadsXLSXAndXML() async throws {
        let xlsx = dir.appendingPathComponent("Подключения.xlsx")
        try Fixtures.xlsx(rows: Fixtures.cleanRows(40)).write(to: xlsx)
        let s = makeStore(xlsx)
        s.start()
        XCTAssertEqual(s.state, .loading)
        await wait(s) { $0.state == .ready }
        XCTAssertEqual(s.snapshot.records.count, 40)

        let xml = dir.appendingPathComponent("hosts.XML")
        try Fixtures.xml(rows: Fixtures.cleanRows(7)).write(to: xml)
        s.setFile(xml)
        await wait(s) { $0.state == .ready && $0.snapshot.records.count == 7 }
    }

    func testUnsupportedType() async throws {
        let csv = dir.appendingPathComponent("a.csv")
        try Data("Name;ID".utf8).write(to: csv)
        let s = makeStore(csv)
        s.start()
        await wait(s) { $0.state == .failed(.unsupportedType) }
    }

    func testReloadsWhenFileChangesInPlace() async throws {
        let url = dir.appendingPathComponent("c.xml")
        try Fixtures.xml(rows: Fixtures.cleanRows(3)).write(to: url)
        let s = makeStore(url)
        s.start()
        await wait(s) { $0.snapshot.records.count == 3 }
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: Fixtures.xml(rows: Fixtures.cleanRows(5)))
        try h.close()
        await wait(s) { $0.snapshot.records.count == 5 }
    }

    /// Так сохраняют Excel и редакторы: новый файл рядом, затем подмена.
    func testReloadsAfterAtomicReplaceRepeatedly() async throws {
        let url = dir.appendingPathComponent("c.xlsx")
        try Fixtures.xlsx(rows: Fixtures.cleanRows(3)).write(to: url)
        let s = makeStore(url)
        s.start()
        await wait(s) { $0.snapshot.records.count == 3 }
        for n in [6, 9] {
            try Fixtures.xlsx(rows: Fixtures.cleanRows(n)).write(to: url, options: .atomic)
            await wait(s) { $0.snapshot.records.count == n }
            XCTAssertEqual(s.state, .ready)
        }
    }

    func testMissingFileThenAppears() async throws {
        let url = dir.appendingPathComponent("later.xml")
        let s = makeStore(url)
        s.start()
        await wait(s) { $0.state == .unavailable }
        try Fixtures.xml(rows: Fixtures.cleanRows(4)).write(to: url)
        await wait(s) { $0.state == .ready && $0.snapshot.records.count == 4 }
    }

    func testFileDeletedClearsListAfterRetries() async throws {
        let url = dir.appendingPathComponent("gone.xml")
        try Fixtures.xml(rows: Fixtures.cleanRows(4)).write(to: url)
        let s = makeStore(url)
        s.start()
        await wait(s) { $0.snapshot.records.count == 4 }
        try FileManager.default.removeItem(at: url)
        await wait(s) { $0.state == .unavailable }
        XCTAssertEqual(s.snapshot.records, [])
        XCTAssertEqual(logger.events.filter { if case .retrying(.unavailable, _) = $0 { return true }; return false }.count,
                       ConnectionsFileStore.busyRetries)
    }

    func testLockedFileRetriesThenSucceeds() async throws {
        let calls = Counter()
        let url = dir.appendingPathComponent("x.xlsx")
        let s = makeStore(url) { _, _ in
            if calls.next() < 3 { throw ConnectionsError.locked }
            return ConnectionsSnapshot(records: [ConnectionRecord(sourceRow: 2, name: "A", id: "123456789")])
        }
        s.start()
        await wait(s) { $0.state == .ready }
        XCTAssertEqual(calls.value, 4)
        XCTAssertEqual(s.snapshot.records.count, 1)
    }

    func testLockedFileGivesUpAfterThreeRetries() async {
        let calls = Counter()
        let s = makeStore(dir.appendingPathComponent("x.xlsx")) { _, _ in _ = calls.next(); throw ConnectionsError.locked }
        s.start()
        await wait(s) { $0.state == .failed(.locked) }
        XCTAssertEqual(calls.value, 1 + ConnectionsFileStore.busyRetries)
        XCTAssertEqual(logger.events.last, .loadFailed(.locked))
    }

    func testCloudFileShowsDownloadingThenUnavailable() async {
        let calls = Counter()
        var sawCloud = false
        let s = makeStore(dir.appendingPathComponent("x.xlsx")) { _, _ in _ = calls.next(); throw ConnectionsError.cloudNotDownloaded }
        s.onChange = { [unowned s] in if s.state == .cloudNotDownloaded { sawCloud = true } }
        s.start()
        await wait(s) { $0.state == .unavailable }
        XCTAssertTrue(sawCloud)
        XCTAssertEqual(calls.value, 1 + ConnectionsFileStore.cloudRetries)
    }

    func testOldCloudStubIsReportedAsDownloading() throws {
        let url = dir.appendingPathComponent("a.xlsx")
        try Data().write(to: dir.appendingPathComponent(".a.xlsx.icloud"))
        XCTAssertThrowsError(try ConnectionsFileStore.readData(url)) {
            XCTAssertEqual($0 as? ConnectionsError, .cloudNotDownloaded)
        }
    }

    func testCorruptFileDropsOldList() async throws {
        let url = dir.appendingPathComponent("c.xml")
        try Fixtures.xml(rows: Fixtures.cleanRows(3)).write(to: url)
        let s = makeStore(url)
        s.start()
        await wait(s) { $0.snapshot.records.count == 3 }
        try Data("<connections><connection>".utf8).write(to: url, options: .atomic)
        await wait(s) { if case .failed(.corrupt) = $0.state { return true }; return false }
        XCTAssertEqual(s.snapshot.records, [])
    }

    func testSheetChoice() async throws {
        let url = dir.appendingPathComponent("book.xlsx")
        try Fixtures.xlsx([
            Fixtures.Sheet(name: "Первый", rows: [[.text("Name"), .text("ID")], [.text("A"), .number("123456789")]]),
            Fixtures.Sheet(name: "Второй", rows: Fixtures.cleanRows(5).map { $0.map(Fixtures.cell) }),
        ]).write(to: url)
        XCTAssertEqual(try ConnectionsFileStore.sheetNames(url: url), ["Первый", "Второй"])
        let s = makeStore(url)
        s.start()
        await wait(s) { $0.snapshot.records.count == 1 }
        s.setSheet("Второй")
        await wait(s) { $0.snapshot.records.count == 5 }
        s.setSheet("Третий")
        await wait(s) { $0.state == .failed(.noSheet("Третий")) }
    }

    func testPasswordIsReadAtConnectTime() async throws {
        let url = dir.appendingPathComponent("p.xlsx")
        let rows = Fixtures.cleanRows(10)
        try Fixtures.xlsx(rows: rows).write(to: url)
        let s = makeStore(url)
        s.start()
        await wait(s) { $0.state == .ready }
        let record = s.snapshot.records[2]
        let secret = try await s.password(for: record)
        XCTAssertEqual(secret?.withBytes { String(decoding: $0, as: UTF8.self) }, Fixtures.password(2))
        secret?.wipe()
        XCTAssertEqual(secret?.count, 0)

        // Строки сдвинулись (вставили строку сверху) — пароль находится по ID и имени.
        var shifted = rows
        shifted.insert(["Новый", "987654321", "new", "", "", "", ""], at: 1)
        try Fixtures.xlsx(rows: shifted).write(to: url)
        let moved = try await s.password(for: record)
        XCTAssertEqual(moved?.withBytes { String(decoding: $0, as: UTF8.self) }, Fixtures.password(2))

        // Без пароля в файле — nil.
        let noPassword = s.snapshot.records.first { !$0.hasPassword }!
        let none = try await s.password(for: noPassword)
        XCTAssertNil(none)
    }

    func testPasswordNotGuessedAmongDuplicates() throws {
        let rows = [["Name", "ID", "Password"], ["A", "123456789", "one"], ["B", "123456789", "two"]]
        let data = Fixtures.xlsx(rows: rows)
        let ghost = ConnectionRecord(sourceRow: 9, name: "C", id: "123456789")
        XCTAssertNil(try XLSXSource().password(for: ghost, in: data))
        let b = ConnectionRecord(sourceRow: 9, name: "B", id: "123456789")
        XCTAssertEqual(try XLSXSource().password(for: b, in: data)?.withBytes { Array($0) }, Array("two".utf8))
    }
}

final class RecordingLogger: RemoteLogger, @unchecked Sendable {
    private(set) var events: [RemoteLogEvent] = []
    func log(_ event: RemoteLogEvent) { events.append(event) }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    /// Возвращает значение до увеличения.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n - 1 }
}

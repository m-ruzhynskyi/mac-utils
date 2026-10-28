@testable import MURemoteConnections
import AppKit
import XCTest

/// «Пароль нигде»: ни в записях, ни в диагностике, ни в журнале, ни в файлах; модуль не трогает
/// UserDefaults, Keychain и буфер обмена.
@MainActor
final class PasswordSafetyTests: XCTestCase {
    /// Все строки, достижимые из значения через отражение.
    private func strings(in value: Any) -> [String] {
        var out: [String] = []
        func walk(_ v: Any, depth: Int) {
            guard depth < 12 else { return }
            if let s = v as? String { out.append(s); return }
            for child in Mirror(reflecting: v).children { walk(child.value, depth: depth + 1) }
        }
        walk(value, depth: 0)
        return out
    }

    func testRecordsAndDiagnosticsHoldNoPasswords() throws {
        let rows = Fixtures.messyRows()
        for snap in [try XLSXSource().load(Fixtures.xlsx(rows: rows)), try XMLSource().load(Fixtures.xml(rows: rows))] {
            let all = strings(in: snap)
            XCTAssertFalse(all.isEmpty)
            XCTAssertFalse(all.contains { $0.contains("секрет") }, "пароль попал в записи или диагностику")
            XCTAssertTrue(snap.records.contains { $0.hasPassword })
        }
    }

    func testRawEntriesKeepPasswordsOnlyWhenAsked() throws {
        let data = Fixtures.xlsx(rows: Fixtures.cleanRows(5))
        let records = try XLSXSource().parse(data, mode: .records)
        XCTAssertTrue(records.entries.allSatisfy { $0.password.isEmpty })
        XCTAssertEqual(records.entries.filter(\.hasPassword).count, 4)
        let passwords = try XLSXSource().parse(data, mode: .passwords)
        XCTAssertEqual(passwords.entries.first?.password, Fixtures.password(0))
    }

    func testSecretBufferDoesNotPrintAndWipes() {
        let secret = SecretBuffer(Array("Pw-1-секрет".utf8))
        XCTAssertFalse("\(secret)".contains("Pw"))
        XCTAssertFalse(String(reflecting: secret).contains("Pw"))
        XCTAssertTrue(Mirror(reflecting: secret).children.isEmpty)
        XCTAssertEqual(secret.count, "Pw-1-секрет".utf8.count)
        secret.wipe()
        XCTAssertTrue(secret.isEmpty)
        XCTAssertEqual(secret.withBytes { $0.count }, 0)
    }

    /// Журнал: только числа и коды — ни имён, ни ID, ни путей, ни паролей.
    func testLogContainsOnlyNumbers() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Секретная папка.xlsx")
        try Fixtures.xlsx(rows: Fixtures.messyRows()).write(to: url)
        let logger = RecordingLogger()
        let store = ConnectionsFileStore(settings: InMemoryConnectionsSettings(filePath: url.path), logger: logger)
        store.start()
        let deadline = Date().addingTimeInterval(5)
        while store.state != .ready, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.state, .ready)
        _ = try await store.password(for: store.snapshot.records[0])
        store.setFile(dir.appendingPathComponent("нет.xml"))
        while store.state != .unavailable, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        store.stop()

        XCTAssertFalse(logger.events.isEmpty)
        let text = logger.events.map(\.message).joined(separator: "\n")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789=_ \n")
        XCTAssertTrue(text.unicodeScalars.allSatisfy(allowed.contains), text)
        for record in store.snapshot.records { XCTAssertFalse(text.contains(record.id)) }
        XCTAssertFalse(text.contains("Секрет"))
        XCTAssertFalse(text.contains(Fixtures.id(0)))
    }

    /// Чтение файла ничего не пишет рядом с ним (ни кэшей, ни копий).
    func testReadingLeavesNoFiles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.xlsx")
        let data = Fixtures.xlsx(rows: Fixtures.cleanRows(20))
        try data.write(to: url)
        _ = try ConnectionsFileStore.read(url: url, sheet: nil)
        let record = try ConnectionsFileStore.read(url: url, sheet: nil).records[1]
        _ = try ConnectionsFileStore.password(for: record, url: url, sheet: nil)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["c.xlsx"])
        XCTAssertEqual(try Data(contentsOf: url), data, "файл только читается")
    }

    /// Подключение с паролем-меткой из настоящего файла: метка доходит только до поля (мок AnyDesk),
    /// её нет в журнале, фазах HUD, исходе, UserDefaults, буфере обмена и рядом с файлом; буфер затёрт.
    func testConnectionLeavesPasswordNowhere() async throws {
        let canary = "PWD-CANARY-\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-canary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var rows = Fixtures.cleanRows(10)
        rows[3][2] = canary
        let url = dir.appendingPathComponent("c.xlsx")
        try Fixtures.xlsx(rows: rows).write(to: url)

        let logger = RecordingLogger()
        let store = ConnectionsFileStore(settings: InMemoryConnectionsSettings(filePath: url.path), logger: logger)
        store.start()
        let deadline = Date().addingTimeInterval(5)
        while store.state != .ready, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let record = try XCTUnwrap(store.snapshot.records.first { $0.sourceRow == 4 })

        let ax = FakeAX(), launcher = FakeLauncher(), clock = FakeClock()
        let window = FakePasswordWindow()
        window.ok.onPress = { ax.close(window.window, pid: 77) }
        launcher.onOpen = { _ in
            launcher.launch(.anyDesk, pid: 77)
            clock.at(clock.milliseconds + 500) { ax.show(window.window, pid: 77) }
        }
        let connector = RemoteConnector(ax: ax, launcher: launcher, keyboard: FakeKeyboard(ax: ax), clock: clock, logger: logger)
        var phases: [ConnectionPhase] = []
        var secret: SecretBuffer?
        let outcome = await connector.connect(ConnectRequest(record: record, program: .anyDesk), provider: AnyDeskAutomator(),
                                              password: {
            let found = try await store.lookupPassword(for: record)
            secret = found.secret
            return found
        }, progress: { phases.append($0) })
        store.stop()

        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(window.field.text, canary, "метка дошла до поля")
        XCTAssertEqual(secret?.isEmpty, true, "буфер затёрт")
        var haystack = logger.events.map(\.message) + strings(in: phases) + strings(in: outcome) + strings(in: store.snapshot)
        haystack += strings(in: connector) + launcher.opened.map(\.absoluteString)
        haystack += UserDefaults.standard.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }
        haystack.append(NSPasteboard.general.string(forType: .string) ?? "")
        for text in haystack { XCTAssertFalse(text.contains(canary), "метка в «\(text.prefix(60))»") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["c.xlsx"])
    }

    /// Линт исходников модуля: нет API, через которые пароль мог бы утечь.
    func testModuleSourcesUseNoLeakyAPIs() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MURemoteConnections")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        let forbidden = ["NSPasteboard", "UIPasteboard", "UserDefaults", "SecItem", "Keychain", "NSLog(", "print(",
                         "os_log", "Logger(", "NSCache", "URLCache", "cachesDirectory", "applicationSupportDirectory"]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for word in forbidden { XCTAssertFalse(text.contains(word), "\(file): \(word)") }
        }
    }
}

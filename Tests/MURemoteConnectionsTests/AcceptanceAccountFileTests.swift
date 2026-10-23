import Foundation
@testable import MURemoteConnections
import XCTest

/// Приёмка задач 3 и 4 (.audit/task-rc-terminal-session.md) на уровне файла и записи: теги/заметка читаются полностью,
/// колонки «Учётная запись»/«Пароль учётной записи» на ru/uk/en не путаются с паролем AnyDesk, пароль учётки нигде не лежит в
/// записи и достаётся только через `lookupSecret`. Вид строки (чипы «+N», заметка одной строкой, ID без переноса, просмотр .xlsx) —
/// слой приложения (MacUtilsTests).
final class AcceptanceAccountFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-acct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func read(_ rows: [[String]]) throws -> ConnectionsSnapshot {
        let url = dir.appendingPathComponent("list-\(UUID().uuidString.prefix(6)).xlsx")
        try Fixtures.xlsx([Fixtures.Sheet(name: "Лист1", rows: rows.map { $0.map(Fixtures.Cell.text) })]).write(to: url)
        return try ConnectionsFileStore.read(url: url, sheet: nil)
    }

    private func secret(_ field: ConnectionField, _ record: ConnectionRecord, in data: Data, xml: Bool) throws -> String? {
        let lookup = xml ? try XMLSource().lookupSecret(field, for: record, in: data) : try XLSXSource().lookupSecret(field, for: record, in: data)
        guard case .found(let s) = lookup else { return nil }
        defer { s.wipe() }
        return s.withBytes { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Задача 3: теги и заметка

    func testTagsAndNoteReachTheRecordWholeSoTheRowCanShowThem() throws {
        let snap = try read([["Название", "ID", "Пароль", "Группа", "Теги", "Заметка"],
                             ["Склад", "123 456 789", "p1", "Вінницька", "касса, ночь; сервер, склад, резерв", "Учётка Windows: admin. Длинная заметка, " + String(repeating: "очень ", count: 40)]])
        let r = try XCTUnwrap(snap.records.first)
        XCTAssertEqual(r.tags, ["касса", "ночь", "сервер", "склад", "резерв"], "все теги целы: «+N» считает вид, а не загрузка")
        XCTAssertTrue(r.note.hasPrefix("Учётка Windows: admin."))
        XCTAssertGreaterThan(r.note.count, 200, "полная заметка доступна для подсказки при наведении")
        XCTAssertEqual(r.id, "123456789", "ID нормализован — без пробелов, которые в списке дали бы перенос")
        XCTAssertEqual(r.group, "Вінницька")
    }

    func testIDWithSpacesIsNormalizedAndRDPAddressIsKeptAsIs() throws {
        let snap = try read([["Название", "ID", "Программа"], ["Склад", "1 333 427 133", "AnyDesk"], ["Сервер", "10.20.0.15", "RDP"]])
        XCTAssertEqual(snap.records.map(\.id), ["1333427133", "10.20.0.15"])
    }

    // MARK: Задача 4: колонки учётной записи

    private let accountHeaders = ["account", "login", "user", "username", "учётная запись", "учетка", "логин", "логін",
                                  "користувач", "обліковий запис", "windows user", "Учётная запись", "LOGIN"]
    private let accountPasswordHeaders = ["account password", "windows password", "пароль учётной записи", "пароль учетки",
                                          "пароль windows", "пароль облікового запису", "Пароль учётной записи"]

    func testAccountColumnsInEveryLanguageAreAccountNotPassword() throws {
        for (i, a) in accountHeaders.enumerated() {
            let ap = accountPasswordHeaders[i % accountPasswordHeaders.count]
            let snap = try read([["Название", "ID", "Пароль", a, ap], ["Касса", "123456789", "AnyDesk-1", "Администратор", "Win-пароль-9"]])
            XCTAssertTrue(snap.diagnostics.isClean, "\(a) / \(ap): \(snap.diagnostics)")
            let r = try XCTUnwrap(snap.records.first, "\(a) / \(ap)")
            XCTAssertEqual(r.account, "Администратор", a)
            XCTAssertTrue(r.hasPassword, "пароль AnyDesk взят из «Пароль»: \(a) / \(ap)")
            XCTAssertTrue(r.hasAccountPassword, "\(a) / \(ap)")
        }
        for ap in accountPasswordHeaders {  // каждый заголовок пароля учётки хотя бы раз
            let snap = try read([["Название", "ID", "Логин", ap], ["Касса", "123456789", "adm", "Win-1"]])
            XCTAssertTrue(try XCTUnwrap(snap.records.first).hasAccountPassword, ap)
            XCTAssertFalse(try XCTUnwrap(snap.records.first).hasPassword, "\(ap): пароль учётки ≠ пароль AnyDesk")
        }
    }

    /// Заголовок «Пароль» сам по себе — пароль AnyDesk/TeamViewer; колонки учётной записи его не подменяют.
    func testBarePasswordHeaderStaysAnyDeskPasswordEvenNextToAccountColumns() throws {
        for header in ["Пароль", "пароль", "Password", "Пароль "] {
            let snap = try read([["Название", "ID", header], ["Касса", "123456789", "AnyDesk-1"]])
            let r = try XCTUnwrap(snap.records.first, header)
            XCTAssertTrue(r.hasPassword, header)
            XCTAssertEqual(r.account, "", header)
            XCTAssertFalse(r.hasAccountPassword, header)
        }
    }

    func testRowWithOnlyAccountPasswordHasNoAnyDeskPassword() throws {
        let snap = try read([["Название", "ID", "Пароль", "Учётная запись", "Пароль учётной записи"],
                             ["Касса", "123456789", "", "Администратор", "Win-пароль-9"]])
        let r = try XCTUnwrap(snap.records.first)
        XCTAssertFalse(r.hasPassword, "пароль учётной записи не выдаётся за пароль AnyDesk")
        XCTAssertTrue(r.hasAccountPassword)
        XCTAssertEqual(r.account, "Администратор")
    }

    func testAccountPasswordIsNeverStoredInRecordOrItsDescriptionAndLookupReturnsTheRightSecret() throws {
        let rows = [["Название", "ID", "Пароль", "Учётная запись", "Пароль учётной записи", "Заметка"],
                    ["Касса", "123456789", "AnyDesk-1", "Администратор", "Win-пароль-9", "Учётка Windows: Администратор"]]
        let data = Fixtures.xlsx([Fixtures.Sheet(name: "Лист1", rows: rows.map { $0.map(Fixtures.Cell.text) })])
        let snap = try XLSXSource().load(data)
        let r = try XCTUnwrap(snap.records.first)
        var dumped = ""; dump(r, to: &dumped)
        for text in [String(describing: r), String(reflecting: r), dumped, String(describing: snap.diagnostics)] {
            XCTAssertFalse(text.contains("Win-пароль-9"), "пароль учётки в описании записи")
            XCTAssertFalse(text.contains("AnyDesk-1"), "пароль AnyDesk в описании записи")
        }
        XCTAssertEqual(try secret(.accountPassword, r, in: data, xml: false), "Win-пароль-9")
        XCTAssertEqual(try secret(.password, r, in: data, xml: false), "AnyDesk-1", "два пароля не перепутаны")
        XCTAssertTrue(ConnectionField.accountPassword.isSecret && ConnectionField.password.isSecret && ConnectionField.access.isSecret)
        XCTAssertFalse(ConnectionField.account.isSecret || ConnectionField.contacts.isSecret)
    }

    func testXMLAccountElementsAreReadAndSecretsComeOnlyFromLookup() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <connections>
          <connection><name>Касса</name><id>123456789</id><password>AnyDesk-1</password><account>Администратор</account><accountPassword>Win-пароль-9</accountPassword></connection>
          <connection><name>Склад</name><id>223456789</id><password>AnyDesk-2</password></connection>
        </connections>
        """
        let data = Data(xml.utf8)
        let records = try XMLSource().load(data).records
        XCTAssertEqual(records[0].account, "Администратор")
        XCTAssertTrue(records[0].hasAccountPassword)
        XCTAssertEqual(records[1].account, "")
        XCTAssertFalse(records[1].hasAccountPassword)
        for r in records { XCTAssertFalse(String(describing: r).contains("Win-пароль-9")) }
        XCTAssertEqual(try secret(.accountPassword, records[0], in: data, xml: true), "Win-пароль-9")
        XCTAssertNil(try secret(.accountPassword, records[1], in: data, xml: true))
    }
}

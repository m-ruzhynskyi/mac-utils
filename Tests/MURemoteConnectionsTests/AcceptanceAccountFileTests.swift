import Foundation
@testable import MURemoteConnections
import XCTest

/// Приёмка задач 3 и 4 (.audit/task-rc-terminal-session.md) на уровне файла и записи: теги/заметка читаются полностью,
/// колонки «Учётная запись»/«Пароль учётной записи» на ru/uk/en не путаются с паролем AnyDesk, пароль учётки нигде не лежит в
/// записи. Что требует нового API (`ConnectionRecord.account`) — пропускается с причиной. Вид строки списка (чипы тегов «+N»,
/// заметка серым в одну строку, ID без переноса, просмотр .xlsx «Правка — в Excel») — слой приложения: ждёт снимков в MacUtilsTests.
final class AcceptanceAccountFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-acct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func requireAccountAPI() throws {
        let probe = ConnectionRecord(sourceRow: 2, name: "x", id: "123456789")
        try XCTSkipUnless(Mirror(reflecting: probe).children.contains { $0.label == "account" },
                          "ожидает API задачи 4: ConnectionRecord.account")
    }

    /// Строковое поле записи по имени (в том числе `String?`); nil — поля нет или оно пустое.
    private func field(_ name: String, of record: ConnectionRecord) -> String? {
        guard let child = Mirror(reflecting: record).children.first(where: { $0.label == name }) else { return nil }
        let m = Mirror(reflecting: child.value)
        if m.displayStyle == .optional { return m.children.first?.value as? String }
        return child.value as? String
    }

    private func read(_ rows: [[String]]) throws -> ConnectionsSnapshot {
        let url = dir.appendingPathComponent("list-\(UUID().uuidString.prefix(6)).xlsx")
        try Fixtures.xlsx([Fixtures.Sheet(name: "Лист1", rows: rows.map { $0.map(Fixtures.Cell.text) })]).write(to: url)
        return try ConnectionsFileStore.read(url: url, sheet: nil)
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

    func testIDWithSpacesIsDisplayedWithoutBreakableWhitespace() throws {
        let snap = try read([["Название", "ID"], ["Склад", "1 333 427 133"]])
        let r = try XCTUnwrap(snap.records.first)
        XCTAssertEqual(r.id, "1333427133")
        // Показ «1 333 427 133» — забота вида: пробелы должны быть неразрывными, иначе ID переносится рядом с «· Вінницька».
        if let spaced = field("displayID", of: r) ?? field("formattedID", of: r) {
            XCTAssertFalse(spaced.contains(" "), "обычный пробел в показанном ID допускает перенос")
        }
    }

    func testRowViewDetailsPendingSnapshots() throws {
        throw XCTSkip("вид строки (чипы тегов до 3 и «+N», заметка серым в одну строку с обрезкой, ID lineLimit 1/fixedSize, .xlsx → просмотр «Правка — в Excel» + «Открыть в Excel») — снимки в MacUtilsTests после появления вида")
    }

    // MARK: Задача 4: колонки учётной записи

    private let accountHeaders = ["account", "login", "user", "username", "учётная запись", "учетка", "логин", "логін",
                                  "користувач", "обліковий запис", "windows user", "Учётная запись", "LOGIN"]
    private let accountPasswordHeaders = ["account password", "windows password", "пароль учётной записи", "пароль учетки",
                                          "пароль windows", "пароль облікового запису", "Пароль учётной записи"]

    func testAccountColumnsInEveryLanguageAreAccountNotPassword() throws {
        try requireAccountAPI()
        for a in accountHeaders {
            for ap in accountPasswordHeaders {
                let snap = try read([["Название", "ID", "Пароль", a, ap], ["Касса", "123456789", "AnyDesk-1", "Администратор", "Win-пароль-9"]])
                XCTAssertTrue(snap.diagnostics.isClean, "\\(a) / \\(ap): \\(snap.diagnostics)")
                let r = try XCTUnwrap(snap.records.first, "\\(a) / \\(ap)")
                XCTAssertEqual(field("account", of: r), "Администратор", "\\(a)")
                XCTAssertTrue(r.hasPassword, "пароль AnyDesk взят из «Пароль»: \\(a) / \\(ap)")
            }
        }
    }

    /// Заголовок «Пароль» сам по себе — пароль AnyDesk/TeamViewer; колонки учётной записи его не подменяют.
    func testBarePasswordHeaderStaysAnyDeskPasswordEvenNextToAccountColumns() throws {
        for header in ["Пароль", "пароль", "Password", "Пароль "] {
            let snap = try read([["Название", "ID", header], ["Касса", "123456789", "AnyDesk-1"]])
            let r = try XCTUnwrap(snap.records.first, header)
            XCTAssertTrue(r.hasPassword, header)
            XCTAssertNil(field("account", of: r), header)
        }
    }

    func testRowWithOnlyAccountPasswordHasNoAnyDeskPassword() throws {
        try requireAccountAPI()
        let snap = try read([["Название", "ID", "Пароль", "Учётная запись", "Пароль учётной записи"],
                             ["Касса", "123456789", "", "Администратор", "Win-пароль-9"]])
        let r = try XCTUnwrap(snap.records.first)
        XCTAssertFalse(r.hasPassword, "пароль учётной записи не выдаётся за пароль AnyDesk")
        XCTAssertEqual(field("account", of: r), "Администратор")
    }

    func testAccountPasswordIsNeverStoredInRecordOrItsDescription() throws {
        try requireAccountAPI()
        let snap = try read([["Название", "ID", "Пароль", "Учётная запись", "Пароль учётной записи", "Заметка"],
                             ["Касса", "123456789", "AnyDesk-1", "Администратор", "Win-пароль-9", "Учётка Windows: Администратор"]])
        let r = try XCTUnwrap(snap.records.first)
        for text in [String(describing: r), String(reflecting: r), "\\(dumpString(r))", String(describing: snap.diagnostics)] {
            XCTAssertFalse(text.contains("Win-пароль-9"), "пароль учётки в описании записи")
            XCTAssertFalse(text.contains("AnyDesk-1"), "пароль AnyDesk в описании записи")
        }
    }

    func testXMLAccountElementsAreRead() throws {
        try requireAccountAPI()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <connections>
          <connection><name>Касса</name><id>123456789</id><password>AnyDesk-1</password><account>Администратор</account><accountPassword>Win-пароль-9</accountPassword></connection>
          <connection><name>Склад</name><id>223456789</id><password>AnyDesk-2</password></connection>
        </connections>
        """
        let records = try XMLSource().load(Data(xml.utf8)).records
        XCTAssertEqual(field("account", of: records[0]), "Администратор")
        XCTAssertNil(field("account", of: records[1]))
        for r in records { XCTAssertFalse(String(describing: r).contains("Win-пароль-9")) }
    }

    private func dumpString(_ value: Any) -> String { var s = ""; dump(value, to: &s); return s }
}

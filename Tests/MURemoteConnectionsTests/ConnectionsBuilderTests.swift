@testable import MURemoteConnections
import XCTest

final class ConnectionsBuilderTests: XCTestCase {
    private func build(_ rows: [[String]]) throws -> ConnectionsSnapshot {
        try XLSXSource().load(Fixtures.xlsx(rows: rows))
    }

    func testHeadersInAnyLanguageAndOrder() throws {
        let variants: [[String]] = [
            ["Name", "ID", "Password", "Group", "Tags", "Note", "App"],
            ["Програма", "Примітка", "Теги", "Група", "Пароль", "Адреса", "Назва"],
            ["ПРОГРАММА", "заметка", "Тэги", "группа", "пароль", "AnyDesk ID", "название"],
            ["Ім’я", "ID AnyDesk", "Pass", "GROUP", "tag", "Notes", "Application"],
        ]
        for header in variants {
            var row = ["", "", "", "", "", "", ""]
            for (i, h) in header.enumerated() {
                switch ConnectionHeaders.field(for: h) {
                case .name?: row[i] = "Лаборатория Север"
                case .id?: row[i] = "123 456 789"
                case .password?: row[i] = "x"
                case .group?: row[i] = "Клиенты"
                case .tags?: row[i] = "касса, ночь, Касса"
                case .note?: row[i] = "звонить заранее"
                case .program?: row[i] = "teamviewer"
                case .account?, .accountPassword?, .access?, .contacts?: XCTFail("заголовок \(h) — не то поле")
                case nil: XCTFail("не распознан заголовок \(h)")
                }
            }
            let snap = try build([header, row])
            XCTAssertEqual(snap.records, [ConnectionRecord(
                sourceRow: 2, name: "Лаборатория Север", id: "123456789", group: "Клиенты",
                tags: ["касса", "ночь"], note: "звонить заранее", program: .teamViewer, hasPassword: true)], "\(header)")
            XCTAssertTrue(snap.diagnostics.isClean, "\(header)")
            XCTAssertEqual(snap.diagnostics.columns.count, 7)
        }
    }

    func testMissingRequiredColumnsListsFoundHeaders() {
        XCTAssertThrowsError(try build([["Название", "Пароль", "Кто"], ["a", "b", "c"]])) { error in
            XCTAssertEqual(error as? ConnectionsError, .missingColumns(found: ["Название", "Пароль", "Кто"]))
        }
        XCTAssertThrowsError(try build([])) { error in
            XCTAssertEqual(error as? ConnectionsError, .missingColumns(found: []))
        }
    }

    func testTitleRowAboveHeaderIsSkipped() throws {
        let snap = try build([["Мои подключения"], ["Название", "ID"], ["Касса 2", "123456789"]])
        XCTAssertEqual(snap.records.map(\.sourceRow), [3])
        XCTAssertEqual(snap.diagnostics.unrecognizedColumns, [])
    }

    func testProgramValues() {
        for (raw, program) in [("AnyDesk", RemoteProgram.anyDesk), ("any desk", .anyDesk), ("AD", .anyDesk),
                               ("TeamViewer", .teamViewer), ("Team-Viewer", .teamViewer), ("ТимВьюер", .teamViewer)] {
            XCTAssertEqual(RemoteProgram.parse(raw), program, raw)
        }
        XCTAssertNil(RemoteProgram.parse("RustDesk"))
    }

    /// 200+ строк с кривыми заголовками: корректные записи видны, некорректные — в диагностике с номером строки.
    func testMessyFileDiagnostics() throws {
        let rows = Fixtures.messyRows()
        let snap = try build(rows)
        let d = snap.diagnostics
        XCTAssertEqual(d.unrecognizedColumns, ["Ответственный"])
        XCTAssertEqual(d.skipped, [
            SkippedRow(row: 4, reason: .missingName, value: ""),
            SkippedRow(row: 6, reason: .missingID, value: ""),
            SkippedRow(row: 8, reason: .invalidID, value: "12345"),
            SkippedRow(row: 16, reason: .unknownProgram, value: "RustDesk"),
            SkippedRow(row: 20, reason: .aliasNotSupported, value: "front@ad"),
        ])
        XCTAssertEqual(d.lossyIDRows, [10])
        XCTAssertEqual(d.duplicates, [DuplicateGroup(id: Fixtures.id(1), rows: [3, 14], names: ["Комп’ютер 1", "Комп’ютер 12"])])
        XCTAssertEqual(d.duplicateCount, 1)
        // 210 строк данных, одна пустая, пять пропущено; дубликаты показываются оба.
        XCTAssertEqual(d.loaded, 210 - 1 - 5)
        XCTAssertEqual(snap.records.count, d.loaded)
        XCTAssertFalse(d.isClean)
        let byRow = Dictionary(uniqueKeysWithValues: snap.records.map { ($0.sourceRow, $0) })
        XCTAssertEqual(byRow[10]?.id, "123000000")
        XCTAssertEqual(byRow[12]?.id, "123456780")
        XCTAssertEqual(byRow[18]?.id, "office@ad")
        XCTAssertEqual(byRow[24]?.id, "123456789")
        XCTAssertNil(byRow[22])
    }

    func testDuplicatesAcrossPrograms() throws {
        let snap = try build([
            ["Name", "ID", "App"],
            ["A", "123456789", "AnyDesk"], ["B", "123456789", "TeamViewer"],   // разные программы — не дубликат
            ["C", "987654321", ""], ["D", "987654321", "AnyDesk"],             // одна без программы — дубликат
        ])
        XCTAssertEqual(snap.diagnostics.duplicates.map(\.id), ["987654321"])
        XCTAssertEqual(snap.records.count, 4, "дубликаты показываются оба")
    }

    func testAmbiguousProgramOnlyWhenFileHasBoth() throws {
        let single = try build([["Name", "ID", "App"], ["A", "123456789", "AnyDesk"], ["B", "223456789", ""]])
        XCTAssertEqual(single.diagnostics.ambiguousProgramRows, [])
        XCTAssertTrue(single.diagnostics.isClean)

        let both = try build([["Name", "ID", "App"], ["A", "123456789", "AnyDesk"], ["B", "223456789", "TeamViewer"],
                              ["C", "323456789", ""], ["D", "x@ad", ""]])
        XCTAssertEqual(both.diagnostics.ambiguousProgramRows, [4], "алиас — всегда AnyDesk")
        let c = both.records.first { $0.name == "C" }!
        XCTAssertEqual(c.program(default: .teamViewer), .teamViewer)
        XCTAssertEqual(both.records.first { $0.name == "D" }!.program(default: .teamViewer), .anyDesk)
    }

    func testCleanFileWithoutProgramColumn() throws {
        let snap = try build(Fixtures.cleanRows(30, header: ["Name", "ID", "Password"]).map { Array($0.prefix(3)) })
        XCTAssertTrue(snap.diagnostics.isClean)
        XCTAssertEqual(snap.diagnostics.loaded, 30)
        XCTAssertEqual(snap.diagnostics.withPassword, 24)
        XCTAssertTrue(snap.records.allSatisfy { $0.program == nil })
    }
}

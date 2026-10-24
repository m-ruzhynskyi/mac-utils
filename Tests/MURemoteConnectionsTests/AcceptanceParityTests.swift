@testable import MURemoteConnections
import XCTest

/// Сверка 1:1 с Windows-версией (`windows/tests/remote/acceptance.test.cjs`): одни и те же выдуманные данные дают
/// одну и ту же картину. Эталон — `Tests/Fixtures/RemoteParity/parity.json` (копия лежит и в Windows-дереве).
/// `MU_RC_PARITY_WRITE=1` перезаписывает эталон текущим результатом Mac.
final class AcceptanceParityTests: XCTestCase {
    private func diag(_ snap: ConnectionsSnapshot) -> [String: Any] {
        let d = snap.diagnostics
        return [
            "records": snap.records.map { r -> [String: Any] in
                ["row": r.sourceRow, "name": r.name, "id": r.id, "group": r.group, "tags": r.tags, "note": r.note,
                 "program": r.program?.rawValue ?? NSNull(), "hasPassword": r.hasPassword]
            },
            "loaded": d.loaded, "withPassword": d.withPassword,
            "skipped": d.skipped.map { ["row": $0.row, "reason": $0.reason.rawValue, "value": $0.value] as [String: Any] },
            "duplicates": d.duplicates.map { ["id": $0.id, "rows": $0.rows, "names": $0.names] as [String: Any] },
            "unrecognizedColumns": d.unrecognizedColumns, "lossyIDRows": d.lossyIDRows, "ambiguousProgramRows": d.ambiguousProgramRows,
            "columns": d.columns.map { ["title": $0.title, "field": $0.field.rawValue, "column": $0.column.map { $0 as Any } ?? NSNull()] as [String: Any] },
            "clean": d.isClean, "duplicateCount": d.duplicateCount,
        ]
    }

    private func listing(_ snap: ConnectionsSnapshot, _ query: String, favorites: [String] = [], recents: [String] = [],
                         filter: ProgramFilter = .all) -> ConnectionListing {
        ConnectionListBuilder.build(search: ConnectionSearch(snap.records), query: query, filter: filter,
                                    defaultProgram: .anyDesk, favorites: favorites, recents: recents)
    }

    private func password(_ source: ConnectionsSource, _ snap: ConnectionsSnapshot, _ data: Data, row: Int) throws -> Any {
        guard let r = snap.records.first(where: { $0.sourceRow == row }) else { return NSNull() }
        guard let secret = try source.password(for: r, in: data) else { return NSNull() }
        defer { secret.wipe() }
        return secret.withBytes { String(decoding: $0, as: UTF8.self) }
    }

    static let idForms: [(Fixtures.Cell, String)] = [
        (.number("123456789"), ""), (.number("1234567890"), ""), (.text("123456789"), ""), (.inline("987654321"), ""),
        (.text("123 456 789"), ""), (.text(" 123\u{00A0}456\u{00A0}780 "), ""), (.number("1.23456789E+08"), ""),
        (.text("1,23456789E+08"), ""), (.formula("111222333"), ""), (.text("office@ad"), ""), (.text("Front-Desk.2@Company"), ""),
        (.text("12345"), ""), (.text("abc"), ""), (.text("123456789012"), ""), (.number("1.23E+08"), ""), (.text("0123456789"), ""),
        (.text("a@b@c"), ""), (.text("123456789.0"), ""),
    ]

    static let handXML = "\u{FEFF}<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<connections>\r\n  <!-- выдуманные данные -->\r\n"
        + "  <connection><name>Аптека Захід</name><id>123 456 789</id><password>Pw-x-секрет</password><group>Філії</group></connection>\r\n"
        + "  <connection><name>Bad row</name><id>12</id></connection>\r\n"
        + "  <connection name=\"Атрибуты\" id=\"555 666 777\" app=\"TeamViewer\"/>\r\n"
        + "  <connection><name>Front</name><id>front@ad</id><tags>a, b; A</tags><note><![CDATA[n & <m>]]></note><extra>x</extra></connection>\r\n"
        + "</connections>\r\n"

    func testParityWithWindows() throws {
        var out: [String: Any] = [:]

        let messy = Fixtures.messyRows()
        let messyX = Fixtures.xlsx(rows: messy), messyM = Fixtures.xml(rows: messy)
        let sx = try XLSXSource().load(messyX), sm = try XMLSource().load(messyM)
        out["messy-xlsx"] = diag(sx)
        out["messy-xml"] = diag(sm)
        out["messy-passwords"] = [
            "xlsx": try [2, 3, 14, 22, 24, 18].map { try password(XLSXSource(), sx, messyX, row: $0) },
            "xml": try [2, 3, 14, 22, 24, 18].map { try password(XMLSource(), sm, messyM, row: $0) },
        ]

        var idRows: [[Fixtures.Cell]] = [[.text("Название"), .text("ID")]]
        for (i, c) in Self.idForms.enumerated() { idRows.append([.text("Узел \(i)"), c.0]) }
        out["id-forms"] = diag(try XLSXSource().load(Fixtures.xlsx([Fixtures.Sheet(name: "Лист1", rows: idRows)])))
        out["hand-xml"] = diag(try XMLSource().load(Data(Self.handXML.utf8)))

        var dup = Fixtures.cleanRows(10)
        dup.append(["Копия кассы", dup[3][1], "", "", "", "", ""])
        dup.append(["Тот же ID, другая программа", dup[1][1], "", "", "", "", "TeamViewer"])
        out["dupes"] = diag(try XLSXSource().load(Fixtures.xlsx(rows: dup)))

        let uk = ["Назва", "Адреса", "Пароль", "Група", "Теги", "Примітка", "Програма"]
        let order = [3, 0, 6, 2, 5, 1, 4]
        let base = Fixtures.cleanRows(40)
        let shuffled = [order.map { uk[$0] }] + base.dropFirst().map { r in order.map { r[$0] } }
        out["shuffled-uk-xlsx"] = diag(try XLSXSource().load(Fixtures.xlsx(rows: shuffled)))
        let en = ["Name", "Address", "Password", "Group", "Tags", "Note", "App"]
        let enRows = [order.map { en[$0] }] + base.dropFirst().map { r in order.map { r[$0] } }
        out["shuffled-en-xml"] = diag(try XMLSource().load(Fixtures.xml(rows: enRows)))
        out["no-password-column"] = diag(try XLSXSource().load(Fixtures.xlsx(rows: [["Назва", "ID"], ["Один", "111222333"], ["Два", "x@ad"]])))

        // Поиск и списки.
        let big = try XLSXSource().load(Fixtures.xlsx(rows: Fixtures.cleanRows(300)))
        var searches: [String: Any] = [:]
        for q in ["", "лаборат", "лаборатория север 1", "100", "108 0", "касса", "ночь", "звонить", "ФІЛІЇ", "приемная", "ctdth", "Лнш",
                  "zzzz", "kyiv front", "Pw-", "офис 7", "123", "клиенты 5", "ё", "Школа №7", "gfhjkm"] {
            let r = ConnectionSearch(big.records).search(q)
            searches[q] = ["rows": r.records.map(\.sourceRow), "hint": r.hint?.converted ?? NSNull(), "effective": r.effectiveQuery]
        }
        out["searches"] = searches

        let small = try XLSXSource().load(Fixtures.xlsx(rows: Fixtures.cleanRows(30)))
        let ids = (0..<30).map(Fixtures.id)
        var lists: [String: Any] = [:]
        for (name, q, f) in [("plain", "", ProgramFilter.all), ("tv", "", .program(.teamViewer)), ("ad", "", .program(.anyDesk)), ("query", "касса", .all)] {
            let l = listing(small, q, favorites: [ids[1], ids[3], "gone-id"], recents: [ids[7], ids[6], ids[5], ids[4], ids[3], ids[2], "x@ad"], filter: f)
            lists[name] = [
                "sections": l.sections.map { ["id": $0.id, "rows": $0.records.map(\.sourceRow)] as [String: Any] },
                "counts": ["all": l.counts[.all] ?? 0, "anyDesk": l.counts[.program(.anyDesk)] ?? 0, "teamViewer": l.counts[.program(.teamViewer)] ?? 0],
            ]
        }
        out["lists"] = lists

        let json = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RemoteParity/parity.json")
        if ProcessInfo.processInfo.environment["MU_RC_PARITY_WRITE"] == "1" {
            try json.write(to: golden)
            return
        }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as! NSDictionary
        let actual = try JSONSerialization.jsonObject(with: json) as! NSDictionary
        for key in (expected.allKeys as! [String]).sorted() {
            XCTAssertEqual(actual[key] as? NSDictionary ?? [:], expected[key] as? NSDictionary ?? [:], "сценарий \(key) разошёлся с эталоном")
        }
        XCTAssertEqual(Set(actual.allKeys as! [String]), Set(expected.allKeys as! [String]))
    }
}

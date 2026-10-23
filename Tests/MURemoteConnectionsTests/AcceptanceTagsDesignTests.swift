import Foundation
@testable import MURemoteConnections
import XCTest

/// Приёмка утверждённого дизайна задач 3 и 5 («Дизайн задач 3 и 5 — УТВЕРЖДЁН» в .audit/task-rc-terminal-session.md), часть модуля:
/// метки (одна метка при разном написании, вид метки, бейджи VPN/RDP не метки), строка «МЕТКИ» со счётчиками, фильтр по нескольким
/// меткам вместе с фильтром программы, колонка «Контакты». Цвета (`RemoteTint`) и «сколько влезло + +N» (`RemoteLabelStrip`) —
/// слой приложения, снимки в MacUtilsTests.
final class AcceptanceTagsDesignTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Метки

    func testRegSpellingsAreOneTag() {
        let keys = Set(["Рег", "рег", "РЕГ", "рег.", "Рег.", " рег ", "Р е г"].map(ConnectionTag.key))
        XCTAssertEqual(keys.count, 1, "\(keys)")
        XCTAssertTrue(["Рег", "рег.", "РЕГ"].allSatisfy { ConnectionTag.kind($0) == .reg })
        XCTAssertTrue(["Рег", "рег.", "РЕГ"].allSatisfy { ConnectionTag.display($0) == "Рег" })
    }

    func testPhytoSpellingsAreOneTagAcrossRussianAndUkrainian() {
        let keys = Set(["Фито", "фито", "ФИТО", "фіто", "Фіто", "фито.", "ФІТО"].map(ConnectionTag.key))
        XCTAssertEqual(keys.count, 1, "\(keys)")
        XCTAssertTrue(["Фито", "фіто", "ФИТО."].allSatisfy { ConnectionTag.kind($0) == .phyto })
        XCTAssertTrue(["Фито", "фіто"].allSatisfy { ConnectionTag.display($0) == "Фито" })
        XCTAssertNotEqual(ConnectionTag.key("Фито"), ConnectionTag.key("Рег"))
    }

    func testOtherTagsAreNeutralAndKeptAsWritten() {
        for t in ["Касса", "ночь", "сервер", "Vinnytsia", "Регион", "Фитотека"] {
            XCTAssertEqual(ConnectionTag.kind(t), .other, t)
            XCTAssertEqual(ConnectionTag.display(t), t, "остальные метки показываются как в файле")
        }
    }

    func testVPNAndRDPAreBadgesNotLabels() {
        for t in ["VPN", "vpn", "Rdp", "RDP.", " vpn "] { XCTAssertTrue(ConnectionTag.isBadge(t), t) }
        XCTAssertFalse(ConnectionTag.isBadge("Рег"))
        let r = ConnectionRecord(sourceRow: 2, name: "x", id: "123456789", tags: ["VPN", "RDP", "vpn", "Рег", "Фито"])
        XCTAssertEqual(r.labels, ["Рег", "Фито"])
    }

    // MARK: Строка «МЕТКИ» и фильтры: несколько меток + программа

    private var records: [ConnectionRecord] {
        [ConnectionRecord(sourceRow: 2, name: "А", id: "123456789", tags: ["Рег"], program: .anyDesk),
         ConnectionRecord(sourceRow: 3, name: "Б", id: "223456789", tags: ["рег.", "Фито", "Склад"], program: .anyDesk),
         ConnectionRecord(sourceRow: 4, name: "В", id: "323456789", tags: ["фіто", "Склад"], program: .teamViewer),
         ConnectionRecord(sourceRow: 5, name: "Г", id: "423456789", tags: ["Склад", "Касса"], program: .anyDesk),
         ConnectionRecord(sourceRow: 6, name: "Д", id: "", tags: ["РЕГ", "RDP"], method: .rdp)]
    }

    private func names(tags: [String] = [], filter: ProgramFilter = .all, query: String = "") -> [String] {
        let search = ConnectionSearch(records)
        return ConnectionListBuilder.build(search: search, query: query, filter: filter, defaultProgram: .anyDesk, favorites: [], recents: [],
                                           tags: Set(tags.map(ConnectionTag.key))).rows.map(\.record.name).sorted()
    }

    func testTagFilterSpellingsAreOneTag() {
        XCTAssertEqual(names(tags: ["Рег"]), ["А", "Б", "Д"], "«рег.», «РЕГ» и «Рег» — одна метка")
        XCTAssertEqual(names(tags: ["фито"]), ["Б", "В"], "«фіто» и «Фито» — одна метка")
    }

    func testSeveralSelectedTagsApplyTogether() {
        XCTAssertEqual(names(tags: ["Рег", "Фито"]), ["Б"], "все выбранные метки сразу")
        XCTAssertEqual(names(tags: ["Склад", "Фито"]), ["Б", "В"])
        XCTAssertEqual(names(tags: ["Рег", "Касса"]), [], "нет записи с обеими")
        XCTAssertEqual(names(tags: []), ["А", "Б", "В", "Г", "Д"])
    }

    func testTagsTogetherWithProgramFilter() {
        XCTAssertEqual(names(tags: ["Фито"], filter: .program(.teamViewer)), ["В"])
        XCTAssertEqual(names(tags: ["Рег"], filter: .program(.teamViewer)), [])
        XCTAssertEqual(names(tags: ["Рег", "Фито"], filter: .program(.anyDesk)), ["Б"])
        XCTAssertEqual(names(tags: ["Рег"], filter: .rdp), ["Д"], "метка + RDP")
        XCTAssertEqual(names(tags: ["Склад"], filter: .rdp), [])
    }

    func testTagsTogetherWithSearchQuery() {
        XCTAssertEqual(names(tags: ["Склад"], query: "Касса"), ["Г"])
    }

    func testTagRowCountsAndOrder() throws {
        let search = ConnectionSearch(records)
        let listing = ConnectionListBuilder.build(search: search, query: "", filter: .all, defaultProgram: .anyDesk, favorites: [], recents: [])
        let tags = listing.tags
        XCTAssertEqual(tags.prefix(2).map(\.kind), [.reg, .phyto], "Рег, Фито — первыми")
        XCTAssertEqual(tags.map(\.title).prefix(2).map { $0 }, ["Рег", "Фито"])
        func count(_ k: String) -> Int? { tags.first { $0.key == ConnectionTag.key(k) }?.count }
        XCTAssertEqual(count("Рег"), 3); XCTAssertEqual(count("Фито"), 2); XCTAssertEqual(count("Склад"), 3); XCTAssertEqual(count("Касса"), 1)
        XCTAssertNil(count("VPN")); XCTAssertNil(count("RDP"))
        let rest = tags.dropFirst(2).map(\.count)
        XCTAssertEqual(rest, rest.sorted(by: >), "остальные — по частоте")
    }

    // MARK: Колонка «Контакты»

    private let contactsHeaders = ["контакты", "контакт", "контакти", "contacts", "contact", "контактна особа", "контактное лицо", "Контакты"]

    private func read(_ rows: [[String]]) throws -> ConnectionsSnapshot {
        try XLSXSource().load(Fixtures.xlsx([Fixtures.Sheet(name: "Лист1", rows: rows.map { $0.map(Fixtures.Cell.text) })]))
    }

    func testContactsColumnIsKnownInEveryHeader() throws {
        for header in contactsHeaders {
            let snap = try read([["Название", "ID", header], ["Лаборатория", "123456789", "Иванова И. +380 00 000 00 00"]])
            XCTAssertTrue(snap.diagnostics.isClean, "\(header): \(snap.diagnostics)")
            XCTAssertEqual(snap.diagnostics.unrecognizedColumns, [], header)
            XCTAssertEqual(snap.records.count, 1)
        }
    }

    func testContactsAreNotSearchableAndNotInDescriptions() throws {
        let snap = try read([["Название", "ID", "Контакты"], ["Лаборатория", "123456789", "Иванова Ирина +380991112233"]])
        let search = ConnectionSearch(snap.records)
        for q in ["Иванова", "380991112233", "Ирина"] { XCTAssertTrue(search.search(q).records.isEmpty, q) }
        XCTAssertFalse(String(describing: snap.records).contains("380991112233"))
    }

    /// При правке XML элемент <contacts/> остаётся как есть.
    func testEditingXMLKeepsContactsElementByteForByte() throws {
        let contacts = "<contacts>Иванова И.\n+380 99 111 22 33</contacts>"
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<connections>\n  <connection>\n    <name>Лаборатория</name>\n    <id>123456789</id>\n    \(contacts)\n  </connection>\n</connections>\n"
        let data = Data(xml.utf8)
        let record = try XCTUnwrap(try XMLSource().load(data).records.first)
        var draft = ConnectionDraft(record); draft.name = "Лаборатория Рег"
        let out = try XMLConnectionsEditor.update(record, with: draft, in: data)
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains(contacts), "контакты сохранены как есть")
    }
}

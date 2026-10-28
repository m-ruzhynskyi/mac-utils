@testable import MURemoteConnections
import XCTest

final class SearchAndListTests: XCTestCase {
    private let records: [ConnectionRecord] = [
        ConnectionRecord(sourceRow: 2, name: "Лаборатория Север", id: "123456789", group: "Лаборатории", tags: ["ночь"], program: .anyDesk, hasPassword: true),
        ConnectionRecord(sourceRow: 3, name: "Север · резервный сервер", id: "678901234", group: "Лаборатории"),
        ConnectionRecord(sourceRow: 4, name: "Лаборатория Восток", id: "1234567890", group: "Лаборатории", program: .teamViewer),
        ConnectionRecord(sourceRow: 5, name: "Бухгалтерия", id: "567890123", group: "Офисы", note: "звонить заранее", program: .teamViewer),
        ConnectionRecord(sourceRow: 6, name: "Касса 4 · Запад", id: "kassa4@ad", group: "Офисы"),
        ConnectionRecord(sourceRow: 7, name: "Склад Харків", id: "345678901", program: .anyDesk),
        ConnectionRecord(sourceRow: 8, name: "Ёлка", id: "987654321"),
    ]

    private func names(_ query: String) -> [String] {
        ConnectionSearch(records).search(query).records.map(\.name)
    }

    func testEmptyQueryReturnsAllInFileOrder() {
        XCTAssertEqual(names("  "), records.map(\.name))
    }

    func testRankingNameStartFirst() {
        XCTAssertEqual(names("север"), ["Север · резервный сервер", "Лаборатория Север"])
        XCTAssertEqual(names("СЕВ"), ["Север · резервный сервер", "Лаборатория Север"])
    }

    func testFieldsAndTokens() {
        XCTAssertEqual(names("ночь"), ["Лаборатория Север"], "тег")
        XCTAssertEqual(names("заранее"), ["Бухгалтерия"], "заметка")
        XCTAssertEqual(names("офисы"), ["Бухгалтерия", "Касса 4 · Запад"], "группа")
        XCTAssertEqual(names("лаб вос"), ["Лаборатория Восток"], "все слова")
        XCTAssertEqual(names("елка"), ["Ёлка"], "ё = е")
        XCTAssertEqual(names("ХАРКІВ"), ["Склад Харків"], "регистр не важен")
        XCTAssertEqual(names("харк"), ["Склад Харків"], "часть слова")
    }

    func testIDWithAndWithoutSpaces() {
        XCTAssertEqual(names("123 456"), ["Лаборатория Север", "Лаборатория Восток"])
        XCTAssertEqual(names("234567890"), ["Лаборатория Восток"])
        XCTAssertEqual(names("kassa4"), ["Касса 4 · Запад"])
    }

    func testWrongLayout() {
        let s = ConnectionSearch(records)
        let r = s.search("ctdth")
        XCTAssertEqual(r.hint, ConnectionSearch.LayoutHint(typed: "ctdth", converted: "север"))
        XCTAssertEqual(r.records.count, 2)
        XCTAssertEqual(r.effectiveQuery, "север")
        // Украинская раскладка: «Харків» набран на английской.
        XCTAssertEqual(s.search("[fhrsd").hint?.converted, "харків")
        XCTAssertEqual(s.search("[fhrsd").records.map(\.name), ["Склад Харків"])
        // Наоборот: «лфыыф4» → «kassa4».
        XCTAssertEqual(s.search("лфыыф4").records.map(\.name), ["Касса 4 · Запад"])
        // Ничего ни в какой раскладке.
        let none = s.search("zzzz")
        XCTAssertEqual(none.records, [])
        XCTAssertNil(none.hint)
        // Есть совпадение в исходной раскладке — другую не пробуем.
        XCTAssertNil(s.search("kassa").hint)
    }

    func testHighlights() {
        let text = "Лаборатория Север"
        let r = ConnectionSearch.highlights(in: text, query: "север")
        XCTAssertEqual(r.map { String(text[$0]) }, ["Север"])
        let id = "123 456 789"
        XCTAssertEqual(ConnectionSearch.highlightsInID(id, query: "3456").map { String(id[$0]) }, ["3 456"])
        XCTAssertEqual(ConnectionSearch.highlightsInID(id, query: "x").count, 0)
    }

    func testDisplayID() {
        XCTAssertEqual(records[0].displayID, "123 456 789")
        XCTAssertEqual(records[2].displayID, "1 234 567 890")
        XCTAssertEqual(records[4].displayID, "kassa4@ad")
    }

    func testFavoritesAndRecents() {
        let prefs = InMemoryRemotePreferences()
        ConnectionLists.toggleFavorite(records[3], in: prefs)
        ConnectionLists.toggleFavorite(records[0], in: prefs)
        XCTAssertTrue(ConnectionLists.isFavorite(records[0], in: prefs))
        ConnectionLists.toggleFavorite(records[3], in: prefs)
        XCTAssertEqual(prefs.favoriteIDs, ["123456789"])
        for r in records { ConnectionLists.noteConnected(r, in: prefs) }
        ConnectionLists.noteConnected(records[4], in: prefs)
        XCTAssertEqual(prefs.recentIDs, ["kassa4@ad", "987654321", "345678901", "567890123", "1234567890"])
        XCTAssertFalse(prefs.recentIDs.joined().contains("секрет"))
    }

    func testSectionsWithoutQuery() {
        let listing = ConnectionListBuilder.build(
            search: ConnectionSearch(records), query: "", filter: .all, defaultProgram: .anyDesk,
            favorites: ["123456789", "000000000"], recents: ["567890123", "999999999", "kassa4@ad"])
        XCTAssertEqual(listing.sections.map(\.kind), [.favorites, .recents, .group("Лаборатории"), .group("Офисы"), .ungrouped])
        XCTAssertEqual(listing.sections[0].records.map(\.sourceRow), [2], "исчезнувший ID не показывается")
        XCTAssertEqual(listing.sections[1].records.map(\.sourceRow), [5, 6])
        XCTAssertEqual(listing.sections.last?.records.map(\.sourceRow), [7, 8])
        XCTAssertEqual(listing.counts[.all], 7)
        XCTAssertEqual(listing.counts[.program(.anyDesk)], 5, "без программы и алиас — AnyDesk по умолчанию")
        XCTAssertEqual(listing.counts[.program(.teamViewer)], 2)
        XCTAssertEqual(listing.rows.count, 7 + 1 + 2)
        XCTAssertEqual(Set(listing.rows.map(\.id)).count, listing.rows.count, "строки уникальны и при повторе записи")
    }

    func testProgramFilterAndDefault() {
        let tv = ConnectionListBuilder.build(search: ConnectionSearch(records), query: "", filter: .program(.teamViewer),
                                             defaultProgram: .teamViewer, favorites: [], recents: [])
        // По умолчанию TeamViewer: записи без программы (кроме алиаса) — его.
        XCTAssertEqual(tv.rows.map(\.record.sourceRow).sorted(), [3, 4, 5, 8])
        XCTAssertEqual(tv.counts[.program(.anyDesk)], 3)
    }

    func testSearchListing() {
        let listing = ConnectionListBuilder.build(search: ConnectionSearch(records), query: "ctdth", filter: .all,
                                                  defaultProgram: .anyDesk, favorites: ["123456789"], recents: [])
        XCTAssertEqual(listing.sections.map(\.kind), [.results])
        XCTAssertEqual(listing.hint?.converted, "север")
        XCTAssertEqual(listing.counts[.all], 2)
        let empty = ConnectionListBuilder.build(search: ConnectionSearch(records), query: "нет такого", filter: .all,
                                                defaultProgram: .anyDesk, favorites: [], recents: [])
        XCTAssertTrue(empty.isEmpty)
    }

    func testColumnLetters() throws {
        let snap = try XLSXSource().load(Fixtures.xlsx(rows: [["", "Name", "ID"], ["", "A", "123456789"]]))
        XCTAssertEqual(snap.diagnostics.columns.map(\.columnLetter), ["B", "C"])
    }

    /// Поиск на каждый символ: 5000 записей — заметно меньше кадра даже в отладочной сборке.
    func testSearchSpeed() throws {
        let snap = try XLSXSource().load(Fixtures.xlsx(rows: Fixtures.cleanRows(5_000)))
        let search = ConnectionSearch(snap.records)
        let start = DispatchTime.now()
        for q in ["л", "ла", "лаб", "лабо", "1234", "ctdth", "касса ночь"] {
            _ = ConnectionListBuilder.build(search: search, query: q, filter: .all, defaultProgram: .anyDesk, favorites: [], recents: [])
        }
        let perQuery = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9 / 7
        XCTAssertLessThan(perQuery, 0.1, "\(perQuery) с на запрос")
    }
}

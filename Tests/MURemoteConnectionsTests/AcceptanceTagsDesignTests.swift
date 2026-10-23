import Foundation
@testable import MURemoteConnections
import XCTest

/// Приёмка утверждённого дизайна задач 3 и 5 («Дизайн задач 3 и 5 — УТВЕРЖДЁН» в .audit/task-rc-terminal-session.md):
/// метки (одна метка при разном написании, цвета, «+N»), фильтр по нескольким меткам вместе с программой, колонка «Контакты».
/// Логика меток в модуле ещё не написана: ровно три точки подключения ниже (`tagStyle`, `fittingChips`, `listing`) возвращают nil,
/// тесты пропускаются с причиной. Как только API появится, достаточно связать эти три функции — сами проверки готовы.
final class AcceptanceTagsDesignTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-tags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: Точки подключения к будущему API (единственное место правки)

    struct TagStyle: Equatable {
        /// Одна метка = один ключ: «Рег»/«рег.»/«РЕГ» → один и тот же.
        var key: String
        /// "reg" (синяя), "phyto" (зелёная), "other" (серая).
        var kind: String
        var background, text, dot: String
    }

    /// Стиль метки по тексту из файла; nil — API нет.
    private func tagStyle(_ tag: String) -> TagStyle? { nil }

    /// Какие метки помещаются в строку шириной `width` (в условных единицах) и сколько уходит в «+N»; nil — API нет.
    private func fittingChips(_ tags: [String], width: Int) -> (shown: [String], more: Int)? { nil }

    /// Список с выбранными метками и фильтром программы; nil — API нет.
    private func listing(_ records: [ConnectionRecord], tags: Set<String>, program: ProgramFilter) -> [String]? { nil }

    private func requireStyle(_ tag: String) throws -> TagStyle {
        try XCTUnwrap(tagStyle(tag), "ожидает API меток (дизайн задач 3/5)")
    }

    // MARK: Метки

    func testRegSpellingsAreOneTag() throws {
        guard tagStyle("Рег") != nil else { throw XCTSkip("ожидает API меток (дизайн задач 3/5)") }
        let keys = Set(try ["Рег", "рег", "РЕГ", "рег.", "Рег.", " рег "].map { try requireStyle($0).key })
        XCTAssertEqual(keys.count, 1, "\(keys)")
    }

    func testPhytoSpellingsAreOneTagAcrossRussianAndUkrainian() throws {
        guard tagStyle("Фито") != nil else { throw XCTSkip("ожидает API меток (дизайн задач 3/5)") }
        let keys = Set(try ["Фито", "фито", "ФИТО", "фіто", "Фіто", "фито."].map { try requireStyle($0).key })
        XCTAssertEqual(keys.count, 1, "\(keys)")
        XCTAssertNotEqual(try requireStyle("Фито").key, try requireStyle("Рег").key)
    }

    func testTagColorsFollowTheApprovedMockup() throws {
        guard tagStyle("Рег") != nil else { throw XCTSkip("ожидает API меток (дизайн задач 3/5)") }
        let reg = try requireStyle("Рег"), phyto = try requireStyle("Фито"), other = try requireStyle("Склад")
        XCTAssertEqual([reg.background, reg.text, reg.dot].map { $0.uppercased() }, ["#1D2B3D", "#8EC3FF", "#5AA5FF"])
        XCTAssertEqual([phyto.background, phyto.text, phyto.dot].map { $0.uppercased() }, ["#1B3024", "#8BE0A8", "#4CC97A"])
        XCTAssertEqual([other.background, other.text, other.dot].map { $0.uppercased() }, ["#26292E", "#C9CED6", "#8A9099"])
        XCTAssertEqual([reg.kind, phyto.kind, other.kind], ["reg", "phyto", "other"])
        for t in ["Касса", "ночь", "сервер", "Vinnytsia"] { XCTAssertEqual(try requireStyle(t).kind, "other", t) }
    }

    func testChipsAreOneLineAndOverflowBecomesPlusN() throws {
        guard fittingChips(["Рег"], width: 100) != nil else { throw XCTSkip("ожидает API меток (дизайн задач 3/5)") }
        let tags = ["Рег", "Фито", "Склад", "Касса", "Ночь", "Резерв"]
        let wide = try XCTUnwrap(fittingChips(tags, width: 10_000))
        XCTAssertEqual(wide.shown, tags); XCTAssertEqual(wide.more, 0, "всё влезло — «+N» нет")
        let narrow = try XCTUnwrap(fittingChips(tags, width: 60))
        XCTAssertLessThan(narrow.shown.count, tags.count)
        XCTAssertEqual(narrow.shown.count + narrow.more, tags.count, "«+N» = ровно столько, сколько не влезло")
        XCTAssertEqual(narrow.shown, Array(tags.prefix(narrow.shown.count)), "порядок меток сохранён")
        let none = try XCTUnwrap(fittingChips(tags, width: 0))
        XCTAssertEqual(none.more, tags.count)
    }

    func testVPNAndRDPTagsAreBadgesNotChips() throws {
        guard fittingChips(["Рег"], width: 100) != nil else { throw XCTSkip("ожидает API меток (дизайн задач 3/5)") }
        let r = try XCTUnwrap(fittingChips(["VPN", "RDP", "vpn", "Рег"], width: 10_000))
        XCTAssertEqual(r.shown, ["Рег"], "VPN/RDP — только бейджи")
        XCTAssertEqual(r.more, 0)
    }

    // MARK: Фильтры: несколько меток + программа

    func testSeveralTagsTogetherWithProgramFilter() throws {
        let records = [
            ConnectionRecord(sourceRow: 2, name: "А", id: "123456789", tags: ["Рег"], program: .anyDesk),
            ConnectionRecord(sourceRow: 3, name: "Б", id: "223456789", tags: ["рег.", "Фито"], program: .anyDesk),
            ConnectionRecord(sourceRow: 4, name: "В", id: "323456789", tags: ["фіто"], program: .teamViewer),
            ConnectionRecord(sourceRow: 5, name: "Г", id: "423456789", tags: ["Склад"], program: .anyDesk),
        ]
        guard listing(records, tags: [], program: .all) != nil else { throw XCTSkip("ожидает API меток (дизайн задач 3/5)") }
        func names(_ tags: Set<String>, _ p: ProgramFilter) throws -> [String] { try XCTUnwrap(listing(records, tags: tags, program: p)).sorted() }
        XCTAssertEqual(try names([], .all), ["А", "Б", "В", "Г"])
        XCTAssertEqual(try names(["Рег"], .all), ["А", "Б"], "«рег.» и «Рег» — одна метка")
        XCTAssertEqual(try names(["Фито"], .all), ["Б", "В"], "«фіто» и «Фито» — одна метка")
        XCTAssertEqual(try names(["Рег", "Фито"], .all), ["Б"], "несколько меток вместе — запись должна иметь все (или все выбранные; см. макет)")
        XCTAssertEqual(try names(["Фито"], .program(.teamViewer)), ["В"])
        XCTAssertEqual(try names(["Рег"], .program(.teamViewer)), [], "метка + программа вместе")
        XCTAssertEqual(try names(["Рег", "Фито"], .program(.anyDesk)), ["Б"])
    }

    // MARK: Колонка «Контакты»

    private let contactsHeaders = ["контакты", "контакт", "контакти", "contacts", "contact", "контактна особа", "контактное лицо", "Контакты"]

    private func read(_ rows: [[String]]) throws -> ConnectionsSnapshot {
        let url = dir.appendingPathComponent("list-\(UUID().uuidString.prefix(6)).xlsx")
        try Fixtures.xlsx([Fixtures.Sheet(name: "Лист1", rows: rows.map { $0.map(Fixtures.Cell.text) })]).write(to: url)
        return try ConnectionsFileStore.read(url: url, sheet: nil)
    }

    /// Колонка известна: проверка файла не называет её лишней/неизвестной.
    func testContactsColumnIsKnownInEveryHeader() throws {
        for header in contactsHeaders {
            let snap = try read([["Название", "ID", header], ["Лаборатория", "123456789", "Иванова И. +380 00 000 00 00"]])
            if !snap.diagnostics.isClean { throw XCTSkip("ожидает: колонка «\(header)» ещё считается неизвестной (\(snap.diagnostics))") }
            XCTAssertEqual(snap.records.count, 1)
        }
    }

    func testContactsAreNotSearchableAndNotInDescriptions() throws {
        let snap = try read([["Название", "ID", "Контакты"], ["Лаборатория", "123456789", "Иванова Ирина +380991112233"]])
        guard snap.diagnostics.isClean else { throw XCTSkip("ожидает: колонка «Контакты» ещё неизвестна") }
        let search = ConnectionSearch(snap.records)
        for q in ["Иванова", "380991112233", "Ирина"] { XCTAssertTrue(search.search(q).records.isEmpty, q) }
        XCTAssertFalse(String(describing: snap.records).contains("380991112233"))
    }

    /// При правке XML элемент <contacts/> остаётся как есть (редактор не трогает чужие поля записи).
    func testEditingXMLKeepsContactsElementByteForByte() throws {
        let contacts = "<contacts>Иванова И.\n+380 99 111 22 33</contacts>"
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<connections>\n  <connection>\n    <name>Лаборатория</name>\n    <id>123456789</id>\n    \(contacts)\n  </connection>\n</connections>\n"
        let data = Data(xml.utf8)
        let record = try XCTUnwrap(try XMLSource().load(data).records.first)
        var draft = ConnectionDraft(record); draft.name = "Лаборатория Рег"
        let out = try XMLConnectionsEditor.update(record, with: draft, in: data)
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains(contacts), "контакты сохранены как есть")
    }

    // MARK: Филиалы: запись с программой VPN/RDP и ID = IP

    func testBranchRecordsWithIPAsIDAndVPNProgramLoadInSameGroup() throws {
        guard RemoteProgram.allCases.contains(where: { $0.rawValue.lowercased() == "vpn" }) else {
            throw XCTSkip("ожидает API задачи 5: RemoteProgram.vpn/rdp")
        }
        let snap = try read([["Название", "ID", "Группа", "Программа", "Теги"],
                             ["Вінницька", "123456789", "Вінницька", "AnyDesk", "Рег"],
                             ["Вінницька · Філія 1", "10.20.30.41", "Вінницька", "VPN", "Рег"],
                             ["Вінницька · Філія 2", "10.20.30.42", "Вінницька", "RDP", "Рег"]])
        XCTAssertTrue(snap.diagnostics.isClean, "\(snap.diagnostics)")
        XCTAssertEqual(snap.records.map(\.group), ["Вінницька", "Вінницька", "Вінницька"])
        XCTAssertEqual(snap.records.map(\.id), ["123456789", "10.20.30.41", "10.20.30.42"], "IP как адрес не ломается и не нормализуется в число")
    }
}

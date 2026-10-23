import Foundation
@testable import MURemoteConnections
import XCTest

/// Приёмка задачи 5 (.audit/task-rc-terminal-session.md): «Доступ» — секрет, программы RDP/VPN/Другое без ID, rdp://, фильтры.
/// Тесты, которым нужно новое API (`RemoteProgram` с RDP/VPN/Другое, `ConnectionRecord.access`), пропускаются с причиной.
/// Вид (бейджи «VPN»/«RDP», панель деталей с размытием, «Показать»/«Скопировать», тост «адрес скопирован») — слой приложения.
final class AcceptanceRecordDetailsTests: XCTestCase {
    private var dir: URL!
    private let accessText = "VPN: vpn.example.test\nlogin: ivanov\npass: Секрет-Доступ-77\nRDP: 10.20.30.40"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-t5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func program(_ name: String) -> RemoteProgram? {
        RemoteProgram.allCases.first { $0.rawValue.lowercased() == name.lowercased() }
    }

    private func requireProgram(_ name: String) throws -> RemoteProgram {
        guard let p = program(name) else { throw XCTSkip("ожидает API задачи 5: RemoteProgram.\(name)") }
        return p
    }

    private func requireAccessAPI() throws {
        let probe = ConnectionRecord(sourceRow: 2, name: "x", id: "123456789")
        try XCTSkipUnless(Mirror(reflecting: probe).children.contains { $0.label == "access" }, "ожидает API задачи 5: ConnectionRecord.access")
    }

    private func read(_ rows: [[String]]) throws -> ConnectionsSnapshot {
        let url = dir.appendingPathComponent("list-\(UUID().uuidString.prefix(6)).xlsx")
        try Fixtures.xlsx([Fixtures.Sheet(name: "Лист1", rows: rows.map { $0.map(Fixtures.Cell.text) })]).write(to: url)
        return try ConnectionsFileStore.read(url: url, sheet: nil)
    }

    private func access(of r: ConnectionRecord) -> String? {
        guard let c = Mirror(reflecting: r).children.first(where: { $0.label == "access" }) else { return nil }
        let m = Mirror(reflecting: c.value)
        return m.displayStyle == .optional ? m.children.first?.value as? String : c.value as? String
    }

    // MARK: Колонка «Доступ»

    func testAccessColumnInEveryHeaderKeepsMultilineTextAsIs() throws {
        try requireAccessAPI()
        for header in ["доступ", "Доступ", "access", "подробности", "деталі", "details", "vpn/rdp", "подключение", "підключення"] {
            let snap = try read([["Название", "ID", header], ["Офис", "123456789", accessText]])
            XCTAssertTrue(snap.diagnostics.isClean, "\(header): \(snap.diagnostics)")
            XCTAssertEqual(access(of: try XCTUnwrap(snap.records.first)), accessText, header)
        }
    }

    func testAccessIsNotSearchableNotEvenByItsOwnWords() throws {
        try requireAccessAPI()
        let snap = try read([["Название", "ID", "Доступ"], ["Офис Север", "123456789", accessText], ["Склад", "223456789", ""]])
        let search = ConnectionSearch(snap.records)
        for q in ["Секрет-Доступ-77", "ivanov", "vpn.example.test", "10.20.30.40", "Секрет", "pass"] {
            XCTAssertTrue(search.search(q).records.isEmpty, "поиск «\(q)» нашёл запись по «Доступу»")
        }
        XCTAssertEqual(search.search("Север").records.count, 1, "по названию поиск работает")
    }

    func testAccessNeverAppearsInDescriptionsDiagnosticsOrErrors() throws {
        try requireAccessAPI()
        let snap = try read([["Название", "ID", "Доступ"], ["Офис", "123456789", accessText], ["Плохая строка", "не-ID", accessText]])
        var dumped = ""; dump(snap, to: &dumped)
        for text in [String(describing: snap.records), String(describing: snap.diagnostics), dumped] {
            XCTAssertFalse(text.contains("Секрет-Доступ-77"), "секрет «Доступа» в описании/диагностике")
        }
    }

    // MARK: Программы RDP / VPN / Другое

    func testRDPVPNOtherRecordsWithEmptyIDLoadWithoutErrors() throws {
        let rdp = try requireProgram("rdp"), vpn = try requireProgram("vpn")
        let snap = try read([["Название", "ID", "Программа", "Теги"],
                             ["Сервер 1С", "", "RDP", "RDP"], ["Филиал", "", "VPN", "VPN"], ["Принтер", "", "Другое", ""],
                             ["Касса", "123456789", "AnyDesk", ""]])
        XCTAssertTrue(snap.diagnostics.isClean, "\(snap.diagnostics)")
        XCTAssertEqual(snap.records.count, 4)
        XCTAssertEqual(snap.records.filter { $0.program == rdp }.count, 1)
        XCTAssertEqual(snap.records.filter { $0.program == vpn }.count, 1)
        XCTAssertEqual(snap.records.first { $0.name == "Принтер" }?.id, "", "ID пустой — допустимо")
    }

    func testEmptyNameIsStillAnErrorForTheseProgramsAndEmptyIDForAnyDeskToo() throws {
        _ = try requireProgram("rdp")
        let snap = try read([["Название", "ID", "Программа"], ["", "", "RDP"], ["Касса", "", "AnyDesk"], ["Сервер", "", "RDP"]])
        XCTAssertEqual(snap.records.map(\.name), ["Сервер"], "без названия записи нет; AnyDesk без ID по-прежнему ошибка")
        XCTAssertFalse(snap.diagnostics.isClean)
    }

    // MARK: RDP: адрес и фильтры

    func testRDPLinkIsBuiltFromHostWithoutLaunching() throws {
        let rdp = try requireProgram("rdp")
        let url = try XCTUnwrap(rdp.connectURL(id: "10.20.30.40"))
        XCTAssertEqual(url.absoluteString, "rdp://full%20address=s:10.20.30.40")
        let host = try XCTUnwrap(rdp.connectURL(id: "srv-1c.example.test"))
        XCTAssertTrue(host.absoluteString.hasPrefix("rdp://full%20address=s:srv-1c.example.test"))
        XCTAssertFalse(url.absoluteString.contains("password"), "пароль в ссылке не передаётся никогда")
    }

    func testFiltersCountRDPAndVPNNextToAnyDeskAndTeamViewer() throws {
        let rdp = try requireProgram("rdp"), vpn = try requireProgram("vpn")
        let snap = try read([["Название", "ID", "Программа"], ["А", "", "RDP"], ["Б", "", "RDP"], ["В", "", "VPN"],
                             ["Г", "123456789", "AnyDesk"], ["Д", "223456789", "TeamViewer"]])
        let search = ConnectionSearch(snap.records)
        func listing(_ f: ProgramFilter) -> ConnectionListing {
            ConnectionListBuilder.build(search: search, query: "", filter: f, defaultProgram: .anyDesk, favorites: [], recents: [])
        }
        let all = listing(.all)
        XCTAssertEqual(all.counts[.program(rdp)], 2)
        XCTAssertEqual(all.counts[.program(vpn)], 1)
        XCTAssertEqual(all.counts[.program(.anyDesk)], 1)
        XCTAssertEqual(listing(.program(rdp)).rows.map(\.record.name).sorted(), ["А", "Б"])
        XCTAssertEqual(listing(.program(vpn)).rows.map(\.record.name), ["В"])
    }

    func testTagsVPNAndRDPAreKeptSoRowsCanShowBadges() throws {
        let snap = try read([["Название", "ID", "Теги"], ["Сервер", "123456789", "RDP, VPN, касса"]])
        XCTAssertEqual(snap.records.first?.tags, ["RDP", "VPN", "касса"])
    }

    func testRowViewDetailsPendingSnapshots() throws {
        throw XCTSkip("вид: бейджи VPN (щит)/RDP (монитор) по тегам или программе, «i» → панель деталей, «Доступ» под размытием + «Показать»/«Скопировать», автоскрытие; Enter на RDP при отсутствии Windows App → адрес в буфер и нейтральный тост — тесты приложения (MacUtilsTests) после появления вида")
    }
}

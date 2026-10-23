import Foundation
@testable import MURemoteConnections
import XCTest

/// Приёмка задачи 5 (.audit/task-rc-terminal-session.md): «Доступ» — секрет, программы RDP/VPN/Другое без ID, адрес RDP, фильтры.
/// Вид (бейджи, панель деталей с размытием, «Показать»/«Скопировать», тост «адрес скопирован») — слой приложения.
final class AcceptanceRecordDetailsTests: XCTestCase {
    private var dir: URL!
    private let accessText = "VPN: vpn.example.test\nlogin: ivanov\n\npass: Секрет-Доступ-77\nRDP — IP: 10.20.30.40"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-t5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func xlsx(_ rows: [[String]]) -> Data {
        Fixtures.xlsx([Fixtures.Sheet(name: "Лист1", rows: rows.map { $0.map(Fixtures.Cell.text) })])
    }

    private func read(_ rows: [[String]]) throws -> ConnectionsSnapshot { try XLSXSource().load(xlsx(rows)) }

    // MARK: Колонка «Доступ»

    func testAccessColumnInEveryHeaderIsKnownKeepsMultilineTextAndStaysOutOfTheRecord() throws {
        for header in ["доступ", "Доступ", "access", "подробности", "деталі", "details", "vpn/rdp", "подключение", "підключення"] {
            let data = xlsx([["Название", "ID", header], ["Офис", "123456789", accessText]])
            let snap = try XLSXSource().load(data)
            XCTAssertTrue(snap.diagnostics.isClean, "\(header): \(snap.diagnostics)")
            let r = try XCTUnwrap(snap.records.first, header)
            XCTAssertEqual(r.accessLines, 4, "\(header): считаются непустые строки; пустая между блоками — разделитель")
            XCTAssertFalse(String(describing: r).contains("Секрет-Доступ-77"), "\(header): текст «Доступа» в записи")
            guard case .found(let s) = try XLSXSource().lookupSecret(.access, for: r, in: data) else { return XCTFail(header) }
            defer { s.wipe() }
            XCTAssertEqual(s.withBytes { String(decoding: $0, as: UTF8.self) }, accessText, "\(header): переносы и пустые строки целы")
        }
    }

    func testAccessIsNotSearchableNotEvenByItsOwnWords() throws {
        let snap = try read([["Название", "ID", "Доступ"], ["Офис Север", "123456789", accessText], ["Склад", "223456789", ""]])
        let search = ConnectionSearch(snap.records)
        for q in ["Секрет-Доступ-77", "ivanov", "vpn.example.test", "10.20.30.40", "Секрет", "pass"] {
            XCTAssertTrue(search.search(q).records.isEmpty, "поиск «\(q)» нашёл запись по «Доступу»")
        }
        XCTAssertEqual(search.search("Север").records.count, 1, "по названию поиск работает")
    }

    func testAccessNeverAppearsInDescriptionsDiagnosticsOrLoggedEvents() throws {
        let logger = RecordingLogger()
        let url = dir.appendingPathComponent("a.xlsx")
        try xlsx([["Название", "ID", "Доступ"], ["Офис", "123456789", accessText], ["Плохая строка", "не-ID", accessText]]).write(to: url)
        let snap = try ConnectionsFileStore.read(url: url, sheet: nil)
        logger.log(.loaded(records: snap.records.count, skipped: 0, duplicates: 0, unrecognizedColumns: 0, milliseconds: 1))
        var dumped = ""; dump(snap, to: &dumped)
        let text = [String(describing: snap.records), String(describing: snap.diagnostics), dumped,
                    logger.events.map(\.message).joined()].joined()
        XCTAssertFalse(text.contains("Секрет-Доступ-77"))
        XCTAssertFalse(text.contains("ivanov"))
    }

    // MARK: Программы RDP / VPN / Другое

    func testRDPVPNOtherRecordsWithEmptyIDLoadWithoutErrors() throws {
        let snap = try read([["Название", "ID", "Программа", "Теги"],
                             ["Сервер 1С", "", "RDP", "RDP"], ["Филиал", "", "VPN", "VPN"], ["Принтер", "", "Другое", ""],
                             ["Касса", "123456789", "AnyDesk", ""]])
        XCTAssertTrue(snap.diagnostics.isClean, "\(snap.diagnostics)")
        XCTAssertEqual(snap.records.count, 4)
        XCTAssertEqual(snap.records.map(\.method), [.rdp, .vpn, .other, nil])
        XCTAssertEqual(snap.records.first { $0.name == "Принтер" }?.id, "", "ID пустой — допустимо")
        XCTAssertTrue(snap.records.dropLast().allSatisfy { $0.program == nil }, "у RDP/VPN/Другое программы AnyDesk/TV нет")
    }

    func testEmptyNameIsStillAnErrorAndAnyDeskWithoutIDToo() throws {
        let snap = try read([["Название", "ID", "Программа"], ["", "", "RDP"], ["Касса", "", "AnyDesk"], ["Сервер", "", "RDP"]])
        XCTAssertEqual(snap.records.map(\.name), ["Сервер"], "без названия записи нет; AnyDesk без ID по-прежнему ошибка")
        XCTAssertFalse(snap.diagnostics.isClean)
    }

    func testBranchRecordsWithIPAsIDAndVPNProgramLoadInSameGroup() throws {
        let snap = try read([["Название", "ID", "Группа", "Программа", "Теги"],
                             ["Вінницька", "123456789", "Вінницька", "AnyDesk", "Рег"],
                             ["Вінницька · Філія 1", "10.20.30.41", "Вінницька", "VPN", "Рег"],
                             ["Вінницька · Філія 2", "10.20.30.42", "Вінницька", "RDP", "Рег"]])
        XCTAssertTrue(snap.diagnostics.isClean, "\(snap.diagnostics)")
        XCTAssertEqual(snap.records.map(\.group), ["Вінницька", "Вінницька", "Вінницька"])
        XCTAssertEqual(snap.records.map(\.id), ["123456789", "10.20.30.41", "10.20.30.42"], "IP не ломается и не нормализуется в число")
    }

    func testTagsVPNAndRDPMakeBadgesAndStayOutOfLabels() throws {
        let snap = try read([["Название", "ID", "Теги"], ["Сервер", "123456789", "RDP, VPN, касса, Рег"]])
        let r = try XCTUnwrap(snap.records.first)
        XCTAssertTrue(r.usesRDP); XCTAssertTrue(r.needsVPN)
        XCTAssertEqual(r.labels, ["касса", "Рег"], "VPN/RDP — только значками")
        let byProgram = try XCTUnwrap(try read([["Название", "ID", "Программа"], ["А", "", "RDP"], ["Б", "", "VPN"]]).records)
        XCTAssertTrue(byProgram[0].usesRDP && !byProgram[0].needsVPN)
        XCTAssertTrue(byProgram[1].needsVPN && !byProgram[1].usesRDP)
    }

    // MARK: RDP: адрес

    func testRDPFileIsBuiltFromHostAndNeverCarriesAPassword() throws {
        let file = try XCTUnwrap(RDPLink.file(host: "10.20.30.40", account: "admin"))
        XCTAssertEqual(String(decoding: file, as: UTF8.self), "full address:s:10.20.30.40\r\nusername:s:admin\r\n")
        XCTAssertEqual(String(decoding: try XCTUnwrap(RDPLink.file(host: "srv-1c.example.test")), as: UTF8.self), "full address:s:srv-1c.example.test\r\n")
        XCTAssertFalse(String(decoding: file, as: UTF8.self).lowercased().contains("password"))
        XCTAssertTrue(RDPLink.isValidHost("10.20.0.15:3390"))
    }

    func testRDPFileRejectsHostsAndAccountsThatCouldInjectLines() throws {
        for bad in ["", " ", "10.0.0.1\nfull address:s:evil", "host name", "10.0.0.1\r\nusername:s:x", "a;b", "host/../x"] {
            XCTAssertNil(RDPLink.file(host: bad), "«\(bad.debugDescription)»")
        }
        let file = String(decoding: try XCTUnwrap(RDPLink.file(host: "10.0.0.1", account: "adm\nfull address:s:evil")), as: UTF8.self)
        XCTAssertFalse(file.contains("evil"), "логин с переводом строки не пишется")
        XCTAssertEqual(RDPLink.fileName(for: "Вінниця / ../Філія: 1"), RDPLink.fileName(for: "Вінниця / ../Філія: 1"))
        XCTAssertFalse(RDPLink.fileName(for: "../../etc/passwd").contains("/"))
        XCTAssertTrue(RDPLink.fileName(for: "").hasSuffix(".rdp"))
    }

    // MARK: Фильтры

    func testFiltersCountRDPAndVPNNextToAnyDeskAndTeamViewer() throws {
        let snap = try read([["Название", "ID", "Программа", "Теги"], ["А", "", "RDP", ""], ["Б", "", "RDP", ""], ["В", "", "VPN", ""],
                             ["Г", "123456789", "AnyDesk", "VPN"], ["Д", "223456789", "TeamViewer", ""]])
        let search = ConnectionSearch(snap.records)
        func listing(_ f: ProgramFilter) -> ConnectionListing {
            ConnectionListBuilder.build(search: search, query: "", filter: f, defaultProgram: .anyDesk, favorites: [], recents: [])
        }
        let all = listing(.all)
        XCTAssertEqual(all.counts[.rdp], 2)
        XCTAssertEqual(all.counts[.vpn], 2, "программа VPN или метка VPN")
        XCTAssertEqual(all.counts[.program(.anyDesk)], 1)
        XCTAssertEqual(all.counts[.program(.teamViewer)], 1)
        XCTAssertEqual(listing(.rdp).rows.map(\.record.name).sorted(), ["А", "Б"])
        XCTAssertEqual(listing(.vpn).rows.map(\.record.name).sorted(), ["Г", "В"].sorted())
    }
}

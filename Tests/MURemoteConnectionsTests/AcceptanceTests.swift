@testable import MURemoteConnections
import XCTest

/// Приёмка модуля по ТЗ § 7 (`.audit/tz-anydesk.md`): файлы на диске, как у пользователя, и путь
/// «файл → хранилище → список → поиск». Данные выдуманные, собираются здесь же (бинарников нет).
@MainActor
final class AcceptanceTests: XCTestCase {
    private var dir: URL!
    private var store: ConnectionsFileStore?
    private let logger = RecordingLogger()

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-acc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        store?.stop()
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Помощники

    private func makeStore(_ url: URL?, reader: ConnectionsFileStore.Reader? = nil) -> ConnectionsFileStore {
        let settings = InMemoryConnectionsSettings(filePath: url?.path)
        let s = reader.map { ConnectionsFileStore(settings: settings, logger: logger, retryDelay: 0.01, debounce: 0.05, reader: $0) }
            ?? ConnectionsFileStore(settings: settings, logger: logger, retryDelay: 0.01, debounce: 0.05)
        store = s
        return s
    }

    private func wait(_ s: ConnectionsFileStore, timeout: TimeInterval = 8, until ok: @escaping (ConnectionsFileStore) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !ok(s), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ok(s), "состояние: \(s.state), записей: \(s.snapshot.records.count)")
    }

    private func loaded(_ url: URL) async -> ConnectionsFileStore {
        let s = makeStore(url)
        s.start()
        await wait(s) { $0.state == .ready }
        return s
    }

    private func listing(_ snap: ConnectionsSnapshot, query: String = "", favorites: [String] = [], recents: [String] = [],
                         filter: ProgramFilter = .all) -> ConnectionListing {
        ConnectionListBuilder.build(search: ConnectionSearch(snap.records), query: query, filter: filter,
                                    defaultProgram: .anyDesk, favorites: favorites, recents: recents)
    }

    /// Строки листа, которые портит `corruptedRows()`: номер строки листа → причина.
    private let expectedSkips: [Int: SkippedRow.Reason] = [
        4: .missingName, 6: .missingID, 8: .invalidID, 16: .unknownProgram, 20: .aliasNotSupported,
    ]

    // MARK: § 7.1 — 200+ строк, корректные видны, некорректные в диагностике с номером строки

    func testXLSX200RowsGoodVisibleBadDiagnosedWithRowNumbers() async throws {
        let url = dir.appendingPathComponent("Подключения.xlsx")
        let rows = Fixtures.messyRows()
        XCTAssertGreaterThanOrEqual(rows.count, 200)
        try Fixtures.xlsx(rows: rows).write(to: url)
        let s = await loaded(url)
        let snap = s.snapshot

        let skipped = Dictionary(uniqueKeysWithValues: snap.diagnostics.skipped.map { ($0.row, $0.reason) })
        XCTAssertEqual(skipped, expectedSkips, "пропущенные строки и причины")
        // 210 данных − 5 пропущено − 1 пустая (строка 22 не диагностика) = 204.
        XCTAssertEqual(snap.records.count, 204)
        XCTAssertEqual(snap.diagnostics.loaded, 204)
        XCTAssertEqual(snap.diagnostics.lossyIDRows, [10], "1.23E+08: цифры потеряны — предупредить")
        XCTAssertEqual(snap.diagnostics.unrecognizedColumns, ["Ответственный"])
        XCTAssertEqual(snap.diagnostics.duplicates.map(\.rows), [[3, 14]])
        // Корректные видны в списке; пропущенных в списке нет.
        let shown = Set(listing(snap).rows.map(\.record.sourceRow))
        for row in expectedSkips.keys { XCTAssertFalse(shown.contains(row), "строка \(row) не должна быть в списке") }
        for row in [2, 3, 5, 9, 10, 12, 14, 18, 24, 211] { XCTAssertTrue(shown.contains(row), "строка \(row) должна быть в списке") }
    }

    func testXMLGoodVisibleBadDiagnosed() async throws {
        let url = dir.appendingPathComponent("connections.xml")
        try Fixtures.xml(rows: Fixtures.messyRows()).write(to: url)
        let s = await loaded(url)
        let snap = s.snapshot
        XCTAssertEqual(snap.records.count, 204)
        XCTAssertEqual(snap.diagnostics.skipped.count, expectedSkips.count)
        XCTAssertEqual(Set(snap.diagnostics.skipped.map(\.reason)), Set(expectedSkips.values))
        XCTAssertTrue(snap.diagnostics.skipped.allSatisfy { $0.row > 0 }, "у каждой пропущенной записи есть номер строки файла")
        XCTAssertEqual(snap.diagnostics.duplicates.count, 1)
    }

    func testHandWrittenXMLWithBOMCRLFAndAttributes() throws {
        let text = "\u{FEFF}<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n<connections>\r\n"
            + "  <!-- выдуманные данные -->\r\n"
            + "  <connection><name>Аптека Захід</name><id>123 456 789</id><password>Pw-x-секрет</password><group>Філії</group></connection>\r\n"
            + "  <connection><name>Bad row</name><id>12</id></connection>\r\n"
            + "  <connection><name>Front</name><id>front@ad</id><tags>a, b</tags><note>n &amp; m</note></connection>\r\n"
            + "</connections>\r\n"
        let snap = try XMLSource().load(Data(text.utf8))
        XCTAssertEqual(snap.records.map(\.id), ["123456789", "front@ad"])
        XCTAssertEqual(snap.records[1].tags, ["a", "b"])
        XCTAssertEqual(snap.records[1].note, "n & m")
        XCTAssertEqual(snap.diagnostics.skipped.count, 1)
        XCTAssertEqual(snap.diagnostics.skipped.first?.reason, .invalidID)
        XCTAssertEqual(snap.diagnostics.skipped.first?.row, 5, "номер строки файла (строка 5), не номер записи")
    }

    // MARK: Произвольный порядок колонок, рус/укр/англ заголовки, «Программа»

    func testShuffledColumnsInThreeLanguages() throws {
        let canonical = Fixtures.cleanRows(60)
        let headerSets: [[String]] = [
            ["Название", "ID", "Пароль", "Группа", "Теги", "Заметка", "Программа"],
            ["Назва", "Адреса", "Пароль", "Група", "Теги", "Примітка", "Програма"],
            ["Name", "Address", "Password", "Group", "Tags", "Note", "Program"],
            ["name", "anydesk", "PASSWORD", "GROUP", "tags", "NOTE", "app"],
        ]
        var rng = SystemRandomNumberGenerator()
        let reference = try XLSXSource().load(Fixtures.xlsx(rows: canonical)).records
        for headers in headerSets {
            for _ in 0..<4 {
                let order = Array(0..<headers.count).shuffled(using: &rng)
                var rows = [order.map { headers[$0] }]
                for r in canonical.dropFirst() { rows.append(order.map { r[$0] }) }
                for snap in [try XLSXSource().load(Fixtures.xlsx(rows: rows)), try XMLSource().load(Fixtures.xml(rows: rows))] {
                    XCTAssertEqual(snap.records.count, reference.count, "\(rows[0])")
                    for (a, b) in zip(snap.records, reference) {
                        XCTAssertEqual([a.name, a.id, a.group, a.note, "\(a.tags)", "\(a.hasPassword)", "\(String(describing: a.program))"],
                                       [b.name, b.id, b.group, b.note, "\(b.tags)", "\(b.hasPassword)", "\(String(describing: b.program))"],
                                       "\(rows[0])")
                    }
                    XCTAssertTrue(snap.diagnostics.skipped.isEmpty)
                }
            }
        }
    }

    // MARK: ID: число / текст / 1.23E+08 / пробелы / алиасы

    func testIDInEveryCellForm() throws {
        let header = ["Название", "ID"].map(Fixtures.Cell.text)
        let cases: [(Fixtures.Cell, String?)] = [
            (.number("123456789"), "123456789"),
            (.number("1234567890"), "1234567890"),
            (.text("123456789"), "123456789"),
            (.inline("987654321"), "987654321"),
            (.text("123 456 789"), "123456789"),
            (.text(" 123\u{00A0}456\u{00A0}780 "), "123456780"),
            (.number("1.23456789E+08"), "123456789"),
            (.text("1,23456789E+08"), "123456789"),
            (.formula("111222333"), "111222333"),
            (.text("office@ad"), "office@ad"),
            (.text("Front-Desk.2@Company"), "front-desk.2@company"),
            (.text("12345"), nil),
            (.text("abc"), nil),
            (.text("123456789012"), nil),
        ]
        var rows: [[Fixtures.Cell]] = [header]
        for (i, c) in cases.enumerated() { rows.append([.text("Узел \(i)"), c.0]) }
        let snap = try XLSXSource().load(Fixtures.xlsx([Fixtures.Sheet(name: "Лист1", rows: rows)]))
        let byRow = Dictionary(uniqueKeysWithValues: snap.records.map { ($0.sourceRow, $0.id) })
        for (i, c) in cases.enumerated() { XCTAssertEqual(byRow[i + 2], c.1, "строка \(i + 2)") }
        XCTAssertEqual(snap.diagnostics.skipped.map(\.row), [13, 14, 15])
        XCTAssertTrue(snap.diagnostics.skipped.allSatisfy { $0.reason == .invalidID })
    }

    func testDuplicatesShowBoth() throws {
        var rows = Fixtures.cleanRows(10)
        rows.append(["Копия кассы", rows[3][1], "", "", "", "", ""])
        let snap = try XLSXSource().load(Fixtures.xlsx(rows: rows))
        XCTAssertEqual(snap.records.count, 11)
        XCTAssertEqual(snap.diagnostics.duplicates.count, 1)
        XCTAssertEqual(snap.diagnostics.duplicates[0].rows, [4, 12])
        let found = listing(snap, query: rows[3][1]).rows
        XCTAssertEqual(found.count, 2, "оба дубликата в поиске")
        XCTAssertEqual(Set(found.map(\.id)).count, 2, "строки списка различимы")
    }

    func testEmptyRowsSkippedSilently() throws {
        var rows = Fixtures.cleanRows(6)
        rows.insert(Array(repeating: "", count: 7), at: 3)
        rows.insert(["  ", "\t", "", "", "", "", ""], at: 5)
        rows.append(Array(repeating: "", count: 7))
        let snap = try XLSXSource().load(Fixtures.xlsx(rows: rows))
        XCTAssertEqual(snap.records.count, 6)
        XCTAssertTrue(snap.diagnostics.skipped.isEmpty, "пустые строки — не ошибка")
        XCTAssertTrue(snap.diagnostics.duplicates.isEmpty && snap.diagnostics.lossyIDRows.isEmpty)
    }

    // MARK: Ошибки файла (§ 6)

    func testMissingColumnsListsFoundHeaders() async throws {
        let url = dir.appendingPathComponent("плохой.xlsx")
        try Fixtures.xlsx(rows: [["Фамилия", "Телефон"], ["Иванов", "555"]]).write(to: url)
        let s = makeStore(url)
        s.start()
        await wait(s) { $0.state != .loading }
        XCTAssertEqual(s.state, .failed(.missingColumns(found: ["Фамилия", "Телефон"])))
        XCTAssertTrue(s.snapshot.records.isEmpty)
    }

    func testCorruptFileGivesErrorAndKeepsNoOldList() async throws {
        let url = dir.appendingPathComponent("c.xlsx")
        try Fixtures.xlsx(rows: Fixtures.cleanRows(30)).write(to: url)
        let s = await loaded(url)
        XCTAssertEqual(s.snapshot.records.count, 30)
        try Data("не архив".utf8).write(to: url)
        s.reload()
        await wait(s) { if case .failed = $0.state { return true } else { return false } }
        XCTAssertTrue(s.snapshot.records.isEmpty, "повреждённый файл: старый список не сохраняется")
    }

    func testNoFileChosenAndUnavailable() async {
        let none = makeStore(nil)
        none.start()
        XCTAssertEqual(none.state, .noFile)
        let gone = makeStore(dir.appendingPathComponent("нет.xlsx"))
        gone.start()
        await wait(gone) { $0.state == .unavailable }
        XCTAssertTrue(gone.snapshot.records.isEmpty)
    }

    func testLockedFileIsRetriedThenLoads() async throws {
        let url = dir.appendingPathComponent("busy.xlsx")
        let data = Fixtures.xlsx(rows: Fixtures.cleanRows(25))
        try data.write(to: url)
        let attempts = Counter()
        let s = makeStore(url) { u, sheet in
            if attempts.next() < 2 { throw ConnectionsError.locked }
            return try ConnectionsFileStore.read(url: u, sheet: sheet)
        }
        s.start()
        await wait(s) { $0.state == .ready }
        XCTAssertEqual(s.snapshot.records.count, 25)
        XCTAssertEqual(attempts.value, 3)
        XCTAssertFalse(logger.events.contains { if case .loadFailed = $0 { return true } else { return false } }, "ошибки пользователю не было")
    }

    func testTruncatedFileWhileExcelSavesThenCompletes() async throws {
        let url = dir.appendingPathComponent("save.xlsx")
        let full = Fixtures.xlsx(rows: Fixtures.cleanRows(40))
        try full.prefix(full.count / 2).write(to: url)
        let s = makeStore(url)
        s.start()
        await wait(s) { if case .failed = $0.state { return true } else { return false } }
        try full.write(to: url)
        s.reload()
        await wait(s) { $0.state == .ready }
        XCTAssertEqual(s.snapshot.records.count, 40)
    }

    // MARK: Изменение файла → перечитывание

    func testEditInPlaceUpdatesList() async throws {
        let url = dir.appendingPathComponent("edit.xlsx")
        try Fixtures.xlsx(rows: Fixtures.cleanRows(200)).write(to: url)
        let s = await loaded(url)
        XCTAssertEqual(s.snapshot.records.count, 200)
        var rows = Fixtures.cleanRows(200)
        rows[1][0] = "Переименованный узел"
        rows.append(["Новый узел", "555666777", "Pw-new-секрет", "Клиенты", "", "", ""])
        try Fixtures.xlsx(rows: rows).write(to: url)
        await wait(s) { $0.snapshot.records.count == 201 }
        XCTAssertEqual(s.snapshot.records.first?.name, "Переименованный узел")
        XCTAssertEqual(s.snapshot.records.last?.id, "555666777")
    }

    func testExcelStyleAtomicSaveUpdatesList() async throws {
        let url = dir.appendingPathComponent("atomic.xlsx")
        try Fixtures.xlsx(rows: Fixtures.cleanRows(50)).write(to: url)
        let s = await loaded(url)
        for n in [51, 52, 53] {
            let tmp = dir.appendingPathComponent("~$tmp-\(n).xlsx")
            try Fixtures.xlsx(rows: Fixtures.cleanRows(n)).write(to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            await wait(s) { $0.snapshot.records.count == n }
        }
    }

    func testDeletedFileEmptiesListThenRestoreBringsItBack() async throws {
        let url = dir.appendingPathComponent("gone.xlsx")
        let data = Fixtures.xlsx(rows: Fixtures.cleanRows(20))
        try data.write(to: url)
        let s = await loaded(url)
        try FileManager.default.removeItem(at: url)
        await wait(s) { $0.state == .unavailable }
        XCTAssertTrue(s.snapshot.records.isEmpty)
        try data.write(to: url)
        await wait(s) { $0.state == .ready }
        XCTAssertEqual(s.snapshot.records.count, 20)
    }

    // MARK: Поиск и Enter

    func testSearchByPartOfNameAndIDThenEnterPicksFirst() throws {
        let snap = try XLSXSource().load(Fixtures.xlsx(rows: Fixtures.cleanRows(300)))
        let target = snap.records[137]

        var byName = listing(snap, query: "лаборат").rows
        XCTAssertFalse(byName.isEmpty)
        XCTAssertTrue(byName.allSatisfy { $0.record.name.lowercased().contains("лаборат") })

        byName = listing(snap, query: target.name.lowercased()).rows
        XCTAssertEqual(byName.first?.record.identity, target.identity, "Enter по точному имени — эта запись")

        for query in [target.id, String(target.id.prefix(6)), target.displayID, String(target.id.dropFirst(3).prefix(5))] {
            let rows = listing(snap, query: query).rows
            XCTAssertTrue(rows.contains { $0.record.identity == target.identity }, "ID по «\(query)»")
        }
        XCTAssertEqual(listing(snap, query: target.id).rows.first?.record.identity, target.identity)
        XCTAssertTrue(listing(snap, query: "нетакогослова").isEmpty)
    }

    func testSearchByGroupTagNoteCaseInsensitive() throws {
        let snap = try XLSXSource().load(Fixtures.xlsx(rows: Fixtures.cleanRows(60)))
        for q in ["ФІЛІЇ", "OFFICE", "КАССА", "Ночь", "ЗВОНИТЬ", "Приёмная", "приемная"] {
            XCTAssertFalse(listing(snap, query: q).isEmpty, q)
        }
        XCTAssertFalse(listing(snap, query: "КЛИЕНТЫ").isEmpty)
    }

    func testSearchInWrongLayout() throws {
        let snap = try XLSXSource().load(Fixtures.xlsx(rows: Fixtures.cleanRows(40)))
        let typed = listing(snap, query: "ctdth")           // «север» на английской раскладке
        XCTAssertFalse(typed.isEmpty)
        XCTAssertEqual(typed.hint?.converted, "север")
        XCTAssertTrue(typed.rows.allSatisfy { $0.record.name.lowercased().contains("север") })
        let kyiv = listing(snap, query: "Лнш")              // «Kyi» в русской раскладке
        XCTAssertFalse(kyiv.isEmpty)
        XCTAssertTrue(kyiv.rows.allSatisfy { $0.record.name.contains("Kyiv") })
        XCTAssertEqual(kyiv.hint?.converted, "kyi")
    }

    func testFavoritesAndRecentsAcrossReload() throws {
        let snap = try XLSXSource().load(Fixtures.xlsx(rows: Fixtures.cleanRows(30)))
        let prefs = InMemoryRemotePreferences()
        for i in 0..<8 { ConnectionLists.noteConnected(snap.records[i], in: prefs) }
        XCTAssertEqual(prefs.recentIDs.count, 5)
        XCTAssertEqual(prefs.recentIDs.first, snap.records[7].id)
        ConnectionLists.toggleFavorite(snap.records[1], in: prefs)
        ConnectionLists.toggleFavorite(snap.records[3], in: prefs)
        // Файл изменился: записи 4 и 9 исчезли (4-я была и в избранном, и в недавних).
        let after = try XLSXSource().load(Fixtures.xlsx(rows: Array(Fixtures.cleanRows(30).enumerated().filter { $0.offset != 4 && $0.offset != 9 }.map(\.element))))
        let l = listing(after, favorites: prefs.favoriteIDs, recents: prefs.recentIDs)
        XCTAssertEqual(l.sections.first?.kind, .favorites)
        let shownIDs = l.sections.filter { $0.kind == .favorites || $0.kind == .recents }.flatMap(\.records).map(\.id)
        XCTAssertFalse(shownIDs.contains(snap.records[3].id), "исчезнувший ID не показывается")
        XCTAssertTrue(shownIDs.contains(snap.records[1].id))
        for kind in [ConnectionSection.Kind.favorites, .recents] {
            let ids = l.sections.first { $0.kind == kind }?.records.map(\.id) ?? []
            XCTAssertTrue(ids.allSatisfy { id in after.records.contains { $0.id == id } }, "исчезнувшие ID не показываются")
        }
    }

    // MARK: «Пароль нигде»

    private func allStrings(_ value: Any, depth: Int = 0) -> [String] {
        guard depth < 14 else { return [] }
        if let s = value as? String { return [s] }
        return Mirror(reflecting: value).children.flatMap { allStrings($0.value, depth: depth + 1) }
    }

    func testNoPasswordInMemoryModelsDefaultsLogOrFiles() async throws {
        let url = dir.appendingPathComponent("pw.xlsx")
        try Fixtures.xlsx(rows: Fixtures.messyRows()).write(to: url)
        let defaultsBefore = UserDefaults.standard.dictionaryRepresentation().keys.count
        let s = await loaded(url)
        let prefs = InMemoryRemotePreferences()
        ConnectionLists.noteConnected(s.snapshot.records[0], in: prefs)
        let search = ConnectionSearch(s.snapshot.records)
        let list = listing(s.snapshot, query: "комп", favorites: prefs.favoriteIDs, recents: prefs.recentIDs)

        let marker = "секрет"
        for (what, value) in [("snapshot", s.snapshot as Any), ("search", search), ("listing", list), ("prefs", prefs),
                              ("состояние", s.state)] {
            XCTAssertFalse(allStrings(value).contains { $0.contains(marker) || $0.hasPrefix("Pw-") }, "\(what): пароль в памяти")
        }
        XCTAssertTrue(s.snapshot.records.contains { $0.hasPassword }, "признак «есть пароль» остаётся")
        XCTAssertFalse(logger.events.map(\.message).joined().contains(marker))
        XCTAssertEqual(UserDefaults.standard.dictionaryRepresentation().keys.count, defaultsBefore, "модуль не пишет в UserDefaults")
        for (_, v) in UserDefaults.standard.dictionaryRepresentation() {
            XCTAssertFalse("\(v)".contains(marker))
        }

        // Пароль выдаётся только по запросу, затирается и не печатается.
        let record = s.snapshot.records.first { $0.hasPassword }!
        let secret = try await s.password(for: record)
        XCTAssertNotNil(secret)
        XCTAssertFalse("\(String(describing: secret))".contains("Pw-"))
        secret?.wipe()
        XCTAssertEqual(secret?.isEmpty, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["pw.xlsx"], "рядом с файлом ничего не появилось")
    }

    func testPasswordReadFromFileAtConnectTimeNotFromMemory() async throws {
        let url = dir.appendingPathComponent("fresh.xlsx")
        var rows = Fixtures.cleanRows(20)
        try Fixtures.xlsx(rows: rows).write(to: url)
        let s = await loaded(url)
        let record = s.snapshot.records[1]
        rows[2][2] = "Новый-пароль-77"
        try Fixtures.xlsx(rows: rows).write(to: url)
        let secret = try await s.password(for: record)
        let text = secret.map { $0.withBytes { String(decoding: $0, as: UTF8.self) } }
        XCTAssertEqual(text, "Новый-пароль-77", "пароль берётся из файла в момент подключения")
        secret?.wipe()
    }

    func testRecordWithoutPasswordYieldsNone() async throws {
        let url = dir.appendingPathComponent("nopw.xlsx")
        try Fixtures.xlsx(rows: Fixtures.cleanRows(10)).write(to: url)
        let s = await loaded(url)
        let record = s.snapshot.records.first { !$0.hasPassword }!
        let secret = try await s.password(for: record)
        XCTAssertNil(secret)
    }

    /// После «удаления файла» в каталогах приложения (Preferences, Application Support, Caches) нет
    /// пароля из фикстур. Только чтение; смотрим файлы приложения с известным идентификатором.
    func testNoFixturePasswordsInUserLibraryAfterFileRemoval() async throws {
        let url = dir.appendingPathComponent("lib.xlsx")
        try Fixtures.xlsx(rows: Fixtures.messyRows()).write(to: url)
        let s = await loaded(url)
        _ = try await s.password(for: s.snapshot.records[0])
        try FileManager.default.removeItem(at: url)
        s.stop()

        let lib = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let needle = Data("секрет".utf8)
        let roots = ["Preferences/com.mruzhynskyi.macutils.plist", "Application Support/MacUtils",
                     "Application Support/com.mruzhynskyi.macutils", "Caches/com.mruzhynskyi.macutils", "Caches/MacUtils"]
        for root in roots {
            let base = lib.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
                if let d = try? Data(contentsOf: base) { XCTAssertNil(d.range(of: needle), root) }
                continue
            }
            for case let f as URL in e.allObjects {
                let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard v?.isRegularFile == true, (v?.fileSize ?? 0) < 20 << 20, let d = try? Data(contentsOf: f) else { continue }
                XCTAssertNil(d.range(of: needle), "пароль фикстур найден в \(root)")
            }
        }
    }

    // MARK: Производительность

    func testThousandPlusRowsLoadAndSearchFast() async throws {
        for ext in ["xlsx", "xml"] {
            let url = dir.appendingPathComponent("big.\(ext)")
            let rows = Fixtures.cleanRows(2_000)
            try (ext == "xlsx" ? Fixtures.xlsx(rows: rows) : Fixtures.xml(rows: rows)).write(to: url)
            let t0 = DispatchTime.now()
            let snap = try ConnectionsFileStore.read(url: url, sheet: nil)
            let load = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
            XCTAssertEqual(snap.records.count, 2_000)
            XCTAssertLessThan(load, 1.0, "\(ext): чтение 2000 строк \(load) с")

            let search = ConnectionSearch(snap.records)
            let t1 = DispatchTime.now()
            for q in ["лабор", "касса 12", "100", "ctdth", "zzzz"] { _ = search.search(q) }
            let each = Double(DispatchTime.now().uptimeNanoseconds - t1.uptimeNanoseconds) / 1e9 / 5
            XCTAssertLessThan(each, 0.1, "\(ext): поиск по 2000 записей \(each) с")
        }
    }
}

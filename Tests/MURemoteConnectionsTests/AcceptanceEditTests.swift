@testable import MURemoteConnections
import XCTest

/// Приёмка A-4 по ТЗ § 3.1, § 4, § 7: правка .xml из приложения (добавить/изменить/удалить), `.bak`, права, шаблоны.
/// Файлы — как их правят люди: BOM, CRLF, комментарии, атрибуты, CDATA, чужие теги, всё в одну строку. Данные выдуманные.
@MainActor
final class AcceptanceEditTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-edit-acc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Файлы

    private static let body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!-- Список подключений. <connection> в комментарии — не запись -->
    <connections>
    \t<connection>
    \t\t<name>Лаборатория Север</name>
    \t\t<id>123 456 789</id>
    \t\t<password><![CDATA[Pw-1-секрет&<>]]></password>
    \t\t<group>Лаборатории</group>
    \t\t<tags>касса, ночь</tags>
    \t\t<extra a="1">чужое поле</extra>
    \t</connection>
    \t<connection name="Касса &amp; склад" id="223456789" password="Pw-2-секрет" app="TeamViewer"/>
    \t<!-- между записями -->
    \t<connection><name>Аптека Захід</name><id>323456789</id><note/><password>Pw-3-секрет</password></connection>
    \t<connection><name>Дубликат</name><id>323456789</id><password>Pw-4-секрет</password></connection>
    \t<connection><name>Алиас</name><id>Office@AD</id></connection>
    </connections>

    """

    private var lf: Data { Data(Self.body.utf8) }
    private var crlf: Data { Data(("\u{FEFF}" + Self.body.replacingOccurrences(of: "\n", with: "\r\n")).utf8) }
    private var oneLine: Data {
        Data(Self.body.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "<!-- Список подключений. <connection> в комментарии — не запись -->", with: "").utf8)
    }

    private func variants() -> [(String, Data)] { [("lf+tab", lf), ("crlf+bom", crlf), ("одна строка", oneLine)] }

    private struct Row: Equatable { var name, id, password, group, tags, note: String; var program: RemoteProgram? }

    private func rows(_ data: Data) throws -> [Row] {
        try XMLSource().parse(data, mode: .passwords).entries.map {
            Row(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), id: ConnectionID.normalize($0.id)?.value ?? $0.id,
                password: $0.password, group: $0.group, tags: $0.tags, note: $0.note, program: RemoteProgram.parse($0.program))
        }
    }

    private func records(_ data: Data) throws -> [ConnectionRecord] { try XMLSource().load(data).records }

    /// Общий префикс и суффикс: сколько байт совпало с начала и с конца.
    private func affix(_ a: Data, _ b: Data) -> (prefix: Int, suffix: Int) {
        let x = [UInt8](a), y = [UInt8](b)
        var p = 0
        while p < min(x.count, y.count), x[p] == y[p] { p += 1 }
        var s = 0
        while s < min(x.count, y.count) - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        return (p, s)
    }

    /// Шаг, который не должен бросать: при ошибке в сообщении видно, где именно.
    private func attempt<T>(_ label: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) -> T? {
        do { return try body() } catch { XCTFail("\(label): \(error)", file: file, line: line); return nil }
    }

    private func collapsed(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }

    private func perms(_ u: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }

    // MARK: Изменить: меняются только байты этой записи

    func testEveryFieldOfEveryRecordChangesOnlyItsOwnBytes() throws {
        for (label, data) in variants() {
            let recs = try records(data)
            let before = try rows(data)
            XCTAssertEqual(recs.count, 5, label)
            let scan = try XMLScan(data)
            for (i, record) in recs.enumerated() {
                // Одна строка + одинаковый ID у двух записей: запись не отличить (отдельный тест ниже).
                if label == "одна строка", i == 2 || i == 3 { continue }
                let element = try scan.find(record)
                for field in ["name", "id", "group", "tags", "note", "program", "password"] {
                    var draft = ConnectionDraft(record)
                    switch field {
                    case "name": draft.name = "Новое имя & «кавычки» <тег>"
                    case "id": draft.id = "999 888 777"
                    case "group": draft.group = "Новая группа"
                    case "tags": draft.tags = "а, б; в"
                    case "note": draft.note = "строка 1\nстрока 2 ]]> & '\""
                    case "program": draft.program = record.program == .teamViewer ? .anyDesk : .teamViewer
                    default: draft.password = "Новый ]]> пароль & \"x\" 🔐"
                    }
                    if field == "id", record.isAlias { draft.program = nil }
                    if field == "program", record.isAlias { continue }
                    guard let out = attempt("\(label) #\(i) \(field)", { try XMLConnectionsEditor.update(record, with: draft, in: data) }) else { continue }
                    let a = affix(data, out)
                    XCTAssertGreaterThanOrEqual(a.prefix, element.range.lowerBound, "\(label) #\(i) \(field): правка вышла за начало записи")
                    XCTAssertGreaterThanOrEqual(a.suffix, data.count - element.range.upperBound - 0 - (field == "tags" ? 0 : 0),
                                                "\(label) #\(i) \(field): правка вышла за конец записи")
                    var after = try rows(out)
                    XCTAssertEqual(after.count, before.count)
                    for (j, row) in after.enumerated() where j != i { XCTAssertEqual(row, before[j], "\(label) #\(i) \(field): запись \(j) изменилась") }
                    let mine = after.remove(at: i)
                    switch field {
                    case "name": XCTAssertEqual(mine.name, "Новое имя & «кавычки» <тег>")
                    case "id": XCTAssertEqual(mine.id, "999888777")
                    case "group": XCTAssertEqual(mine.group, "Новая группа")
                    case "tags": XCTAssertEqual(XMLConnectionsEditorTags.split(mine.tags), ["а", "б", "в"])
                    case "note": XCTAssertEqual(collapsed(mine.note), "строка 1 строка 2 ]]> & '\"")
                    case "program": XCTAssertEqual(mine.program, record.program == .teamViewer ? .anyDesk : .teamViewer)
                    default: XCTAssertEqual(mine.password, "Новый ]]> пароль & \"x\" 🔐")
                    }
                    // Остальные поля этой записи не тронуты.
                    for (name, same) in [("password", mine.password == before[i].password), ("group", mine.group == before[i].group),
                                         ("name", mine.name == before[i].name)] where name != field && !(field == "password" && name == "password") {
                        XCTAssertTrue(same, "\(label) #\(i) \(field): поле \(name) соседнее изменилось")
                    }
                }
            }
        }
    }

    func testSavingUnchangedDraftKeepsFileByteForByte() throws {
        for (label, data) in variants() {
            for record in try records(data) {
                if label == "одна строка", record.id == "323456789" { continue }
                XCTAssertEqual(try XMLConnectionsEditor.update(record, with: ConnectionDraft(record), in: data), data, "\(label) \(record.name)")
            }
        }
    }

    func testPasswordUntouchedWhenDraftHasNone_ClearedWhenEmpty() throws {
        let data = lf
        let record = try records(data)[0]
        var d = ConnectionDraft(record); d.note = "заметка"
        XCTAssertEqual(try rows(XMLConnectionsEditor.update(record, with: d, in: data))[0].password, "Pw-1-секрет&<>")
        d.password = ""
        XCTAssertEqual(try rows(XMLConnectionsEditor.update(record, with: d, in: data))[0].password, "")
    }

    func testEditingDuplicateAffectsOnlyThatRow() throws {
        let data = lf
        let dup = try records(data)[3]
        XCTAssertEqual(dup.name, "Дубликат")
        var d = ConnectionDraft(dup); d.group = "Правка дубликата"
        let out = try XMLConnectionsEditor.update(dup, with: d, in: data)
        let r = try rows(out)
        XCTAssertEqual(r[3].group, "Правка дубликата")
        XCTAssertEqual(r[2], try rows(data)[2], "оригинал с тем же ID не тронут")
        XCTAssertEqual(r[3].password, "Pw-4-секрет")
    }

    // MARK: Добавить / удалить

    func testAddIsPureInsertionAndKeepsEverythingElse() throws {
        for (label, data) in variants() where label != "одна строка" {      // однострочный файл — отдельный тест ниже
            var draft = ConnectionDraft(name: "Новый & узел", id: "555 666 777", group: "Новая", tags: "x, y", note: "n", program: .anyDesk, password: "Pw-new-секрет")
            guard let out = attempt("add \(label)", { try XMLConnectionsEditor.add(draft, to: data) }) else { continue }
            let a = affix(data, out)
            XCTAssertEqual(a.prefix + a.suffix, data.count, "\(label): добавление — вставка, исходные байты целы")
            let r = try rows(out)
            XCTAssertEqual(r.count, 6)
            XCTAssertEqual(Array(r.dropLast()), try rows(data))
            XCTAssertEqual(r.last, Row(name: "Новый & узел", id: "555666777", password: "Pw-new-секрет", group: "Новая", tags: "x, y", note: "n", program: .anyDesk), label)
            XCTAssertEqual(try records(out).last?.hasPassword, true)
            // Без пароля.
            draft.password = nil
            XCTAssertEqual(try rows(XMLConnectionsEditor.add(draft, to: data)).last?.password, "")
        }
    }

    func testAddKeepsLineEndingsOfTheFile() throws {
        let out = try XMLConnectionsEditor.add(ConnectionDraft(name: "X", id: "555666777"), to: crlf)
        let text = String(decoding: out, as: UTF8.self)
        let bareLF = text.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        XCTExpectFailure("ОШИБКА A-4 (rc-acceptance.md): add в CRLF-файле вставляет одиночный LF") {
            XCTAssertFalse(bareLF, "в CRLF-файле появился одиночный LF (смешанные окончания строк)")
        }
    }

    func testDeleteRemovesOnlyThatRecordAndRoundTripsWithAdd() throws {
        for (label, data) in variants() {
            let recs = try records(data)
            let before = try rows(data)
            for (i, record) in recs.enumerated() {
                if label == "одна строка", i == 2 || i == 3 { continue }
                let out = try XMLConnectionsEditor.delete(record, in: data)
                var expected = before; expected.remove(at: i)
                XCTAssertEqual(try rows(out), expected, "\(label) удалена \(i)")
                let scan = try XMLScan(data), range = try scan.find(record).range
                let a = affix(data, out)
                XCTAssertGreaterThanOrEqual(a.prefix + 0, scan.lineStart(of: range.lowerBound) - 0 , "\(label) \(i): удалено лишнее до записи")
                XCTAssertLessThanOrEqual(data.count - out.count, scan.lineEnd(after: range.upperBound) - scan.lineStart(of: range.lowerBound) + 2, "\(label) \(i): удалено больше строки записи")
            }
        }
        // Добавили и удалили то же — файл вернулся байт в байт (файлы с переводами строк).
        for (label, data) in [("lf", lf)] {
            let added = try XMLConnectionsEditor.add(ConnectionDraft(name: "Временный", id: "555666777"), to: data)
            let back = try XMLConnectionsEditor.delete(try records(added).last!, in: added)
            XCTAssertEqual(back, data, label)
        }
    }

    func testDeleteEverythingThenAddToEmptyFile() throws {
        var data = lf
        while let r = try records(data).first { data = try XMLConnectionsEditor.delete(r, in: data) }
        XCTAssertEqual(try records(data).count, 0)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<!-- Список подключений"), "комментарии пережили")
        data = try XMLConnectionsEditor.add(ConnectionDraft(name: "Первая", id: "123456789"), to: data)
        XCTAssertEqual(try records(data).map(\.name), ["Первая"])
    }

    func testInvalidDraftsAreRejectedAndFileUntouched() throws {
        for bad in [ConnectionDraft(name: "", id: "123456789"), ConnectionDraft(name: "x", id: "12345"), ConnectionDraft(name: "x", id: "ab c@ad", program: .teamViewer),
                    ConnectionDraft(name: "x", id: "office@ad", program: .teamViewer), ConnectionDraft(name: "  ", id: "")] {
            XCTAssertThrowsError(try XMLConnectionsEditor.add(bad, to: lf), "\(bad)")
        }
    }

    func testFilesThatCannotBeEditedLosslesslyAreRefused() throws {
        let utf16 = "<connections><connection><name>x</name><id>123456789</id></connection></connections>".data(using: .utf16)!
        let xlsx = Fixtures.xlsx(rows: Fixtures.cleanRows(3))
        let junk = Data("не xml".utf8)
        let wrongRoot = Data("<list><connection><name>x</name><id>123456789</id></connection></list>".utf8)
        for data in [utf16, xlsx, junk, wrongRoot] {
            XCTAssertThrowsError(try XMLConnectionsEditor.add(ConnectionDraft(name: "x", id: "123456789"), to: data))
        }
    }

    // MARK: Запись на диск: .bak, права, атомарность

    func testWriteWithEveryPermissionModeKeepsModeAndMakesBackup() throws {
        for mode in [0o600, 0o640, 0o644, 0o660, 0o400] {
            let url = dir.appendingPathComponent("c\(mode).xml")
            try lf.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            let out = try XMLConnectionsEditor.delete(try records(lf)[0], in: lf)
            try XMLConnectionsEditor.write(out, to: url)
            let bak = URL(fileURLWithPath: url.path + ".bak")
            XCTAssertEqual(try Data(contentsOf: url), out, "\(String(mode, radix: 8))")
            XCTAssertEqual(try Data(contentsOf: bak), lf, ".bak — прежнее содержимое")
            XCTAssertEqual(try perms(url), mode, "права файла после записи")
            XCTAssertEqual(try perms(bak), mode, "права .bak те же")
        }
        // Ничего лишнего: временных файлов нет.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") }, "\(names)")
    }

    func testSecondEditKeepsOnlyPreviousVersionInBackup() throws {
        let url = dir.appendingPathComponent("c.xml")
        try lf.write(to: url)
        let v1 = try XMLConnectionsEditor.add(ConnectionDraft(name: "Один", id: "555666777"), to: lf)
        try XMLConnectionsEditor.write(v1, to: url)
        let v2 = try XMLConnectionsEditor.add(ConnectionDraft(name: "Два", id: "555666778"), to: v1)
        try XMLConnectionsEditor.write(v2, to: url)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + ".bak")), v1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["c.xml", "c.xml.bak"])
    }

    func testFailedWriteLeavesOriginalAndNoGarbage() throws {
        let url = dir.appendingPathComponent("c.xml")
        try lf.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try XMLConnectionsEditor.write(Data("x".utf8), to: url))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try Data(contentsOf: url), lf)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["c.xml"])
    }

    func testBackupIsWrittenBeforeOriginalIsReplacedAndFileNeverHalfWritten() throws {
        // Атомарность: во время записи другой читатель видит либо старый, либо новый файл целиком.
        let url = dir.appendingPathComponent("c.xml")
        let big = try (0..<400).reduce(lf) { try XMLConnectionsEditor.add(ConnectionDraft(name: "Узел \($1)", id: String(100_000_000 + $1)), to: $0) }
        try big.write(to: url)
        let next = try XMLConnectionsEditor.add(ConnectionDraft(name: "Последний", id: "999999999"), to: big)
        let stop = Atomic()
        let bad = Atomic()
        let reader = Thread {
            while !stop.flag {
                if let d = try? Data(contentsOf: url), d != big, d != next { bad.flag = true }
            }
        }
        reader.start()
        for _ in 0..<50 { try XMLConnectionsEditor.write(next, to: url); try XMLConnectionsEditor.write(big, to: url) }
        stop.flag = true
        XCTAssertFalse(bad.flag, "читатель увидел наполовину записанный файл")
    }

    final class Atomic: @unchecked Sendable {
        private let lock = NSLock(); private var v = false
        var flag: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
    }

    // MARK: Правка и список приложения

    func testEditThroughStoreUpdatesListAndPasswordLookup() async throws {
        let url = dir.appendingPathComponent("live.xml")
        try lf.write(to: url)
        let settings = InMemoryConnectionsSettings(filePath: url.path)
        let store = ConnectionsFileStore(settings: settings, logger: nil, retryDelay: 0.01, debounce: 0.05)
        defer { store.stop() }
        store.start()
        try await until { store.state == .ready && store.snapshot.records.count == 5 }
        let target = store.snapshot.records[1]
        var draft = ConnectionDraft(target); draft.name = "Касса (правка)"; draft.password = "Новый-пароль-№2"
        let data = try Data(contentsOf: url)
        try XMLConnectionsEditor.write(try XMLConnectionsEditor.update(target, with: draft, in: data), to: url)
        try await until { store.snapshot.records.contains { $0.name == "Касса (правка)" } }
        XCTAssertEqual(store.snapshot.records.count, 5)
        let edited = store.snapshot.records[1]
        let secret = try await store.password(for: edited)
        XCTAssertEqual(secret.map { $0.withBytes { String(decoding: $0, as: UTF8.self) } }, "Новый-пароль-№2")
        secret?.wipe()
        let other = try await store.password(for: store.snapshot.records[0])
        XCTAssertEqual(other.map { $0.withBytes { String(decoding: $0, as: UTF8.self) } }, "Pw-1-секрет&<>", "чужой пароль не тронут")
        other?.wipe()
        // Правка устаревшей записи (файл поменяли руками) находит запись по ID и имени или честно отказывает.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func until(_ ok: @escaping @MainActor () -> Bool) async throws {
        let end = Date().addingTimeInterval(6)
        while !ok(), Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ok())
    }

    func testStaleRecordAfterManualEditIsFoundOrRejectedNeverWrongRecord() throws {
        let data = lf
        let stale = try records(data)[3]       // «Дубликат», строка файла сдвинется
        let shifted = Data(("<!-- добавили комментарий -->\n<!-- и ещё -->\n" + Self.body.replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n", with: "")).utf8)
        var d = ConnectionDraft(stale); d.group = "Ушла"
        do {
            let out = try XMLConnectionsEditor.update(stale, with: d, in: shifted)
            let r = try rows(out)
            XCTAssertEqual(r.filter { $0.group == "Ушла" }.map(\.name), ["Дубликат"], "правка попала не в ту запись")
        } catch {
            XCTAssertEqual(error as? XMLEditError, .entryNotFound)
        }
        let gone = Data(Self.body.replacingOccurrences(of: "\t<connection><name>Дубликат</name><id>323456789</id><password>Pw-4-секрет</password></connection>\n", with: "").utf8)
        try XCTExpectFailure("ОШИБКА A-4 (rc-acceptance.md): запись пропала, а у соседней тот же ID — правка/удаление уходят в чужую запись") {
            XCTAssertThrowsError(try XMLConnectionsEditor.update(stale, with: d, in: gone)) { XCTAssertEqual($0 as? XMLEditError, .entryNotFound) }
            XCTAssertThrowsError(try XMLConnectionsEditor.delete(stale, in: gone))
        }
    }

    // MARK: Случайные цепочки правок

    private struct Lcg { var s: UInt64; mutating func next(_ n: Int) -> Int { s = s &* 6364136223846793005 &+ 1442695040888963407; return Int((s >> 33) % UInt64(n)) } }

    func testRandomEditChainsMatchAModelAndNeverCorrupt() throws {
        let dup = "<connection><name>Дубликат</name><id>323456789</id><password>Pw-4-секрет</password></connection>"
        for (label, original) in variants() where label != "одна строка" {
            let start = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: dup, with: "").utf8)
            var rng = Lcg(s: 777)
            var data = start
            var model = try rows(start)
            var nextID = 500_000_000
            for n in 0..<150 {
                let recs = try records(data)
                XCTAssertEqual(recs.count, model.count, "\(label) шаг \(n)")
                let op = rng.next(3)
                do {
                    switch op {
                    case 0:
                        nextID += 13
                        let name = ["Узел", "Філія & Ко", "Склад <1>", "Касса\"2\""][rng.next(4)] + " \(n)"
                        let pw = rng.next(2) == 0 ? "Pw-\(n)-]]>-&" : nil
                        let out = try XMLConnectionsEditor.add(ConnectionDraft(name: name, id: String(nextID), group: "Г\(n % 3)", tags: "t\(n % 4)", password: pw), to: data)
                        let a = affix(data, out); XCTAssertEqual(a.prefix + a.suffix, data.count, "\(label) шаг \(n): вставка")
                        data = out
                        model.append(Row(name: name, id: String(nextID), password: pw ?? "", group: "Г\(n % 3)", tags: "t\(n % 4)", note: "", program: nil))
                    case 1 where !recs.isEmpty:
                        let i = rng.next(recs.count)
                        var d = ConnectionDraft(recs[i])
                        d.note = "правка \(n) ]]> &"
                        d.group = "Г\(rng.next(5))"
                        if rng.next(3) == 0 { d.password = "Новый-\(n)" }
                        data = try XMLConnectionsEditor.update(recs[i], with: d, in: data)
                        model[i].note = d.note; model[i].group = d.group
                        if let p = d.password { model[i].password = p }
                    case 2 where !recs.isEmpty:
                        let i = rng.next(recs.count)
                        data = try XMLConnectionsEditor.delete(recs[i], in: data)
                        model.remove(at: i)
                    default: continue
                    }
                } catch {
                    XCTFail("\(label) шаг \(n) операция \(op): \(error); записей \(recs.count)")
                    break
                }
                let got = try rows(data)
                XCTAssertEqual(got.map { [$0.name, $0.id, $0.password, $0.group] }, model.map { [$0.name, $0.id, $0.password, $0.group] }, "\(label) шаг \(n)")
                XCTAssertEqual(got.map { collapsed($0.note) }, model.map { collapsed($0.note) }, "\(label) шаг \(n) заметки")
            }
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<!--") || label == "одна строка", label)
        }
    }

    // MARK: Найденные ошибки (ожидаемые падения; когда Connection исправит — XCTExpectFailure начнёт падать, убрать)

    func testAddToSingleLineXMLWorks() throws {
        XCTExpectFailure("ОШИБКА A-4 (rc-acceptance.md): add в XML из одной строки вставляет запись после </connections> и бросает corrupt")
        let out = try XMLConnectionsEditor.add(ConnectionDraft(name: "Новый", id: "555666777"), to: oneLine)
        XCTAssertEqual(try records(out).count, 6)
    }

    func testSameLineDuplicateIDEditsTheRightRecord() throws {
        let data = oneLine
        let second = try records(data)[3]
        XCTAssertEqual(second.name, "Дубликат")
        var d = ConnectionDraft(second); d.group = "Правка"
        XCTExpectFailure("ОШИБКА A-4 (rc-acceptance.md): две записи на одной строке с одним ID — правится первая, не выбранная")
        let out = try XMLConnectionsEditor.update(second, with: d, in: data)
        let r = try rows(out)
        XCTAssertEqual(r[2], try rows(data)[2], "правка не должна менять соседнюю запись с тем же ID")
        XCTAssertEqual(r[3].group, "Правка")
    }

    func testAddWithCommentAfterRootGoesIntoRoot() throws {
        let data = Data("<connections>\n  <connection><name>a</name><id>123456789</id></connection>\n</connections>\n<!-- конец </x> -->\n".utf8)
        let out = try? XMLConnectionsEditor.add(ConnectionDraft(name: "Новый", id: "555666777"), to: data)
        XCTAssertEqual(try out.map { try records($0).map(\.name) }, ["a", "Новый"], "запись должна читаться из файла, а не уйти в комментарий")
    }

    func testPasswordWithEdgeSpacesSurvivesRoundTrip() throws {
        let data = lf
        let record = try records(data)[0]
        var d = ConnectionDraft(record); d.password = " внутри пробелы "
        let out = try XMLConnectionsEditor.update(record, with: d, in: data)
        XCTExpectFailure("ОШИБКА A-4 (rc-acceptance.md, оба клиента): пароль читается с обрезкой пробелов по краям") {
            XCTAssertEqual(try? rows(out)[0].password, " внутри пробелы ", "пробелы по краям пароля сохраняются")
        }
    }

    // MARK: Шаблоны

    func testTemplatesWrittenToDiskReadBackCleanInEveryLanguageAndStayPrivate() throws {
        defer { RemoteL10n.language = .ru }
        for language in RemoteLanguage.allCases {
            RemoteL10n.language = language
            for (ext, data) in [("xlsx", ConnectionsTemplate.xlsx()), ("xml", ConnectionsTemplate.xml())] {
                let url = dir.appendingPathComponent("tpl-\(language.rawValue).\(ext)")
                try data.write(to: url)
                try ConnectionsFilePermissions.restrict(url)
                XCTAssertFalse(ConnectionsFilePermissions.isShared(url))
                XCTAssertEqual(try perms(url), 0o600)
                let snap = try ConnectionsFileStore.read(url: url, sheet: nil)
                XCTAssertTrue(snap.diagnostics.isClean, "\(language.rawValue) \(ext): \(snap.diagnostics)")
                XCTAssertEqual(snap.records.count, 1)
                XCTAssertEqual(snap.records[0].id, "123456789")
                XCTAssertEqual(snap.records[0].program, .anyDesk)
                XCTAssertFalse(snap.records[0].hasPassword, "в шаблоне пароля нет")
                XCTAssertEqual(Set(snap.diagnostics.columns.map(\.field)), Set(ConnectionField.allCases))
            }
        }
    }

    func testTemplateXMLIsEditableAndTemplateXLSXIsAValidPackage() throws {
        let xml = ConnectionsTemplate.xml()
        let example = try records(xml)[0]
        var out = try XMLConnectionsEditor.add(ConnectionDraft(name: "Моё", id: "222333444", password: "Pw-мой"), to: xml)
        out = try XMLConnectionsEditor.delete(example, in: out)
        XCTAssertEqual(try records(out).map(\.name), ["Моё"])
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("<!-- Mac Utils:"), "подсказка в шаблоне осталась")
        // XLSX: настоящий zip с обязательными частями, XML частей корректен.
        let path = dir.appendingPathComponent("t.xlsx")
        try ConnectionsTemplate.xlsx().write(to: path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", path.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        for part in ["[Content_Types].xml", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "_rels/.rels"] {
            let q = Process(); q.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); q.arguments = ["-p", path.path, part.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")]
            let o = Pipe(); q.standardOutput = o; q.standardError = Pipe()
            try q.run()
            let xml = o.fileHandleForReading.readDataToEndOfFile()
            q.waitUntilExit()
            XCTAssertEqual(q.terminationStatus, 0, "нет части \(part)")
            let parser = XMLParser(data: xml)
            XCTAssertTrue(parser.parse(), "\(part): \(String(describing: parser.parserError))")
        }
    }

    func testSharedFileWarningFollowsGroupAndWorldBits() throws {
        let url = dir.appendingPathComponent("p.xml")
        try lf.write(to: url)
        for (mode, shared) in [(0o600, false), (0o400, false), (0o640, true), (0o604, true), (0o644, true), (0o660, true), (0o700, false)] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            XCTAssertEqual(ConnectionsFilePermissions.isShared(url), shared, String(mode, radix: 8))
        }
        XCTAssertFalse(ConnectionsFilePermissions.isShared(dir.appendingPathComponent("нет.xml")))
    }

    func testEditorNeverTouchesXLSXFiles() throws {
        let url = dir.appendingPathComponent("never.xlsx")
        let data = Fixtures.xlsx(rows: Fixtures.cleanRows(5))
        try data.write(to: url)
        XCTAssertThrowsError(try XMLConnectionsEditor.add(ConnectionDraft(name: "x", id: "123456789"), to: data))
        XCTAssertThrowsError(try XMLConnectionsEditor.delete(try XLSXSource().load(data).records[0], in: data))
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["never.xlsx"])
    }
}

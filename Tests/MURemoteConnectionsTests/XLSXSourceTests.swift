@testable import MURemoteConnections
import XCTest

final class XLSXSourceTests: XCTestCase {
    func testCellKindsAndGaps() throws {
        let sheet = Fixtures.Sheet(name: "Лист1", rows: [
            [.text("Name"), .empty, .inline("ID"), .text("Note")],
            [.inline("Склад Південь"), .empty, .number("123456789"), .formula("через VPN")],
            [.text("Касса 2"), .empty, .number("1.23456789E+08"), .empty],
        ], firstRow: 3)
        let snap = try XLSXSource().load(Fixtures.xlsx([sheet]))
        XCTAssertEqual(snap.records.map(\.name), ["Склад Південь", "Касса 2"])
        XCTAssertEqual(snap.records.map(\.id), ["123456789", "123456789"])
        XCTAssertEqual(snap.records.map(\.sourceRow), [4, 5])
        XCTAssertEqual(snap.records[0].note, "через VPN")
    }

    func testRichTextAndPhoneticSharedStrings() throws {
        // Общая строка из нескольких кусков с фонетикой: фонетика не попадает в текст.
        var zip = ZipWriter()
        zip.add("xl/workbook.xml", Data(#"<workbook xmlns:r="r"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>"#.utf8))
        zip.add("xl/_rels/workbook.xml.rels", Data(#"<Relationships><Relationship Id="rId1" Target="worksheets/a.xml"/></Relationships>"#.utf8))
        zip.add("xl/sharedStrings.xml", Data("""
            <sst><si><t>Name</t></si><si><t>ID</t></si>\
            <si><r><rPr><b/></rPr><t>Лаборатория </t></r><r><t>Север</t></r><rPh><t>ignored</t></rPh></si></sst>
            """.utf8))
        zip.add("xl/worksheets/a.xml", Data("""
            <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>\
            <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>123456789</v></c></row></sheetData></worksheet>
            """.utf8))
        let snap = try XLSXSource().load(zip.finish())
        XCTAssertEqual(snap.records.first?.name, "Лаборатория Север")
    }

    func testSheetSelectionAndNames() throws {
        let data = Fixtures.xlsx([
            Fixtures.Sheet(name: "Справка", rows: [[.text("Это не таблица")]]),
            Fixtures.Sheet(name: "Клиенты & партнёры", rows: [[.text("Name"), .text("ID")], [.text("A"), .number("123456789")]]),
        ], absoluteTargets: true)
        XCTAssertEqual(try XLSXSource.sheetNames(in: data), ["Справка", "Клиенты & партнёры"])
        XCTAssertEqual(try XLSXSource(sheet: "Клиенты & партнёры").load(data).records.count, 1)
        XCTAssertThrowsError(try XLSXSource().load(data)) {
            XCTAssertEqual($0 as? ConnectionsError, .missingColumns(found: ["Это не таблица"]))
        }
        XCTAssertThrowsError(try XLSXSource(sheet: "Нет такого").load(data)) {
            XCTAssertEqual($0 as? ConnectionsError, .noSheet("Нет такого"))
        }
    }

    func testStoredAndDeflatedArchives() throws {
        let rows = Fixtures.cleanRows(50)
        for compress in [true, false] {
            let data = Fixtures.xlsx([Fixtures.Sheet(name: "S", rows: rows.map { $0.map(Fixtures.cell) })], compress: compress)
            XCTAssertEqual(try XLSXSource().load(data).records.count, 50)
        }
    }

    func testCorruptFiles() {
        let good = Fixtures.xlsx(rows: Fixtures.cleanRows(5))
        let cases: [(String, Data)] = [
            ("пусто", Data()),
            ("не zip", Data("Name;ID\nA;123456789".utf8)),
            ("обрезан", good.prefix(good.count / 2)),
            ("без книги", { var z = ZipWriter(); z.add("a.txt", Data("x".utf8)); return z.finish() }()),
        ]
        for (label, data) in cases {
            XCTAssertThrowsError(try XLSXSource().load(data), label) { error in
                guard case .corrupt = error as? ConnectionsError else { return XCTFail("\(label): \(error)") }
            }
        }
    }

    func testEncryptedEntryIsRejected() {
        var data = Fixtures.xlsx(rows: Fixtures.cleanRows(2))
        // Взвести бит шифрования у всех записей центрального каталога.
        let bytes = [UInt8](data)
        for i in 0..<(bytes.count - 4) where bytes[i] == 0x50 && bytes[i + 1] == 0x4b && bytes[i + 2] == 1 && bytes[i + 3] == 2 {
            data[i + 8] |= 1
        }
        XCTAssertThrowsError(try XLSXSource().load(data)) { error in
            XCTAssertEqual(error as? ConnectionsError, .corrupt("Файл защищён паролем"))
        }
    }

    /// Свой ZIP-писатель (пригодится шаблону .xlsx) даёт архив, который принимает системный unzip.
    func testZipWriterOutputIsValidZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.xlsx")
        try Fixtures.xlsx(rows: Fixtures.cleanRows(20)).write(to: file)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testColumnIndex() {
        XCTAssertEqual(Fixtures.column(0), "A")
        XCTAssertEqual(Fixtures.column(27), "AB")
    }
}

/// Проверка на настоящем файле из Excel или другой программы — только по явной просьбе:
///   MU_RC_XLSX=/путь/к/файлу.xlsx [MU_RC_SHEET=Лист] swift test --filter ExternalWorkbookTests
/// Печатает только числа диагностики, без содержимого файла.
final class ExternalWorkbookTests: XCTestCase {
    func testExternalWorkbook() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MU_RC_XLSX"] else { throw XCTSkip("MU_RC_XLSX не задан") }
        let url = URL(fileURLWithPath: path)
        let sheets = try ConnectionsFileStore.sheetNames(url: url)
        let snap = try ConnectionsFileStore.read(url: url, sheet: env["MU_RC_SHEET"])
        let d = snap.diagnostics
        print("sheets=\(sheets.count) loaded=\(d.loaded) withPassword=\(d.withPassword) skipped=\(d.skipped.count) "
            + "duplicates=\(d.duplicateCount) unrecognized=\(d.unrecognizedColumns.count) lossy=\(d.lossyIDRows.count) "
            + "columns=\(d.columns.map(\.field.rawValue).joined(separator: ","))")
        XCTAssertGreaterThan(d.loaded, 0)
    }
}

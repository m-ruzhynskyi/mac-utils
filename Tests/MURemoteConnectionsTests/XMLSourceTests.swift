@testable import MURemoteConnections
import XCTest

final class XMLSourceTests: XCTestCase {
    func testElementsAttributesAndLineNumbers() throws {
        let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <connections>
              <connection>
                <name>Лаборатория Север</name><id>123 456 789</id><password><![CDATA[p<&>]]></password>
                <group>Клиенты</group><tags>касса; ночь</tags><note>звонить &amp; ждать</note><app>AnyDesk</app>
              </connection>
              <connection name="Склад Південь" id="office@ad" Пароль="x"/>
              <connection><Назва>Офис</Назва><Ідентифікатор>223456789</Ідентифікатор><color>red</color></connection>
            </connections>
            """
        let snap = try XMLSource().load(Data(xml.utf8))
        XCTAssertEqual(snap.records, [
            ConnectionRecord(sourceRow: 3, name: "Лаборатория Север", id: "123456789", group: "Клиенты",
                             tags: ["касса", "ночь"], note: "звонить & ждать", program: .anyDesk, hasPassword: true),
            ConnectionRecord(sourceRow: 7, name: "Склад Південь", id: "office@ad", hasPassword: true),
            ConnectionRecord(sourceRow: 8, name: "Офис", id: "223456789"),
        ])
        XCTAssertEqual(snap.diagnostics.unrecognizedColumns, ["color"])
    }

    func testMessyFileMatchesXLSX() throws {
        let rows = Fixtures.messyRows()
        let xml = try XMLSource().load(Fixtures.xml(rows: rows))
        let xlsx = try XLSXSource().load(Fixtures.xlsx(rows: rows))
        XCTAssertEqual(xml.records.map(\.id), xlsx.records.map(\.id))
        XCTAssertEqual(xml.diagnostics.skipped.map(\.reason), xlsx.diagnostics.skipped.map(\.reason))
        XCTAssertEqual(xml.diagnostics.duplicateCount, 1)
        XCTAssertEqual(xml.diagnostics.lossyIDRows.count, 1)
    }

    func testCorrupt() {
        for (label, xml) in [("не xml", "Name;ID"), ("обрезан", "<connections><connection><name>a"),
                             ("другой корень", "<hosts><host/></hosts>")] {
            XCTAssertThrowsError(try XMLSource().load(Data(xml.utf8)), label) { error in
                guard case .corrupt = error as? ConnectionsError else { return XCTFail("\(label): \(error)") }
            }
        }
    }

    func testExternalEntitiesAreNotResolved() throws {
        let xml = """
            <?xml version="1.0"?>
            <!DOCTYPE connections [<!ENTITY x SYSTEM "file:///etc/hosts">]>
            <connections><connection><name>&x;A</name><id>123456789</id></connection></connections>
            """
        let snap = try? XMLSource().load(Data(xml.utf8))
        XCTAssertFalse(snap?.records.first?.name.contains("localhost") ?? false)
    }

    func testEmptyFile() throws {
        let snap = try XMLSource().load(Data("<connections/>".utf8))
        XCTAssertEqual(snap.records, [])
        XCTAssertTrue(snap.diagnostics.isClean)
    }
}

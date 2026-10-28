@testable import MURemoteConnections
import XCTest

/// 1000+ строк — не дольше секунды (ТЗ); 5000 — для запаса, порог мягче (отладочная сборка на CI).
final class PerformanceTests: XCTestCase {
    private func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now()
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }

    func testThousandRowsXLSXUnderOneSecond() throws {
        for count in [1_000, 5_000] {
            let data = Fixtures.xlsx(rows: Fixtures.cleanRows(count))
            var snap: ConnectionsSnapshot?
            let t = try seconds { snap = try XLSXSource().load(data) }
            XCTAssertEqual(snap?.records.count, count)
            XCTAssertLessThan(t, count <= 1_000 ? 1.0 : 3.0, "\(count) строк xlsx: \(t) с")
        }
    }

    func testThousandRowsXMLUnderOneSecond() throws {
        for count in [1_000, 5_000] {
            let data = Fixtures.xml(rows: Fixtures.cleanRows(count))
            var snap: ConnectionsSnapshot?
            let t = try seconds { snap = try XMLSource().load(data) }
            XCTAssertEqual(snap?.records.count, count)
            XCTAssertLessThan(t, count <= 1_000 ? 1.0 : 3.0, "\(count) строк xml: \(t) с")
        }
    }

    func testPasswordLookupInThousandRowsUnderOneSecond() throws {
        let data = Fixtures.xlsx(rows: Fixtures.cleanRows(1_000))
        let record = try XLSXSource().load(data).records[777]
        var secret: SecretBuffer?
        let t = try seconds { secret = try XLSXSource().password(for: record, in: data) }
        XCTAssertNotNil(secret)
        XCTAssertLessThan(t, 1.0)
    }
}

@testable import MURemoteConnections
import XCTest

final class ConnectionIDTests: XCTestCase {
    private func norm(_ s: String) -> String? { ConnectionID.normalize(s)?.value }

    func testPlainDigits() {
        XCTAssertEqual(norm("123456789"), "123456789")
        XCTAssertEqual(norm("1234567890"), "1234567890")
        XCTAssertEqual(norm("0123456789"), "0123456789", "ноль слева у текста — часть ID")
    }

    func testSpacesAndInvisibleCharacters() {
        XCTAssertEqual(norm("123 456 789"), "123456789")
        XCTAssertEqual(norm(" 123\u{00A0}456\u{202F}789 "), "123456789")
        XCTAssertEqual(norm("\u{FEFF}123\u{200B}456789\n"), "123456789")
    }

    func testNumberFormsFromExcel() {
        XCTAssertEqual(norm("123456789.0"), "123456789")
        XCTAssertEqual(norm("123456789.000"), "123456789")
        XCTAssertEqual(norm("1.23456789E+08"), "123456789")
        XCTAssertEqual(norm("1.23456789e8"), "123456789")
        XCTAssertEqual(norm("1,23456789E+08"), "123456789")
        XCTAssertEqual(norm("1.234567891E+09"), "1234567891")
        XCTAssertFalse(ConnectionID.normalize("1.23456789E+08")!.lossy)
    }

    func testLossyExponent() {
        let n = ConnectionID.normalize("1.23E+08")
        XCTAssertEqual(n?.value, "123000000")
        XCTAssertEqual(n?.lossy, true)
    }

    func testInvalid() {
        for bad in ["", "   ", "12345", "12345678901", "123456789.5", "abc", "12a456789", "1.2.3", "1E+40",
                    "-123456789", "+123456789", "123-456-789", "@ad", "name@", "a@b@c", "имя@ad", "a b@c d@e"] {
            XCTAssertNil(norm(bad), bad)
        }
    }

    func testAliases() {
        XCTAssertEqual(norm("Office@AD"), "office@ad")
        XCTAssertEqual(norm("front-desk.2@company"), "front-desk.2@company")
        XCTAssertEqual(norm(" office @ ad "), "office@ad")
        XCTAssertTrue(ConnectionID.normalize("office@ad")!.isAlias)
    }
}

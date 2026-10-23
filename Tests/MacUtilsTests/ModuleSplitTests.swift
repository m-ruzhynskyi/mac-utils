import XCTest
@testable import MacUtils
@testable import MUCore

/// Границы модулей: то, что MUCore знает о типах приложения только по значению, не должно разойтись с самими типами.
final class ModuleSplitTests: XCTestCase {
    func testEditorDefaultsMatchTypes() {
        XCTAssertEqual(TextEncoding.utf8.rawValue, "utf8")
        XCTAssertEqual(LineEnding.lf.rawValue, "lf")
    }
}

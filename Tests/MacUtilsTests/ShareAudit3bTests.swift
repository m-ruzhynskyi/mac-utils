import XCTest
@testable import MacUtils

@MainActor
final class ShareAudit3bTests: XCTestCase {
    /// B5: при откате подписи (раньше подписывал, теперь нет) текст тот же, что на странице relay; при неверной подписи — общий.
    func testSignatureFailureTexts() {
        XCTAssertEqual(ShareViewer.signatureFailureText(downgrade: true), "Ведущий раньше подписывал принятие, а теперь нет: подключение отменено")
        XCTAssertEqual(ShareViewer.signatureFailureText(downgrade: false), "Подпись ведущего не сошлась: подключение отменено")
    }
}

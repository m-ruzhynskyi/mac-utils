@testable import MacUtils
import MURemoteConnections
import XCTest

/// Приёмка карточки v2, слой приложения: звонок идёт только через двойник, UniTalk не запускается, буфер и HUD подменены.
@MainActor
final class CardV2AcceptanceAppTests: XCTestCase {
    private final class FakeDialer: RemoteDialer {
        var installed: Bool
        var asked: [String] = []
        var opened: [(url: URL, app: URL)] = []
        init(installed: Bool) { self.installed = installed }
        func appURL(bundleID: String) -> URL? {
            asked.append(bundleID)
            return installed ? URL(fileURLWithPath: "/Fake/UniTalk.app") : nil
        }
        func open(_ url: URL, withApplicationAt app: URL) { opened.append((url, app)) }
    }

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "mu-rc-card-accept-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeCenter(_ dialer: FakeDialer) -> (RemoteConnectionsCenter, copied: () -> [String], huds: () -> [String]) {
        let center = RemoteConnectionsCenter(defaults: defaults)
        var copied: [String] = []
        var huds: [String] = []
        center.dialer = dialer
        center.writePlain = { copied.append($0) }
        center.showHUD = { huds.append($0.title) }
        return (center, { copied }, { huds })
    }

    /// UniTalk есть: открывается tel:+380… именно в нём, нормализованный номер, буфер не трогается.
    func testCallGoesOnlyThroughUniTalkDouble() {
        let dialer = FakeDialer(installed: true)
        let (center, copied, huds) = makeCenter(dialer)
        let plan = center.call("(050) 000-00-01")
        XCTAssertEqual(plan, .call(URL(string: "tel:+380500000001")!))
        XCTAssertEqual(dialer.asked, ["com.unitalk.desktop"], "ищется только UniTalk, обработчик tel: по умолчанию не запрашивается")
        XCTAssertEqual(dialer.opened.count, 1)
        XCTAssertEqual(dialer.opened.first?.url.absoluteString, "tel:+380500000001")
        XCTAssertEqual(dialer.opened.first?.app.lastPathComponent, "UniTalk.app")
        XCTAssertTrue(copied().isEmpty)
        XCTAssertTrue(huds().isEmpty, "успешный вызов без HUD «скопирован»")
    }

    /// UniTalk нет: ничего не открывается, номер копируется как в файле, HUD говорит «UniTalk не найден — номер скопирован».
    func testNoUniTalkCopiesNumberAndSaysSo() {
        let dialer = FakeDialer(installed: false)
        let (center, copied, huds) = makeCenter(dialer)
        let plan = center.call("050 000 00 01")
        XCTAssertEqual(plan, .copy("050 000 00 01", reason: .noUniTalk))
        XCTAssertTrue(dialer.opened.isEmpty, "без UniTalk звонка нет")
        XCTAssertEqual(copied(), ["050 000 00 01"])
        XCTAssertEqual(huds(), [RL("UniTalk не найден — номер скопирован")])
    }

    /// Не номер: копирование и нейтральный HUD, даже если UniTalk установлен.
    func testNonNumberIsCopiedNotDialed() {
        let dialer = FakeDialer(installed: true)
        let (center, copied, huds) = makeCenter(dialer)
        XCTAssertEqual(center.call("доб. 12"), .copy("доб. 12", reason: .notANumber))
        XCTAssertTrue(dialer.opened.isEmpty)
        XCTAssertEqual(copied(), ["доб. 12"])
        XCTAssertEqual(huds(), [RL("Номер скопирован")])
    }

    /// Серия звонков: каждый уходит в двойник отдельным вызовом, ничего не накапливается и не звонит реально.
    func testSeveralCallsAreIndependent() {
        let dialer = FakeDialer(installed: true)
        let (center, copied, _) = makeCenter(dialer)
        _ = center.call("067 000 00 02")
        _ = center.call("+380 93 000 00 03")
        XCTAssertEqual(dialer.opened.map(\.url.absoluteString), ["tel:+380670000002", "tel:+380930000003"])
        XCTAssertTrue(copied().isEmpty)
    }
}

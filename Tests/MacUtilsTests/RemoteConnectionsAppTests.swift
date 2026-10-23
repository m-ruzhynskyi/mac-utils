@testable import MacUtils
import MURemoteConnections
import XCTest

/// Тонкий слой приложения над MURemoteConnections: адаптер настроек и вкладка панели.
/// Логика модуля проверяется в MURemoteConnectionsTests.
@MainActor
final class RemoteConnectionsAppTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "mu-rc-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testStoreKeepsOnlyPathSheetAndIDs() {
        let store = DefaultsRemoteStore(defaults: defaults)
        store.filePath = "/tmp/c.xlsx"
        store.sheetName = "Лист"
        let record = ConnectionRecord(sourceRow: 2, name: "Лаборатория Север", id: "123456789", hasPassword: true)
        ConnectionLists.toggleFavorite(record, in: store)
        ConnectionLists.noteConnected(record, in: store)
        XCTAssertEqual(store.favoriteIDs, ["123456789"])
        XCTAssertEqual(store.recentIDs, ["123456789"])
        store.sheetName = nil
        XCTAssertNil(defaults.object(forKey: RemotePref.sheet))
        let keys = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
        XCTAssertEqual(keys, [RemotePref.filePath, RemotePref.favorites, RemotePref.recents])
        XCTAssertFalse("\(defaults.persistentDomain(forName: suite) ?? [:])".contains("Лаборатория"), "имён в настройках нет")
    }

    func testPanelTabAddedOnceAfterEditor() {
        defaults.set("music,textEditor,uninstaller", forKey: Pref.toolsPanelTabs)
        RemoteConnectionsCenter.addPanelTabOnce(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: Pref.toolsPanelTabs), "music,textEditor,remote,uninstaller")
        // Пользователь убрал вкладку — второй раз не возвращаем.
        defaults.set("music,textEditor", forKey: Pref.toolsPanelTabs)
        RemoteConnectionsCenter.addPanelTabOnce(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: Pref.toolsPanelTabs), "music,textEditor")
        XCTAssertTrue(PanelTabs.available.contains(.remote))
    }

    func testCenterReadsChosenFileWithoutTouchingStandardDefaults() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.xml")
        try Data("""
            <connections><connection><name>Касса 2</name><id>123 456 789</id><password>p</password><app>TeamViewer</app></connection>
            <connection><name>Склад</name><id>223456789</id></connection></connections>
            """.utf8).write(to: url)
        let center = RemoteConnectionsCenter(defaults: defaults)
        center.setFile(url)
        let deadline = Date().addingTimeInterval(5)
        while center.state != .ready, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(center.state, .ready)
        XCTAssertEqual(center.snapshot.records.map(\.name), ["Касса 2", "Склад"])
        center.defaultProgram = .teamViewer
        let listing = center.listing(query: "", filter: .program(.teamViewer))
        XCTAssertEqual(listing.rows.count, 2, "без программы — по умолчанию TeamViewer")
        XCTAssertEqual(center.listing(query: "crkfl", filter: .all).hint?.converted, "склад")
        center.toggleFavorite(center.snapshot.records[1])
        XCTAssertTrue(center.isFavorite(center.snapshot.records[1]))
        XCTAssertEqual(defaults.string(forKey: RemotePref.filePath), url.path)
        center.setFile(nil)
    }

    func testDefaultHotKeyIsFree() {
        let combo = HotKeyAction.remoteConnections.defaultCombo
        XCTAssertNil(HotKeyConflicts.system(combo))
        XCTAssertEqual(HotKeyAction.allCases.filter { $0.defaultCombo == combo }, [.remoteConnections])
        XCTAssertFalse(WindowTiler.bindings.contains { $0.keyCode == combo.keyCode }, "раскладка окон с ⌥⌘ не занимает A")
        XCTAssertEqual(AppAction(hotKey: .remoteConnections), .remoteConnections)
    }
}

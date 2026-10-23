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
        center.defaultProgramSetting = .teamViewer
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
    func testConnectionSettingsDefaults() {
        let center = RemoteConnectionsCenter(defaults: defaults)
        XCTAssertNil(center.defaultProgramSetting, "по умолчанию: AnyDesk, а если в файле обе программы — спросить")
        XCTAssertEqual(center.defaultProgram, .anyDesk)
        XCTAssertFalse(center.autologin)
        XCTAssertEqual(center.timeoutSeconds, 20)
        center.timeoutSeconds = 500
        XCTAssertEqual(center.timeoutSeconds, 60)
        center.timeoutSeconds = 1
        XCTAssertEqual(center.timeoutSeconds, 5)
        center.defaultProgramSetting = .teamViewer
        center.defaultProgramSetting = nil
        XCTAssertNil(defaults.object(forKey: RemotePref.defaultProgram))
    }

    /// HUD (m06/m07): каждая фаза и ошибка — свой текст и кнопки, имя и ID записи, пароля нет и взяться неоткуда.
    func testHUDTextsFollowDesign() {
        let record = ConnectionRecord(sourceRow: 2, name: "Лаборатория Север", id: "123456789", hasPassword: true)
        func hud(_ phase: ConnectionPhase, _ program: RemoteProgram = .anyDesk) -> RemoteHUDContent {
            RemoteHUDContent.make(phase, program: program, record: record)
        }
        XCTAssertEqual(hud(.opening).title, "Открываю AnyDesk…")
        XCTAssertEqual(hud(.opening).detail, "Лаборатория Север · 123 456 789")
        let waiting = hud(.waiting(elapsed: 7, timeout: 20))
        XCTAssertEqual(waiting.title, "Жду окно пароля… 7 с")
        XCTAssertEqual(waiting.progress, 0.35)
        XCTAssertEqual(waiting.actions, [.cancel])
        XCTAssertFalse(waiting.fadesOut)
        XCTAssertEqual(hud(.waiting(elapsed: 7, timeout: 20), .teamViewer).title, "Жду окно аутентификации… 7 с")
        XCTAssertFalse(hud(.entered).fadesOut, "«Пароль введён» висит до ответа программы")
        XCTAssertTrue(hud(.finished(.connected)).fadesOut)
        XCTAssertEqual(hud(.finished(.connected)).lifetime, 2.5)
        XCTAssertEqual(hud(.finished(.connectedWithoutPassword)).title, "Подключено без пароля")

        let errors: [(ConnectionFailure, String, [RemoteHUDAction])] = [
            (.noAccessibility, "AnyDesk открыт, пароль не введён", [.openAccessibility, .close]),
            (.notInstalled, "AnyDesk не найден", [.download, .close]),
            (.fieldNotFound(structure: ["AXWindow"]), "Введите пароль вручную", [.diagnostics, .close]),
            (.wrongPassword, "Проверьте пароль в файле", [.openFile, .close]),
            (.focusLost, "Ввод прерван", [.retry, .close]),
            (.entryGone, "Записи больше нет в файле", [.close]),
            (.programNotSpecified, "Программа не указана", [.choose(.anyDesk), .choose(.teamViewer)]),
            (.launchFailed, "AnyDesk не запустился", [.retry, .close]),
            (.aliasNotSupported, "AnyDesk не открывает алиасы", [.openFile, .close]),
            (.fileUnavailable(.locked), "Файл подключений не прочитан", [.retry, .close]),
        ]
        for (failure, title, actions) in errors {
            let c = hud(.finished(.failed(failure)))
            XCTAssertEqual(c.title, title)
            XCTAssertEqual(c.actions, actions, title)
            XCTAssertEqual(c.lifetime, 12, title)
            XCTAssertNotEqual(c.tone, .success, title)
        }
        XCTAssertEqual(hud(.finished(.failed(.wrongPassword)), .teamViewer).detail, "TeamViewer отклонил пароль для «Лаборатория Север».")
        XCTAssertEqual(RemoteHUDAction.download.title(.teamViewer), "Скачать TeamViewer")
    }
    /// Правка .xml через центр: запись меняется в файле, рядом — .bak с теми же правами, список перечитан.
    func testCenterEditsXMLWithBackup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("c.xml")
        let original = """
            <connections>
              <!-- офис -->
              <connection><name>Касса 2</name><id>123456789</id><password>p</password></connection>
            </connections>

            """
        try Data(original.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let center = RemoteConnectionsCenter(defaults: defaults)
        center.setFile(url)
        func wait(_ count: Int) async throws {
            let deadline = Date().addingTimeInterval(5)
            while center.snapshot.records.count != count || center.state != .ready, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try await wait(1)
        XCTAssertTrue(center.canEdit)
        try center.save(ConnectionDraft(name: "Склад", id: "223 456 789", program: .teamViewer, password: "PWD-CANARY-7"), replacing: nil)
        try await wait(2)
        XCTAssertEqual(center.snapshot.records.map(\.name), ["Касса 2", "Склад"])
        let bak = dir.appendingPathComponent("c.xml.bak")
        XCTAssertEqual(try String(contentsOf: bak, encoding: .utf8), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: bak.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let cash = center.snapshot.records[0]
        center.toggleFavorite(cash)
        try center.delete(cash)
        try await wait(1)
        XCTAssertEqual(center.snapshot.records.map(\.name), ["Склад"])
        XCTAssertFalse(center.isFavorite(cash), "из избранного убрана")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<!-- офис -->"), "чужие байты на месте")
        XCTAssertFalse("\(defaults.persistentDomain(forName: suite) ?? [:])".contains("PWD-CANARY"), "пароль в настройки не попал")
        center.setFile(nil)
        XCTAssertFalse(center.canEdit)
    }

    func testLanguageAndNotifySettings() {
        let center = RemoteConnectionsCenter(defaults: defaults)
        defer { center.language = .ru }
        XCTAssertEqual(center.language, .ru)
        XCTAssertTrue(center.notifySuccess)
        center.language = .uk
        XCTAssertEqual(RemoteHUDContent.make(.opening, program: .anyDesk,
                                             record: ConnectionRecord(sourceRow: 1, name: "a", id: "123456789")).title,
                       "Відкриваю AnyDesk…")
        XCTAssertEqual(RemoteConnectionsCenter(defaults: defaults).language, .uk, "язык запоминается")
        center.notifySuccess = false
        XCTAssertFalse(RemoteConnectionsCenter(defaults: defaults).notifySuccess)
    }
}

@testable import MacUtils
import Carbon.HIToolbox
import MURemoteConnections
import SwiftUI
import XCTest
import MUCore
import MUDesign
@testable import MUWindowSnap
@testable import MUTextEditor

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

    /// ⌃⌥⌘A: ⌥⌘A занята в Finder («Снять выделение»). Сочетание не занято другими действиями Mac Utils,
    /// раскладкой окон (у неё всегда два модификатора) и системой.
    func testDefaultHotKeyIsFree() {
        let combo = HotKeyAction.remoteConnections.defaultCombo
        XCTAssertEqual(combo, LayoutHotKey(keyCode: kVK_ANSI_A, modifiers: cmdKey | optionKey | controlKey))
        XCTAssertNil(HotKeyConflicts.system(combo))
        XCTAssertEqual(HotKeyAction.allCases.filter { $0.defaultCombo == combo }, [.remoteConnections])
        for modifier in WindowSnapModifier.allCases {
            XCTAssertNotEqual(modifier.carbon, combo.modifiers, "раскладка окон: \(modifier)")
        }
        XCTAssertEqual(AppAction(hotKey: .remoteConnections), .remoteConnections)
    }

    /// Клавиша регистрируется, только когда выбран файл подключений.
    func testHotKeyOnlyWithFile() {
        XCTAssertFalse(RemoteConnectionsCenter.hasFile(defaults: defaults))
        defaults.set("", forKey: RemotePref.filePath)
        XCTAssertFalse(RemoteConnectionsCenter.hasFile(defaults: defaults))
        DefaultsRemoteStore(defaults: defaults).filePath = "/tmp/c.xlsx"
        XCTAssertTrue(RemoteConnectionsCenter.hasFile(defaults: defaults))
        DefaultsRemoteStore(defaults: defaults).filePath = nil
        XCTAssertFalse(RemoteConnectionsCenter.hasFile(defaults: defaults))
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
            (.untrustedProgram, "Подпись AnyDesk не подтверждена", [.download, .close]),
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
    /// Промежуточные окна и «не подтверждено» (task-rc-terminal-session): нейтральные, без галочки.
    func testHUDIntermediateAndUnconfirmedAreNeutral() {
        let record = ConnectionRecord(sourceRow: 2, name: "Лаборатория Север", id: "123456789", hasPassword: true)
        func hud(_ phase: ConnectionPhase, _ program: RemoteProgram = .anyDesk) -> RemoteHUDContent {
            RemoteHUDContent.make(phase, program: program, record: record)
        }
        XCTAssertEqual(hud(.intermediate(.sessionChoice)).title, "Выбираю сеанс в AnyDesk…")
        XCTAssertEqual(hud(.intermediate(.sessionChoice)).detail, "Пароль введу после")
        XCTAssertEqual(hud(.intermediate(.unknown)).detail, "Ответьте в окне AnyDesk — пароль введу после")
        XCTAssertEqual(hud(.typingID, .teamViewer).title, "Ввожу ID в TeamViewer…")
        XCTAssertEqual(hud(.intermediate(.chooseConsole)).title, "Выберите Console и нажмите Connect")
        XCTAssertEqual(hud(.intermediate(.chooseConsole)).detail, "В окне AnyDesk «Terminal Session» — пароль введу после")
        for phase in [ConnectionPhase.intermediate(.sessionChoice), .intermediate(.chooseConsole), .intermediate(.remoteSide),
                      .intermediate(.unknown), .typingID] {
            let c = hud(phase)
            XCTAssertEqual(c.tone, .info)
            XCTAssertFalse(c.fadesOut, "\(phase) — не итог")
            XCTAssertEqual(c.actions, [.cancel])
        }
        let ad = hud(.finished(.unconfirmed(copyID: false)))
        XCTAssertEqual(ad.title, "Не удалось подтвердить подключение")
        XCTAssertEqual(ad.tone, .neutral)
        // rc-console: «Terminal Session» не прошло — нейтральный итог с подсказкой, не успех и не «нет пароля».
        let stuck = hud(.finished(.sessionNotChosen))
        XCTAssertEqual(stuck.title, "Сеанс в AnyDesk не выбран")
        XCTAssertEqual(stuck.detail, "Выберите Console и нажмите Connect в окне AnyDesk.")
        XCTAssertEqual(stuck.tone, .neutral)
        XCTAssertEqual(stuck.actions, [.retry, .close])
        XCTAssertTrue(stuck.fadesOut)
        // «Нет пароля» называет программу и отличается от «поле не найдено».
        let noPassword = hud(.finished(.openedWithoutPassword(.notInFile)))
        XCTAssertEqual(noPassword.detail, "В файле нет пароля AnyDesk для «Лаборатория Север» — введите его в окне AnyDesk.")
        XCTAssertNotEqual(noPassword.title, hud(.finished(.failed(.fieldNotFound(structure: [])))).title)
        let tv = hud(.finished(.unconfirmed(copyID: true)), .teamViewer)
        XCTAssertEqual(tv.title, "Не удалось подключиться — ID скопирован")
        XCTAssertEqual(tv.tone, .neutral)
        XCTAssertTrue(tv.fadesOut)
    }

    /// Строка списка: ID не переносится рядом с длинной группой; теги и заметка — одной строкой под ID.
    func testRowKeepsIDOnOneLineAndShowsTagsAndNote() {
        func height(_ record: ConnectionRecord, showGroup: Bool = true) -> CGFloat {
            let host = NSHostingView(rootView: RemoteRow(record: record, program: .anyDesk, showGroup: showGroup,
                                                         onFavorite: {}, onConnect: {}).frame(width: 340))
            return host.fittingSize.height
        }
        let plain = ConnectionRecord(sourceRow: 2, name: "Вінниця", id: "1333427133", group: "Офіс")
        let grouped = ConnectionRecord(sourceRow: 2, name: "Вінниця", id: "1333427133",
                                       group: "Вінницька область · філія на Соборній, другий поверх")
        XCTAssertEqual(height(grouped), height(plain), "ID «1 333 427 133» и длинная группа — одна строка, группа обрезается")

        let tagged = ConnectionRecord(sourceRow: 2, name: "Вінниця", id: "1333427133", group: "Офіс", tags: ["каса", "ніч", "сервер", "склад"],
                                      note: "Дзвонити заздалегідь\nключ у охорони, другий поверх, кабінет 12, з 9 до 18")
        XCTAssertGreaterThan(height(tagged), height(plain), "теги и заметка видны")
        let short = ConnectionRecord(sourceRow: 2, name: "Вінниця", id: "1333427133", group: "Офіс", tags: ["каса"], note: "ок")
        XCTAssertEqual(height(tagged), height(short), "длинная заметка — одной строкой с обрезкой")
    }

    /// .xlsx: карточка записи открывается только для просмотра, правка — в Excel.
    func testExcelRecordsOpenReadOnly() {
        let center = RemoteConnectionsCenter(defaults: defaults)
        XCTAssertFalse(center.canView)
        for (ext, edit) in [("xlsx", false), ("xlsm", false), ("XML", true)] {
            center.setFile(FileManager.default.temporaryDirectory.appendingPathComponent("mu-rc-view-\(UUID().uuidString).\(ext)"))
            XCTAssertTrue(center.canView, ext)
            XCTAssertEqual(center.canEdit, edit, ext)
        }
        center.setFile(nil)
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

    /// Звонок: только через двойник — UniTalk не запускается, буфер и HUD не трогаются.
    func testCallOpensTelInUniTalkOrCopiesNumber() {
        final class FakeDialer: RemoteDialer {
            var installed = true
            var opened: [(URL, URL)] = []
            var asked: [String] = []
            func appURL(bundleID: String) -> URL? {
                asked.append(bundleID)
                return installed ? URL(fileURLWithPath: "/Applications/UniTalk.app") : nil
            }
            var opens = true
            func open(_ url: URL, withApplicationAt app: URL, completion: @escaping @MainActor (Bool) -> Void) {
                opened.append((url, app))
                let ok = opens
                MainActor.assumeIsolated { completion(ok) }
            }
        }
        let center = RemoteConnectionsCenter(defaults: defaults)
        let dialer = FakeDialer()
        var copied: [String] = []
        var huds: [String] = []
        center.dialer = dialer
        center.writePlain = { copied.append($0) }
        center.showHUD = { huds.append($0.title) }

        XCTAssertEqual(center.call("050 000 00 01"), .call(URL(string: "tel:+380500000001")!))
        XCTAssertEqual(dialer.asked, ["com.unitalk.desktop"])
        XCTAssertEqual(dialer.opened.map(\.0.absoluteString), ["tel:+380500000001"])
        XCTAssertEqual(dialer.opened.map(\.1.lastPathComponent), ["UniTalk.app"], "именно в UniTalk, обработчик по умолчанию не меняется")
        XCTAssertEqual(copied, [])

        dialer.installed = false
        XCTAssertEqual(center.call("050 000 00 01"), .copy("050 000 00 01", reason: .noUniTalk))
        XCTAssertEqual(copied, ["050 000 00 01"])
        XCTAssertEqual(huds, [RL("UniTalk не найден — номер скопирован")])
        XCTAssertEqual(dialer.opened.count, 1, "без UniTalk ничего не открывается")

        dialer.installed = true
        XCTAssertEqual(center.call("каб. 12-34"), .copy("каб. 12-34", reason: .notANumber))
        XCTAssertEqual(dialer.opened.count, 1)
        XCTAssertEqual(huds.last, RL("Номер скопирован"))

        // UniTalk есть, но не открылся (ошибка в completion) — номер копируется, как на Windows.
        dialer.opens = false
        copied = []
        XCTAssertEqual(center.call("050 000 00 01"), .call(URL(string: "tel:+380500000001")!))
        XCTAssertEqual(dialer.opened.count, 2)
        XCTAssertEqual(copied, ["050 000 00 01"])
        XCTAssertEqual(huds.last, RL("UniTalk не открылся — номер скопирован"))
    }

    /// Фильтр в окне — только программы: «Другое» вместо RDP и VPN, и только если такие записи есть.
    func testFilterChipsAreProgramsAndOther() {
        let model = RemoteListModel(center: RemoteConnectionsCenter(defaults: defaults))
        XCTAssertEqual(model.filters([.all: 3, .program(.anyDesk): 3, .program(.teamViewer): 0, .other: 0]),
                       [.all, .program(.anyDesk), .program(.teamViewer)])
        let counts: [ProgramFilter: Int] = [.all: 37, .program(.anyDesk): 17, .program(.teamViewer): 12, .other: 8]
        XCTAssertEqual(model.filters(counts), [.all, .program(.anyDesk), .program(.teamViewer), .other])
        XCTAssertEqual(model.filters(counts).map { model.chipTitle($0, counts: counts) },
                       [RL("Все %@", 37), "AnyDesk 17", "TeamViewer 12", RL("Другое %@", 8)])
        model.filter = .other
        XCTAssertEqual(model.filters([.all: 1, .other: 0]).last, .other, "выбранный чип не пропадает")
        model.cycleFilter()
        XCTAssertEqual(model.filter, .all)
    }
}

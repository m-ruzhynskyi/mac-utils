import Carbon.HIToolbox
import XCTest
@testable import MacUtils

final class HotKeyRegistryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "HotKeyRegistryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func combo(_ keyCode: Int, _ modifiers: Int) -> LayoutHotKey { LayoutHotKey(keyCode: keyCode, modifiers: modifiers) }

    // MARK: - Умолчания и миграция

    func testDefaultsAreThePreviousHardcodedShortcuts() {
        let expected: [HotKeyAction: String] = [
            .settings: "⌃⌥⌘,", .tools: "⌃⌥⌘T", .screenshot: "⇧⌘X", .screenshotOCR: "⌥⇧⌘X",
            .dropShelf: "⌃⌥D", .annotate: "⌃⌥A", .windowPin: "⌃⌥P (З)", .fixText: "⌃⌥E", .meeting: "⌃⌥M",
            .focus: "⌃⌥F", .qr: "⌃⌥Q", .appVolume: "⌃⌥V", .layoutFix: "⌘] (Ъ)", .textEditor: "⌃⌥⌘E",
            .videoPlayer: "⌃⌥⌘P (З)", .remoteConnections: "⌃⌥⌘A",
        ]
        for action in HotKeyAction.allCases {
            XCTAssertEqual(HotKeyRegistry.combo(for: action, defaults: defaults).title, expected[action], action.rawValue)
            XCTAssertFalse(HotKeyRegistry.isCustomized(action, defaults: defaults))
        }
    }

    func testHotKeyIDsMatchTheOnesFeaturesRegister() {
        XCTAssertEqual(HotKeyAction.dropShelf.hotKeyID, HotKeyID.dropShelf)
        XCTAssertEqual(HotKeyAction.focus.hotKeyID, HotKeyID.focus)
        XCTAssertEqual(HotKeyAction.qr.hotKeyID, HotKeyID.qr)
        XCTAssertEqual(Set(HotKeyAction.allCases.map(\.hotKeyID)).count, HotKeyAction.allCases.count, "идентификаторы уникальны")
        for action in HotKeyAction.allCases { XCTAssertEqual(HotKeyAction.action(forHotKeyID: action.hotKeyID), action) }
    }

    /// Пользователь раньше переназначил Раскладку и Громкость: после обновления сочетания те же, ничего не переносится.
    func testExistingLayoutAndVolumeSettingsAreKept() {
        defaults.set(kVK_Space, forKey: Pref.layoutFixKeyCode)
        defaults.set(optionKey | shiftKey, forKey: Pref.layoutFixModifiers)
        defaults.set(kVK_ANSI_B, forKey: Pref.appVolumeKeyCode)
        defaults.set(controlKey | cmdKey, forKey: Pref.appVolumeModifiers)
        XCTAssertEqual(HotKeyRegistry.combo(for: .layoutFix, defaults: defaults), combo(kVK_Space, optionKey | shiftKey))
        XCTAssertEqual(HotKeyRegistry.combo(for: .appVolume, defaults: defaults), combo(kVK_ANSI_B, controlKey | cmdKey))
        XCTAssertNil(defaults.object(forKey: HotKeyRegistry.overridesKey), "в новый ключ ничего не копируется")
        XCTAssertTrue(HotKeyRegistry.isCustomized(.layoutFix, defaults: defaults))
    }

    func testBrokenSavedValuesFallBackToDefault() {
        defaults.set(kVK_ANSI_V, forKey: Pref.appVolumeKeyCode)
        defaults.set(0, forKey: Pref.appVolumeModifiers) // без модификатора — так глобальную клавишу не зарегистрировать
        XCTAssertEqual(HotKeyRegistry.combo(for: .appVolume, defaults: defaults), .controlOptionV)
        defaults.set(["qr": [kVK_ANSI_W], "focus": "мусор", "dropShelf": [500, controlKey]], forKey: HotKeyRegistry.overridesKey)
        XCTAssertEqual(HotKeyRegistry.combo(for: .qr, defaults: defaults), HotKeyAction.qr.defaultCombo)
        XCTAssertEqual(HotKeyRegistry.combo(for: .focus, defaults: defaults), HotKeyAction.focus.defaultCombo)
        XCTAssertEqual(HotKeyRegistry.combo(for: .dropShelf, defaults: defaults), HotKeyAction.dropShelf.defaultCombo)
    }

    // MARK: - Сохранение

    func testOverrideIsStoredAndDefaultIsNot() {
        let new = combo(kVK_ANSI_S, controlKey | optionKey)
        HotKeyRegistry.setCombo(new, for: .dropShelf, defaults: defaults)
        XCTAssertEqual(HotKeyRegistry.combo(for: .dropShelf, defaults: defaults), new)
        XCTAssertEqual(defaults.dictionary(forKey: HotKeyRegistry.overridesKey)?["dropShelf"] as? [Int], [kVK_ANSI_S, controlKey | optionKey])
        HotKeyRegistry.setCombo(HotKeyAction.dropShelf.defaultCombo, for: .dropShelf, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: HotKeyRegistry.overridesKey), "умолчание не хранится")
        HotKeyRegistry.setCombo(new, for: .focus, defaults: defaults)
        HotKeyRegistry.reset(.focus, defaults: defaults)
        XCTAssertFalse(HotKeyRegistry.isCustomized(.focus, defaults: defaults))
    }

    func testLegacyActionsWriteTheirOwnKeys() {
        let new = combo(kVK_ANSI_L, cmdKey | optionKey)
        HotKeyRegistry.setCombo(new, for: .layoutFix, defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: Pref.layoutFixKeyCode), kVK_ANSI_L)
        XCTAssertEqual(defaults.integer(forKey: Pref.layoutFixModifiers), cmdKey | optionKey)
        XCTAssertNil(defaults.object(forKey: HotKeyRegistry.overridesKey))
    }

    func testInvalidCombosAreRejected() {
        XCTAssertFalse(HotKeyRegistry.isValid(combo(kVK_ANSI_A, 0)))
        XCTAssertFalse(HotKeyRegistry.isValid(combo(kVK_ANSI_A, shiftKey)), "только ⇧ — нельзя")
        XCTAssertFalse(HotKeyRegistry.isValid(combo(200, cmdKey)))
        XCTAssertFalse(HotKeyRegistry.isValid(combo(kVK_ANSI_A, cmdKey | 0x10000)), "посторонние биты")
        XCTAssertTrue(HotKeyRegistry.isValid(combo(kVK_ANSI_A, controlKey | shiftKey)))
        HotKeyRegistry.setCombo(combo(kVK_ANSI_A, 0), for: .qr, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: HotKeyRegistry.overridesKey))
    }

    // MARK: - Подстановка при регистрации

    func testResolveSubstitutesOverrideOnlyForRegistryActions() {
        let requested = HotKeyAction.qr.defaultCombo
        XCTAssertEqual(HotKeyRegistry.resolve(id: HotKeyID.qr, requested: requested, defaults: defaults), requested)
        let new = combo(kVK_ANSI_K, controlKey | optionKey | cmdKey)
        HotKeyRegistry.setCombo(new, for: .qr, defaults: defaults)
        XCTAssertEqual(HotKeyRegistry.resolve(id: HotKeyID.qr, requested: requested, defaults: defaults), new)
        // Раскладка сама передаёт выбранное из своих ключей: подставлять нечего.
        let layout = combo(kVK_Space, optionKey | shiftKey)
        XCTAssertEqual(HotKeyRegistry.resolve(id: HotKeyID.layoutFix, requested: layout, defaults: defaults), layout)
        // Неизвестный идентификатор (например, старые 10…20 раскладки окон) — как есть.
        XCTAssertEqual(HotKeyRegistry.resolve(id: 999, requested: new, defaults: defaults), new)
    }

    // MARK: - Конфликты

    @MainActor
    func testDefaultsHaveNoInternalDuplicatesEvenWithWindowSnap() {
        for modifier in WindowSnapModifier.allCases {
            let entries = HotKeyRegistry.entries(defaults: defaults, windowSnap: modifier)
            XCTAssertEqual(HotKeyConflicts.allDuplicates(in: entries), [], modifier.rawValue)
        }
    }

    @MainActor
    func testDuplicateBetweenTwoActionsAndWithWindowSnapIsFound() {
        HotKeyRegistry.setCombo(HotKeyAction.qr.defaultCombo, for: .focus, defaults: defaults)
        var entries = HotKeyRegistry.entries(defaults: defaults)
        let clash = HotKeyConflicts.duplicates(of: HotKeyAction.qr.defaultCombo, excluding: .action(.focus), in: entries)
        XCTAssertEqual(clash.map(\.owner), [.action(.qr)])
        XCTAssertEqual(HotKeyConflicts.allDuplicates(in: entries).count, 1)

        HotKeyRegistry.reset(.focus, defaults: defaults)
        HotKeyRegistry.setCombo(combo(kVK_LeftArrow, controlKey | optionKey), for: .meeting, defaults: defaults)
        entries = HotKeyRegistry.entries(defaults: defaults, windowSnap: .controlOption)
        let snap = HotKeyConflicts.duplicates(of: combo(kVK_LeftArrow, controlKey | optionKey), excluding: .action(.meeting), in: entries)
        XCTAssertEqual(snap.first?.title, "Окна: левая половина")
        XCTAssertTrue(HotKeyConflicts.duplicates(of: combo(kVK_LeftArrow, controlKey | optionKey), excluding: .action(.meeting),
                                                 in: HotKeyRegistry.entries(defaults: defaults, windowSnap: .optionCommand)).isEmpty,
                      "с другим модификатором окон пересечения нет")
    }

    func testSystemShortcuts() {
        XCTAssertEqual(HotKeyConflicts.system(combo(kVK_Space, cmdKey)), "Spotlight")
        XCTAssertNotNil(HotKeyConflicts.system(combo(kVK_ANSI_4, cmdKey | shiftKey)))
        XCTAssertNotNil(HotKeyConflicts.system(combo(kVK_ANSI_P, cmdKey)), "⌘P — печать")
        XCTAssertNotNil(HotKeyConflicts.system(.commandBracket))
        XCTAssertNotNil(HotKeyConflicts.system(combo(kVK_UpArrow, controlKey)), "Mission Control")
        XCTAssertNil(HotKeyConflicts.system(combo(kVK_ANSI_D, controlKey | optionKey)))
        XCTAssertNil(HotKeyConflicts.system(combo(kVK_ANSI_X, cmdKey | shiftKey)), "⌘⇧X не считается стандартной командой")
        // Из сочетаний по умолчанию системное перекрывает только ⌘] Раскладки (о нём и раньше предупреждали).
        let flagged = HotKeyAction.allCases.filter { HotKeyConflicts.system($0.defaultCombo) != nil }
        XCTAssertEqual(flagged, [.layoutFix])
    }
}

final class SettingsSearchTests: XCTestCase {
    func testMatching() {
        XCTAssertTrue(SettingsSearch.matches("Горячие клавиши сочетания", query: ""))
        XCTAssertTrue(SettingsSearch.matches("Горячие клавиши сочетания", query: "  ГОРЯЧ  "))
        XCTAssertTrue(SettingsSearch.matches("тёплый экран", query: "теплый"))
        XCTAssertTrue(SettingsSearch.matches("снимок разметка распознать", query: "разм снимок"), "каждое слово, в любом порядке")
        XCTAssertFalse(SettingsSearch.matches("снимок разметка", query: "снимок видео"))
    }

    func testSectionsAreFoundByTitleKeywordsAndShortcutNames() {
        XCTAssertEqual(SettingsSearch.filter(SettingsSection.allCases, query: "").count, SettingsSection.allCases.count)
        XCTAssertTrue(SettingsSearch.filter(SettingsSection.allCases, query: "горячие").contains(.hotKeys))
        XCTAssertTrue(SettingsSearch.filter(SettingsSection.allCases, query: "ocr").contains(.screenshot))
        XCTAssertTrue(SettingsSearch.filter(SettingsSection.allCases, query: "умная папка").contains(.shots))
        XCTAssertTrue(SettingsSearch.filter(SettingsSection.allCases, query: "распознать текст").contains(.screenshot),
                      "название сочетания из реестра")
        XCTAssertEqual(SettingsSearch.filter(SettingsSection.allCases, query: "ghbdtn"), [.layout])
        XCTAssertTrue(SettingsSearch.filter(SettingsSection.allCases, query: "parallels").contains(.exclusions))
        XCTAssertTrue(SettingsSearch.filter(SettingsSection.allCases, query: "удалённый рабочий стол").contains(.exclusions))
        XCTAssertTrue(SettingsSearch.filter(SettingsSection.allCases, query: "исключения").contains(.exclusions))
        for section in SettingsSection.allCases {
            XCTAssertFalse(section.title.isEmpty); XCTAssertFalse(section.panelTitle.isEmpty)
            XCTAssertFalse(section.symbol.isEmpty); XCTAssertFalse(section.keywords.isEmpty)
        }
        XCTAssertTrue(SettingsSearch.filter(SettingsSection.allCases, query: "zzzz несуществующее").isEmpty)
    }
}

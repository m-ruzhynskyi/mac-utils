import Foundation

/// Чистые правила интерфейса «Скрытого экрана»: тексты и решения без обращения к системе. Всё проверяется тестами.
package enum HiddenScreenRules {
    // MARK: Программы по умолчанию

    package static let defaultApps: [(bundleID: String, name: String)] = [
        ("com.anthropic.claudefordesktop", "Claude"),
        ("com.openai.chat", "ChatGPT"),
        // Новый ChatGPT для Mac (26.x) — тот же продукт под другим идентификатором.
        ("com.openai.codex", "ChatGPT"),
    ]

    // MARK: Тексты

    /// «1 окно», «2 окна», «5 окон», «11 окон».
    package static func windows(_ n: Int) -> String {
        let mod100 = n % 100, mod10 = n % 10
        let word: String
        if (11...14).contains(mod100) { word = "окон" }
        else if mod10 == 1 { word = "окно" }
        else if (2...4).contains(mod10) { word = "окна" }
        else { word = "окон" }
        return "\(n) \(word)"
    }

    /// Подпись программы на странице настроек: «2 окна на скрытом экране».
    package static func appSubtitle(_ app: HiddenScreenApp, enabled: Bool) -> String {
        guard enabled else { return "Скрытый экран выключен" }
        return app.windowCount == 0 ? "Нет открытых окон" : "\(windows(app.windowCount)) на скрытом экране"
    }

    /// Строка состояния в меню и под переключателем: «Claude и ChatGPT скрыты».
    package static func statusLine(_ state: HiddenScreenState) -> String {
        guard state.isEnabled else { return "Скрытый экран выключен" }
        let names = state.apps.map(\.name)
        switch names.count {
        case 0: return "Нет программ для скрытия"
        case 1: return "\(names[0]) скрыт"
        case 2: return "\(names[0]) и \(names[1]) скрыты"
        default: return "\(names.count) программ скрыто"
        }
    }

    // MARK: Полоска зеркала

    package enum Badge: Equatable {
        case hidden      // зелёная «не видно в звонке»
        case visible     // красная «видно в звонке!»
        case unchecked   // проверка ещё не делалась — нейтральная
    }

    package static func badge(_ state: HiddenScreenState) -> Badge {
        switch state.hidingVerified {
        case .some(true): return .hidden
        case .some(false): return .visible
        case .none: return .unchecked
        }
    }

    package static func badgeText(_ badge: Badge) -> String {
        switch badge {
        case .hidden: return "не видно в звонке"
        case .visible: return "видно в звонке!"
        case .unchecked: return "проверяется…"
        }
    }

    // MARK: Меню

    package enum MenuEntry: Equatable {
        case header(String)
        case toggle(title: String, on: Bool, key: String)
        case showWindow(title: String, key: String, enabled: Bool)
        case app(bundleID: String, name: String, on: Bool)
        case addApp
        case returnAll(enabled: Bool)
        case separator
    }

    /// Раздел «Скрытый экран» в меню Mac Utils. `toggleKey`/`windowKey` — подписи сочетаний (⌥⇧H, ⌥Space).
    package static func menu(_ state: HiddenScreenState, toggleKey: String, windowKey: String) -> [MenuEntry] {
        var list: [MenuEntry] = [
            .header("Скрытый экран"),
            .toggle(title: "Скрытый экран включён", on: state.isEnabled, key: toggleKey),
            .showWindow(title: state.mirrorShown ? "Спрятать окно ИИ" : "Показать окно ИИ", key: windowKey, enabled: state.isEnabled),
            .separator,
        ]
        list += state.apps.map { .app(bundleID: $0.bundleID, name: $0.name, on: true) }
        list.append(.addApp)
        list.append(.separator)
        list.append(.returnAll(enabled: state.isEnabled || state.totalWindows > 0))
        return list
    }
}

// MARK: - «Перед звонком»

/// Одна проверка: что видно человеку и нужно ли действие.
package struct PreCallCheck: Identifiable, Equatable {
    package enum Level: Equatable { case ok, attention }
    package enum Action: Equatable { case openNotificationSettings, openSoundSettings }
    package let id: String
    package let level: Level
    package let title: String
    package let detail: String
    package let action: Action?
}

package enum PreCallRules {
    // MARK: Dock

    /// `autohide` из `com.apple.dock`: nil — ключа нет (значит, Dock не прячется).
    package static func dock(autohide: Bool?) -> PreCallCheck {
        if autohide == true {
            return PreCallCheck(id: "dock", level: .ok, title: "Dock прячется сам",
                                detail: "Иначе в нём видны значки Claude и ChatGPT", action: nil)
        }
        return PreCallCheck(id: "dock", level: .attention, title: "Dock виден",
                            detail: "В нём видны значки Claude и ChatGPT. Включите автоскрытие Dock (⌥⌘D)", action: nil)
    }

    // MARK: Уведомления

    package enum NotificationsState: Equatable {
        case off(apps: [String])      // у всех выключены
        case on(apps: [String])       // у этих включены
        case unknown                  // прочитать нельзя
    }

    /// Флаги записи программы в `com.apple.ncprefs`: бит 25 — «Разрешить уведомления» выключено.
    /// Это недокументированный формат, поэтому при любом сомнении возвращается `nil` (неизвестно), а не «выключено».
    package static func notificationsEnabled(flags: Int?) -> Bool? {
        guard let flags else { return nil }
        return flags & (1 << 25) == 0
    }

    package static func notifications(_ state: NotificationsState) -> PreCallCheck {
        switch state {
        case .off:
            return PreCallCheck(id: "notifications", level: .ok, title: "Уведомления Claude и ChatGPT выключены",
                                detail: "Ничто не всплывёт в углу экрана", action: nil)
        case .on(let apps):
            let names = apps.isEmpty ? "Claude и ChatGPT" : apps.joined(separator: " и ")
            return PreCallCheck(id: "notifications", level: .attention, title: "Уведомления \(names) включены",
                                detail: "Всплывут в углу экрана, и их увидят", action: .openNotificationSettings)
        case .unknown:
            return PreCallCheck(id: "notifications", level: .attention, title: "Проверьте уведомления Claude и ChatGPT",
                                detail: "Mac Utils не смог их прочитать. Выключите, чтобы они не всплывали в углу экрана",
                                action: .openNotificationSettings)
        }
    }

    // MARK: Наушники

    package enum OutputKind: Equatable {
        case builtInSpeakers
        case builtInHeadphones      // разъём 3,5 мм с подключёнными наушниками
        case external               // Bluetooth, USB, HDMI, AirPlay и т. д.
        case unknown
    }

    /// По транспорту и источнику данных текущего устройства вывода (CoreAudio).
    package static func outputKind(isBuiltIn: Bool?, dataSourceIsHeadphones: Bool) -> OutputKind {
        guard let isBuiltIn else { return .unknown }
        if !isBuiltIn { return .external }
        return dataSourceIsHeadphones ? .builtInHeadphones : .builtInSpeakers
    }

    package static func headphones(_ kind: OutputKind) -> PreCallCheck {
        switch kind {
        case .builtInHeadphones, .external:
            return PreCallCheck(id: "headphones", level: .ok, title: "Наушники подключены",
                                detail: "Голос ответа ИИ не услышит микрофон звонка", action: nil)
        case .builtInSpeakers:
            return PreCallCheck(id: "headphones", level: .attention, title: "Нет наушников",
                                detail: "Голос ответа ИИ из динамиков услышит микрофон звонка", action: .openSoundSettings)
        case .unknown:
            return PreCallCheck(id: "headphones", level: .attention, title: "Не удалось определить устройство вывода",
                                detail: "Убедитесь, что ответы ИИ не звучат из динамиков", action: .openSoundSettings)
        }
    }

    // MARK: Экран в звонке

    package static func shareHint(mainDisplayName: String?) -> PreCallCheck {
        let name = mainDisplayName.map { "«\($0)»" } ?? "основной"
        return PreCallCheck(id: "share", level: .ok, title: "В звонке показывайте экран \(name)",
                            detail: "Не выбирайте «Все экраны» и не выбирайте скрытый экран", action: nil)
    }

    /// Все проверки по порядку из макета.
    package static func all(dockAutohide: Bool?, notifications: NotificationsState, output: OutputKind,
                            mainDisplayName: String?) -> [PreCallCheck] {
        [dock(autohide: dockAutohide), self.notifications(notifications), headphones(output), shareHint(mainDisplayName: mainDisplayName)]
    }

    /// Все ли проверки пройдены (подсказка про экран не считается).
    package static func allClear(_ checks: [PreCallCheck]) -> Bool {
        checks.filter { $0.id != "share" }.allSatisfy { $0.level == .ok }
    }
}

import Carbon.HIToolbox
import Foundation

/// Сочетание Mac Utils, которое можно переназначить.
/// Функции регистрируют свои сочетания как раньше (`HotKeyCenter.register` со значением по умолчанию),
/// а `HotKeyCenter` подставляет то, что пользователь выбрал в настройках (`HotKeyRegistry.resolve`).
enum HotKeyAction: String, CaseIterable, Identifiable {
    case settings, tools, screenshot, screenshotOCR, dropShelf, annotate, windowPin, fixText, meeting, focus, qr,
         appVolume, layoutFix, textEditor, videoPlayer

    var id: String { rawValue }

    var hotKeyID: UInt32 {
        switch self {
        case .settings: return HotKeyID.settings
        case .tools: return HotKeyID.tools
        case .screenshot: return HotKeyID.screenshot
        case .screenshotOCR: return HotKeyID.screenshotOCR
        case .dropShelf: return HotKeyID.dropShelf
        case .annotate: return HotKeyID.annotate
        case .windowPin: return HotKeyID.windowPin
        case .fixText: return HotKeyID.fixText
        case .meeting: return HotKeyID.meeting
        case .focus: return HotKeyID.focus
        case .qr: return HotKeyID.qr
        case .appVolume: return HotKeyID.appVolume
        case .layoutFix: return HotKeyID.layoutFix
        case .textEditor: return HotKeyID.textEditor
        case .videoPlayer: return HotKeyID.videoPlayer
        }
    }

    var title: String {
        switch self {
        case .settings: return "Настройки"
        case .tools: return "Инструменты"
        case .screenshot: return "Снимок экрана"
        case .screenshotOCR: return "Распознать текст"
        case .dropShelf: return "Полка"
        case .annotate: return "Рисовать на экране"
        case .windowPin: return "Окно поверх всех"
        case .fixText: return "Исправить текст (ИИ)"
        case .meeting: return "Запись встречи"
        case .focus: return "Фокус (размыть фон)"
        case .qr: return "Мгновенный QR"
        case .appVolume: return "Громкость приложений"
        case .layoutFix: return "Исправить раскладку"
        case .textEditor: return "Текстовый редактор"
        case .videoPlayer: return "Видеоплеер"
        }
    }

    /// Раздел настроек, где включается функция.
    var section: SettingsSection {
        switch self {
        case .settings, .tools: return .general
        case .screenshot, .screenshotOCR: return .screenshot
        case .dropShelf: return .shelf
        case .annotate: return .annotate
        case .windowPin: return .windows
        case .fixText: return .ai
        case .meeting: return .meetings
        case .focus: return .focus
        case .qr: return .qr
        case .appVolume: return .volume
        case .layoutFix: return .layout
        case .textEditor: return .textEditor
        case .videoPlayer: return .videoPlayer
        }
    }

    /// Прежние, жёстко заданные значения: у пользователей, ничего не менявших, всё остаётся как было.
    var defaultCombo: LayoutHotKey {
        switch self {
        case .settings: return LayoutHotKey(keyCode: kVK_ANSI_Comma, modifiers: cmdKey | optionKey | controlKey)
        case .tools: return LayoutHotKey(keyCode: kVK_ANSI_T, modifiers: cmdKey | optionKey | controlKey)
        case .screenshot: return LayoutHotKey(keyCode: kVK_ANSI_X, modifiers: cmdKey | shiftKey)
        case .screenshotOCR: return LayoutHotKey(keyCode: kVK_ANSI_X, modifiers: cmdKey | shiftKey | optionKey)
        case .dropShelf: return LayoutHotKey(keyCode: kVK_ANSI_D, modifiers: controlKey | optionKey)
        case .annotate: return LayoutHotKey(keyCode: kVK_ANSI_A, modifiers: controlKey | optionKey)
        case .windowPin: return LayoutHotKey(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey)
        case .fixText: return LayoutHotKey(keyCode: kVK_ANSI_E, modifiers: controlKey | optionKey)
        case .meeting: return LayoutHotKey(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey)
        case .focus: return LayoutHotKey(keyCode: kVK_ANSI_F, modifiers: controlKey | optionKey)
        case .qr: return LayoutHotKey(keyCode: kVK_ANSI_Q, modifiers: controlKey | optionKey)
        case .appVolume: return .controlOptionV
        case .layoutFix: return .commandBracket
        case .textEditor: return LayoutHotKey(keyCode: kVK_ANSI_E, modifiers: cmdKey | optionKey | controlKey)
        // ⌃⌥⌘P свободна: ⌃⌥P — «Окно поверх всех», это другое сочетание.
        case .videoPlayer: return LayoutHotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey | optionKey | controlKey)
        }
    }

    /// Раскладка и Громкость хранили своё сочетание и раньше: реестр читает и пишет те же ключи,
    /// сами функции регистрируют уже выбранное — сохранённые настройки не теряются и не дублируются.
    var legacyKeys: (code: String, modifiers: String)? {
        switch self {
        case .layoutFix: return (Pref.layoutFixKeyCode, Pref.layoutFixModifiers)
        case .appVolume: return (Pref.appVolumeKeyCode, Pref.appVolumeModifiers)
        default: return nil
        }
    }

    static func action(forHotKeyID id: UInt32) -> HotKeyAction? {
        allCases.first { $0.hotKeyID == id }
    }
}

enum HotKeyRegistry {
    /// `{ "<action>": [keyCode, modifiers] }` — только изменённые пользователем сочетания.
    static let overridesKey = "hotKeyOverrides"

    /// Подходит ли сочетание для глобальной клавиши: обычная клавиша и хотя бы один из ⌘ ⌥ ⌃, без лишних битов.
    static func isValid(_ combo: LayoutHotKey) -> Bool {
        let allowed = cmdKey | optionKey | controlKey | shiftKey
        return (0...127).contains(combo.keyCode)
            && combo.modifiers & ~allowed == 0
            && combo.modifiers & (cmdKey | optionKey | controlKey) != 0
    }

    /// Сочетание, выбранное в настройках (или по умолчанию). Негодные сохранённые значения игнорируются.
    static func combo(for action: HotKeyAction, defaults: UserDefaults = .standard) -> LayoutHotKey {
        if let keys = action.legacyKeys {
            guard defaults.object(forKey: keys.code) != nil else { return action.defaultCombo }
            let saved = LayoutHotKey(keyCode: defaults.integer(forKey: keys.code), modifiers: defaults.integer(forKey: keys.modifiers))
            return isValid(saved) ? saved : action.defaultCombo
        }
        return override(for: action, defaults: defaults) ?? action.defaultCombo
    }

    static func override(for action: HotKeyAction, defaults: UserDefaults = .standard) -> LayoutHotKey? {
        guard let pair = (defaults.dictionary(forKey: overridesKey)?[action.rawValue] as? [Int]), pair.count == 2 else { return nil }
        let combo = LayoutHotKey(keyCode: pair[0], modifiers: pair[1])
        return isValid(combo) ? combo : nil
    }

    static func isCustomized(_ action: HotKeyAction, defaults: UserDefaults = .standard) -> Bool {
        combo(for: action, defaults: defaults) != action.defaultCombo
    }

    /// Сохранить выбор. Значение по умолчанию не хранится (чтобы будущая смена умолчания дошла до пользователя).
    static func setCombo(_ combo: LayoutHotKey, for action: HotKeyAction, defaults: UserDefaults = .standard) {
        guard isValid(combo) else { return }
        if let keys = action.legacyKeys {
            defaults.set(combo.keyCode, forKey: keys.code)
            defaults.set(combo.modifiers, forKey: keys.modifiers)
            return
        }
        var all = defaults.dictionary(forKey: overridesKey) ?? [:]
        if combo == action.defaultCombo { all[action.rawValue] = nil } else { all[action.rawValue] = [combo.keyCode, combo.modifiers] }
        if all.isEmpty { defaults.removeObject(forKey: overridesKey) } else { defaults.set(all, forKey: overridesKey) }
    }

    static func reset(_ action: HotKeyAction, defaults: UserDefaults = .standard) {
        setCombo(action.defaultCombo, for: action, defaults: defaults)
    }

    /// Что на самом деле регистрировать, когда функция просит `requested` под идентификатором `id`.
    /// Раскладка и Громкость уже передают выбранное (свои ключи настроек); остальным подставляется замена из настроек.
    static func resolve(id: UInt32, requested: LayoutHotKey, defaults: UserDefaults = .standard) -> LayoutHotKey {
        guard let action = HotKeyAction.action(forHotKeyID: id), action.legacyKeys == nil else { return requested }
        return override(for: action, defaults: defaults) ?? requested
    }

    // MARK: - Все сочетания

    /// Кто занимает сочетание: функция с переназначаемым сочетанием или клавиша раскладки окон.
    struct Entry: Equatable {
        enum Owner: Equatable {
            case action(HotKeyAction)
            case windowSnap(String)
        }
        let owner: Owner
        let combo: LayoutHotKey

        var title: String {
            switch owner {
            case .action(let action): return action.title
            case .windowSnap(let title): return "Окна: \(title.lowercased())"
            }
        }
    }

    /// Все сочетания Mac Utils. Клавиши раскладки окон — только если она включена (её модификатор выбирается в «Окнах»).
    @MainActor
    static func entries(defaults: UserDefaults = .standard, windowSnap: WindowSnapModifier? = nil) -> [Entry] {
        var list = HotKeyAction.allCases.map { Entry(owner: .action($0), combo: combo(for: $0, defaults: defaults)) }
        if let modifier = windowSnap {
            list += WindowTiler.bindings.map {
                Entry(owner: .windowSnap($0.title), combo: LayoutHotKey(keyCode: $0.keyCode, modifiers: modifier.carbon))
            }
        }
        return list
    }
}

/// Пересечения сочетаний: между собой и со стандартными сочетаниями macOS.
enum HotKeyConflicts {
    /// Другие сочетания Mac Utils с тем же `combo` (кроме самого `owner`).
    static func duplicates(of combo: LayoutHotKey, excluding owner: HotKeyRegistry.Entry.Owner,
                           in entries: [HotKeyRegistry.Entry]) -> [HotKeyRegistry.Entry] {
        entries.filter { $0.owner != owner && $0.combo == combo }
    }

    /// Все группы совпадающих сочетаний (по две и больше записей).
    static func allDuplicates(in entries: [HotKeyRegistry.Entry]) -> [[HotKeyRegistry.Entry]] {
        var groups: [[HotKeyRegistry.Entry]] = []
        for entry in entries where !groups.contains(where: { $0.first?.combo == entry.combo }) {
            let same = entries.filter { $0.combo == entry.combo }
            if same.count > 1 { groups.append(same) }
        }
        return groups
    }

    /// Стандартное сочетание macOS или программ, которое перекроется, пока сочетание Mac Utils работает.
    static func system(_ combo: LayoutHotKey) -> String? {
        let m = combo.modifiers, k = combo.keyCode
        let cmd = cmdKey, opt = optionKey, ctrl = controlKey, shift = shiftKey
        let known: [(Int, Int, String)] = [
            (cmd, kVK_Space, "Spotlight"),
            (cmd | opt, kVK_Space, "поиск в Finder"),
            (ctrl, kVK_Space, "предыдущий источник ввода"),
            (ctrl | opt, kVK_Space, "следующий источник ввода"),
            (ctrl | cmd, kVK_Space, "эмодзи и символы"),
            (cmd, kVK_Tab, "переключение программ"),
            (cmd | shift, kVK_Tab, "переключение программ"),
            (cmd, kVK_ANSI_Grave, "переключение окон программы"),
            (cmd | shift, kVK_ANSI_3, "снимок экрана macOS"),
            (cmd | shift, kVK_ANSI_4, "снимок экрана macOS"),
            (cmd | shift, kVK_ANSI_5, "снимок экрана macOS"),
            (cmd | shift | ctrl, kVK_ANSI_3, "снимок экрана macOS"),
            (cmd | shift | ctrl, kVK_ANSI_4, "снимок экрана macOS"),
            (cmd | opt, kVK_Escape, "принудительное завершение"),
            (ctrl | cmd, kVK_ANSI_Q, "блокировка экрана"),
            (ctrl | cmd, kVK_ANSI_F, "полноэкранный режим"),
            (cmd | opt, kVK_ANSI_D, "показать или скрыть Dock"),
            (cmd | opt, kVK_ANSI_H, "скрыть остальные"),
            (cmd | shift, kVK_ANSI_Slash, "справка"),
            (cmd | shift, kVK_ANSI_Q, "выход из системы"),
            (ctrl, kVK_UpArrow, "Mission Control"),
            (ctrl, kVK_DownArrow, "окна программы (App Exposé)"),
            (ctrl, kVK_LeftArrow, "переход между рабочими столами"),
            (ctrl, kVK_RightArrow, "переход между рабочими столами"),
            (cmd, kVK_ANSI_RightBracket, "«Вперёд» в Safari и Finder, сдвиг вправо в редакторах кода"),
            (cmd, kVK_ANSI_LeftBracket, "«Назад» в Safari и Finder"),
        ]
        if let hit = known.first(where: { $0.0 == m && $0.1 == k }) { return hit.2 }
        // ⌘ + клавиша без других модификаторов — стандартные команды программ (⌘C, ⌘P, ⌘Q…).
        if m == cmd, k != kVK_Space { return "стандартная команда программ (\(combo.title))" }
        return nil
    }
}

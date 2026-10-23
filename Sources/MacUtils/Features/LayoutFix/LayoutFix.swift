import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MUCore

/// «Раскладка»: по горячей клавише переводит текст, набранный не в той
/// раскладке (ghbdtn → привет и обратно). Выделенный текст — целиком,
/// без выделения — последнее набранное слово. По желанию переключает раскладку.
@MainActor
final class LayoutFix: ObservableObject {
    static let shared = LayoutFix()

    @Published private(set) var isRunning = false
    /// Горячая клавиша зарегистрирована (не занята другим приложением).
    @Published private(set) var hotKeyRegistered = false

    /// Метка наших синтетических нажатий, чтобы не записывать их в слово.
    private static let marker: Int64 = SelectedText.marker

    private var tap: EventTap?
    private var hotKey: LayoutHotKey?
    /// Последнее слово и пробелы после него — как они были набраны.
    private var tracker = WordTracker()
    private var word: String { tracker.word }
    private var trailing: String { tracker.trailing }
    private var busy = false

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { LayoutFix.shared.reset() }
        }
        // В исключённой программе горячая клавиша не регистрируется (иначе она не дошла бы до виртуальной машины).
        NotificationCenter.default.addObserver(forName: AppExclusions.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LayoutFix.shared.sync() }
        }
    }

    func sync() {
        let defaults = UserDefaults.standard
        let wanted = defaults.bool(forKey: Pref.layoutFix) && Permissions.accessibility
        let key = LayoutHotKey.current
        let center = HotKeyCenter.shared

        guard wanted else {
            tap?.stop()
            tap = nil
            center.unregister(id: HotKeyID.layoutFix)
            hotKey = nil
            reset()
            isRunning = false
            hotKeyRegistered = false
            return
        }
        if tap == nil {
            // Обработчик ничего не поглощает: только наблюдаем (система не ждёт ответа и не задерживает ввод).
            let tap = EventTap(types: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], listenOnly: true) { [weak self] type, event in
                self?.track(type: type, event: event)
                return true
            }
            // Tap отключали: нажатия могли пропасть, слово больше не соответствует тексту.
            tap.onDisabled = { [weak self] in self?.reset() }
            self.tap = tap
        }
        let tapOK = tap?.start() ?? false
        let excluded = AppExclusions.shared.isFrontExcluded
        if excluded {
            center.unregister(id: HotKeyID.layoutFix)
            hotKey = nil
        } else if hotKey != key || !center.isRegistered(id: HotKeyID.layoutFix) {
            center.register(id: HotKeyID.layoutFix, keyCode: key.keyCode, modifiers: key.modifiers) {
                AppRouter.shared.runHotKey(HotKeyID.layoutFix)
            }
            hotKey = key
        }
        hotKeyRegistered = excluded ? false : center.isRegistered(id: HotKeyID.layoutFix)
        if !hotKeyRegistered && !excluded { Log.layout.error("Горячая клавиша \(key.title, privacy: .public) не зарегистрирована") }
        isRunning = tapOK && (excluded || hotKeyRegistered)
    }

    /// Пока в настройках записывается новое сочетание, старое не должно срабатывать.
    func suspendHotKey(_ suspended: Bool) {
        if suspended {
            HotKeyCenter.shared.unregister(id: HotKeyID.layoutFix)
            hotKey = nil
        } else {
            sync()
        }
    }

    // MARK: - Последнее слово

    private func reset() {
        tracker.reset()
    }

    private func track(type: CGEventType, event: CGEvent) {
        guard type == .keyDown else {
            reset() // клик мышью — курсор мог уехать
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker || busy { return }
        if AppExclusions.shared.isFrontExcluded {
            reset()
            return
        }
        if IsSecureEventInputEnabled() {
            reset()
            return
        }
        let flags = event.flags
        // Наша же горячая клавиша.
        if let hotKey, event.getIntegerValueField(.keyboardEventKeycode) == Int64(hotKey.keyCode),
           flags.intersection([.maskShift, .maskAlternate, .maskControl, .maskCommand]) == hotKey.cgFlags { return }
        var modifiers: WordTracker.Modifiers = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        tracker.feed(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), modifiers: modifiers,
                     characters: NSEvent(cgEvent: event)?.characters)
    }

    // MARK: - Перевод

    func fix() {
        guard !busy else { return }
        // Виртуальная машина / удалённый рабочий стол: синтетические Backspace и ввод ушли бы в гостевую систему.
        guard !AppExclusions.shared.isFrontExcluded else {
            Log.layout.info("Программа из списка исключений: перевод раскладки пропущен")
            return
        }
        guard !IsSecureEventInputEnabled() else {
            Log.layout.info("Поле пароля: перевод раскладки пропущен")
            return
        }
        if let selected = Self.selectedTextViaAX(), !selected.isEmpty {
            replaceSelection(selected)
        } else if !word.isEmpty {
            replaceLastWord()
        } else {
            busy = true
            Task { @MainActor in
                let selected = await Self.selectedTextViaCopy()
                self.busy = false
                if let selected, !selected.isEmpty { self.replaceSelection(selected) }
            }
        }
    }

    private func replaceSelection(_ text: String) {
        let direction = LayoutMap.direction(of: text, cyrillic: Self.cyrillicLayout())
        let converted = LayoutMap.convert(text, direction)
        guard converted != text else { return }
        Log.layout.debug("Выделение: \(text.count) симв.")
        Self.type(converted)
        reset()
        if UserDefaults.standard.bool(forKey: Pref.layoutFixSwitchSource) { Self.selectInputSource(for: direction) }
    }

    private func replaceLastWord() {
        let direction = LayoutMap.direction(of: word, cyrillic: Self.cyrillicLayout())
        let converted = LayoutMap.convert(word, direction)
        let erase = word.count + trailing.count
        let tail = trailing
        Log.layout.debug("Слово: \(self.word.count) симв.")
        pressBackspace(times: erase)
        Self.type(converted + tail)
        // Повторное нажатие вернёт как было.
        tracker.replace(word: converted, trailing: tail)
        if UserDefaults.standard.bool(forKey: Pref.layoutFixSwitchSource) { Self.selectInputSource(for: direction) }
    }

    // MARK: - Синтетический ввод

    private func pressBackspace(times: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<times {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete),
                                          keyDown: down) else { continue }
                event.flags = []
                event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Печатает строку юникодом — не зависит от текущей раскладки.
    static func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            // До 20 символов в событии; суррогатную пару не разрываем.
            var end = min(index + 20, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            var chunk = Array(units[index..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                event.post(tap: .cgSessionEventTap)
            }
            index = end
        }
    }

    // MARK: - Выделенный текст

    static func selectedTextViaAX() -> String? { SelectedText.viaAX() }

    /// Запасной путь для приложений без AX: ⌘C с сохранением и возвратом буфера обмена.
    static func selectedTextViaCopy() async -> String? { await SelectedText.viaCopy() }

    // MARK: - Раскладка

    /// Включённые в системе раскладки: основной язык каждой («ru», «uk», «en»…).
    private static func enabledKeyboardLanguages() -> [String] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
            return (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String])?.first
        }
    }

    /// Русская или украинская: настройка «Кириллица» (авто / русская / украинская).
    static func cyrillicLayout() -> LayoutMap.CyrillicLayout {
        let setting = UserDefaults.standard.string(forKey: cyrillicSettingKey)
        // В режиме «авто» включённые раскладки смотрим только если выбор вообще нужен.
        return LayoutMap.cyrillicLayout(setting: setting, enabledLanguages: setting == "russian" || setting == "ukrainian" ? [] : enabledKeyboardLanguages())
    }

    static let cyrillicSettingKey = "layoutFixCyrillic"

    private static func selectInputSource(for direction: LayoutMap.Direction) {
        let language = LayoutMap.inputLanguage(for: direction)
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        let match = list.first { source in
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return false }
            let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
            return languages.first == language
        }
        if let match { TISSelectInputSource(match) }
    }
}

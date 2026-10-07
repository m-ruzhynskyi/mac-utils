import AppKit
import ApplicationServices
import Carbon.HIToolbox

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
    private static let marker: Int64 = 0x4D55_4C46

    private var tap: EventTap?
    private var hotKey: LayoutHotKey?
    /// Последнее слово и пробелы после него — как они были набраны.
    private var word = ""
    private var trailing = ""
    private var busy = false

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { LayoutFix.shared.reset() }
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
            tap = EventTap(types: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] type, event in
                self?.track(type: type, event: event)
                return true
            }
        }
        let tapOK = tap?.start() ?? false
        if hotKey != key || !center.isRegistered(id: HotKeyID.layoutFix) {
            center.register(id: HotKeyID.layoutFix, keyCode: key.keyCode, modifiers: key.modifiers) {
                LayoutFix.shared.fix()
            }
            hotKey = key
        }
        hotKeyRegistered = center.isRegistered(id: HotKeyID.layoutFix)
        if !hotKeyRegistered { Log.layout.error("Горячая клавиша \(key.title, privacy: .public) не зарегистрирована") }
        isRunning = tapOK && hotKeyRegistered
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
        word = ""
        trailing = ""
    }

    private func track(type: CGEventType, event: CGEvent) {
        guard type == .keyDown else {
            reset() // клик мышью — курсор мог уехать
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker || busy { return }
        if IsSecureEventInputEnabled() {
            reset()
            return
        }
        let flags = event.flags
        // Наша же горячая клавиша.
        if let hotKey, event.getIntegerValueField(.keyboardEventKeycode) == Int64(hotKey.keyCode),
           flags.intersection([.maskShift, .maskAlternate, .maskControl, .maskCommand]) == hotKey.cgFlags { return }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            reset()
            return
        }
        // ⌥ — спецсимволы: слово не трогаем.
        if flags.contains(.maskAlternate) { return }

        switch Int(event.getIntegerValueField(.keyboardEventKeycode)) {
        case kVK_Delete:
            if !trailing.isEmpty { trailing.removeLast() } else if !word.isEmpty { word.removeLast() }
            return
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            reset()
            return
        default:
            break
        }

        guard let characters = NSEvent(cgEvent: event)?.characters, !characters.isEmpty else { return }
        for character in characters {
            if character == " " {
                if !word.isEmpty { trailing.append(character) }
            } else if character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol {
                if !trailing.isEmpty {
                    word = ""
                    trailing = ""
                }
                word.append(character)
                if word.count > 64 { word.removeFirst(word.count - 64) }
            } else {
                reset()
            }
        }
    }

    // MARK: - Перевод

    func fix() {
        guard !busy else { return }
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
        let direction = LayoutMap.direction(of: text)
        let converted = LayoutMap.convert(text, direction)
        guard converted != text else { return }
        Log.layout.debug("Выделение: \(text.count) симв.")
        type(converted)
        reset()
        if UserDefaults.standard.bool(forKey: Pref.layoutFixSwitchSource) { Self.selectInputSource(for: direction) }
    }

    private func replaceLastWord() {
        let direction = LayoutMap.direction(of: word)
        let converted = LayoutMap.convert(word, direction)
        let erase = word.count + trailing.count
        let tail = trailing
        Log.layout.debug("Слово: \(self.word.count) симв.")
        pressBackspace(times: erase)
        type(converted + tail)
        // Повторное нажатие вернёт как было.
        word = converted
        trailing = tail
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
    private func type(_ text: String) {
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

    static func selectedTextViaAX() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString,
                                            &value) == .success else { return nil }
        return value as? String
    }

    /// Запасной путь для приложений без AX: ⌘C с сохранением и возвратом буфера обмена.
    private static func selectedTextViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        let before = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C),
                                      keyDown: down) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cgSessionEventTap)
        }
        var text: String?
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return text
    }

    // MARK: - Раскладка

    private static func selectInputSource(for direction: LayoutMap.Direction) {
        let language = direction == .toRussian ? "ru" : "en"
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

/// Горячая клавиша «Раскладки»: код клавиши (не символ — работает в любой
/// раскладке: ⌘] = ⌘Ъ, ⌘P = ⌘З) и модификаторы Carbon.
struct LayoutHotKey: Equatable {
    var keyCode: Int
    var modifiers: Int

    static let commandBracket = LayoutHotKey(keyCode: kVK_ANSI_RightBracket, modifiers: cmdKey)
    static let controlOptionV = LayoutHotKey(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey)

    /// Сочетание из настроек по паре ключей (код клавиши и модификаторы).
    static func load(codeKey: String, modifiersKey: String, default value: LayoutHotKey) -> LayoutHotKey {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: codeKey) != nil else { return value }
        return LayoutHotKey(keyCode: defaults.integer(forKey: codeKey), modifiers: defaults.integer(forKey: modifiersKey))
    }

    func save(codeKey: String, modifiersKey: String) {
        UserDefaults.standard.set(keyCode, forKey: codeKey)
        UserDefaults.standard.set(modifiers, forKey: modifiersKey)
    }
    static let commandP = LayoutHotKey(keyCode: kVK_ANSI_P, modifiers: cmdKey)
    static let presets: [LayoutHotKey] = [
        .commandBracket,
        .commandP,
        LayoutHotKey(keyCode: kVK_Space, modifiers: optionKey | shiftKey),
        LayoutHotKey(keyCode: kVK_Space, modifiers: controlKey | optionKey),
    ]

    static var current: LayoutHotKey {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Pref.layoutFixKeyCode) != nil else { return .commandBracket }
        return LayoutHotKey(keyCode: defaults.integer(forKey: Pref.layoutFixKeyCode),
                            modifiers: defaults.integer(forKey: Pref.layoutFixModifiers))
    }

    func save() {
        UserDefaults.standard.set(keyCode, forKey: Pref.layoutFixKeyCode)
        UserDefaults.standard.set(modifiers, forKey: Pref.layoutFixModifiers)
    }

    /// Из нажатия в окне настроек; нужен хотя бы один из ⌘ ⌥ ⌃.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        guard modifiers != 0 else { return nil }
        if flags.contains(.shift) { modifiers |= shiftKey }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers)
    }

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var cgFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & cmdKey != 0 { flags.insert(.maskCommand) }
        if modifiers & optionKey != 0 { flags.insert(.maskAlternate) }
        if modifiers & controlKey != 0 { flags.insert(.maskControl) }
        if modifiers & shiftKey != 0 { flags.insert(.maskShift) }
        return flags
    }

    /// Символы для показа: ⌃⌥⇧⌘ + клавиша.
    var keys: [String] {
        var result: [String] = []
        if modifiers & controlKey != 0 { result.append("⌃") }
        if modifiers & optionKey != 0 { result.append("⌥") }
        if modifiers & shiftKey != 0 { result.append("⇧") }
        if modifiers & cmdKey != 0 { result.append("⌘") }
        result.append(Self.keyName(keyCode))
        return result
    }

    var title: String { keys.joined() }

    /// Чьё стандартное сочетание перекрывается.
    var conflictNote: String? {
        switch self {
        case .commandBracket: return "⌘] (⌘Ъ) — это «Вперёд» в Safari и Finder и «сдвинуть вправо» в редакторах кода: пока исправление включено, они работать не будут."
        case .commandP: return "⌘P (⌘З) заменяет «Печать» во всех приложениях, пока исправление раскладки включено."
        default: return nil
        }
    }

    private static func keyName(_ code: Int) -> String {
        let special: [Int: String] = [
            kVK_Space: "Пробел", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "Esc", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[code] { return name }
        // Буквы и цифры — по английской раскладке (QWERTY).
        let ansi: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P (З)", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
            kVK_ANSI_9: "9", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "] (Ъ)", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        return ansi[code] ?? "#\(code)"
    }
}

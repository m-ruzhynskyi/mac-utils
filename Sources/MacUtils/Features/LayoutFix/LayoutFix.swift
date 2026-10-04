// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// «Раскладка»: по горячей клавише переводит текст, набранный не в той
/// раскладке (ghbdtn → привет и обратно). Выделенный текст — целиком,
/// без выделения — последнее набранное слово. Затем переключает раскладку.
@MainActor
final class LayoutFix: ObservableObject {
    static let shared = LayoutFix()

    @Published private(set) var isRunning = false

    /// Метка наших синтетических нажатий, чтобы не записывать их в слово.
    private static let marker: Int64 = 0x4D55_4C46

    private var tap: EventTap?
    private var hotKey: LayoutFixHotKey?
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
        let key = LayoutFixHotKey(rawValue: defaults.string(forKey: Pref.layoutFixHotKey) ?? "") ?? .optionShiftSpace
        let center = HotKeyCenter.shared

        guard wanted else {
            tap?.stop()
            tap = nil
            center.unregister(id: HotKeyID.layoutFix)
            hotKey = nil
            reset()
            isRunning = false
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
        isRunning = tapOK && center.isRegistered(id: HotKeyID.layoutFix)
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
        Self.selectInputSource(for: direction)
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
        Self.selectInputSource(for: direction)
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

    private static func selectedTextViaAX() -> String? {
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

/// Варианты горячей клавиши «Раскладки».
enum LayoutFixHotKey: String, CaseIterable, Identifiable {
    case optionShiftSpace, controlOptionSpace, controlShiftSpace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionShiftSpace: return "⌥⇧ Пробел"
        case .controlOptionSpace: return "⌃⌥ Пробел"
        case .controlShiftSpace: return "⌃⇧ Пробел"
        }
    }

    var keys: [String] {
        switch self {
        case .optionShiftSpace: return ["⌥", "⇧", "Пробел"]
        case .controlOptionSpace: return ["⌃", "⌥", "Пробел"]
        case .controlShiftSpace: return ["⌃", "⇧", "Пробел"]
        }
    }

    var keyCode: Int { kVK_Space }

    var cgFlags: CGEventFlags {
        switch self {
        case .optionShiftSpace: return [.maskAlternate, .maskShift]
        case .controlOptionSpace: return [.maskControl, .maskAlternate]
        case .controlShiftSpace: return [.maskControl, .maskShift]
        }
    }

    var modifiers: Int {
        switch self {
        case .optionShiftSpace: return optionKey | shiftKey
        case .controlOptionSpace: return controlKey | optionKey
        case .controlShiftSpace: return controlKey | shiftKey
        }
    }
}

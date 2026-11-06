import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Строка символов события после замены — как у настоящего ⌘-сочетания: символ новой клавиши в текущей раскладке (с ⇧ — заглавный),
/// без управляющего знака. В событии с клавиатуры строка уже посчитана с Ctrl («\u{19}» у Ctrl+Y, «\u{3}» у Ctrl+C), и AppKit берёт
/// из неё и `characters`, и `charactersIgnoringModifiers`: без замены ⇧⌘ + «\u{19}» (или «y», «н») не совпадёт с «Повторить» (⇧⌘Z),
/// а ⌘ + «\u{3}» — с «Копировать» там, где сочетание сверяют по символу, а не по коду клавиши.
package enum WinKeysCharacters {
    /// Символ клавиши `keyCode` в раскладке `layout` (`kTISPropertyUnicodeKeyLayoutData`) только с ⇧ (если `shift`);
    /// `nil` — раскладка не дала печатного символа.
    package static func string(keyCode: Int64, shift: Bool, layout: Data) -> String? {
        layout.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(base, UInt16(truncatingIfNeeded: keyCode), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let string = String(utf16CodeUnits: chars, count: length)
            return string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? nil : string
        }
    }

    /// Раскладка, которой сейчас печатает клавиатура; у методов ввода без своей таблицы (китайский, японский) — латинская.
    package static func currentLayout() -> Data? {
        if let data = layoutData(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()) { return data }
        return layoutData(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
    }

    /// Таблица раскладки по её id (`com.apple.keylayout.Russian`), даже не включённой у пользователя — для тестов.
    package static func layout(id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.lazy.compactMap { layoutData($0) }.first
    }

    private static func layoutData(_ source: TISInputSource?) -> Data? {
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// Поставить событию строку новой клавиши; раскладка неизвестна — строку не трогаем.
    package static func apply(to event: CGEvent, keyCode: Int64, shift: Bool, layout: Data?) {
        guard let layout, let string = string(keyCode: keyCode, shift: shift, layout: layout) else { return }
        let units = Array(string.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    }
}

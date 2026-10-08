import AppKit
import Carbon.HIToolbox

/// ⌃⌥E: исправить ошибки и опечатки в выделенном тексте локальной моделью и заменить выделение.
@MainActor
final class TextFixer {
    static let shared = TextFixer()

    private var busy = false

    static let system = """
    Ты корректор. Исправь орфографию, опечатки, пунктуацию и грамматику в тексте пользователя. \
    Сохрани язык, смысл, стиль, регистр, разметку и переносы строк. Ничего не добавляй и не объясняй. \
    Если ошибок нет — верни текст без изменений. Ответь только исправленным текстом.
    """

    func sync() {
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.fixText)
        guard Ollama.isOn(Pref.aiFixText) else { return }
        center.register(id: HotKeyID.fixText, keyCode: kVK_ANSI_E, modifiers: controlKey | optionKey) {
            TextFixer.shared.fix()
        }
    }

    func fix() {
        guard !busy, !IsSecureEventInputEnabled() else { return }
        busy = true
        Task {
            defer { busy = false }
            var text = LayoutFix.selectedTextViaAX()
            if text?.isEmpty ?? true { text = await LayoutFix.selectedTextViaCopy() }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Toast.show("Выделите текст, который нужно исправить", symbol: "text.cursor", tint: .orange)
                return
            }
            guard text.count <= 6000 else {
                Toast.show("Слишком длинный текст — выделите поменьше", symbol: "exclamationmark.triangle.fill", tint: .orange)
                return
            }
            Toast.show("Исправляю…", symbol: "sparkles", tint: .purple)
            do {
                let answer = try await Ollama.generate(text, system: Self.system, temperature: 0, maxTokens: max(200, text.count))
                let fixed = AIParsing.keepingEdges(of: text, AIParsing.cleanedText(answer))
                guard !fixed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                if fixed == text {
                    Toast.show("Ошибок не найдено", symbol: "checkmark.circle.fill")
                    return
                }
                await Self.paste(fixed)
                Toast.show("Текст исправлен", symbol: "sparkles", tint: .purple, action: Toast.Action(title: "Отменить") {
                    Self.undo()
                })
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    /// Вставка через буфер обмена (надёжно для длинного текста с переносами), затем буфер возвращается.
    static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        press(kVK_ANSI_V, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 400_000_000)
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    private static func undo() {
        press(kVK_ANSI_Z, flags: .maskCommand)
    }

    private static func press(_ key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
        }
    }
}

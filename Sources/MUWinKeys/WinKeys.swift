import AppKit
import MUCore

/// Ctrl+C / V / X / A / Z / Y / S / F как ⌘C … ⌘F (Ctrl+Y → ⇧⌘Z) во всех программах, кроме терминалов, виртуальных машин и
/// удалённых столов. Событие не создаётся заново: в нём меняется флаг Control на Command (у Ctrl+Y ещё и код клавиши),
/// и оно идёт дальше. Каждое сочетание включается отдельно (`WinKeysShortcuts`).
@MainActor
package final class WinKeys: NSObject, ObservableObject {
    package static let shared = WinKeys()

    @Published package private(set) var isRunning = false

    private var tap: EventTap?
    private var pairing = WinKeysRules.Pairing()

    private override init() { super.init() }

    package func sync() {
        let wanted = UserDefaults.standard.bool(forKey: Pref.winKeys) && Permissions.accessibility
        if wanted {
            if tap == nil {
                tap = EventTap(types: [.keyDown, .keyUp]) { [weak self] type, event in
                    self?.handle(type: type, event: event)
                    return true
                }
            }
            isRunning = tap?.start() ?? false
        } else {
            tap?.stop()
            tap = nil
            isRunning = false
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let output = pairing.translate(
            type: type, flags: event.flags, keyCode: key,
            isSynthetic: event.getIntegerValueField(.eventSourceUserData) == SelectedText.marker,
            isRecordingShortcut: ShortcutRecording.isActive,
            customExcluded: WinKeysExclusions.shared.list, disabled: WinKeysShortcuts.shared.disabled,
            app: { (NSWorkspace.shared.frontmostApplication?.bundleIdentifier, AppExclusions.shared.isFrontExcluded) })
        guard let output else { return }
        Self.apply(output, to: event, layout: WinKeysCharacters.currentLayout())
    }

    /// Применить замену к событию: флаги, код клавиши (у Ctrl+Y) и строку символов — как у настоящего ⌘-сочетания
    /// (`WinKeysCharacters`): иначе в событии остаётся строка, посчитанная с Ctrl.
    nonisolated package static func apply(_ output: WinKeysRules.Pairing.Output, to event: CGEvent, layout: Data?) {
        event.flags = output.flags
        if output.keyCode != event.getIntegerValueField(.keyboardEventKeycode) {
            event.setIntegerValueField(.keyboardEventKeycode, value: output.keyCode)
        }
        WinKeysCharacters.apply(to: event, keyCode: output.keyCode, shift: output.flags.contains(.maskShift), layout: layout)
    }
}

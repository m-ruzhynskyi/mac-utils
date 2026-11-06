import AppKit
import MUCore

/// Ctrl+C / Ctrl+V / Ctrl+X как ⌘C / ⌘V / ⌘X во всех программах, кроме терминалов, виртуальных машин и удалённых столов.
/// Событие не создаётся заново: в нём меняется флаг Control на Command и оно идёт дальше.
@MainActor
package final class WinKeys: NSObject, ObservableObject {
    package static let shared = WinKeys()

    @Published package private(set) var isRunning = false

    private var tap: EventTap?

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
        // Дешёвые проверки первыми: узнавать активную программу нужно только для подходящего сочетания.
        guard WinKeysRules.decision(type: type, flags: event.flags, keyCode: key, bundleID: nil,
                                    isExcluded: false, isSynthetic: false) == .rewrite else { return }
        let decision = WinKeysRules.decision(
            type: type, flags: event.flags, keyCode: key,
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            isExcluded: AppExclusions.shared.isFrontExcluded,
            isSynthetic: event.getIntegerValueField(.eventSourceUserData) == SelectedText.marker,
            customExcluded: WinKeysExclusions.shared.list,
            isRecordingShortcut: ShortcutRecording.isActive)
        if decision == .rewrite { event.flags = WinKeysRules.rewritten(event.flags) }
    }
}

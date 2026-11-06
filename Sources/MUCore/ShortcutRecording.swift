/// Идёт запись сочетания в `ShortcutRecorder`. Перехваты, которые переписывают нажатия («Клавиши Windows»), пропускают
/// их как есть: иначе в запись попадёт уже заменённое сочетание (⌃C записался бы как ⌘C).
@MainActor
package enum ShortcutRecording {
    package private(set) static var active = 0
    package static var isActive: Bool { active > 0 }
    package static func begin() { active += 1 }
    package static func end() { active = max(0, active - 1) }
}

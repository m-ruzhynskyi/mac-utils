import AppKit
import SwiftUI

// MARK: - Переключатель

struct SwitcherPage: View {
    @AppStorage(Pref.switcher) private var enabled = true
    @AppStorage(Pref.switcherModifier) private var modifier = "option"
    @AppStorage(Pref.switcherPreviews) private var previews = true
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = AppSwitcher.shared

    private var mod: String { modifier == "command" ? "⌘" : "⌥" }

    var body: some View {
        Form {
            Section {
                Toggle("Переключатель приложений", isOn: $enabled)
                Picker("Сочетание", selection: $modifier) {
                    Text("⌥ Tab").tag("option")
                    Text("⌘ Tab (заменить системный)").tag("command")
                }
                .disabled(!enabled)
                Toggle("Показывать превью окон", isOn: $previews)
                    .disabled(!enabled)
                if enabled && previews && !permissions.screenRecording {
                    StatusLine(ok: false, okText: "", problemText: "Для превью нужно разрешение «Запись экрана»",
                               action: {
                                   Permissions.requestScreenRecording()
                                   Permissions.open(.screenRecording)
                               },
                               relaunchHint: true)
                }
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Переключатель работает")
                }
            }
            Section("Как пользоваться") {
                ShortcutRow(keys: [mod, "Tab"], text: "Удерживайте \(mod) и нажимайте Tab, отпустите \(mod) — переход.")
                ShortcutRow(keys: ["⇧", "Tab"], text: "Назад по списку. Также работают ← и →.")
                ShortcutRow(keys: ["Q"], text: "Завершить выбранное приложение.")
                ShortcutRow(keys: ["H"], text: "Скрыть выбранное приложение.")
                ShortcutRow(keys: ["Esc"], text: "Закрыть без переключения.")
                Text("Приложения идут в порядке последнего использования. Если у приложения нет окон, оно откроет новое, как при клике по Dock; свёрнутое окно разворачивается.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Переключатель приложений")
    }
}

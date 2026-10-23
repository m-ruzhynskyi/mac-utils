import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUAppSwitcher
import MUScreenshot

// MARK: - Переключатель

struct SwitcherPage: View {
    @AppStorage(Pref.switcher) private var enabled = true
    @AppStorage(Pref.switcherModifier) private var modifier = "option"
    @AppStorage(Pref.switcherPreviews) private var previews = true
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = AppSwitcher.shared

    private var mod: String { modifier == "command" ? "⌘" : "⌥" }

    var body: some View {
        SettingsPage(.switcher, isOn: $enabled, toggleLabel: "Переключатель приложений") {
            ListCard {
                Row("Сочетание", systemImage: "command") {
                    Segmented(selection: $modifier, options: [("option", "⌥ Tab"), ("command", "⌘ Tab (заменить системный)")])
                }
                .disabled(!enabled)
                ToggleRow("Показывать превью окон", systemImage: "rectangle.on.rectangle", isOn: $previews)
                    .disabled(!enabled)
                if enabled && previews && !permissions.screenRecording {
                    PermissionRow(.screenRecording, state: .needed, purpose: "Для превью нужно разрешение «Запись экрана»",
                                  action: {
                                      Permissions.requestScreenRecording()
                                      Permissions.open(.screenRecording)
                                  },
                                  relaunchHint: true)
                }
                if enabled {
                    AccessibilityStatusRow(running: service.isRunning, readyText: "Переключатель работает")
                }
            }
            CollapsibleCard("Как пользоваться") {
                HintRow(keys: [mod, "Tab"], text: "Удерживайте \(mod) и нажимайте Tab, отпустите \(mod) — переход.")
                HintRow(keys: ["⇧", "Tab"], text: "Назад по списку. Также работают ← и →.")
                HintRow(keys: ["Q"], text: "Завершить выбранное приложение.")
                HintRow(keys: ["H"], text: "Скрыть выбранное приложение.")
                HintRow(keys: ["Esc"], text: "Закрыть без переключения.")
            }
            Footnote("Приложения идут в порядке последнего использования. Если у приложения нет окон, оно откроет новое, как при клике по Dock; свёрнутое окно разворачивается.")
        }
    }
}

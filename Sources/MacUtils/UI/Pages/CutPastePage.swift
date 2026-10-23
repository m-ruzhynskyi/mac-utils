import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUCutPaste
import MUTextEditor

// MARK: - Вырезать и вставить

struct CutPastePage: View {
    @AppStorage(Pref.cutPaste) private var enabled = true
    @AppStorage(Pref.cutPanel) private var showPanel = true
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = FinderCutPaste.shared

    var body: some View {
        SettingsPage(.cutPaste, isOn: $enabled, toggleLabel: "Вырезать и вставлять файлы в Finder") {
            ListCard {
                ToggleRow("Показывать плавающую панель", subtitle: "Пока Finder активен, панель показывает вырезанные файлы.",
                          systemImage: "rectangle.on.rectangle", isOn: $showPanel)
                    .disabled(!enabled)
                if enabled {
                    AccessibilityStatusRow(running: service.isRunning, readyText: "Готово к вырезанию в Finder")
                }
            }
            CollapsibleCard("Как пользоваться") {
                HintRow(keys: ["⌘", "X"], text: "Выделите объекты в Finder и нажмите ⌘X.")
                HintRow(keys: ["⌘", "V"], text: "Откройте нужную папку и нажмите ⌘V — объекты переместятся.")
            }
            Footnote("В текстовых полях (например, при переименовании) ⌘X и ⌘V работают как обычно. Если после ⌘X скопировать что-то другое, вырезание отменится.")
        }
    }
}

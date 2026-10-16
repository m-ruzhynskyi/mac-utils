import AppKit
import SwiftUI

// MARK: - Вырезать и вставить

struct CutPastePage: View {
    @AppStorage(Pref.cutPaste) private var enabled = true
    @AppStorage(Pref.cutPanel) private var showPanel = true
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = FinderCutPaste.shared

    var body: some View {
        Form {
            Section {
                Toggle("Вырезать и вставлять файлы в Finder", isOn: $enabled)
                Text("⌘X — вырезать, ⌘V — переместить файлы и папки в Finder.")
                    .foregroundStyle(.secondary)
                Toggle("Показывать плавающую панель", isOn: $showPanel)
                    .disabled(!enabled)
                Text("Пока Finder активен, панель показывает вырезанные файлы.")
                    .foregroundStyle(.secondary)
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Готово к вырезанию в Finder")
                }
            }

            Section("Как пользоваться") {
                ShortcutRow(keys: ["⌘", "X"], text: "Выделите объекты в Finder и нажмите ⌘X.")
                ShortcutRow(keys: ["⌘", "V"], text: "Откройте нужную папку и нажмите ⌘V — объекты переместятся.")
                Text("В текстовых полях (например, при переименовании) ⌘X и ⌘V работают как обычно. Если после ⌘X скопировать что-то другое, вырезание отменится.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Вырезать и вставить")
    }
}

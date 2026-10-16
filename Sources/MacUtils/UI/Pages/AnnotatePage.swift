import AppKit
import SwiftUI

// MARK: - Рисование

struct AnnotatePage: View {
    @AppStorage(Pref.annotate) private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Рисование поверх экрана", isOn: $enabled)
                Text("Стрелки, рамки, маркер и перо прямо поверх экрана — во время созвона, демонстрации или записи экрана (рисунки попадают в запись).")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Как пользоваться") {
                ActionShortcutRow(action: .annotate, text: "Начать или закончить рисование.")
                ShortcutRow(keys: ["1", "2", "3", "4"], text: "Перо, стрелка, рамка, маркер.")
                ShortcutRow(keys: ["⌘", "Z"], text: "Отменить последний штрих.")
                ShortcutRow(keys: ["⌫"], text: "Стереть всё.")
                ShortcutRow(keys: ["Esc"], text: "Закончить.")
                Text("На панели сверху — цвета и режим «исчезающие штрихи» (через 3 секунды).")
                    .foregroundStyle(.secondary)
                Button("Попробовать") { ScreenAnnotator.shared.start() }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Рисование на экране")
    }
}

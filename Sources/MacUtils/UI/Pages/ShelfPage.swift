import AppKit
import SwiftUI

// MARK: - Полка и шпаргалка

struct ShelfPage: View {
    @AppStorage(Pref.dropShelf) private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Полка для файлов", isOn: $enabled)
                Text("Временное место для файлов: положите их на полку, перейдите в нужную папку или программу и вытащите обратно — по одному или все сразу.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Как пользоваться") {
                ShortcutRow(keys: ["↔︎"], text: "Перетаскивая файлы, встряхните мышь влево-вправо — полка появится рядом с курсором.")
                ActionShortcutRow(action: .dropShelf, text: "Показать или скрыть полку.")
                Text("Вытащенные с полки файлы с неё убираются; чтобы оставить их на полке, держите ⌥. Сами файлы никуда не копируются, пока вы их не перетащите.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Полка")
    }
}

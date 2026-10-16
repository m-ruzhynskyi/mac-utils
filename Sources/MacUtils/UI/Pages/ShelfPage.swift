import AppKit
import SwiftUI

// MARK: - Полка

struct ShelfPage: View {
    @AppStorage(Pref.dropShelf) private var enabled = true

    var body: some View {
        SettingsPage(.shelf, isOn: $enabled, toggleLabel: "Полка для файлов") {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                GroupLabel("Как пользоваться")
                Card {
                    ShortcutHintRow(keys: ["↔︎"], text: "Перетаскивая файлы, встряхните мышь влево-вправо — полка появится рядом с курсором.")
                    ShortcutHintRow(action: .dropShelf, text: "Показать или скрыть полку.")
                    Text("Вытащенные с полки файлы с неё убираются; чтобы оставить их на полке, держите ⌥. Сами файлы никуда не копируются, пока вы их не перетащите.")
                        .font(DS.Font.rowSub).foregroundStyle(.dsMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : DS.State.disabledOpacity)
        }
    }
}

import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUAnnotate

// MARK: - Рисование

struct AnnotatePage: View {
    @AppStorage(Pref.annotate) private var enabled = true

    var body: some View {
        SettingsPage(.annotate, isOn: $enabled, toggleLabel: "Рисование поверх экрана") {
            GroupLabel("Как пользоваться")
            ListCard {
                HintRow(action: .annotate, text: "Начать или закончить рисование.")
                HintRow(keys: ["1", "2", "3", "4"], text: "Перо, стрелка, рамка, маркер.")
                HintRow(keys: ["⌘", "Z"], text: "Отменить последний штрих.")
                HintRow(keys: ["⌫"], text: "Стереть всё.")
                HintRow(keys: ["Esc"], text: "Закончить.")
                Row("Попробовать", subtitle: "На панели сверху — цвета и режим «исчезающие штрихи» (через 3 секунды).",
                    systemImage: "pencil.tip.crop.circle") {
                    Button("Попробовать") { ScreenAnnotator.shared.start() }.buttonStyle(.graphite(.primary, size: .compact))
                }
            }
            .disabled(!enabled)
        }
    }
}

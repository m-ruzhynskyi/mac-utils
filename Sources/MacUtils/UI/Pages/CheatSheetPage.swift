import AppKit
import SwiftUI

struct CheatSheetPage: View {
    @AppStorage(Pref.cheatSheet) private var enabled = true
    @AppStorage(Pref.cheatSheetDelay) private var delay = 0.8
    @AppStorage(Pref.cheatSheetSticky) private var sticky = false
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = CheatSheet.shared

    var body: some View {
        Form {
            Section {
                Toggle("Шпаргалка сочетаний клавиш", isOn: $enabled)
                Text("Удерживайте ⌘ — появятся все сочетания клавиш активной программы (из её меню) и Mac Utils. Отпустите ⌘ — шпаргалка исчезнет.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Шпаргалка работает")
                }
            }
            Section("Настройка") {
                Picker("Держать ⌘", selection: $delay) {
                    Text("0,5 с").tag(0.5)
                    Text("0,8 с").tag(0.8)
                    Text("1,2 с").tag(1.2)
                    Text("2 с").tag(2.0)
                }
                Toggle(isOn: $sticky) {
                    VStack(alignment: .leading) {
                        Text("Оставлять открытой")
                        Text(sticky ? "Подержали ⌘ — шпаргалка открылась и остаётся; нажмите ⌘ ещё раз (или Esc), чтобы закрыть."
                                    : "Шпаргалка видна, только пока ⌘ зажата.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Когда сочетаний много, листайте колесом мыши или трекпадом, наведя курсор на шпаргалку.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Шпаргалка")
    }
}

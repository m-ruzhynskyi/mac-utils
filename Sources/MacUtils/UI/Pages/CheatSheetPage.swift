import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUCheatSheet

struct CheatSheetPage: View {
    @AppStorage(Pref.cheatSheet) private var enabled = true
    @AppStorage(Pref.cheatSheetDelay) private var delay = 0.8
    @AppStorage(Pref.cheatSheetSticky) private var sticky = false
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = CheatSheet.shared

    private let delays: [(value: Double, title: String)] = [(0.5, "0,5 с"), (0.8, "0,8 с"), (1.2, "1,2 с"), (2.0, "2 с")]

    var body: some View {
        SettingsPage(.cheatSheet, isOn: $enabled, toggleLabel: "Шпаргалка сочетаний клавиш") {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                if enabled { status }
                GroupLabel("Настройка")
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ListCard {
                        Row("Держать ⌘", systemImage: "command") {
                            Segmented(selection: $delay, options: delays)
                        }
                        ToggleRow("Оставлять открытой",
                                  subtitle: sticky ? "Подержали ⌘ — шпаргалка открылась и остаётся; нажмите ⌘ ещё раз (или Esc), чтобы закрыть."
                                                   : "Шпаргалка видна, только пока ⌘ зажата.",
                                  systemImage: "pin", isOn: $sticky)
                    }
                    Text("Когда сочетаний много, листайте колесом мыши или трекпадом, наведя курсор на шпаргалку.")
                        .font(DS.Font.rowSub).foregroundStyle(.dsMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(!enabled)
                .opacity(enabled ? 1 : DS.State.disabledOpacity)
            }
        }
    }

    /// «Универсальный доступ»: рабочее состояние — таблетка, иначе — предупреждение с кнопкой.
    @ViewBuilder
    private var status: some View {
        if permissions.accessibility && service.isRunning {
            HStack { Pill(.success, "Шпаргалка работает"); Spacer() }
        } else {
            Banner(.warning, title: permissions.accessibility ? "Утилита выключена" : "Нужен доступ «Универсальный доступ»") {
                if !permissions.accessibility {
                    Button("Открыть настройки") {
                        Permissions.requestAccessibility()
                        Permissions.open(.accessibility)
                    }
                    .buttonStyle(.graphite(.primary, size: .compact))
                }
            }
        }
    }
}

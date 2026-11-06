import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUWinKeys

// MARK: - Клавиши Windows

struct WinKeysPage: View {
    @AppStorage(Pref.winKeys) private var enabled = false
    @ObservedObject private var service = WinKeys.shared
    @ObservedObject private var shortcuts = WinKeysShortcuts.shared

    var body: some View {
        SettingsPage(.winKeys, isOn: $enabled, toggleLabel: "Копировать, вставлять, отменять и другие сочетания через Ctrl, как в Windows") {
            ListCard {
                ForEach(WinKeysShortcut.all) { shortcut in
                    ToggleRow(shortcut.windows, subtitle: shortcut.summary, isOn: Binding(
                        get: { shortcuts.isEnabled(shortcut) }, set: { shortcuts.setEnabled(shortcut, $0) }))
                }
                if enabled {
                    AccessibilityStatusRow(running: service.isRunning, readyText: "Работает во всех программах")
                }
            }
            GroupLabel("Где Ctrl остаётся как есть")
            ListCard {
                Row("Терминалы", subtitle: "Там Ctrl+C останавливает команду: Терминал, iTerm2, Ghostty, Warp, WezTerm, kitty и другие.",
                    systemImage: "terminal") { EmptyView() }
                Row("Исключённые программы", subtitle: "Виртуальные машины и удалённые рабочие столы: Ctrl уходит в Windows как есть.",
                    systemImage: "rectangle.on.rectangle.slash") {
                    Button("Открыть список") {
                        NotificationCenter.default.post(name: .openSettingsSection, object: SettingsSection.exclusions)
                    }
                    .buttonStyle(.graphite(.secondary, size: .compact))
                }
            }
            WinKeysExclusionsSection()
            Footnote("Сочетания с ⌘ работают как раньше. Сочетания с Ctrl и ещё одной клавишей (⇧, ⌥, ⌘) не меняются.")
        }
    }
}

/// Свой список программ, где Ctrl остаётся как есть (только для «Клавиш Windows»): редакторы и среды разработки.
private struct WinKeysExclusionsSection: View {
    var body: some View {
        AppListEditor(WinKeysExclusions.shared, fallbackSymbol: "chevron.left.forwardslash.chevron.right") {
            Row("Свои исключения", subtitle: "Редакторы и среды разработки, где сочетания с Ctrl нужны как есть. Запись с точкой на конце — все программы с таким началом.",
                systemImage: "chevron.left.forwardslash.chevron.right") { EmptyView() }
        }
    }
}

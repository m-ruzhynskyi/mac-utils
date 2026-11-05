import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUWinKeys

// MARK: - Клавиши Windows

struct WinKeysPage: View {
    @AppStorage(Pref.winKeys) private var enabled = false
    @ObservedObject private var service = WinKeys.shared

    var body: some View {
        SettingsPage(.winKeys, isOn: $enabled, toggleLabel: "Копировать, вставлять и вырезать через Ctrl, как в Windows") {
            ListCard {
                HintRow(keys: ["Ctrl", "C"], text: "Копировать — как ⌘C")
                HintRow(keys: ["Ctrl", "V"], text: "Вставить — как ⌘V")
                HintRow(keys: ["Ctrl", "X"], text: "Вырезать — как ⌘X. В Finder перемещает файлы, если включено «Вырезать и вставить».")
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
            Footnote("⌘C, ⌘V и ⌘X работают как раньше. Сочетания с Ctrl и ещё одной клавишей (⇧, ⌥, ⌘) не меняются.")
        }
    }
}

/// Свой список программ, где Ctrl остаётся как есть (только для «Клавиш Windows»): редакторы и среды разработки.
private struct WinKeysExclusionsSection: View {
    @ObservedObject private var exclusions = WinKeysExclusions.shared
    @State private var running: [NSRunningApplication] = []

    var body: some View {
        ListCard {
            Row("Свои исключения", subtitle: "Редакторы и среды разработки, где Ctrl+C, Ctrl+V и Ctrl+X нужны как есть. Запись с точкой на конце — все программы с таким началом.",
                systemImage: "chevron.left.forwardslash.chevron.right") { EmptyView() }
            ForEach(exclusions.list, id: \.self) { entry in
                let title = AppExclusions.title(for: entry)
                AppRow(title, subtitle: entry.hasSuffix(".") ? "(все с таким началом)" : (title == entry ? nil : entry),
                       bundleID: entry.hasSuffix(".") ? nil : entry, fallbackSymbol: "chevron.left.forwardslash.chevron.right") {
                    IconButton("Убрать из списка", systemImage: "minus", compact: true) { exclusions.remove(entry) }
                }
            }
        }
        HStack(spacing: DS.Space.s) {
            Menu {
                ForEach(running, id: \.processIdentifier) { app in
                    if let id = app.bundleIdentifier {
                        Button(app.localizedName ?? id) { exclusions.add(id) }
                    }
                }
            } label: {
                Label("Добавить запущенную программу…", systemImage: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.graphite(.secondary))
            .fixedSize()
            .onAppear { refreshRunning() }
            Spacer()
            Button("По умолчанию") { exclusions.resetToDefaults() }
                .buttonStyle(.graphite(.ghost))
        }
    }

    private func refreshRunning() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !exclusions.isExcluded($0.bundleIdentifier) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

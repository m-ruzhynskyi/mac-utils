import AppKit
import SwiftUI
import MUDesign
import MUCore

/// Страница настроек «Исключённые программы»: объяснение и список.
struct ExclusionsPage: View {
    var body: some View {
        SettingsPage(.exclusions) {
            Footnote("Это нужно для виртуальных машин (Parallels, VMware, UTM) и удалённых рабочих столов (Общий экран, Microsoft Remote Desktop, TeamViewer, AnyDesk): они сами передают клавиатуру в другую систему, и перехват Mac Utils им мешает. Если таких программ у вас нет, здесь ничего менять не нужно.")
            ExcludedAppsSection()
        }
    }
}

/// Список исключённых программ с кнопками (на странице «Исключённые программы»).
struct ExcludedAppsSection: View {
    @ObservedObject private var exclusions = AppExclusions.shared
    @State private var running: [NSRunningApplication] = []

    var body: some View {
        GroupLabel("Список")
        ListCard {
            ForEach(exclusions.list, id: \.self) { entry in
                let title = AppExclusions.title(for: entry)
                // Значок программы, если она установлена; префикс bundle id — «все с таким началом».
                AppRow(title, subtitle: entry.hasSuffix(".") ? "(все с таким началом)" : (title == entry ? nil : entry),
                       bundleID: entry.hasSuffix(".") ? nil : entry, fallbackSymbol: "rectangle.on.rectangle.slash") {
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

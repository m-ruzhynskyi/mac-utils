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
    var body: some View {
        GroupLabel("Список")
        AppListEditor(AppExclusions.shared, fallbackSymbol: "rectangle.on.rectangle.slash")
    }
}

/// Список программ с кнопками «Добавить запущенную программу…» и «По умолчанию»: общие исключения и свой список
/// «Клавиш Windows». `header` — строки над списком внутри той же карточки.
struct AppListEditor<Store: AppListStore, Header: View>: View {
    @ObservedObject private var store: Store
    private let fallbackSymbol: String
    private let header: Header
    @State private var running: [NSRunningApplication] = []

    init(_ store: Store, fallbackSymbol: String, @ViewBuilder header: () -> Header) {
        _store = ObservedObject(wrappedValue: store)
        self.fallbackSymbol = fallbackSymbol
        self.header = header()
    }

    var body: some View {
        ListCard {
            header
            ForEach(store.list, id: \.self) { entry in
                let title = AppExclusions.title(for: entry)
                // Значок программы, если она установлена; префикс bundle id — «все с таким началом».
                AppRow(title, subtitle: entry.hasSuffix(".") ? "(все с таким началом)" : (title == entry ? nil : entry),
                       bundleID: entry.hasSuffix(".") ? nil : entry, fallbackSymbol: fallbackSymbol) {
                    IconButton("Убрать из списка", systemImage: "minus", compact: true) { store.remove(entry) }
                }
            }
        }
        HStack(spacing: DS.Space.s) {
            Menu {
                ForEach(running, id: \.processIdentifier) { app in
                    if let id = app.bundleIdentifier {
                        Button(app.localizedName ?? id) { store.add(id) }
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
            Button("По умолчанию") { store.resetToDefaults() }
                .buttonStyle(.graphite(.ghost))
        }
    }

    private func refreshRunning() {
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !store.isExcluded($0.bundleIdentifier) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }
}

extension AppListEditor where Header == EmptyView {
    init(_ store: Store, fallbackSymbol: String) { self.init(store, fallbackSymbol: fallbackSymbol) { EmptyView() } }
}

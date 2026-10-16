import AppKit
import SwiftUI

/// Что показать о сочетании: работает, выключено, занято, совпадает с другим.
struct HotKeyStatus: Equatable {
    enum Level { case ok, off, warning, error }
    let level: Level
    let text: String

    @MainActor
    static func of(_ action: HotKeyAction, combo: LayoutHotKey, entries: [HotKeyRegistry.Entry], center: HotKeyCenter) -> HotKeyStatus {
        let duplicates = HotKeyConflicts.duplicates(of: combo, excluding: .action(action), in: entries)
        if let other = duplicates.first {
            return HotKeyStatus(level: .error, text: "Совпадает с «\(other.title)» — одно из двух не сработает")
        }
        if center.failures[action.hotKeyID] != nil {
            return HotKeyStatus(level: .error, text: "Занято системой или другой программой — выберите другое")
        }
        let system = HotKeyConflicts.system(combo)
        if !center.isRequested(id: action.hotKeyID) {
            return HotKeyStatus(level: .off, text: system.map { "Функция выключена · перекроет: \($0)" } ?? "Функция выключена")
        }
        if let system { return HotKeyStatus(level: .warning, text: "Работает, но перекрывает: \(system)") }
        return HotKeyStatus(level: .ok, text: "Работает")
    }

    var color: Color {
        switch level {
        case .ok: return .green
        case .off: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    var symbol: String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .off: return "minus.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
}

struct HotKeysPage: View {
    @ObservedObject private var prefs = HotKeyPrefs.shared
    @ObservedObject private var center = HotKeyCenter.shared
    @AppStorage(Pref.windowSnap) private var windowSnap = true
    @AppStorage(Pref.windowSnapModifier) private var snapModifier = WindowSnapModifier.controlOption.rawValue

    var body: some View {
        let entries = prefs.entries()
        let problems = HotKeyAction.allCases.filter {
            HotKeyStatus.of($0, combo: HotKeyRegistry.combo(for: $0), entries: entries, center: center).level == .error
        }
        Form {
            Section {
                Text("Все сочетания Mac Utils. Нажмите на сочетание и введите новое (нужен ⌘, ⌥ или ⌃; Esc — отмена). Сочетание, уже занятое другой функцией Mac Utils, не сохранится.")
                    .foregroundStyle(.secondary)
                if !problems.isEmpty {
                    Label("Не работают: \(problems.map(\.title).joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section("Сочетания") {
                ForEach(HotKeyAction.allCases) { action in
                    HotKeyActionRow(action: action, entries: entries)
                }
                if HotKeyAction.allCases.contains(where: { HotKeyRegistry.isCustomized($0) }) {
                    Button("Вернуть все по умолчанию") {
                        for action in HotKeyAction.allCases {
                            HotKeyRegistry.reset(action)
                            HotKeyCenter.shared.reapply(id: action.hotKeyID)
                        }
                    }
                }
            }
            Section("Раскладка окон") {
                Picker("Модификатор", selection: $snapModifier) {
                    ForEach(WindowSnapModifier.allCases) { Text($0.symbols + " + клавиша").tag($0.rawValue) }
                }
                let modifier = WindowSnapModifier(rawValue: snapModifier) ?? .controlOption
                ForEach(WindowTiler.bindings, id: \.label) { binding in
                    let combo = LayoutHotKey(keyCode: binding.keyCode, modifiers: modifier.carbon)
                    let clash = HotKeyConflicts.duplicates(of: combo, excluding: .windowSnap(binding.title), in: entries).first
                    HStack {
                        ShortcutRow(keys: combo.keys, text: binding.title)
                        Spacer()
                        if let clash, windowSnap {
                            Label("Совпадает с «\(clash.title)»", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                        }
                    }
                }
                if !windowSnap {
                    Text("Раскладка окон выключена — эти сочетания сейчас не действуют.").foregroundStyle(.secondary)
                }
            }
            .disabled(!windowSnap)
            Section("Другие клавиши") {
                Text("Удерживание ⌘ — шпаргалка, ⌘Tab — переключатель приложений, ⌘X/⌘V в Finder — перенос файлов. Их меняют в разделах «Шпаргалка», «Переключатель приложений» и «Вырезать и вставить».")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Горячие клавиши")
    }
}

struct HotKeyActionRow: View {
    let action: HotKeyAction
    let entries: [HotKeyRegistry.Entry]
    @ObservedObject private var center = HotKeyCenter.shared

    var body: some View {
        let combo = HotKeyRegistry.combo(for: action)
        let status = HotKeyStatus.of(action, combo: combo, entries: entries, center: center)
        LabeledContent {
            HStack(spacing: 6) {
                ShortcutRecorder(hotKey: combo,
                                 suspend: { $0 ? center.suspend(id: action.hotKeyID) : center.resume(id: action.hotKeyID) },
                                 validate: { HotKeyPrefs.shared.problem($0, for: action) }) {
                    HotKeyRegistry.setCombo($0, for: action)
                    HotKeyCenter.shared.reapply(id: action.hotKeyID)
                }
                Button {
                    HotKeyRegistry.reset(action)
                    HotKeyCenter.shared.reapply(id: action.hotKeyID)
                } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless)
                    .help("По умолчанию: \(action.defaultCombo.title)")
                    .opacity(HotKeyRegistry.isCustomized(action) ? 1 : 0)
                    .disabled(!HotKeyRegistry.isCustomized(action))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Button(action.title) {
                    NotificationCenter.default.post(name: .openSettingsSection, object: action.section)
                }
                .buttonStyle(.plain)
                .help("Открыть раздел «\(action.section.title)»")
                Label(status.text, systemImage: status.symbol)
                    .font(.caption)
                    .foregroundStyle(status.color)
            }
        }
    }
}

import AppKit
import SwiftUI

// MARK: - Раскладка

struct LayoutPage: View {
    @AppStorage(Pref.layoutFix) private var enabled = true
    @AppStorage(Pref.layoutFixSwitchSource) private var switchSource = false
    @AppStorage("layoutFixCyrillic") private var cyrillic = "auto"
    @AppStorage(Pref.layoutFixKeyCode) private var keyCode = LayoutHotKey.commandBracket.keyCode
    @AppStorage(Pref.layoutFixModifiers) private var modifiers = LayoutHotKey.commandBracket.modifiers
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = LayoutFix.shared

    private var current: LayoutHotKey { LayoutHotKey(keyCode: keyCode, modifiers: modifiers) }

    var body: some View {
        Form {
            Section {
                Toggle("Исправление раскладки", isOn: $enabled)
                Text("Набрали по-русски в английской раскладке (ghbdtn) или наоборот (руддщ)? Нажмите горячую клавишу — текст переведётся (привет, hello).")
                    .foregroundStyle(.secondary)
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Исправление раскладки работает")
                }
            }
            Section("Горячая клавиша") {
                LabeledContent("Перевести") {
                    ShortcutRecorder(hotKey: current, validate: { HotKeyPrefs.shared.problem($0, for: .layoutFix) }) { $0.save() }
                }
                LabeledContent("Готовые варианты") {
                    HStack {
                        ForEach(LayoutHotKey.presets, id: \.title) { preset in
                            Button(preset.title) { preset.save() }
                                .disabled(preset == current)
                        }
                    }
                }
                if enabled && !service.hotKeyRegistered && permissions.accessibility {
                    Label("Сочетание \(current.title) занято системой или другим приложением — выберите другое.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let note = current.conflictNote {
                    Text(note).foregroundStyle(.secondary)
                }
            }
            .disabled(!enabled)
            AppInputSourceSection()
            Section("Как пользоваться") {
                ShortcutRow(keys: current.keys, text: "Без выделения — последнее набранное слово. С выделением — весь выделенный текст.")
                Text("Повторное нажатие возвращает слово обратно. Клик мышью, стрелки и Enter начинают слово заново. В полях паролей не работает.")
                    .foregroundStyle(.secondary)
                Toggle("Переключать раскладку после исправления", isOn: $switchSource)
                    .disabled(!enabled)
                Picker("Кириллица", selection: $cyrillic) {
                    Text("Авто (по включённым раскладкам)").tag("auto")
                    Text("Русская").tag("russian")
                    Text("Украинская").tag("ukrainian")
                }
                .disabled(!enabled)
                Text("Какую раскладку подставлять при переводе с английской: ghbdtn → привет (русская) или ghbdsn → привіт (украинская). Текст кириллицей всегда переводится в английскую.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Раскладка")
    }
}

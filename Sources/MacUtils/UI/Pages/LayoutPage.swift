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
        SettingsPage(.layout, isOn: $enabled, toggleLabel: "Исправление раскладки") {
            if enabled {
                ListCard { AccessibilityStatusRow(running: service.isRunning, readyText: "Исправление раскладки работает") }
            }
            GroupLabel("Горячая клавиша")
            ListCard {
                Row("Перевести", systemImage: "keyboard") {
                    ShortcutRecorder(hotKey: current, validate: { HotKeyPrefs.shared.problem($0, for: .layoutFix) }) { $0.save() }
                }
                Row("Готовые варианты", systemImage: "list.bullet") {
                    HStack(spacing: DS.Space.s) {
                        ForEach(LayoutHotKey.presets, id: \.title) { preset in
                            Button(preset.title) { preset.save() }
                                .buttonStyle(.graphite(.secondary, size: .compact))
                                .disabled(preset == current)
                        }
                    }
                }
            }
            .disabled(!enabled)
            if enabled && !service.hotKeyRegistered && permissions.accessibility {
                Banner(.warning, title: "Сочетание \(current.title) занято системой или другим приложением — выберите другое.")
            }
            if let note = current.conflictNote {
                Footnote(note)
            }
            AppLayoutRulesCard()
            GroupLabel("Как пользоваться")
            ListCard {
                HintRow(keys: current.keys, text: "Без выделения — последнее набранное слово. С выделением — весь выделенный текст.")
                ToggleRow("Переключать раскладку после исправления", systemImage: "globe", isOn: $switchSource)
                    .disabled(!enabled)
                Row("Кириллица",
                    subtitle: "Какую раскладку подставлять при переводе с английской: ghbdtn → привет (русская) или ghbdsn → привіт (украинская). Текст кириллицей всегда переводится в английскую.",
                    systemImage: "character") {
                    Picker("Кириллица", selection: $cyrillic) {
                        Text("Авто (по включённым раскладкам)").tag("auto")
                        Text("Русская").tag("russian")
                        Text("Украинская").tag("ukrainian")
                    }
                    .graphitePicker()
                }
                .disabled(!enabled)
            }
            Footnote("Повторное нажатие возвращает слово обратно. Клик мышью, стрелки и Enter начинают слово заново. В полях паролей не работает.")
        }
    }
}

/// «Раскладка по программам» в стиле Graphite: то же поведение, что у `AppInputSourceSection` (`Features/AppInputSource`),
/// но строками карточки вместо `Form`.
private struct AppLayoutRulesCard: View {
    @AppStorage(Pref.appInputSource) private var enabled = true
    @AppStorage(Pref.appInputRemember) private var remember = true
    @ObservedObject private var service = AppInputSource.shared
    @State private var newApp = ""

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }

    var body: some View {
        GroupLabel("Раскладка по программам")
        ListCard {
            ToggleRow("Переключать раскладку при смене программы", systemImage: "arrow.left.arrow.right", isOn: $enabled)
            ToggleRow("Запоминать последнюю раскладку в каждой программе",
                      subtitle: "Например: в Telegram была русская, в Терминале — английская. Переключитесь один раз — дальше Mac Utils сделает это сам. Правило ниже важнее запомненного.",
                      systemImage: "memories", isOn: $remember)
                .disabled(!enabled)
            ForEach(service.rules.keys.sorted(), id: \.self) { bundleID in
                AppRow(appName(bundleID), bundleID: bundleID) {
                    Picker("", selection: Binding(
                        get: { service.rules[bundleID] ?? "" },
                        set: { service.setRule(bundleID, sourceID: $0) })) {
                        ForEach(service.sources) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    IconButton("Удалить правило", systemImage: "minus", compact: true) { service.setRule(bundleID, sourceID: nil) }
                }
            }
            Row("Добавить правило для", systemImage: "plus.app") {
                Picker("Добавить правило для", selection: $newApp) {
                    Text("Выберите программу…").tag("")
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Text(app.localizedName ?? app.bundleIdentifier ?? "").tag(app.bundleIdentifier ?? "")
                    }
                }
                .graphitePicker()
                Button("Добавить") {
                    guard !newApp.isEmpty, let first = AppInputSource.currentSourceID() ?? service.sources.first?.id else { return }
                    service.setRule(newApp, sourceID: first)
                    newApp = ""
                }
                .buttonStyle(.graphite(.primary, size: .compact))
                .disabled(newApp.isEmpty)
            }
            if !service.remembered.isEmpty {
                Row("Запомнено программ: \(service.remembered.count)", systemImage: "tray.full") {
                    Button("Забыть") { service.forgetRemembered() }.buttonStyle(.graphite(.secondary, size: .compact))
                }
            }
        }
        .onAppear { service.sync() }
    }
}

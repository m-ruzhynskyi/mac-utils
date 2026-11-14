import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MUCore
import MUDesign
import MUHiddenScreen

// MARK: - Скрытый экран

struct HiddenScreenPage: View {
    @StateObject private var store: HiddenScreenStore
    @AppStorage(HiddenScreenUI.alwaysOnTopKey) private var alwaysOnTop = true
    @State private var checks: [PreCallCheck]

    /// `controller` и `checks` задаются для снимков и тестов; в приложении — живой движок и чтение системы.
    init(controller: HiddenScreenControlling? = nil, checks: [PreCallCheck]? = nil) {
        _store = StateObject(wrappedValue: HiddenScreenStore(controller ?? MainActor.assumeIsolated { HiddenScreenUI.controller }))
        _checks = State(initialValue: checks ?? PreCallProbe.run())
    }

    var body: some View {
        let state = store.state
        SettingsPage(.hiddenScreen, isOn: Binding(get: { state.isEnabled }, set: { store.controller.setEnabled($0) }),
                     toggleLabel: "Скрытый экран") {
            GroupLabel("Программы")
            ListCard {
                ForEach(state.apps) { app in
                    AppRow(app.name, subtitle: HiddenScreenRules.appSubtitle(app, enabled: state.isEnabled), bundleID: app.bundleID) {
                        IconButton("Убрать «\(app.name)»", systemImage: "minus.circle", compact: true) {
                            store.controller.removeApp(app.bundleID)
                        }
                    }
                }
                Row("Добавить программу", subtitle: "Любая программа, которую не нужно показывать в звонке", systemImage: "plus") {
                    Button("+ Добавить программу") { HiddenScreenAppPicker.choose { store.controller.addApp(bundleID: $0.bundleID, name: $0.name) } }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                }
            }
            GroupLabel("Клавиши")
            ListCard {
                HiddenScreenKeyRow(action: .hiddenScreen, title: "Включить и выключить")
                HiddenScreenKeyRow(action: .hiddenScreenWindow, title: "Показать или спрятать окно ИИ")
                ToggleRow("Окно ИИ поверх всех окон", subtitle: "Не закрывается другими программами, пока вы в звонке",
                          systemImage: "square.3.layers.3d.top.filled", isOn: $alwaysOnTop)
            }
            GroupLabel("Перед звонком")
            ListCard {
                ForEach(checks) { check in
                    FeatureStatusRow(tone: check.level == .ok ? .success : .warning, label: check.title, detail: check.detail,
                                     actions: check.action.map { act in [StatusAction(title: "Открыть настройки") { HiddenScreenSettingsLinks.open(act) }] } ?? [])
                }
            }
            Footnote("Выключили скрытый экран — окна Claude и ChatGPT возвращаются на ваш экран туда, где были.")
        }
        .onAppear { checks = checks.isEmpty ? PreCallProbe.run() : checks }
    }
}

private struct HiddenScreenKeyRow: View {
    let action: HotKeyAction
    let title: String
    @ObservedObject private var center = HotKeyCenter.shared

    var body: some View {
        Row(title, systemImage: "keyboard") {
            ShortcutRecorder(hotKey: HotKeyRegistry.combo(for: action),
                             suspend: { $0 ? center.suspend(id: action.hotKeyID) : center.resume(id: action.hotKeyID) },
                             validate: { HotKeyPrefs.shared.problem($0, for: action) }) {
                HotKeyRegistry.setCombo($0, for: action)
                center.reapply(id: action.hotKeyID)
            }
        }
    }
}

/// Ссылки на панели «Системных настроек»: только открытие, ничего не меняется.
enum HiddenScreenSettingsLinks {
    static func open(_ action: PreCallCheck.Action) {
        let url: String
        switch action {
        case .openNotificationSettings: url = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .openSoundSettings: url = "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        }
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

/// Выбор программы для скрытия: обычная панель открытия на /Applications.
enum HiddenScreenAppPicker {
    static func choose(_ done: @escaping (_ app: (bundleID: String, name: String)) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Добавить"
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        done((id, name))
    }
}

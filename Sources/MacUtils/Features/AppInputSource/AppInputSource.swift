import AppKit
import Carbon
import SwiftUI

/// Какую раскладку включить для программы (без системных вызовов — для тестов).
enum InputSourceRules {
    /// Правило важнее запомненного; запомненное — только если включено «запоминать».
    static func target(for bundleID: String, rules: [String: String], remembered: [String: String],
                       remember: Bool) -> String? {
        rules[bundleID] ?? (remember ? remembered[bundleID] : nil)
    }
}

struct KeyboardInputSource: Identifiable, Hashable {
    let id: String
    let name: String
}

/// «Раскладка по программам»: при переключении программ включается её раскладка —
/// заданная правилом или последняя, с которой в ней работали (Telegram — русская,
/// Терминал — английская).
@MainActor
final class AppInputSource: ObservableObject {
    static let shared = AppInputSource()

    @Published private(set) var rules: [String: String]
    @Published private(set) var remembered: [String: String]
    @Published private(set) var sources: [KeyboardInputSource] = []

    /// Когда мы сами переключили раскладку — это не выбор пользователя.
    private var ownSwitchUntil = Date.distantPast
    private var observing = false

    private init() {
        let defaults = UserDefaults.standard
        rules = defaults.dictionary(forKey: Pref.appInputRules) as? [String: String] ?? [:]
        remembered = defaults.dictionary(forKey: Pref.appInputRemembered) as? [String: String] ?? [:]
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.appInputSource) }
    private var remember: Bool { UserDefaults.standard.bool(forKey: Pref.appInputRemember) }

    func sync() {
        sources = Self.availableSources()
        guard !observing else { return }
        observing = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(sourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil)
    }

    // MARK: - События

    @objc private func appActivated(_ note: Notification) {
        guard enabled,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let target = InputSourceRules.target(for: bundleID, rules: rules, remembered: remembered, remember: remember),
              target != Self.currentSourceID() else { return }
        select(target)
    }

    @objc private func sourceChanged() {
        guard enabled, remember, Date() > ownSwitchUntil,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let current = Self.currentSourceID() else { return }
        remembered[bundleID] = current
        UserDefaults.standard.set(remembered, forKey: Pref.appInputRemembered)
    }

    private func select(_ id: String) {
        guard let source = Self.source(id: id) else { return }
        ownSwitchUntil = Date().addingTimeInterval(0.6)
        TISSelectInputSource(source)
    }

    // MARK: - Правила

    func setRule(_ bundleID: String, sourceID: String?) {
        rules[bundleID] = sourceID
        UserDefaults.standard.set(rules, forKey: Pref.appInputRules)
    }

    func forgetRemembered() {
        remembered = [:]
        UserDefaults.standard.removeObject(forKey: Pref.appInputRemembered)
    }

    func name(of sourceID: String) -> String {
        sources.first { $0.id == sourceID }?.name ?? sourceID
    }

    // MARK: - TIS

    static func availableSources() -> [KeyboardInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            guard let id = string(source, kTISPropertyInputSourceID) else { return nil }
            return KeyboardInputSource(id: id, name: string(source, kTISPropertyLocalizedName) ?? id)
        }
    }

    static func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(source, kTISPropertyInputSourceID)
    }

    private static func source(id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        return (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource])?.first
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

/// Раздел настроек «Раскладка по программам» (внутри страницы «Раскладка»).
struct AppInputSourceSection: View {
    @AppStorage(Pref.appInputSource) private var enabled = true
    @AppStorage(Pref.appInputRemember) private var remember = true
    @ObservedObject private var service = AppInputSource.shared
    @State private var newApp = ""

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Section("Раскладка по программам") {
            Toggle("Переключать раскладку при смене программы", isOn: $enabled)
            Toggle("Запоминать последнюю раскладку в каждой программе", isOn: $remember)
                .disabled(!enabled)
            Text("Например: в Telegram была русская, в Терминале — английская. Переключитесь один раз — дальше Mac Utils сделает это сам. Правило ниже важнее запомненного.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(service.rules.keys.sorted(), id: \.self) { bundleID in
                HStack {
                    appLabel(bundleID)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { service.rules[bundleID] ?? "" },
                        set: { service.setRule(bundleID, sourceID: $0) })) {
                        ForEach(service.sources) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                    Button { service.setRule(bundleID, sourceID: nil) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Удалить правило")
                }
            }
            HStack {
                Picker("Добавить правило для", selection: $newApp) {
                    Text("Выберите программу…").tag("")
                    ForEach(runningApps, id: \.bundleIdentifier) { app in
                        Text(app.localizedName ?? app.bundleIdentifier ?? "").tag(app.bundleIdentifier ?? "")
                    }
                }
                Button("Добавить") {
                    guard !newApp.isEmpty, let first = AppInputSource.currentSourceID() ?? service.sources.first?.id else { return }
                    service.setRule(newApp, sourceID: first)
                    newApp = ""
                }
                .disabled(newApp.isEmpty)
            }
            if !service.remembered.isEmpty {
                HStack {
                    Text("Запомнено программ: \(service.remembered.count)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Забыть") { service.forgetRemembered() }
                }
            }
        }
        .onAppear { service.sync() }
    }

    @ViewBuilder
    private func appLabel(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 6) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            }
            Text(url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID)
        }
    }
}

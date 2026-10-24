import AppKit
import Carbon
import SwiftUI
import MUCore

/// Какую раскладку включить для программы (без системных вызовов — для тестов).
package enum InputSourceRules {
    /// Правило важнее запомненного; запомненное — только если включено «запоминать».
    package static func target(for bundleID: String, rules: [String: String], remembered: [String: String],
                       remember: Bool) -> String? {
        rules[bundleID] ?? (remember ? remembered[bundleID] : nil)
    }

    /// Сразу после смены программы уведомление о раскладке может относиться к прошлой программе
    /// (или к нашему же переключению, пришедшему с задержкой) — не запоминаем.
    package static let settleAfterActivation: TimeInterval = 0.5

    /// Запомнить ли текущую раскладку как выбранную пользователем в программе `front`.
    /// - secure: включён защищённый ввод (поле пароля): система сама переключает на латиницу, это не выбор пользователя;
    /// - ownUntil: до этого момента смена раскладки — наша собственная;
    /// - activatedAt: когда активировалась текущая программа.
    package static func shouldRemember(now: Date, ownUntil: Date, activatedAt: Date?, secure: Bool,
                               front: String?, ownBundleID: String?) -> Bool {
        guard !secure, now > ownUntil, let front, !front.isEmpty, front != ownBundleID else { return false }
        if let activatedAt, now.timeIntervalSince(activatedAt) < settleAfterActivation { return false }
        return true
    }
}

package struct KeyboardInputSource: Identifiable, Hashable {
    package let id: String
    package let name: String
}

/// «Раскладка по программам»: при переключении программ включается её раскладка —
/// заданная правилом или последняя, с которой в ней работали (Telegram — русская,
/// Терминал — английская).
@MainActor
package final class AppInputSource: ObservableObject {
    package static let shared = AppInputSource()

    @Published package private(set) var rules: [String: String]
    @Published package private(set) var remembered: [String: String]
    @Published package private(set) var sources: [KeyboardInputSource] = []

    /// Когда мы сами переключили раскладку — это не выбор пользователя.
    private var ownSwitchUntil = Date.distantPast
    /// Программа, активная сейчас, и когда она стала активной (раскладка запоминается за ней, а не за той,
    /// что окажется впереди к моменту запоздавшего уведомления).
    private var activeBundleID: String?
    private var activatedAt: Date?
    private var observing = false

    private init() {
        let defaults = UserDefaults.standard
        rules = defaults.dictionary(forKey: Pref.appInputRules) as? [String: String] ?? [:]
        remembered = defaults.dictionary(forKey: Pref.appInputRemembered) as? [String: String] ?? [:]
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.appInputSource) }
    private var remember: Bool { UserDefaults.standard.bool(forKey: Pref.appInputRemember) }

    package func sync() {
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
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        activeBundleID = app?.bundleIdentifier
        activatedAt = Date()
        guard enabled,
              let app,
              let bundleID = app.bundleIdentifier,
              let target = InputSourceRules.target(for: bundleID, rules: rules, remembered: remembered, remember: remember),
              target != Self.currentSourceID() else { return }
        select(target)
    }

    @objc private func sourceChanged() {
        let front = activeBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard enabled, remember,
              InputSourceRules.shouldRemember(now: Date(), ownUntil: ownSwitchUntil, activatedAt: activatedAt,
                                              secure: IsSecureEventInputEnabled(), front: front,
                                              ownBundleID: Bundle.main.bundleIdentifier),
              let bundleID = front,
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

    package func setRule(_ bundleID: String, sourceID: String?) {
        rules[bundleID] = sourceID
        UserDefaults.standard.set(rules, forKey: Pref.appInputRules)
    }

    package func forgetRemembered() {
        remembered = [:]
        UserDefaults.standard.removeObject(forKey: Pref.appInputRemembered)
    }

    package func name(of sourceID: String) -> String {
        sources.first { $0.id == sourceID }?.name ?? sourceID
    }

    // MARK: - TIS

    package static func availableSources() -> [KeyboardInputSource] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap { source in
            guard let id = string(source, kTISPropertyInputSourceID) else { return nil }
            return KeyboardInputSource(id: id, name: string(source, kTISPropertyLocalizedName) ?? id)
        }
    }

    package static func currentSourceID() -> String? {
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
package struct AppInputSourceSection: View {
    @AppStorage(Pref.appInputSource) private var enabled = true
    @AppStorage(Pref.appInputRemember) private var remember = true
    @ObservedObject private var service = AppInputSource.shared
    @State private var newApp = ""

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    package var body: some View {
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

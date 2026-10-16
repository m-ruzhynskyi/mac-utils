import AppKit
import SwiftUI

// MARK: - Общие

struct GeneralPage: View {
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var hotKeys = HotKeyPrefs.shared
    @AppStorage(Pref.menuBarIcon) private var menuBarIcon = true
    @AppStorage(Pref.showInDock) private var showInDock = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(showInDock ? "Mac Utils показан в Dock: клик по значку открывает настройки." : "Mac Utils работает в фоне, без иконки в Dock.")
                    Text("Открыть это окно: запустите приложение ещё раз или нажмите \(HotKeyRegistry.combo(for: .settings).title). Все сочетания — в разделе «Горячие клавиши».")
                        .foregroundStyle(.secondary)
                }
                Toggle("Показывать в Dock", isOn: $showInDock)
                Toggle("Значок в строке меню", isOn: $menuBarIcon)
                if menuBarIcon {
                    Text("Какие вкладки показывать в панели — в разделе «Панель в строке меню».")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Клик — панель «Инструменты» со вкладками прямо под значком (или \(HotKeyRegistry.combo(for: .tools).title)). Настройки и выход — в шапке панели.")
                    .foregroundStyle(.secondary)
            }

            if MoveToApplications.showsBanner {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.down.app").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mac Utils не в «Программах»").font(.headline)
                            Text("Оттуда запущенное приложение не может само обновляться.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Перенести…") { MoveToApplications.presentOffer() }
                    }
                }
            }

            Section("Разрешения") {
                StatusLine(ok: permissions.accessibility,
                           okText: "Универсальный доступ выдан",
                           problemText: "Универсальный доступ: нужен для ⌘X/⌘V, прокрутки и переключателя",
                           action: {
                               Permissions.requestAccessibility()
                               Permissions.open(.accessibility)
                           })
                StatusLine(ok: permissions.screenRecording,
                           okText: "Запись экрана разрешена",
                           problemText: "Запись экрана: нужна для снимков",
                           action: {
                               Permissions.requestScreenRecording()
                               Permissions.open(.screenRecording)
                           },
                           relaunchHint: true)
                StatusLine(ok: permissions.microphone == .granted,
                           okText: "Микрофон разрешён",
                           problemText: permissions.microphone == .denied
                               ? "Микрофон запрещён: нужен записям встреч и записи экрана с микрофоном"
                               : "Микрофон: нужен записям встреч и записи экрана с микрофоном",
                           action: {
                               if permissions.microphone == .notAsked { Permissions.requestMicrophone() }
                               else { Permissions.open(.microphone) }
                           },
                           actionTitle: permissions.microphone == .notAsked ? "Разрешить" : "Открыть настройки")
                if let disk = permissions.fullDiskAccess {
                    StatusLine(ok: disk,
                               okText: "Полный доступ к диску есть",
                               problemText: "Полный доступ к диску: нужен удалению программ и очистке",
                               action: { Permissions.openFullDiskAccess() },
                               relaunchHint: true)
                }
                HStack {
                    Text("Управление Finder (Автоматизация) macOS спросит при первом ⌘X.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Открыть") { Permissions.open(.automation) }
                }
            }

            UpdatesSection()

            Section {
                Toggle("Открывать при входе в систему", isOn: Binding(
                    get: { permissions.launchAtLogin },
                    set: { permissions.setLaunchAtLogin($0) }
                ))
            }

            Section {
                HStack {
                    Text("Версия \(Updater.shared.displayVersion) (сборка \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")) · © Maksym Ruzhynskyi")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Выйти из Mac Utils") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Общие")
    }
}

// MARK: - Обновления

struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true
    @AppStorage(Pref.updateRepo) private var customRepo = ""

    private var statusText: String {
        switch updater.state {
        case .idle: return ""
        case .checking: return "Проверяю…"
        case .upToDate: return "Установлена последняя версия"
        case .available(let version): return "Доступна версия \(version)"
        case .installing(let version): return "Устанавливаю \(version)…"
        case .failed(let message): return message
        }
    }

    var body: some View {
        Section("Обновления") {
            LabeledContent("Версия") {
                HStack {
                    Text(updater.displayVersion)
                    Button("Что нового и история версий") { WhatsNewWindowController.shared.show() }
                }
            }
            TextField("Репозиторий GitHub", text: $customRepo,
                      prompt: Text(updater.repository.isEmpty ? "владелец/имя" : updater.repository))
            Toggle("Обновляться автоматически", isOn: $autoUpdate)
            HStack {
                Text(statusText)
                    .foregroundStyle(.secondary)
                Spacer()
                if case .available = updater.state {
                    Button("Установить") { updater.installAvailable() }
                }
                Button("Проверить сейчас") { updater.check(install: false, userInitiated: true) }
            }
            Text("Новая версия собирается на GitHub при каждом пуше в main. Приложение проверяет релизы раз в 6 часов и само перезапускается после обновления.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

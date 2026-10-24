import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUUpdate
import MUScreenshot
import MUTextEditor

// MARK: - Общие

struct GeneralPage: View {
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var hotKeys = HotKeyPrefs.shared
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Pref.menuBarIcon) private var menuBarIcon = true
    @AppStorage(Pref.showInDock) private var showInDock = false
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true

    var body: some View {
        SettingsPage(.general) {
            if MoveToApplications.showsBanner {
                Banner(.warning, title: "Mac Utils не в «Программах»", message: "Оттуда запущенное приложение не может само обновляться.") {
                    Button("Перенести…") { MoveToApplications.presentOffer() }.buttonStyle(.graphite(.primary, size: .compact))
                }
            }
            ListCard {
                ToggleRow("Открывать при входе в систему", subtitle: "Mac Utils запускается вместе с macOS", systemImage: "power",
                          isOn: Binding(get: { permissions.launchAtLogin }, set: { permissions.setLaunchAtLogin($0) }))
                ToggleRow("Обновляться автоматически", subtitle: "Скачивать и ставить новые версии",
                          systemImage: "arrow.triangle.2.circlepath", isOn: $autoUpdate)
                ToggleRow("Значок в строке меню",
                          subtitle: "Клик — панель «Инструменты» со вкладками прямо под значком (или \(HotKeyRegistry.combo(for: .tools).title)). Настройки и выход — в шапке панели.",
                          systemImage: "menubar.rectangle", isOn: $menuBarIcon)
                ToggleRow("Показывать в Dock",
                          subtitle: showInDock ? "Mac Utils показан в Dock: клик по значку открывает настройки." : "Mac Utils работает в фоне, без иконки в Dock.",
                          systemImage: "dock.rectangle", isOn: $showInDock)
            }
            Footnote("Открыть это окно: запустите приложение ещё раз или нажмите \(HotKeyRegistry.combo(for: .settings).title). Все сочетания — в разделе «Горячие клавиши».")
            if menuBarIcon {
                Footnote("Какие вкладки показывать в панели — в разделе «Панель в строке меню».")
            }

            GroupLabel("Разрешения")
            ListCard {
                PermissionRow(.accessibility, state: permissions.accessibility ? .granted : .needed,
                              purpose: "Нужен для ⌘X/⌘V, прокрутки и переключателя",
                              action: {
                                  Permissions.requestAccessibility()
                                  Permissions.open(.accessibility)
                              },
                              statusText: permissions.accessibility ? "Универсальный доступ выдан"
                                  : "Универсальный доступ: нужен для ⌘X/⌘V, прокрутки и переключателя")
                PermissionRow(.screenRecording, state: permissions.screenRecording ? .granted : .needed,
                              purpose: "Нужна для снимков",
                              action: {
                                  Permissions.requestScreenRecording()
                                  Permissions.open(.screenRecording)
                              },
                              relaunchHint: true,
                              statusText: permissions.screenRecording ? "Запись экрана разрешена" : "Запись экрана: нужна для снимков")
                PermissionRow(.microphone, state: microphoneState,
                              purpose: "Нужен записям встреч и записи экрана с микрофоном",
                              actionTitle: permissions.microphone == .notAsked ? "Разрешить" : "Открыть настройки",
                              action: {
                                  if permissions.microphone == .notAsked { Permissions.requestMicrophone() }
                                  else { Permissions.open(.microphone) }
                              },
                              statusText: microphoneStatusText)
                if let disk = permissions.fullDiskAccess {
                    PermissionRow(.fullDiskAccess, state: disk ? .granted : .needed,
                                  purpose: "Нужен удалению программ и очистке",
                                  action: { Permissions.openFullDiskAccess() },
                                  relaunchHint: true,
                                  statusText: disk ? "Полный доступ к диску есть" : "Полный доступ к диску: нужен удалению программ и очистке")
                }
                Row("Управление Finder (Автоматизация)", subtitle: "macOS спросит при первом ⌘X.", systemImage: PermissionKind.automation.symbol) {
                    Button("Открыть") { Permissions.open(.automation) }.buttonStyle(.graphite(.secondary, size: .compact))
                }
            }

            UpdatesSection()

            HStack(spacing: DS.Space.m) {
                Text("Версия \(updater.displayVersion) (сборка \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")) · © Maksym Ruzhynskyi")
                    .font(DS.Font.manrope(13, .regular, relativeTo: .callout))
                    .foregroundStyle(.dsMute)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.m)
                Button("Выйти из Mac Utils") { NSApp.terminate(nil) }.buttonStyle(.graphite(.ghost))
                Button("Проверить сейчас") { updater.check(install: false, userInitiated: true) }.buttonStyle(.graphite(.primary))
            }
            .padding(.top, DS.Space.s)
        }
    }

    private var microphoneState: PermissionState {
        switch permissions.microphone {
        case .granted: return .granted
        case .denied: return .denied
        default: return .needed
        }
    }

    private var microphoneStatusText: String {
        switch permissions.microphone {
        case .granted: return "Микрофон разрешён"
        case .denied: return "Микрофон запрещён: нужен записям встреч и записи экрана с микрофоном"
        default: return "Микрофон: нужен записям встреч и записи экрана с микрофоном"
        }
    }
}

// MARK: - Обновления

struct UpdatesSection: View {
    @ObservedObject private var updater = Updater.shared
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

    private var available: Bool {
        if case .available = updater.state { return true }
        return false
    }

    var body: some View {
        GroupLabel("Обновления")
        ListCard {
            Row("Версия", subtitle: updater.displayVersion, systemImage: "shippingbox") {
                Button("Что нового и история версий") { WhatsNewWindowController.shared.show() }
                    .buttonStyle(.graphite(.secondary, size: .compact))
            }
            Row("Репозиторий GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                TextField("Репозиторий GitHub", text: $customRepo,
                          prompt: Text(updater.repository.isEmpty ? "владелец/имя" : updater.repository))
                    .textFieldStyle(.graphite)
                    .labelsHidden()
                    .frame(width: 220)
            }
            if !statusText.isEmpty {
                Row(statusText, systemImage: available ? "arrow.down.circle" : "info.circle", tile: available ? .accent : .neutral) {
                    if available {
                        Button("Установить") { updater.installAvailable() }.buttonStyle(.graphite(.primary, size: .compact))
                    }
                }
            }
        }
        Footnote("Новая версия собирается на GitHub при каждом пуше в main. Приложение проверяет релизы раз в 6 часов и само перезапускается после обновления.")
    }
}

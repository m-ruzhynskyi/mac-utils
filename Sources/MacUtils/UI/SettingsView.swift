// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Модель разрешений

@MainActor
final class PermissionsModel: NSObject, ObservableObject {
    static let shared = PermissionsModel()

    @Published private(set) var accessibility = Permissions.accessibility
    @Published private(set) var screenRecording = Permissions.screenRecording
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var timer: Timer?

    private override init() {
        super.init()
        let timer = Timer(timeInterval: 1.5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() {
        guard SettingsWindowController.shared.isVisible else { return }
        refresh()
    }

    func refresh() {
        let ax = Permissions.accessibility
        let screen = Permissions.screenRecording
        let login = SMAppService.mainApp.status == .enabled
        if ax != accessibility { accessibility = ax }
        if screen != screenRecording { screenRecording = screen }
        if login != launchAtLogin { launchAtLogin = login }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
        refresh()
    }
}

// MARK: - Разделы

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, cutPaste, smoothScroll, switcher, screenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Общие"
        case .cutPaste: return "Вырезать и вставить"
        case .smoothScroll: return "Плавная прокрутка"
        case .switcher: return "Переключатель приложений"
        case .screenshot: return "Снимки экрана"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .cutPaste: return "scissors"
        case .smoothScroll: return "computermouse"
        case .switcher: return "rectangle.on.rectangle"
        case .screenshot: return "camera.viewfinder"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .cutPaste: return .orange
        case .smoothScroll: return .green
        case .switcher: return .blue
        case .screenshot: return .purple
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.symbol)
                        .foregroundStyle(section.tint)
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            switch selection ?? .general {
            case .general: GeneralPage()
            case .cutPaste: CutPastePage()
            case .smoothScroll: SmoothScrollPage()
            case .switcher: SwitcherPage()
            case .screenshot: ScreenshotPage()
            }
        }
    }
}

// MARK: - Общие элементы

struct StatusLine: View {
    let ok: Bool
    let okText: String
    let problemText: String
    var action: (() -> Void)?
    var actionTitle = "Открыть настройки"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(ok ? okText : problemText)
                .foregroundStyle(ok ? Color.green : Color.orange)
            Spacer()
            if !ok, let action {
                Button(actionTitle, action: action)
            }
        }
    }
}

struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold))
            .frame(minWidth: 26, minHeight: 24)
            .padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
    }
}

struct ShortcutRow: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.self) { KeyCap(key: $0) }
            Text(text).padding(.leading, 4)
        }
    }
}

@MainActor
private func accessibilityStatus(_ model: PermissionsModel, running: Bool, readyText: String) -> some View {
    var action: (() -> Void)?
    if !model.accessibility {
        action = {
            Permissions.requestAccessibility()
            Permissions.open(.accessibility)
        }
    }
    return StatusLine(
        ok: model.accessibility && running,
        okText: readyText,
        problemText: model.accessibility ? "Утилита выключена" : "Нужен доступ «Универсальный доступ»",
        action: action
    )
}

// MARK: - Общие

struct GeneralPage: View {
    @ObservedObject private var permissions = PermissionsModel.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac Utils работает в фоне: без иконки в Dock и в строке меню.")
                    Text("Открыть это окно: запустите приложение ещё раз или нажмите ⌃⌥⌘ ,")
                        .foregroundStyle(.secondary)
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
                           })
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
                    Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · GPL-3.0")
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
            LabeledContent("Версия", value: updater.currentVersion)
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

// MARK: - Вырезать и вставить

struct CutPastePage: View {
    @AppStorage(Pref.cutPaste) private var enabled = true
    @AppStorage(Pref.cutPanel) private var showPanel = true
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = FinderCutPaste.shared

    var body: some View {
        Form {
            Section {
                Toggle("Вырезать и вставлять файлы в Finder", isOn: $enabled)
                Text("⌘X — вырезать, ⌘V — переместить файлы и папки в Finder.")
                    .foregroundStyle(.secondary)
                Toggle("Показывать плавающую панель", isOn: $showPanel)
                    .disabled(!enabled)
                Text("Пока Finder активен, панель показывает вырезанные файлы.")
                    .foregroundStyle(.secondary)
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Готово к вырезанию в Finder")
                }
            }

            Section("Как пользоваться") {
                ShortcutRow(keys: ["⌘", "X"], text: "Выделите объекты в Finder и нажмите ⌘X.")
                ShortcutRow(keys: ["⌘", "V"], text: "Откройте нужную папку и нажмите ⌘V — объекты переместятся.")
                Text("В текстовых полях (например, при переименовании) ⌘X и ⌘V работают как обычно. Если после ⌘X скопировать что-то другое, вырезание отменится.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Вырезать и вставить")
    }
}

// MARK: - Плавная прокрутка

struct SmoothScrollPage: View {
    @AppStorage(Pref.smoothScroll) private var enabled = true
    @AppStorage(Pref.smoothSpeed) private var speed = 1.0
    @AppStorage(Pref.smoothDuration) private var duration = 0.35
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = SmoothScroll.shared

    var body: some View {
        Form {
            Section {
                Toggle("Плавная прокрутка", isOn: $enabled)
                Text("Колесо обычной мыши прокручивает плавно, как трекпад. Трекпад и Magic Mouse не затрагиваются.")
                    .foregroundStyle(.secondary)
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Плавная прокрутка работает")
                }
            }
            Section("Настройка") {
                LabeledContent("Скорость") {
                    HStack {
                        Slider(value: $speed, in: 0.3...3)
                        Text(String(format: "%.1f×", speed)).monospacedDigit().frame(width: 40)
                    }
                }
                .disabled(!enabled)
                LabeledContent("Плавность") {
                    HStack {
                        Slider(value: $duration, in: 0.1...0.9)
                        Text(String(format: "%.2f с", duration)).monospacedDigit().frame(width: 50)
                    }
                }
                .disabled(!enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Плавная прокрутка")
    }
}

// MARK: - Переключатель

struct SwitcherPage: View {
    @AppStorage(Pref.switcher) private var enabled = true
    @AppStorage(Pref.switcherModifier) private var modifier = "option"
    @AppStorage(Pref.switcherPreviews) private var previews = true
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = AppSwitcher.shared

    private var mod: String { modifier == "command" ? "⌘" : "⌥" }

    var body: some View {
        Form {
            Section {
                Toggle("Переключатель приложений", isOn: $enabled)
                Picker("Сочетание", selection: $modifier) {
                    Text("⌥ Tab").tag("option")
                    Text("⌘ Tab (заменить системный)").tag("command")
                }
                .disabled(!enabled)
                Toggle("Показывать превью окон", isOn: $previews)
                    .disabled(!enabled)
                if enabled && previews && !permissions.screenRecording {
                    StatusLine(ok: false, okText: "", problemText: "Для превью нужно разрешение «Запись экрана»",
                               action: {
                                   Permissions.requestScreenRecording()
                                   Permissions.open(.screenRecording)
                               })
                }
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Переключатель работает")
                }
            }
            Section("Как пользоваться") {
                ShortcutRow(keys: [mod, "Tab"], text: "Удерживайте \(mod) и нажимайте Tab, отпустите \(mod) — переход.")
                ShortcutRow(keys: ["⇧", "Tab"], text: "Назад по списку. Также работают ← и →.")
                ShortcutRow(keys: ["Q"], text: "Завершить выбранное приложение.")
                ShortcutRow(keys: ["H"], text: "Скрыть выбранное приложение.")
                ShortcutRow(keys: ["Esc"], text: "Закрыть без переключения.")
                Text("Приложения идут в порядке последнего использования. Если у приложения нет окон, оно откроет новое, как при клике по Dock; свёрнутое окно разворачивается.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Переключатель приложений")
    }
}

// MARK: - Снимки

struct ScreenshotPage: View {
    @AppStorage(Pref.screenshot) private var enabled = true
    @AppStorage(Pref.screenshotFolder) private var folder = ""
    @ObservedObject private var permissions = PermissionsModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("Снимки экрана", isOn: $enabled)
                Text("Своя утилита по мотивам macshot: выделение области или окна, стрелки, рамки, текст, маркер, размытие и распознавание текста.")
                    .foregroundStyle(.secondary)
                if enabled {
                    StatusLine(ok: permissions.screenRecording,
                               okText: "Снимки готовы",
                               problemText: "Нужно разрешение «Запись экрана»",
                               action: {
                                   Permissions.requestScreenRecording()
                                   Permissions.open(.screenRecording)
                               })
                }
            }
            Section("Сохранение") {
                LabeledContent("Папка") {
                    HStack {
                        Text(Pref.screenshotDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Выбрать…", action: chooseFolder)
                    }
                }
            }
            Section("Горячие клавиши") {
                ShortcutRow(keys: ["⌘", "⇧", "X"], text: "Снимок области с разметкой.")
                ShortcutRow(keys: ["⌘", "⇧", "⌥", "X"], text: "Распознать текст в области и скопировать.")
            }
            Section("В режиме снимка") {
                Text("Потяните мышью, чтобы выделить область. Клик без перетаскивания снимает окно под курсором (или весь экран).")
                ShortcutRow(keys: ["1…7"], text: "Стрелка, прямоугольник, карандаш, маркер, текст, нумерация 1 2 3, размытие.")
                ShortcutRow(keys: ["V"], text: "Выбор: перетаскивайте выделенную область целиком.")
                Text("Нарисованное можно перетаскивать любым инструментом: наведите и тяните. Delete удаляет выбранный элемент, кнопка цвета перекрашивает его. За белые маркеры по краям меняется размер области.")
                    .foregroundStyle(.secondary)
                ShortcutRow(keys: ["⇕"], text: "Длинный снимок: кнопка на панели, затем медленно прокручивайте вниз и нажмите «Готово».")
                ShortcutRow(keys: ["⇧"], text: "Ровная стрелка / квадрат при рисовании.")
                ShortcutRow(keys: ["⌘", "C"], text: "Скопировать (также Enter или двойной клик).")
                ShortcutRow(keys: ["⌘", "S"], text: "Сохранить в папку.")
                ShortcutRow(keys: ["⌘", "Z"], text: "Отменить последнее действие.")
                ShortcutRow(keys: ["Esc"], text: "Закрыть.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Снимки экрана")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = Pref.screenshotDirectory
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }
}

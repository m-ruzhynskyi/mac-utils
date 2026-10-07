import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Модель разрешений

@MainActor
final class PermissionsModel: NSObject, ObservableObject {
    static let shared = PermissionsModel()

    @Published private(set) var accessibility = Permissions.accessibility
    @Published private(set) var screenRecording = Permissions.screenRecording
    @Published private(set) var fullDiskAccess = Permissions.fullDiskAccess
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
        let disk = Permissions.fullDiskAccess
        if disk != fullDiskAccess { fullDiskAccess = disk }
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
    case general, cutPaste, smoothScroll, switcher, screenshot, windows, volume, layout, shelf, cheatSheet, downloads, qr,
         uninstaller, monitor, tasks, cleanup, shots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Общие"
        case .cutPaste: return "Вырезать и вставить"
        case .smoothScroll: return "Плавная прокрутка"
        case .switcher: return "Переключатель приложений"
        case .screenshot: return "Снимки экрана"
        case .windows: return "Окна"
        case .volume: return "Громкость"
        case .layout: return "Раскладка"
        case .shelf: return "Полка"
        case .cheatSheet: return "Шпаргалка"
        case .downloads: return "Загрузки"
        case .qr: return "QR-коды"
        case .uninstaller: return "Удаление программ"
        case .monitor: return "Монитор системы"
        case .tasks: return "Диспетчер задач"
        case .cleanup: return "Очистка диска"
        case .shots: return "Мои снимки"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .cutPaste: return "scissors"
        case .smoothScroll: return "computermouse"
        case .switcher: return "rectangle.on.rectangle"
        case .screenshot: return "camera.viewfinder"
        case .windows: return "rectangle.split.2x2"
        case .volume: return "speaker.wave.2"
        case .layout: return "keyboard"
        case .shelf: return "tray.full"
        case .cheatSheet: return "command"
        case .downloads: return "arrow.down.circle"
        case .qr: return "qrcode"
        case .uninstaller: return "trash"
        case .monitor: return "gauge.with.dots.needle.67percent"
        case .tasks: return "list.bullet.rectangle"
        case .cleanup: return "externaldrive.badge.minus"
        case .shots: return "photo.on.rectangle.angled"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .cutPaste: return .orange
        case .smoothScroll: return .green
        case .switcher: return .blue
        case .screenshot: return .purple
        case .windows: return .indigo
        case .volume: return .pink
        case .layout: return .teal
        case .shelf: return .orange
        case .cheatSheet: return .gray
        case .downloads: return .blue
        case .qr: return .indigo
        case .uninstaller: return .red
        case .monitor: return .mint
        case .tasks: return .brown
        case .cleanup: return .cyan
        case .shots: return .purple
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
            case .windows: WindowsPage()
            case .volume: VolumePage()
            case .layout: LayoutPage()
            case .shelf: ShelfPage()
            case .cheatSheet: CheatSheetPage()
            case .downloads: DownloadsPage()
            case .qr: QRPage()
            case .uninstaller: UninstallerPage()
            case .monitor: SystemMonitorView(model: .shared).navigationTitle("Монитор системы")
            case .tasks: TaskManagerView(model: .shared).navigationTitle("Диспетчер задач")
            case .cleanup: DiskCleanupView(model: .shared).navigationTitle("Очистка диска")
            case .shots: ScreenshotLibraryView(library: .shared).navigationTitle("Мои снимки")
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
    @AppStorage(Pref.menuBarIcon) private var menuBarIcon = true

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Mac Utils работает в фоне, без иконки в Dock.")
                    Text("Открыть это окно: запустите приложение ещё раз или нажмите ⌃⌥⌘ ,")
                        .foregroundStyle(.secondary)
                }
                Toggle("Значок в строке меню", isOn: $menuBarIcon)
                Text("Клик — панель «Инструменты» со вкладками прямо под значком (или ⌃⌥⌘T). Настройки и выход — в шапке панели.")
                    .foregroundStyle(.secondary)
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
                    Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (сборка \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—")) · © Maksym Ruzhynskyi")
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

// MARK: - Инструменты

// MARK: - Удаление программ

struct UninstallerPage: View {
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var model = UninstallerModel.shared
    var compact = false

    var body: some View {
        VStack(spacing: 0) {
            fullDiskAccessBar
            UninstallerView(model: model, compact: compact)
        }
        .navigationTitle("Удаление программ")
        .onAppear {
            permissions.refresh()
            if model.apps.isEmpty { model.reload() }
        }
    }

    /// Нужен для контейнеров приложений из App Store и части защищённых папок.
    @ViewBuilder
    private var fullDiskAccessBar: some View {
        if permissions.fullDiskAccess == false {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Нет «Полного доступа к диску» — часть контейнеров может не удалиться.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Уже включили? Доступ действует после перезапуска Mac Utils. Если и после перезапуска не видно — удалите Mac Utils из списка кнопкой «−» и добавьте снова.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Открыть настройки") { Permissions.openFullDiskAccess() }
                        Button("Перезапустить Mac Utils") { Permissions.relaunch() }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
        } else if permissions.fullDiskAccess == true && !compact {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Полный доступ к диску есть").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Громкость

struct VolumePage: View {
    @AppStorage(Pref.appVolume) private var enabled = true
    @AppStorage(Pref.appVolumeKeyCode) private var keyCode = LayoutHotKey.controlOptionV.keyCode
    @AppStorage(Pref.appVolumeModifiers) private var modifiers = LayoutHotKey.controlOptionV.modifiers
    @ObservedObject private var model = AppVolume.shared

    private var hotKey: LayoutHotKey { LayoutHotKey(keyCode: keyCode, modifiers: modifiers) }

    var body: some View {
        Form {
            Section {
                Toggle("Громкость для каждого приложения", isOn: $enabled)
                    .disabled(!AppVolume.isSupported)
                Text("Своя громкость (0–150 %) и выключение звука для каждой программы. Громкость запоминается. Перехватываются только приложения, у которых она не 100 % — остальные звучат как обычно.")
                    .foregroundStyle(.secondary)
                if !AppVolume.isSupported {
                    Text("Нужна macOS 14.2 или новее.").foregroundStyle(.orange)
                }
            }
            if enabled && AppVolume.isSupported {
                Section("Сейчас играют") {
                    AppVolumeList(model: model)
                    if model.permissionSuspect {
                        HStack {
                            Text("Перехват не получает звук — разрешите Mac Utils «Запись системного звука» (Конфиденциальность → Запись экрана и системного звука).")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Открыть настройки") { model.openPrivacySettings() }
                        }
                    }
                    if let error = model.lastError {
                        Text(error).foregroundStyle(.orange).font(.caption)
                    }
                }
                Section("Панель громкости") {
                    LabeledContent("Открыть панель") {
                        ShortcutRecorder(hotKey: hotKey, suspend: { recording in
                            if recording { HotKeyCenter.shared.unregister(id: HotKeyID.appVolume) } else { AppVolume.shared.sync() }
                        }) { $0.save(codeKey: Pref.appVolumeKeyCode, modifiersKey: Pref.appVolumeModifiers) }
                    }
                    Text("Плавающая панель со списком играющих приложений. Esc или клик мимо — закрыть. Двойной клик по процентам — вернуть 100 %.")
                        .foregroundStyle(.secondary)
                    Text("При первом изменении громкости macOS спросит разрешение на запись системного звука — оно нужно, чтобы перехватить звук приложения. Ничего не записывается и не сохраняется.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Громкость")
        .onAppear { AppVolume.shared.refresh() }
    }
}

// MARK: - QR

struct QRPage: View {
    @AppStorage(Pref.qr) private var enabled = true
    @ObservedObject private var permissions = PermissionsModel.shared

    var body: some View {
        Form {
            Section {
                Toggle("Мгновенный QR", isOn: $enabled)
                Text("Одно сочетание для двух дел: сделать QR-код из выделенного текста или прочитать QR-код с экрана.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Как пользоваться") {
                ShortcutRow(keys: ["⌃", "⌥", "Q"], text: "Выделен текст — появится его QR-код: скопировать картинку или сохранить.")
                ShortcutRow(keys: ["⌃", "⌥", "Q"], text: "Ничего не выделено — QR-коды на экране распознаются и копируются; ссылку можно сразу открыть.")
                if !permissions.screenRecording {
                    Text("Для чтения QR с экрана нужно разрешение «Запись экрана».").foregroundStyle(.orange)
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("QR-коды")
    }
}

// MARK: - Полка и шпаргалка

struct ShelfPage: View {
    @AppStorage(Pref.dropShelf) private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Полка для файлов", isOn: $enabled)
                Text("Временное место для файлов: положите их на полку, перейдите в нужную папку или программу и вытащите обратно — по одному или все сразу.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Как пользоваться") {
                ShortcutRow(keys: ["↔︎"], text: "Перетаскивая файлы, встряхните мышь влево-вправо — полка появится рядом с курсором.")
                ShortcutRow(keys: ["⌃", "⌥", "D"], text: "Показать или скрыть полку.")
                Text("Вытащенные с полки файлы с неё убираются; чтобы оставить их на полке, держите ⌥. Сами файлы никуда не копируются, пока вы их не перетащите.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Полка")
    }
}

struct CheatSheetPage: View {
    @AppStorage(Pref.cheatSheet) private var enabled = true
    @AppStorage(Pref.cheatSheetDelay) private var delay = 0.8
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = CheatSheet.shared

    var body: some View {
        Form {
            Section {
                Toggle("Шпаргалка сочетаний клавиш", isOn: $enabled)
                Text("Удерживайте ⌘ — появятся все сочетания клавиш активной программы (из её меню) и Mac Utils. Отпустите ⌘ — шпаргалка исчезнет.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Шпаргалка работает")
                }
            }
            Section("Настройка") {
                Picker("Держать ⌘", selection: $delay) {
                    Text("0,5 с").tag(0.5)
                    Text("0,8 с").tag(0.8)
                    Text("1,2 с").tag(1.2)
                    Text("2 с").tag(2.0)
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Шпаргалка")
    }
}

// MARK: - Окна

struct WindowsPage: View {
    @AppStorage(Pref.windowSnap) private var enabled = true
    @AppStorage(Pref.windowSnapDrag) private var drag = true
    @AppStorage(Pref.windowSnapGap) private var gap = 0
    @AppStorage(Pref.windowSnapModifier) private var modifier = WindowSnapModifier.controlOption.rawValue
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = WindowTiler.shared

    /// Встроенная в macOS раскладка перетаскиванием (Рабочий стол и Dock).
    private var systemTiling: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
    }

    private var symbols: String { (WindowSnapModifier(rawValue: modifier) ?? .controlOption).symbols }

    var body: some View {
        Form {
            Section {
                Toggle("Раскладка окон", isOn: $enabled)
                Text("Как в Windows: перетащите окно за заголовок к краю экрана — оно займёт половину, к углу — четверть, к верхнему краю — весь экран. Или горячими клавишами.")
                    .foregroundStyle(.secondary)
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Раскладка окон работает")
                }
            }
            Section("Настройка") {
                Toggle("Прилипание при перетаскивании", isOn: $drag)
                if drag && systemTiling {
                    Text("В macOS тоже включена раскладка перетаскиванием — подсказки могут дублироваться. Её можно выключить: Системные настройки → Рабочий стол и Dock → «Перетаскивать окна к краям экрана».")
                        .foregroundStyle(.orange)
                }
                Picker("Отступ между окнами", selection: $gap) {
                    Text("Нет").tag(0)
                    Text("4 pt").tag(4)
                    Text("8 pt").tag(8)
                }
                Picker("Модификатор клавиш", selection: $modifier) {
                    ForEach(WindowSnapModifier.allCases) { option in
                        Text(option.symbols).tag(option.rawValue)
                    }
                }
                if !service.failedHotKeys.isEmpty {
                    Label("Заняты другим приложением: \(service.failedHotKeys.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .disabled(!enabled)
            Section("Горячие клавиши") {
                ForEach(WindowTiler.bindings, id: \.label) { binding in
                    ShortcutRow(keys: Array(symbols).map(String.init) + [binding.label], text: binding.title)
                }
                Text("Повторное нажатие той же половины переносит окно на следующий монитор.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Окна")
    }
}

/// Образец фона в настройках снимков.
private struct BackgroundSwatch: View {
    let background: ShotBackground
    let selected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            if background == .transparent {
                shape.fill(Color.gray.opacity(0.15))
                Image(systemName: "circle.slash").foregroundStyle(.secondary).font(.system(size: 11))
            } else {
                shape.fill(LinearGradient(colors: background.colors.map(Color.init(nsColor:)),
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                // Мини-окно поверх фона.
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 18, height: 12)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 1.5) {
                            Circle().fill(Color.red).frame(width: 2.5)
                            Circle().fill(Color.yellow).frame(width: 2.5)
                            Circle().fill(Color.green).frame(width: 2.5)
                        }
                        .padding(1.5)
                    }
                    .shadow(radius: 1)
            }
        }
        .frame(width: 34, height: 24)
        .overlay(shape.stroke(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1))
        .contentShape(shape)
    }
}

// MARK: - Раскладка

struct LayoutPage: View {
    @AppStorage(Pref.layoutFix) private var enabled = true
    @AppStorage(Pref.layoutFixSwitchSource) private var switchSource = false
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
                    ShortcutRecorder(hotKey: current) { $0.save() }
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Раскладка")
    }
}

/// Запись сочетания: нажмите кнопку, затем нужные клавиши (нужен ⌘, ⌥ или ⌃). Esc — отмена.
struct ShortcutRecorder: View {
    let hotKey: LayoutHotKey
    /// Пока идёт запись, старое сочетание нужно отключить, чтобы оно не сработало.
    var suspend: (Bool) -> Void = { LayoutFix.shared.suspendHotKey($0) }
    let onChange: (LayoutHotKey) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint = false

    var body: some View {
        HStack(spacing: 8) {
            if hint {
                Text("Нужен ⌘, ⌥ или ⌃").font(.caption).foregroundStyle(.orange)
            }
            Button(recording ? "Нажмите сочетание…" : hotKey.title) {
                recording ? stop() : start()
            }
            .frame(minWidth: 140)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        hint = false
        suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            guard let key = LayoutHotKey(event: event) else {
                hint = true
                return nil
            }
            onChange(key)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            suspend(false)
        }
    }
}

// MARK: - Снимки

struct ScreenshotPage: View {
    @AppStorage(Pref.screenshot) private var enabled = true
    @AppStorage(Pref.screenshotFolder) private var folder = ""
    @AppStorage(Pref.screenshotDestination) private var destination = "clipboard"
    @AppStorage(Pref.screenshotStepsLayout) private var stepsLayout = StepsLayout.auto.rawValue
    @AppStorage(Pref.screenshotStepsEqualSize) private var stepsEqualSize = true
    @AppStorage(Pref.screenshotStepsFrame) private var stepsFrame = true
    @AppStorage(Pref.screenshotStepsTitles) private var stepsTitles = true
    @AppStorage(Pref.screenshotFrameDefault) private var frameDefault = false
    @AppStorage(Pref.screenshotBackground) private var background = ShotBackground.sky.rawValue
    @AppStorage(Pref.screenshotLibrary) private var library = true
    @AppStorage(Pref.screenshotLibrarySystem) private var librarySystem = false
    @AppStorage(Pref.screenshotLibraryClipboard) private var libraryClipboard = true
    @AppStorage(Pref.screenshotLibraryTrashDays) private var libraryTrashDays = 0
    @AppStorage(Pref.recordingFormat) private var recordingFormat = ScreenRecorder.Format.mp4.rawValue
    @AppStorage(Pref.recordingFPS) private var recordingFPS = 30
    @AppStorage(Pref.recordingCursor) private var recordingCursor = true
    @AppStorage(Pref.recordingAudio) private var recordingAudio = false
    @AppStorage(Pref.recordingMicrophone) private var recordingMicrophone = false
    @AppStorage(Pref.recordingFolder) private var recordingFolder = ""
    @AppStorage(Pref.recordingCopy) private var recordingCopy = true
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
                Picker("Куда сохранять", selection: $destination) {
                    Text("В буфер обмена").tag("clipboard")
                    Text("В папку").tag("folder")
                    Text("В буфер и в папку").tag("both")
                }
                LabeledContent("Папка снимков и видео") {
                    HStack {
                        Text(Pref.screenshotDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Выбрать…", action: chooseFolder)
                        Button {
                            NSWorkspace.shared.open(Pref.screenshotDirectory)
                        } label: { Image(systemName: "folder") }
                        .help("Показать в Finder")
                        if !folder.isEmpty {
                            Button { folder = "" } label: { Image(systemName: "arrow.uturn.backward") }
                                .help("Вернуть Рабочий стол")
                        }
                    }
                }
                Text("Действует для Enter, двойного клика и длинного снимка. Кнопки «Скопировать» (⌘C) и «Сохранить» (⌘S) работают как обычно.")
                    .foregroundStyle(.secondary)
            }
            Section("Умная папка") {
                Toggle("Раскладывать снимки по дням и программам", isOn: $library)
                Text("Снимки и записи экрана сохраняются в «Снимки экрана/дата/программа» внутри папки снимков, текст на снимках распознаётся — искать и смотреть всё можно в «Мои снимки» (раздел слева и вкладка «Снимки» в панели 🔧).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Забирать и системные снимки (⌘⇧3, ⌘⇧4)", isOn: $librarySystem)
                    .disabled(!library)
                Toggle("Сохранять и скопированные в буфер", isOn: $libraryClipboard)
                    .disabled(!library)
                Picker("Удалять снимки и видео старше", selection: $libraryTrashDays) {
                    Text("Никогда").tag(0)
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                .disabled(!library)
                if libraryTrashDays > 0 {
                    Text("Старые снимки и видео из умной папки уходят в Корзину — безвозвратно ничего не удаляется.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Разложить уже сохранённые снимки и видео") {
                    let count = ScreenshotLibrary.shared.importExisting()
                    Toast.show("Разложено: \(count)", symbol: "photo.on.rectangle.angled", tint: .green)
                }
                .disabled(!library)
            }
            Section("Оформление") {
                LabeledContent("Фон") {
                    HStack(spacing: 8) {
                        ForEach(ShotBackground.allCases) { option in
                            BackgroundSwatch(background: option, selected: background == option.rawValue)
                                .onTapGesture { background = option.rawValue }
                                .help(option.title)
                        }
                    }
                }
                Toggle("Рамка окна macOS для обычных снимков по умолчанию", isOn: $frameDefault)
                Text("В режиме снимка рамку включает и выключает кнопка «Рамка» или клавиша F. Снимок кладётся в окно со «светофором», скруглёнными углами и тенью на выбранном фоне.")
                    .foregroundStyle(.secondary)
            }
            Section("Запись экрана") {
                Picker("Формат", selection: $recordingFormat) {
                    ForEach(ScreenRecorder.Format.allCases) { format in
                        Text(format.title).tag(format.rawValue)
                    }
                }
                if recordingFormat == ScreenRecorder.Format.mp4.rawValue {
                    Picker("Кадров в секунду", selection: $recordingFPS) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    Toggle("Звук системы", isOn: $recordingAudio)
                    if #available(macOS 15.0, *) {
                        Toggle("Микрофон", isOn: $recordingMicrophone)
                    }
                } else {
                    Text("GIF: 15 кадров в секунду, ширина до 960 px, без звука, повтор по кругу.")
                        .foregroundStyle(.secondary)
                }
                Toggle("Показывать курсор", isOn: $recordingCursor)
                LabeledContent("Папка для видео") {
                    HStack {
                        Text(recordingFolder.isEmpty ? "Как у снимков (\(Pref.screenshotDirectory.lastPathComponent))"
                                                     : Pref.recordingDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Выбрать…", action: chooseRecordingFolder)
                        Button {
                            NSWorkspace.shared.open(Pref.recordingDirectory)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Показать в Finder")
                        if !recordingFolder.isEmpty {
                            Button {
                                recordingFolder = ""
                            } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .help("Как у снимков")
                        }
                    }
                }
                Toggle("Копировать видео в буфер обмена", isOn: $recordingCopy)
                ShortcutRow(keys: ["R"], text: "В режиме снимка — записать выделенную область. Стоп — кнопкой на панели или ⌘⇧X, Esc — отмена.")
                Text("Файл сохраняется в папку для видео и (если включено) копируется в буфер обмена — его можно сразу вставить в чат.")
                    .foregroundStyle(.secondary)
            }
            Section("Коллаж шагов") {
                Picker("Расположение", selection: $stepsLayout) {
                    ForEach(StepsLayout.allCases) { layout in
                        Text(layout.title).tag(layout.rawValue)
                    }
                }
                Toggle("Одинаковый размер", isOn: $stepsEqualSize)
                Toggle("Рамка окна macOS", isOn: $stepsFrame)
                Toggle("Подпись «Шаг N» в заголовке окна", isOn: $stepsTitles)
                    .disabled(!stepsFrame)
                ShortcutRow(keys: ["A"], text: "В режиме снимка — «Шаг +»: область с разметкой добавляется в коллаж.")
                Text("Внизу экрана появится панель: «Ещё шаг» (или ⌘⇧X) — следующий снимок, «Готово» — собрать одну картинку с номерами 1, 2, 3 и сохранить её по настройке «Куда сохранять», «Отмена» — сбросить.")
                    .foregroundStyle(.secondary)
            }
            Section("Горячие клавиши") {
                ShortcutRow(keys: ["⌘", "⇧", "X"], text: "Снимок области с разметкой.")
                ShortcutRow(keys: ["⌘", "⇧", "⌥", "X"], text: "Распознать текст в области и скопировать.")
            }
            Section("В режиме снимка") {
                Text("Потяните мышью, чтобы выделить область. Клик без перетаскивания снимает окно под курсором (или весь экран).")
                ShortcutRow(keys: ["1…7"], text: "Стрелка, прямоугольник, карандаш, маркер, текст, нумерация 1 2 3, размытие.")
                ShortcutRow(keys: ["V"], text: "Выбор: перетаскивайте выделенную область целиком.")
                ShortcutRow(keys: ["F"], text: "Рамка окна macOS вокруг снимка: вкл/выкл.")
                Text("Нарисованное можно перетаскивать любым инструментом: наведите и тяните. Delete удаляет выбранный элемент, кнопка цвета перекрашивает его, синие ручки меняют размер (у стрелки — концы). За белые маркеры по краям меняется размер области.")
                    .foregroundStyle(.secondary)
                ShortcutRow(keys: ["⇕"], text: "Длинный снимок: кнопка на панели, затем медленно прокручивайте вниз и нажмите «Готово» (Enter).")
                ShortcutRow(keys: ["⇧"], text: "Ровная стрелка / квадрат при рисовании.")
                ShortcutRow(keys: ["Enter"], text: "Готово: в буфер или в папку — по настройке выше (также двойной клик).")
                ShortcutRow(keys: ["⌘", "C"], text: "Скопировать в буфер обмена.")
                ShortcutRow(keys: ["⌘", "S"], text: "Сохранить в папку.")
                ShortcutRow(keys: ["⌘", "Z"], text: "Отменить последнее действие (также ⌃Z). ⇧⌘Z или ⇧⌃Z — повторить.")
                ShortcutRow(keys: ["Esc"], text: "Закрыть.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Снимки экрана")
    }

    private func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = Pref.recordingDirectory
        if panel.runModal() == .OK, let url = panel.url {
            recordingFolder = url.path
        }
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

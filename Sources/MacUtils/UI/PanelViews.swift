import AppKit
import SwiftUI

extension Notification.Name {
    /// Открыть в настройках нужный раздел (object — SettingsSection).
    static let openSettingsSection = Notification.Name("MacUtils.openSettingsSection")
}

/// Вкладка панели 🔧: быстрые действия раздела, а не страница настроек. Инструменты (программы, монитор, задачи,
/// очистка, снимки) и разделы с собственным компактным видом показывают его.
struct PanelSectionView: View {
    let section: SettingsSection

    /// Разделы с быстрой панелью (действия и переключатели); остальные показывают свою страницу в компактном виде
    /// (со своей прокруткой) — иначе вкладка была бы пустой (так было с «Исключениями» и «Клавишами»).
    static let quickPanels: Set<SettingsSection> = [
        .screenshot, .windows, .volume, .layout, .shelf, .cheatSheet, .downloads, .qr, .annotate, .wellbeing, .meetings, .ai,
        .cutPaste, .smoothScroll, .switcher, .textEditor, .videoPlayer,
    ]

    /// Раздел показывает свою страницу в компактном виде (со своей прокруткой).
    static func usesPage(_ section: SettingsSection) -> Bool { !quickPanels.contains(section) }

    var body: some View {
        if Self.usesPage(section) {
            // Компактные страницы инструментов держат свои поля ~10 pt; +6 — вровень с шапкой и вкладками поповера (16 pt).
            SettingsSectionPage(section: section, compact: true)
                .padding(.horizontal, 6)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) { content }
                    .padding(.horizontal, DS.Space.l)
                    .padding(.top, DS.Space.xxs)
                    .padding(.bottom, DS.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .screenshot: CaptureQuick()
        case .windows: WindowsPanel()
        case .volume: VolumePanel()
        case .layout: LayoutPanel()
        case .shelf: ShelfPanel()
        case .cheatSheet: CheatSheetPanel()
        case .downloads: DownloadsPanel()
        case .qr: QRPanel()
        case .annotate: AnnotatePanel()
        case .wellbeing: WellbeingPanel()
        case .meetings: MeetingsPanel()
        case .ai: AIPanel()
        case .cutPaste: CutPastePanel()
        case .smoothScroll: SmoothScrollPanel()
        case .switcher: SwitcherPanel()
        case .textEditor: EditorPanel()
        case .videoPlayer: PlayerPanel()
        default: EmptyView()
        }
    }
}

// MARK: - Общие кусочки

/// Действие из панели: сначала закрываем её, чтобы не мешала (снимок, рисование…).
@MainActor
private func fromPanel(_ action: @escaping @MainActor () -> Void) {
    AppStatusItem.shared.closeTools()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { action() } }
}

/// Строка-действие в карточке поповера: вся строка — кнопка, при наведении подсвечивается.
private struct QuickAction: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    var tile: RowTile.Kind = .neutral
    var keys: [String]?
    var hotKey: HotKeyAction?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Row(title, subtitle: subtitle, systemImage: systemImage, tile: tile) {
                if let hotKey {
                    Keycap(action: hotKey, compact: true, onPanel: true)
                } else if let keys {
                    Keycap(keys, compact: true, onPanel: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickRowStyle())
        .accessibilityAddTraits(.isButton)
    }
}

/// Подсветка строки поповера: при наведении — `panel` под строкой, при нажатии — чуть плотнее.
private struct QuickRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { QuickRowBody(configuration: configuration) }
}

private struct QuickRowBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .background((hovered && enabled ? Color.dsPanel : .clear).opacity(configuration.isPressed ? 1 : 0.7),
                        in: RoundedRectangle(cornerRadius: DS.Radius.iconButton, style: .continuous))
            .opacity(enabled ? 1 : DS.State.disabledOpacity)
            .onHover { hovered = $0 }
    }
}

/// Заголовок группы и карточка поповера (`ListCard` на `field`).
private struct QuickGroup<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupLabel(title).padding(.horizontal, DS.Space.xs)
            ListCard(style: .field) { content }
        }
    }
}

/// Сочетание переключателя приложений (⌥Tab или ⌘Tab — по настройке).
private func switcherKeys(_ modifier: String) -> [String] { [modifier == "command" ? "⌘" : "⌥", "Tab"] }

// MARK: - Группы вкладок разделов

private struct CaptureQuick: View {
    var body: some View {
        QuickGroup("Захват") {
            QuickAction(title: "Снять область или окно", systemImage: "camera.viewfinder", tile: .accent, hotKey: .screenshot) {
                fromPanel { ScreenshotService.shared.start(.edit) }
            }
            QuickAction(title: "Распознать текст", subtitle: "Текст сразу в буфер", systemImage: "text.viewfinder", hotKey: .screenshotOCR) {
                fromPanel { ScreenshotService.shared.start(.ocr) }
            }
            QuickAction(title: "Записать экран", subtitle: "Выделите область и нажмите R", systemImage: "record.circle",
                        tile: .record, keys: ["R"]) {
                fromPanel { ScreenshotService.shared.start(.edit) }
            }
            QuickAction(title: "Открыть папку снимков", systemImage: "folder") {
                NSWorkspace.shared.open(Pref.screenshotDirectory)
            }
        }
    }
}

private struct WindowsQuick: View {
    @AppStorage(Pref.switcher) private var switcher = true
    @AppStorage(Pref.switcherModifier) private var modifier = "option"
    @AppStorage(Pref.windowSnap) private var windowSnap = true
    @AppStorage(Pref.appVolume) private var appVolume = true

    var body: some View {
        QuickGroup("Окна и приложения") {
            KeyedToggleRow("Переключатель приложений", subtitle: "Превью каждого окна", systemImage: "rectangle.on.rectangle",
                           keys: switcherKeys(modifier), isOn: $switcher)
            Row("Окна поверх всех", subtitle: "Закрепить активное окно", systemImage: "pin") {
                Keycap(action: .windowPin, compact: true, onPanel: true)
            }
            KeyedToggleRow("Раскладка окон", subtitle: "Половины, четверти, центр", systemImage: "rectangle.split.2x2",
                           keys: [WindowSnapModifier.current.symbols, "←→"], isOn: $windowSnap)
            if AppVolume.isSupported {
                KeyedToggleRow("Громкость приложений", systemImage: "speaker.wave.2", hotKey: .appVolume, isOn: $appVolume)
            }
        }
    }
}

/// Переключатель с кейкапом сочетания между подписью и дорожкой.
private struct KeyedToggleRow: View {
    let title: String
    var subtitle: String?
    let systemImage: String
    var keys: [String]?
    var hotKey: HotKeyAction?
    @Binding var isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, subtitle: String? = nil, systemImage: String, keys: [String]? = nil, hotKey: HotKeyAction? = nil,
         isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.keys = keys
        self.hotKey = hotKey
        _isOn = isOn
    }

    var body: some View {
        Row(title, subtitle: subtitle, systemImage: systemImage) {
            if let hotKey {
                Keycap(action: hotKey, compact: true, onPanel: true)
            } else if let keys {
                Keycap(keys, compact: true, onPanel: true)
            }
            Toggle(title, isOn: $isOn).toggleStyle(.graphite)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(DS.Motion.animation(DS.Motion.toggle, reduceMotion: reduceMotion)) { isOn.toggle() }
        }
    }
}

/// Тёплый экран вручную (то же, что кнопка в шапке).
private struct WarmScreenRow: View {
    @ObservedObject private var screen = WarmScreen.shared
    @AppStorage(Pref.warmScreen) private var warm = false
    @AppStorage(Pref.warmMode) private var warmMode = "schedule"
    @AppStorage(Pref.warmManualOn) private var manualOn = false

    var body: some View {
        let on = warm && warmMode == "manual" && manualOn
        Row("Тёплый экран", subtitle: warm && warmMode == "schedule" ? "Сейчас по расписанию" : nil,
            systemImage: warm && screen.currentLevel > 0 ? "sun.horizon.fill" : "sun.horizon") {
            Toggle("Тёплый экран", isOn: Binding(get: { on }, set: { _ in WarmScreen.shared.toggleManual() }))
                .toggleStyle(.graphite)
        }
    }
}

/// Запись встречи: старт, остановка (с таймером) или ход расшифровки.
private struct MeetingRow: View {
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        switch recorder.state {
        case .idle:
            QuickAction(title: "Записать встречу", systemImage: "waveform.badge.mic", tile: .record, hotKey: .meeting) { recorder.start() }
        case .recording(let since):
            Button { recorder.stop() } label: {
                Row("Остановить запись", systemImage: "stop.circle.fill", tile: .record) {
                    Text(since, style: .timer).font(DS.Font.mono).foregroundStyle(DS.Tone.danger.text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(QuickRowStyle())
        case .processing(let step):
            Row(step, systemImage: "waveform") { ProgressView().controlSize(.small) }
        }
    }
}

/// «Исправить текст в буфере» (ИИ, локально): исправленный текст возвращается в буфер.
private struct AIFixRow: View {
    @State private var fixing = false
    @State private var note: String?

    var body: some View {
        QuickAction(title: "Исправить текст в буфере",
                    subtitle: note ?? "Скопируйте текст — исправленный вернётся в буфер. В любом поле: выделить и \(HotKeyRegistry.combo(for: .fixText).title)",
                    systemImage: "sparkles", hotKey: nil) {
            fixClipboard()
        }
        .disabled(fixing)
        .overlay(alignment: .trailing) {
            if fixing { ProgressView().controlSize(.small).padding(.trailing, DS.Space.l) }
        }
    }

    private func fixClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            note = "В буфере нет текста"
            return
        }
        fixing = true
        note = nil
        Task {
            defer { fixing = false }
            do {
                let answer = try await Ollama.generate(text, system: TextFixer.system, temperature: 0)
                let fixed = AIParsing.keepingEdges(of: text, AIParsing.cleanedText(answer))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fixed, forType: .string)
                note = fixed == text ? "Ошибок не найдено" : "Исправленный текст в буфере — вставьте ⌘V"
            } catch {
                note = error.localizedDescription
            }
        }
    }
}

// MARK: - Вкладки разделов

private struct WindowsPanel: View {
    @ObservedObject private var pin = WindowPin.shared
    @ObservedObject private var memory = WindowMemory.shared

    var body: some View {
        WindowsQuick()
        QuickGroup("Окна поверх всех") {
            if pin.pins.isEmpty {
                EmptyState("Нет закреплённых окон", systemImage: "pin", compact: true)
            }
            ForEach(pin.pins) { item in
                Row(item.title, systemImage: "pin.fill", tile: .accent) {
                    Slider(value: Binding(get: { item.opacity }, set: { item.setOpacity($0) }), in: 0.2...1)
                        .tint(.dsAccLine)
                        .frame(width: 90)
                        .accessibilityLabel("Прозрачность")
                    IconButton("Открепить", systemImage: "xmark", compact: true) { pin.unpin(item) }
                }
            }
        }
        QuickGroup("Окна по мониторам") {
            Row("Сейчас: \(memory.monitorsDescription)", subtitle: "Запомнено наборов: \(memory.layouts.count)", systemImage: "display.2") {
                Button("Запомнить") { memory.snapshot(force: true) }.buttonStyle(.graphite(.secondary, size: .compact))
                Button("Расставить") { memory.restore() }.buttonStyle(.graphite(.secondary, size: .compact))
            }
        }
    }
}

private struct VolumePanel: View {
    @ObservedObject private var model = AppVolume.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GroupLabel("Громкость приложений").padding(.horizontal, DS.Space.xs)
            Card(style: .field) { AppVolumeList(model: model, compact: true) }
        }
        .onAppear { model.refresh() }
    }
}

private struct LayoutPanel: View {
    @AppStorage(Pref.layoutFix) private var layoutFix = true
    @AppStorage(Pref.appInputSource) private var perApp = true

    var body: some View {
        QuickGroup("Раскладка") {
            KeyedToggleRow("Исправлять раскладку", subtitle: "ghbdtn → привет", systemImage: "keyboard", hotKey: .layoutFix, isOn: $layoutFix)
            ToggleRow("Раскладка по программам", subtitle: "У каждой программы — своя раскладка", systemImage: "arrow.left.arrow.right",
                      isOn: $perApp)
        }
    }
}

private struct ShelfPanel: View {
    @ObservedObject private var shelf = DropShelf.shared

    var body: some View {
        QuickGroup("Полка") {
            QuickAction(title: "Показать полку", subtitle: "Или встряхните мышь с файлами", systemImage: "tray.full", hotKey: .dropShelf) {
                fromPanel { DropShelf.shared.toggle() }
            }
        }
        QuickGroup(shelf.items.isEmpty ? "На полке" : "На полке: \(shelf.items.count)") {
            if shelf.items.isEmpty {
                EmptyState("Полка пуста", systemImage: "tray", compact: true)
            }
            ForEach(shelf.items.prefix(8), id: \.self) { url in
                AppRow(url.lastPathComponent, url: url) {
                    IconButton("Убрать с полки", systemImage: "xmark", compact: true) { shelf.remove(url) }
                }
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            }
        }
        if !shelf.items.isEmpty {
            Button("Очистить полку") { shelf.clear() }.buttonStyle(.graphite(.secondary))
        }
    }
}

private struct CheatSheetPanel: View {
    @AppStorage(Pref.cheatSheet) private var enabled = true
    @AppStorage(Pref.cheatSheetSticky) private var sticky = false

    var body: some View {
        QuickGroup("Шпаргалка") {
            ToggleRow("Шпаргалка", subtitle: "Удерживайте ⌘ — сочетания клавиш программы", systemImage: "command", isOn: $enabled)
            ToggleRow("Оставлять открытой", subtitle: "Закрыть — ⌘ или Esc", systemImage: "pin", isOn: $sticky)
                .disabled(!enabled)
        }
    }
}

private struct DownloadsPanel: View {
    @ObservedObject private var sorter = DownloadsSorter.shared
    @AppStorage(Pref.downloadsSort) private var enabled = false

    var body: some View {
        QuickGroup("Загрузки") {
            ToggleRow("Сортировать «Загрузки»", subtitle: "Новые файлы — по папкам Images, Documents…", systemImage: "arrow.down.circle",
                      isOn: $enabled)
            QuickAction(title: "Разложить сейчас", subtitle: sorter.lastResult, systemImage: "arrow.down.to.line.compact") {
                _ = sorter.run()
            }
            .disabled(!enabled)
            QuickAction(title: "Открыть «Загрузки»", systemImage: "folder") {
                NSWorkspace.shared.open(sorter.folder)
            }
        }
    }
}

private struct QRPanel: View {
    @State private var text = ""

    var body: some View {
        QuickGroup("QR-коды") {
            QuickAction(title: "Прочитать QR с экрана", subtitle: "Без выделенного текста", systemImage: "qrcode.viewfinder", hotKey: .qr) {
                fromPanel { QRCodeService.shared.scanScreen() }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            GroupLabel("Сделать QR-код").padding(.horizontal, DS.Space.xs)
            Card(style: .field) {
                TextField("Текст или ссылка", text: $text).textFieldStyle(.graphite)
                if !text.isEmpty, let image = QRTools.make(text, scale: 6) {
                    HStack {
                        Spacer()
                        Image(nsImage: NSImage(cgImage: image, size: NSSize(width: 160, height: 160)))
                            .interpolation(.none).resizable().frame(width: 160, height: 160)
                            .padding(DS.Space.s)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .onDrag {
                                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
                                return NSItemProvider(item: data as NSData, typeIdentifier: "public.png")
                            }
                            .accessibilityLabel("QR-код")
                        Spacer()
                    }
                    Button("Скопировать картинку") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
                    }
                    .buttonStyle(.graphite(.secondary, fill: true))
                }
            }
        }
    }
}

private struct AnnotatePanel: View {
    var body: some View {
        QuickGroup("Рисование") {
            QuickAction(title: "Рисовать на экране", subtitle: "1–4 — инструменты, Esc — выйти", systemImage: "pencil.tip.crop.circle",
                        tile: .accent, hotKey: .annotate) {
                fromPanel { ScreenAnnotator.shared.start() }
            }
        }
    }
}

private struct WellbeingPanel: View {
    @ObservedObject private var reminder = BreakReminder.shared
    @AppStorage(Pref.breakReminder) private var breaks = false

    var body: some View {
        QuickGroup("Не засыпать") {
            KeepAwakeTicker()
        }
        Text(KeepAwakeRow.note)
            .font(DS.Font.rowSub)
            .foregroundStyle(.dsMute)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.xs)
        QuickGroup("Перерывы и тёплый экран") {
            WarmScreenRow()
            ToggleRow("Напоминать о перерыве", subtitle: breaks ? "Работаете без перерыва: \(reminder.workedMinutes) мин" : nil,
                      systemImage: "figure.walk", isOn: $breaks)
            QuickAction(title: "Перерыв сейчас", systemImage: "cup.and.saucer") {
                fromPanel { BreakReminder.shared.show() }
            }
        }
    }
}

private struct MeetingsPanel: View {
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        QuickGroup("Записи встреч") { MeetingRow() }
        QuickGroup("Последние") {
            if recorder.meetings.isEmpty {
                EmptyState("Пока нет записей", systemImage: "waveform", compact: true)
            }
            ForEach(recorder.meetings.prefix(6)) { meeting in
                Row(meeting.title, systemImage: meeting.hasReport ? "doc.text" : "waveform") {
                    if meeting.hasReport {
                        Button("Отчёт") { NSWorkspace.shared.open(meeting.report) }.buttonStyle(.graphite(.secondary, size: .compact))
                    }
                    if meeting.hasTranscript {
                        Button("Текст") { NSWorkspace.shared.open(meeting.transcript) }.buttonStyle(.graphite(.ghost, size: .compact))
                    }
                }
            }
        }
        .onAppear { recorder.reload() }
    }
}

private struct AIPanel: View {
    @ObservedObject private var ollama = Ollama.shared

    var body: some View {
        QuickGroup("ИИ (Ollama)") {
            switch ollama.status {
            case .ready:
                FeatureStatusRow(tone: .success, label: "Готово", detail: "Модель готова: \(Ollama.model)")
            case .noServer:
                FeatureStatusRow(tone: .warning, label: "Нужен запуск", detail: "Ollama не запущена",
                                 actions: [StatusAction(title: "Запустить") { ollama.launchServer() }])
            case .noModel:
                FeatureStatusRow(tone: .warning, label: "Нет модели", detail: "Модель не скачана")
            default:
                FeatureStatusRow(tone: .neutral, label: "Проверяю…")
            }
            AIFixRow()
        }
        .onAppear { ollama.refresh() }
    }
}

private struct CutPastePanel: View {
    @AppStorage(Pref.cutPaste) private var enabled = true

    var body: some View {
        QuickGroup("Вырезать и вставить") {
            ToggleRow("Вырезать и вставить в Finder", subtitle: "⌘X / ⌘V в Finder перемещают файлы.", systemImage: "scissors", isOn: $enabled)
        }
    }
}

private struct SmoothScrollPanel: View {
    @AppStorage(Pref.smoothScroll) private var enabled = true
    @AppStorage(Pref.smoothSpeed) private var speed = 1.0

    var body: some View {
        QuickGroup("Плавная прокрутка") {
            ToggleRow("Плавная прокрутка", subtitle: "Колесо обычной мыши", systemImage: "computermouse", isOn: $enabled)
            SliderRow("Скорость", systemImage: "hare", value: $speed, in: 0.5...3) { String(format: "%.1f×", $0) }
                .disabled(!enabled)
        }
    }
}

private struct SwitcherPanel: View {
    @AppStorage(Pref.switcher) private var enabled = true
    @AppStorage(Pref.switcherModifier) private var modifier = "option"

    var body: some View {
        QuickGroup("Переключатель окон") {
            KeyedToggleRow("Переключатель окон", subtitle: "Превью каждого окна", systemImage: "rectangle.on.rectangle",
                           keys: switcherKeys(modifier), isOn: $enabled)
            Row("Сочетание", systemImage: "command") {
                Segmented(selection: $modifier, options: [("option", "⌥Tab"), ("command", "⌘Tab")])
            }
            .disabled(!enabled)
        }
    }
}

private struct PlayerPanel: View {
    @State private var recent = PlayerRecent.urls

    var body: some View {
        QuickGroup("Видеоплеер") {
            QuickAction(title: "Открыть плеер", subtitle: "Плейлист, субтитры, пропуск интро", systemImage: "play.rectangle",
                        tile: .accent, hotKey: .videoPlayer) {
                fromPanel { PlayerWindowController.show() }
            }
            QuickAction(title: "Открыть видео…", subtitle: "MP4, MOV, M4V, MP3, M4A… или перетащите сюда", systemImage: "folder",
                        keys: ["⌘", "O"]) {
                fromPanel { PlayerWindowController.openPanel() }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            AppStatusItem.shared.closeTools()
            PlayerWindowController.openDropped(providers)
            return true
        }
        Group {
            if !recent.isEmpty {
                QuickGroup("Продолжить просмотр") {
                    ForEach(recent.prefix(6), id: \.self) { url in
                        QuickAction(title: url.lastPathComponent, subtitle: EditorRecent.folderTitle(url),
                                    systemImage: PlayerMedia.isVideo(url) ? "film" : "waveform") {
                            fromPanel { PlayerWindowController.open([url]) }
                        }
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = PlayerRecent.urls
            if now != recent { recent = now }
        }
    }
}

private struct EditorPanel: View {
    @State private var recent = EditorRecent.urls

    var body: some View {
        QuickGroup("Текстовый редактор") {
            QuickAction(title: "Открыть редактор", subtitle: "Вкладки прошлого сеанса вернутся", systemImage: "doc.plaintext",
                        tile: .accent, hotKey: .textEditor) {
                fromPanel { EditorWindowController.shared.show() }
            }
            QuickAction(title: "Открыть файл…", subtitle: ".frm, .rtf, .txt, .json, .xml… или перетащите сюда", systemImage: "folder",
                        keys: ["⌘", "O"]) {
                fromPanel { EditorWindowController.shared.openPanel() }
            }
            QuickAction(title: "Новый документ", systemImage: "plus", keys: ["⌘", "N"]) {
                fromPanel { EditorWindowController.shared.newDocument() }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            AppStatusItem.shared.closeTools()
            EditorWindowController.shared.openDropped(providers)
            return true
        }
        Group {
            if !recent.isEmpty {
            QuickGroup("Недавние") {
                ForEach(recent.prefix(6), id: \.self) { url in
                    QuickAction(title: url.lastPathComponent, subtitle: EditorRecent.folderTitle(url),
                                systemImage: DocumentTab.symbol(EditorLanguage.detect(url: url, head: Data()), url: url)) {
                        fromPanel { EditorWindowController.shared.open([url]) }
                    }
                }
            }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let now = EditorRecent.urls
            if now != recent { recent = now }
        }
    }
}


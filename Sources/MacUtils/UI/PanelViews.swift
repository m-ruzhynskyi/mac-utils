import AppKit
import SwiftUI

extension Notification.Name {
    /// Открыть в настройках нужный раздел (object — SettingsSection).
    static let openSettingsSection = Notification.Name("MacUtils.openSettingsSection")
}

/// Вкладка панели 🔧: быстрые действия раздела, а не страница настроек.
struct PanelSectionView: View {
    let section: SettingsSection

    var body: some View {
        switch section {
        case .music, .share, .textInput, .uninstaller, .monitor, .tasks, .cleanup, .shots:
            SettingsSectionPage(section: section, compact: true)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    content
                    Divider()
                    Button {
                        AppStatusItem.shared.closeTools()
                        SettingsWindowController.shared.show(section: section)
                    } label: {
                        Label("Все настройки раздела", systemImage: "gearshape")
                    }
                    .buttonStyle(.link)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .screenshot: ScreenshotPanel()
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
        case .cutPaste: SimpleTogglePanel(title: "Вырезать и вставить в Finder", key: Pref.cutPaste,
                                          detail: "⌘X / ⌘V в Finder перемещают файлы.", symbol: "scissors")
        case .smoothScroll: SmoothScrollPanel()
        case .switcher: SwitcherPanel()
        default: EmptyView()
        }
    }
}

// MARK: - Общие кусочки

/// Большая кнопка действия: значок, название, подсказка.
private struct ActionTile: View {
    let title: String
    let symbol: String
    var detail: String?
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(tint).frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

/// Действие из панели: сначала закрываем её, чтобы не мешала (снимок, рисование…).
@MainActor
private func fromPanel(_ action: @escaping @MainActor () -> Void) {
    AppStatusItem.shared.closeTools()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { action() } }
}

private struct SimpleTogglePanel: View {
    let title: String
    let key: String
    let detail: String
    let symbol: String
    @AppStorage private var on: Bool

    init(title: String, key: String, detail: String, symbol: String) {
        self.title = title
        self.key = key
        self.detail = detail
        self.symbol = symbol
        _on = AppStorage(wrappedValue: true, key)
    }

    var body: some View {
        HStack {
            Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch)
        }
    }
}

// MARK: - Разделы

private struct ScreenshotPanel: View {
    @ObservedObject private var library = ScreenshotLibrary.shared

    var body: some View {
        VStack(spacing: 8) {
            ActionTile(title: "Снять область или окно", symbol: "camera.viewfinder", detail: "⌘⇧X") {
                fromPanel { ScreenshotService.shared.start(.edit) }
            }
            ActionTile(title: "Распознать текст", symbol: "text.viewfinder", detail: "⌘⇧⌥X — текст сразу в буфер") {
                fromPanel { ScreenshotService.shared.start(.ocr) }
            }
            ActionTile(title: "Записать экран", symbol: "record.circle", detail: "Выделите область и нажмите R", tint: .red) {
                fromPanel { ScreenshotService.shared.start(.edit) }
            }
            ActionTile(title: "Открыть папку снимков", symbol: "folder", tint: .secondary) {
                NSWorkspace.shared.open(Pref.screenshotDirectory)
            }
        }
    }
}

private struct WindowsPanel: View {
    @ObservedObject private var pin = WindowPin.shared
    @ObservedObject private var memory = WindowMemory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Окна поверх всех").font(.headline)
            if pin.pins.isEmpty {
                Text("Нет закреплённых. ⌃⌥P — закрепить активное окно.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(pin.pins) { item in
                HStack {
                    Image(systemName: "pin.fill").foregroundStyle(.blue)
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Slider(value: Binding(get: { item.opacity }, set: { item.setOpacity($0) }), in: 0.2...1).frame(width: 90)
                    Button { pin.unpin(item) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
                }
            }
            Divider()
            Text("Окна по мониторам").font(.headline)
            Text("Сейчас: \(memory.monitorsDescription), запомнено наборов: \(memory.layouts.count)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Запомнить") { memory.snapshot(force: true) }
                Button("Расставить") { memory.restore() }
            }
            Divider()
            Text("⌃⌥ ← → ↑ ↓ — половины, U I J K — четверти, ↩ — весь экран, C — центр, ⌫ — вернуть.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct VolumePanel: View {
    @ObservedObject private var model = AppVolume.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Громкость приложений").font(.headline)
            AppVolumeList(model: model, compact: true)
        }
        .onAppear { model.refresh() }
    }
}

private struct LayoutPanel: View {
    @AppStorage(Pref.layoutFix) private var layoutFix = true
    @AppStorage(Pref.appInputSource) private var perApp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $layoutFix) {
                VStack(alignment: .leading) {
                    Text("Исправлять раскладку").font(.headline)
                    Text("\(LayoutHotKey.current.title) — ghbdtn → привет").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $perApp) {
                VStack(alignment: .leading) {
                    Text("Раскладка по программам").font(.headline)
                    Text("У каждой программы — своя раскладка").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}

private struct ShelfPanel: View {
    @ObservedObject private var shelf = DropShelf.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ActionTile(title: "Показать полку", symbol: "tray.full", detail: "⌃⌥D или встряхните мышь с файлами") {
                fromPanel { DropShelf.shared.toggle() }
            }
            if shelf.items.isEmpty {
                Text("Полка пуста").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("На полке: \(shelf.items.count)").font(.headline)
                ForEach(shelf.items.prefix(8), id: \.self) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { shelf.remove(url) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary)
                    }
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                }
                Button("Очистить полку") { shelf.clear() }
            }
        }
    }
}

private struct CheatSheetPanel: View {
    @AppStorage(Pref.cheatSheet) private var enabled = true
    @AppStorage(Pref.cheatSheetSticky) private var sticky = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading) {
                    Text("Шпаргалка").font(.headline)
                    Text("Удерживайте ⌘ — сочетания клавиш программы").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Оставлять открытой (закрыть — ⌘ или Esc)", isOn: $sticky).disabled(!enabled)
        }
        .toggleStyle(.switch)
    }
}

private struct DownloadsPanel: View {
    @ObservedObject private var sorter = DownloadsSorter.shared
    @AppStorage(Pref.downloadsSort) private var enabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading) {
                    Text("Сортировать «Загрузки»").font(.headline)
                    Text("Новые файлы — по папкам Images, Documents…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            ActionTile(title: "Разложить сейчас", symbol: "arrow.down.to.line.compact") {
                _ = sorter.run()
            }
            .disabled(!enabled)
            if let result = sorter.lastResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
            ActionTile(title: "Открыть «Загрузки»", symbol: "folder", tint: .secondary) {
                NSWorkspace.shared.open(sorter.folder)
            }
        }
    }
}

private struct QRPanel: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActionTile(title: "Прочитать QR с экрана", symbol: "qrcode.viewfinder", detail: "⌃⌥Q — без выделенного текста") {
                fromPanel { QRCodeService.shared.scanScreen() }
            }
            Text("Сделать QR-код").font(.headline)
            TextField("Текст или ссылка", text: $text).textFieldStyle(.roundedBorder)
            if !text.isEmpty, let image = QRTools.make(text, scale: 6) {
                HStack {
                    Spacer()
                    Image(nsImage: NSImage(cgImage: image, size: NSSize(width: 160, height: 160)))
                        .interpolation(.none).resizable().frame(width: 160, height: 160)
                        .onDrag {
                            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
                            return NSItemProvider(item: data as NSData, typeIdentifier: "public.png")
                        }
                    Spacer()
                }
                Button("Скопировать картинку") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
                }
            }
        }
    }
}

private struct AnnotatePanel: View {
    var body: some View {
        VStack(spacing: 8) {
            ActionTile(title: "Рисовать на экране", symbol: "pencil.tip.crop.circle", detail: "⌃⌥A · 1–4 — инструменты, Esc — выйти", tint: .red) {
                fromPanel { ScreenAnnotator.shared.start() }
            }
        }
    }
}

private struct WellbeingPanel: View {
    @ObservedObject private var screen = WarmScreen.shared
    @ObservedObject private var reminder = BreakReminder.shared
    @AppStorage(Pref.warmScreen) private var warm = false
    @AppStorage(Pref.warmMode) private var warmMode = "schedule"
    @AppStorage(Pref.warmManualOn) private var manualOn = false
    @AppStorage(Pref.breakReminder) private var breaks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActionTile(title: warm && warmMode == "manual" && manualOn ? "Выключить тёплый экран" : "Включить тёплый экран",
                       symbol: warm && screen.currentLevel > 0 ? "sun.horizon.fill" : "sun.horizon",
                       detail: warm && warmMode == "schedule" ? "Сейчас по расписанию" : nil, tint: .orange) {
                WarmScreen.shared.toggleManual()
            }
            Toggle(isOn: $breaks) {
                VStack(alignment: .leading) {
                    Text("Напоминать о перерыве").font(.headline)
                    if breaks {
                        Text("Работаете без перерыва: \(reminder.workedMinutes) мин").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)
            ActionTile(title: "Перерыв сейчас", symbol: "figure.walk", tint: .green) {
                fromPanel { BreakReminder.shared.show() }
            }
        }
    }
}

private struct MeetingsPanel: View {
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch recorder.state {
            case .idle:
                ActionTile(title: "Записать встречу", symbol: "record.circle", detail: "⌃⌥M", tint: .red) { recorder.start() }
            case .recording(let since):
                ActionTile(title: "Остановить запись", symbol: "stop.circle.fill", tint: .red) { recorder.stop() }
                Text(since, style: .timer).font(.title3.monospacedDigit()).foregroundStyle(.red)
            case .processing(let step):
                HStack { ProgressView().controlSize(.small); Text(step).foregroundStyle(.secondary) }
            }
            if !recorder.meetings.isEmpty {
                Text("Последние").font(.headline).padding(.top, 4)
                ForEach(recorder.meetings.prefix(6)) { meeting in
                    HStack {
                        Image(systemName: meeting.hasReport ? "doc.text.fill" : "waveform").foregroundStyle(.secondary)
                        Text(meeting.title)
                        Spacer()
                        if meeting.hasReport { Button("Отчёт") { NSWorkspace.shared.open(meeting.report) } }
                        if meeting.hasTranscript { Button("Текст") { NSWorkspace.shared.open(meeting.transcript) } }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .onAppear { recorder.reload() }
    }
}

private struct AIPanel: View {
    @ObservedObject private var ollama = Ollama.shared
    @State private var fixing = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                switch ollama.status {
                case .ready: Label("Модель готова: \(Ollama.model)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .noServer: Label("Ollama не запущена", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .noModel: Label("Модель не скачана", systemImage: "arrow.down.circle").foregroundStyle(.orange)
                default: Label("Проверяю…", systemImage: "hourglass").foregroundStyle(.secondary)
                }
                Spacer()
                if ollama.status == .noServer { Button("Запустить") { ollama.launchServer() } }
            }
            ActionTile(title: "Исправить текст в буфере", symbol: "sparkles",
                       detail: "Скопируйте текст — исправленный вернётся в буфер. В любом поле: выделить и ⌃⌥E", tint: .purple) {
                fixClipboard()
            }
            .disabled(fixing)
            if fixing { ProgressView().controlSize(.small) }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { ollama.refresh() }
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

private struct SmoothScrollPanel: View {
    @AppStorage(Pref.smoothScroll) private var enabled = true
    @AppStorage(Pref.smoothSpeed) private var speed = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading) {
                    Text("Плавная прокрутка").font(.headline)
                    Text("Колесо обычной мыши").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            LabeledContent("Скорость") { Slider(value: $speed, in: 0.5...3) }.disabled(!enabled)
        }
    }
}

private struct SwitcherPanel: View {
    @AppStorage(Pref.switcher) private var enabled = true
    @AppStorage(Pref.switcherModifier) private var modifier = "option"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $enabled) {
                VStack(alignment: .leading) {
                    Text("Переключатель окон").font(.headline)
                    Text("Превью каждого окна").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Picker("Сочетание", selection: $modifier) {
                Text("⌥Tab").tag("option")
                Text("⌘Tab").tag("command")
            }
            .pickerStyle(.segmented)
            .disabled(!enabled)
        }
    }
}

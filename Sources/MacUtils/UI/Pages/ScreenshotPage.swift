import AppKit
import SwiftUI

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
    @AppStorage(Pref.screenshotWindowSnap) private var windowSnap = false
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
                               },
                               relaunchHint: true)
                }
            }
            Section("Выбор области") {
                Picker("Что снимать", selection: $windowSnap) {
                    Text("Окно под курсором (клик) или своя область").tag(true)
                    Text("Только своя область").tag(false)
                }
                Text("Переключается и прямо при съёмке: кнопка вверху экрана или Tab. Названия кнопок панели видны при наведении.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
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
                ActionShortcutRow(action: .screenshot, text: "Снимок области с разметкой.")
                ActionShortcutRow(action: .screenshotOCR, text: "Распознать текст в области и скопировать.")
                Text("Изменить — в разделе «Горячие клавиши».").font(.caption).foregroundStyle(.secondary)
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

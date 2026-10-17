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
                shape.fill(Color.dsField)
                Image(systemName: "circle.slash").foregroundStyle(.dsMute).font(.system(size: 11))
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
        .overlay(shape.stroke(selected ? Color.dsAccLine : Color.dsLine, lineWidth: selected ? 2 : 1))
        .accessibilityLabel(background.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    @AppStorage(Pref.screenshotStepsBadges) private var stepsBadges = true
    @AppStorage(Pref.screenshotStepsArrows) private var stepsArrows = false
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
        SettingsPage(.screenshot, isOn: $enabled, toggleLabel: "Снимки экрана") {
            if enabled && !permissions.screenRecording {
                Banner(.warning, title: "Нужно разрешение «Запись экрана»") {
                    Button("Открыть настройки") {
                        Permissions.requestScreenRecording()
                        Permissions.open(.screenRecording)
                    }
                    .buttonStyle(.graphite(.primary, size: .compact))
                    Button("Перезапустить") { Permissions.relaunch() }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                        .help("Уже выдали разрешение? Оно начнёт действовать после перезапуска Mac Utils")
                }
            }
            ListCard {
                Row("Снимки экрана",
                    subtitle: "Своя утилита по мотивам macshot: выделение области или окна, стрелки, рамки, текст, маркер, размытие и распознавание текста.",
                    systemImage: "camera.viewfinder") {
                    if enabled && permissions.screenRecording { Pill(.success, "Снимки готовы") }
                }
                Row("Что снимать", subtitle: "Переключается и прямо при съёмке: кнопка вверху экрана или Tab. Названия кнопок панели видны при наведении.",
                    systemImage: "viewfinder") {
                    Picker("Что снимать", selection: $windowSnap) {
                        Text("Окно под курсором (клик) или своя область").tag(true)
                        Text("Только своя область").tag(false)
                    }
                    .graphitePicker()
                }
            }
            .disabled(!enabled)

            GroupLabel("Сохранение")
            ListCard {
                Row("Куда сохранять", systemImage: "square.and.arrow.down") {
                    Picker("Куда сохранять", selection: $destination) {
                        Text("В буфер обмена").tag("clipboard")
                        Text("В папку").tag("folder")
                        Text("В буфер и в папку").tag("both")
                    }
                    .graphitePicker()
                }
                PathRow("Папка снимков и видео", url: Pref.screenshotDirectory, isCustom: !folder.isEmpty,
                        choose: chooseFolder, reset: { folder = "" }, resetHelp: "Вернуть Рабочий стол")
            }
            .disabled(!enabled)
            Footnote("Действует для Enter, двойного клика и длинного снимка. Кнопки «Скопировать» (⌘C) и «Сохранить» (⌘S) работают как обычно.")

            GroupLabel("Умная папка")
            ListCard {
                ToggleRow("Раскладывать снимки по дням и программам",
                          subtitle: "Снимки и записи экрана сохраняются в «Снимки экрана/дата/программа» внутри папки снимков, текст на снимках распознаётся — искать и смотреть всё можно в «Мои снимки» (раздел слева и вкладка «Снимки» в панели 🔧).",
                          systemImage: "folder.badge.gearshape", isOn: $library)
                ToggleRow("Забирать и системные снимки (⌘⇧3, ⌘⇧4)", systemImage: "camera", isOn: $librarySystem)
                    .disabled(!library)
                ToggleRow("Сохранять и скопированные в буфер", systemImage: "doc.on.clipboard", isOn: $libraryClipboard)
                    .disabled(!library)
                Row("Удалять снимки и видео старше",
                    subtitle: libraryTrashDays > 0 ? "Старые снимки и видео из умной папки уходят в Корзину — безвозвратно ничего не удаляется." : nil,
                    systemImage: "trash") {
                    Picker("Удалять снимки и видео старше", selection: $libraryTrashDays) {
                        Text("Никогда").tag(0)
                        Text("7 дней").tag(7)
                        Text("30 дней").tag(30)
                        Text("90 дней").tag(90)
                    }
                    .graphitePicker()
                }
                .disabled(!library)
                Row("Разложить уже сохранённые снимки и видео", systemImage: "square.stack.3d.up") {
                    Button("Разложить") {
                        let count = ScreenshotLibrary.shared.importExisting()
                        Toast.show("Разложено: \(count)", symbol: "photo.on.rectangle.angled", tint: .green)
                    }
                    .buttonStyle(.graphite(.secondary, size: .compact))
                }
                .disabled(!library)
            }
            .disabled(!enabled)

            GroupLabel("Оформление")
            ListCard {
                Row("Фон", systemImage: "paintpalette") {
                    HStack(spacing: DS.Space.s) {
                        ForEach(ShotBackground.allCases) { option in
                            BackgroundSwatch(background: option, selected: background == option.rawValue)
                                .onTapGesture { background = option.rawValue }
                                .help(option.title)
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                }
                ToggleRow("Рамка окна macOS для обычных снимков по умолчанию", systemImage: "macwindow", isOn: $frameDefault)
            }
            .disabled(!enabled)
            Footnote("В режиме снимка рамку включает и выключает кнопка «Рамка» или клавиша F. Снимок кладётся в окно со «светофором», скруглёнными углами и тенью на выбранном фоне.")

            GroupLabel("Запись экрана")
            ListCard {
                Row("Формат", systemImage: "video") {
                    Segmented(selection: $recordingFormat,
                              options: ScreenRecorder.Format.allCases.map { (value: $0.rawValue, title: $0.title) })
                }
                if recordingFormat == ScreenRecorder.Format.mp4.rawValue {
                    Row("Кадров в секунду", systemImage: "speedometer") {
                        Segmented(selection: $recordingFPS, options: [(value: 30, title: "30"), (value: 60, title: "60")])
                    }
                    ToggleRow("Звук системы", systemImage: "speaker.wave.2", isOn: $recordingAudio)
                    if #available(macOS 15.0, *) {
                        ToggleRow("Микрофон", systemImage: "mic", isOn: $recordingMicrophone)
                    }
                } else {
                    Row("GIF: 15 кадров в секунду, ширина до 960 px, без звука, повтор по кругу.", systemImage: "photo.stack")
                }
                ToggleRow("Показывать курсор", systemImage: "cursorarrow", isOn: $recordingCursor)
                PathRow("Папка для видео", systemImage: "film.stack", url: Pref.recordingDirectory,
                        display: recordingFolder.isEmpty ? "Как у снимков (\(Pref.screenshotDirectory.lastPathComponent))" : nil,
                        isCustom: !recordingFolder.isEmpty, choose: chooseRecordingFolder, reset: { recordingFolder = "" },
                        resetHelp: "Как у снимков")
                ToggleRow("Копировать видео в буфер обмена", systemImage: "doc.on.clipboard", isOn: $recordingCopy)
                HintRow(keys: ["R"], text: "В режиме снимка — записать выделенную область. Стоп — кнопкой на панели или ⌘⇧X, Esc — отмена.")
            }
            .disabled(!enabled)
            Footnote("Файл сохраняется в папку для видео и (если включено) копируется в буфер обмена — его можно сразу вставить в чат.")

            GroupLabel("Коллаж шагов")
            ListCard {
                Row("Расположение", systemImage: "square.grid.2x2") {
                    Picker("Расположение", selection: $stepsLayout) {
                        ForEach(StepsLayout.allCases) { layout in
                            Text(layout.title).tag(layout.rawValue)
                        }
                    }
                    .graphitePicker()
                }
                ToggleRow("Одинаковый размер", systemImage: "rectangle.3.group", isOn: $stepsEqualSize)
                ToggleRow("Рамка окна macOS", systemImage: "macwindow", isOn: $stepsFrame)
                ToggleRow("Подпись «Шаг N» в заголовке окна", systemImage: "textformat", isOn: $stepsTitles)
                    .disabled(!stepsFrame)
                ToggleRow("Номера шагов", systemImage: "list.number", isOn: $stepsBadges)
                ToggleRow("Стрелки между шагами", systemImage: "arrow.right", isOn: $stepsArrows)
                HintRow(keys: ["A"], text: "В режиме снимка — «Шаг +»: область с разметкой добавляется в коллаж.")
                HintRow(action: .screenshot, text: "Во время коллажа — ещё шаг: та же область уже выделена, Enter снимает её.")
            }
            .disabled(!enabled)
            Footnote("Внизу экрана — панель с миниатюрами шагов: шаг можно переснять, удалить или перетащить на другое место. «Готово» открывает предпросмотр: раскладка, оформление, подписи к шагам, «Сохранить» и «Скопировать». Панель и предпросмотр в снимок не попадают. Отмена при двух шагах и больше переспрашивает.")

            GroupLabel("Горячие клавиши")
            ListCard {
                HintRow(action: .screenshot, text: "Снимок области с разметкой.")
                HintRow(action: .screenshotOCR, text: "Распознать текст в области и скопировать.")
            }
            Footnote("Изменить — в разделе «Горячие клавиши».")

            GroupLabel("В режиме снимка")
            Card {
                Text("Потяните мышью, чтобы выделить область. Клик без перетаскивания снимает окно под курсором (или весь экран).")
                    .font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Space.s), count: 3), spacing: DS.Space.s) {
                    ToolTile(systemImage: "arrow.up.right", title: "Стрелка", key: "1")
                    ToolTile(systemImage: "rectangle", title: "Прямоугольник", key: "2")
                    ToolTile(systemImage: "pencil", title: "Карандаш", key: "3")
                    ToolTile(systemImage: "highlighter", title: "Маркер", key: "4")
                    ToolTile(systemImage: "textformat", title: "Текст", key: "5")
                    ToolTile(systemImage: "list.number", title: "Нумерация 1 2 3", key: "6")
                    ToolTile(systemImage: "drop", title: "Размытие", key: "7")
                    ToolTile(systemImage: "cursorarrow", title: "Выбор", key: "V")
                    ToolTile(systemImage: "macwindow", title: "Рамка окна", key: "F")
                }
            }
            CollapsibleCard("Все сочетания в режиме снимка", expanded: false) {
                HintRow(keys: ["1…7"], text: "Стрелка, прямоугольник, карандаш, маркер, текст, нумерация 1 2 3, размытие.")
                HintRow(keys: ["V"], text: "Выбор: перетаскивайте выделенную область целиком.")
                HintRow(keys: ["F"], text: "Рамка окна macOS вокруг снимка: вкл/выкл.")
                HintRow(keys: ["⇕"], text: "Длинный снимок: кнопка на панели, затем медленно прокручивайте вниз и нажмите «Готово» (Enter).")
                HintRow(keys: ["⇧"], text: "Ровная стрелка / квадрат при рисовании.")
                HintRow(keys: ["Enter"], text: "Готово: в буфер или в папку — по настройке выше (также двойной клик).")
                HintRow(keys: ["⌘", "C"], text: "Скопировать в буфер обмена.")
                HintRow(keys: ["⌘", "S"], text: "Сохранить в папку.")
                HintRow(keys: ["⌘", "Z"], text: "Отменить последнее действие (также ⌃Z). ⇧⌘Z или ⇧⌃Z — повторить.")
                HintRow(keys: ["Esc"], text: "Закрыть.")
            }
            Footnote("Нарисованное можно перетаскивать любым инструментом: наведите и тяните. Delete удаляет выбранный элемент, кнопка цвета перекрашивает его, синие ручки меняют размер (у стрелки — концы). За белые маркеры по краям меняется размер области.")
        }
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

import SwiftUI

// MARK: - Окна: поверх всех и память по мониторам

struct WindowExtrasSections: View {
    @AppStorage(Pref.windowPin) private var pinEnabled = true
    @AppStorage(Pref.windowMemory) private var memoryEnabled = true
    @ObservedObject private var pin = WindowPin.shared
    @ObservedObject private var memory = WindowMemory.shared

    var body: some View {
        Section("Поверх всех окон") {
            Toggle("Закреплять окна поверх остальных", isOn: $pinEnabled)
            ShortcutRow(keys: ["⌃", "⌥", "P"], text: "Закрепить активное окно поверх всех или открепить его.")
            Text("Поверх остальных показывается живая копия окна. Клик по ней открывает настоящее окно, правый клик — прозрачность и «Открепить».")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(pin.pins) { item in
                HStack {
                    Image(systemName: "pin.fill").foregroundStyle(.blue)
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Slider(value: Binding(get: { item.opacity }, set: { item.setOpacity($0) }), in: 0.2...1)
                        .frame(width: 120)
                        .help("Прозрачность")
                    Button { pin.unpin(item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Открепить")
                }
            }
        }
        Section("Окна по мониторам") {
            Toggle("Запоминать окна для каждого набора мониторов", isOn: $memoryEnabled)
            Text("Подключили внешний монитор — окна сами встанут туда, где стояли при этом мониторе в прошлый раз.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Сейчас: \(memory.monitorsDescription), запомнено наборов: \(memory.layouts.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Запомнить сейчас") { memory.snapshot(force: true) }
                Button("Расставить") { memory.restore() }
                Button("Забыть") { memory.forget() }
            }
            .disabled(!memoryEnabled)
        }
    }
}

// MARK: - Рисование

struct AnnotatePage: View {
    @AppStorage(Pref.annotate) private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Рисование поверх экрана", isOn: $enabled)
                Text("Стрелки, рамки, маркер и перо прямо поверх экрана — во время созвона, демонстрации или записи экрана (рисунки попадают в запись).")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Как пользоваться") {
                ShortcutRow(keys: ["⌃", "⌥", "A"], text: "Начать или закончить рисование.")
                ShortcutRow(keys: ["1", "2", "3", "4"], text: "Перо, стрелка, рамка, маркер.")
                ShortcutRow(keys: ["⌘", "Z"], text: "Отменить последний штрих.")
                ShortcutRow(keys: ["⌫"], text: "Стереть всё.")
                ShortcutRow(keys: ["Esc"], text: "Закончить.")
                Text("На панели сверху — цвета и режим «исчезающие штрихи» (через 3 секунды).")
                    .foregroundStyle(.secondary)
                Button("Попробовать") { ScreenAnnotator.shared.start() }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Рисование на экране")
    }
}

// MARK: - Перерывы и тёплый экран

struct WellbeingPage: View {
    @AppStorage(Pref.breakReminder) private var breaks = false
    @AppStorage(Pref.breakInterval) private var interval = 45
    @AppStorage(Pref.breakDuration) private var duration = 20
    @AppStorage(Pref.warmScreen) private var warm = false
    @AppStorage(Pref.warmStrength) private var strength = 0.5
    @AppStorage(Pref.warmExternalStrength) private var externalStrength = 0.5
    @AppStorage(Pref.warmFrom) private var from = 21
    @AppStorage(Pref.warmTo) private var to = 7
    @ObservedObject private var reminder = BreakReminder.shared
    @ObservedObject private var screen = WarmScreen.shared

    var body: some View {
        Form {
            Section("Напоминание о перерыве") {
                Toggle("Напоминать о перерыве", isOn: $breaks)
                Text("Каждые N минут работы — мягкий экран «встаньте, посмотрите вдаль». Если вы сами отошли от компьютера на 5 минут, отсчёт начнётся заново.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Group {
                    Picker("Каждые", selection: $interval) {
                        ForEach([20, 30, 45, 60, 90], id: \.self) { Text("\($0) мин").tag($0) }
                    }
                    Picker("Длительность", selection: $duration) {
                        ForEach([20, 30, 60, 120, 300], id: \.self) { Text($0 < 60 ? "\($0) с" : "\($0 / 60) мин").tag($0) }
                    }
                }
                .disabled(!breaks)
                HStack {
                    if breaks { Text("Работаете без перерыва: \(reminder.workedMinutes) мин").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Показать сейчас") { reminder.show() }
                }
            }
            Section("Тёплый экран вечером") {
                Toggle("Тёплый экран", isOn: $warm)
                Text("Свой Night Shift: вечером экран плавно желтеет и синий свет приглушается. Для встроенного экрана и внешних мониторов — своя сила.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Group {
                    Picker("С", selection: $from) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                Picker("До", selection: $to) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                LabeledContent("Встроенный экран") {
                    Slider(value: $strength, in: 0.1...1) { _ in screen.apply() }
                }
                LabeledContent("Внешние мониторы") {
                    Slider(value: $externalStrength, in: 0.1...1) { _ in screen.apply() }
                }
                }
                .disabled(!warm)
                HStack {
                    Text(!warm ? "Выключен" : screen.currentLevel > 0 ? "Сейчас включён: \(Int(screen.currentLevel * 100)) %" : "Включится в \(String(format: "%02d:00", from))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Показать, как будет") { screen.preview() }
                }
                Text("Вход и выход — плавно, в течение часа. Системный Night Shift лучше выключить, чтобы они не складывались.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Перерывы и тёплый экран")
        .onChange(of: from) { _, _ in screen.apply() }
        .onChange(of: to) { _, _ in screen.apply() }
    }
}

// MARK: - Записи встреч

struct MeetingsPage: View {
    @AppStorage(Pref.meetings) private var enabled = true
    @AppStorage(Pref.meetingsMicrophone) private var microphone = true
    @AppStorage(Pref.meetingsLanguage) private var language = "ru_RU"
    @AppStorage(Pref.meetingsReport) private var report = true
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        Form {
            Section {
                Toggle("Записи встреч", isOn: $enabled)
                Text("Записывает звук созвона (собеседников и ваш микрофон отдельно), расшифровывает прямо на Mac встроенным распознаванием речи Apple, а локальная модель (Ollama) делает отчёт: итог, решения, задачи. Можно расшифровать и готовую запись. Ничего не уходит в интернет.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    switch recorder.state {
                    case .idle:
                        Button { recorder.start() } label: { Label("Начать запись", systemImage: "record.circle") }
                        Button { recorder.importFile() } label: { Label("Расшифровать файл…", systemImage: "doc.badge.plus") }
                            .help("Готовая запись созвона — аудио или видео")
                    case .recording(let since):
                        Button { recorder.stop() } label: { Label("Остановить", systemImage: "stop.fill") }
                        Text(since, style: .timer).monospacedDigit().foregroundStyle(.red)
                    case .processing(let step):
                        ProgressView().controlSize(.small)
                        Text(step).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ShortcutRow(keys: ["⌃", "⌥", "M"], text: "старт / стоп")
                }
                if let error = recorder.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section("Настройки") {
                Toggle("Записывать мой микрофон", isOn: $microphone)
                Picker("Язык встреч", selection: $language) {
                    Text("Русский").tag("ru_RU")
                    Text("Українська").tag("uk_UA")
                    Text("English").tag("en_US")
                }
                Toggle("Отчёт ИИ после расшифровки", isOn: $report)
                Text("Нужны разрешения «Запись экрана» (звук системы) и «Микрофон». Языковая модель Apple для расшифровки скачивается один раз.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
            Section("Встречи") {
                if recorder.meetings.isEmpty {
                    Text("Пока нет записей").foregroundStyle(.secondary)
                }
                ForEach(recorder.meetings) { meeting in
                    HStack {
                        Image(systemName: meeting.hasReport ? "doc.text.fill" : "waveform").foregroundStyle(.secondary)
                        Text(meeting.title)
                        Spacer()
                        if meeting.hasReport { Button("Отчёт") { NSWorkspace.shared.open(meeting.report) } }
                        if meeting.hasTranscript { Button("Текст") { NSWorkspace.shared.open(meeting.transcript) } }
                        if !meeting.hasTranscript || !meeting.hasReport {
                            Button("Обработать") { Task { await recorder.process(meeting) } }
                                .disabled(recorder.state != .idle)
                        }
                        Button { NSWorkspace.shared.open(meeting.folder) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Записи встреч")
        .onAppear { recorder.reload() }
    }
}

// MARK: - ИИ

struct AIPage: View {
    @AppStorage(Pref.ai) private var enabled = true
    @AppStorage(Pref.aiModel) private var model = "qwen2.5:7b"
    @AppStorage(Pref.aiFixText) private var fixText = true
    @AppStorage(Pref.aiShotNames) private var shotNames = true
    @AppStorage(Pref.aiShotSearch) private var shotSearch = true
    @AppStorage(Pref.aiDownloads) private var downloads = true
    @AppStorage(Pref.aiDownloadsTags) private var downloadsTags = true
    @AppStorage(Pref.aiTasks) private var tasks = true
    @AppStorage(Pref.aiCleanup) private var cleanup = true
    @AppStorage(Pref.aiShelf) private var shelf = true
    @AppStorage(Pref.meetingsReport) private var meetings = true
    @ObservedObject private var ollama = Ollama.shared

    var body: some View {
        Form {
            Section {
                Toggle("ИИ-функции", isOn: $enabled)
                Text("Всё работает на локальной модели через Ollama — тексты, снимки и файлы не уходят в интернет.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Модель") {
                HStack {
                    statusLabel
                    Spacer()
                    Button("Проверить") { ollama.refresh() }
                }
                Picker("Модель", selection: $model) {
                    ForEach(Array(Set(ollama.models + [model])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model) { _, _ in ollama.refresh() }
                if ollama.status == .noServer {
                    Button("Запустить Ollama") { ollama.launchServer() }
                }
                if ollama.status == .noModel {
                    if let progress = ollama.pullProgress {
                        ProgressView(value: progress) { Text("Скачиваю \(model)…") }
                    } else {
                        Button("Скачать \(model)") { ollama.pull() }
                        Text("qwen2.5:7b — около 4,7 ГБ.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!enabled)
            Section("Функции") {
                Toggle(isOn: $fixText) {
                    VStack(alignment: .leading) {
                        Text("Исправить ошибки в выделенном тексте — ⌃⌥E")
                        Text("Опечатки, орфография, пунктуация; выделение заменяется исправленным текстом.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $shotNames) {
                    VStack(alignment: .leading) {
                        Text("Умные имена снимков")
                        Text("По распознанному тексту: «Счёт за интернет 20.15.03.png».").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $shotSearch) {
                    VStack(alignment: .leading) {
                        Text("Поиск снимков по смыслу")
                        Text("«оплата» найдёт и «счёт», и «invoice».").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $downloads) {
                    VStack(alignment: .leading) {
                        Text("Папка для неизвестных типов в «Загрузках»")
                        Text("Кнопка «Предложить папку» в своих правилах.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $downloadsTags) {
                    VStack(alignment: .leading) {
                        Text("Теги для документов в «Загрузках»")
                        Text("Теги Finder «Счёт», «Договор», «Билет»… по имени и тексту.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $tasks) {
                    VStack(alignment: .leading) {
                        Text("Объяснения в диспетчере задач")
                        Text("Что за процесс и можно ли его закрыть; категории списка.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $cleanup) {
                    VStack(alignment: .leading) {
                        Text("Разбор очистки диска")
                        Text("Что безопасно удалять и почему.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $shelf) {
                    VStack(alignment: .leading) {
                        Text("Группы на полке")
                        Text("Файлы на полке группируются по смыслу.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $meetings) {
                    VStack(alignment: .leading) {
                        Text("Отчёты о встречах")
                        Text("Итог, решения и задачи по расшифровке созвона.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("ИИ (Ollama)")
        .onAppear { ollama.refresh() }
    }

    @ViewBuilder private var statusLabel: some View {
        switch ollama.status {
        case .unknown, .checking:
            Label("Проверяю Ollama…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .ready:
            Label("Готово: \(model)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .noServer:
            Label("Ollama не запущена", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .noModel:
            Label("Модель \(model) не скачана", systemImage: "arrow.down.circle").foregroundStyle(.orange)
        }
    }
}

import AppKit
import SwiftUI
import Speech
import MUCore
import MUDesign
import MUCopilot
import MUAIBackend

// MARK: - Подсказчик на встрече

struct CopilotPage: View {
    @AppStorage(CopilotPrefs.autoAnswer) private var autoAnswer = true
    @AppStorage(CopilotPrefs.placement) private var placement = CopilotPlacement.underCamera.rawValue
    @AppStorage(CopilotPrefs.meetingLanguage) private var meetingLanguage = ""
    @AppStorage(CopilotPrefs.answerLanguage) private var answerLanguage = ""
    @AppStorage(CopilotPrefs.about) private var about = ""
    @AppStorage(CopilotPrefs.reactToPauses) private var reactToPauses = true
    @AppStorage(CopilotPrefs.fastModels) private var fastModels = true
    @AppStorage(CopilotPrefs.hybrid) private var hybrid = false
    @AppStorage(CopilotModels.warm) private var warm = true
    @AppStorage(Pref.ai) private var aiEnabled = true
    @AppStorage(Pref.aiProvider) private var aiProvider = AIProvider.standard.rawValue
    @ObservedObject private var aiStatus = AIStatus.shared
    @ObservedObject private var permissions = PermissionsModel.shared
    @AppStorage(CopilotPrefs.screenID) private var screenID = ""
    @State private var screens = CopilotGlue.screens()
    @ObservedObject private var session = CopilotGlue.shared.session
    /// Демо для снимков интерфейса: не запускает codex и claude и не читает разрешения, состояния готовые.
    var demo = false
    @State private var transcription: CopilotReadiness.Transcription?
    /// Язык, модель которого сейчас скачивается.
    @State private var downloading: String?
    /// Сервис для снимков (в демо); nil — со страницы «ИИ».
    var demoProvider: AIProvider?

    var body: some View {
        // Главный переключатель — не сохранённая настройка, а текущее состояние: включает только человек, после перезапуска выключено.
        SettingsPage(.copilot, isOn: Binding(get: { session.isOn }, set: { _ in CopilotGlue.shared.toggle() }),
                     toggleLabel: "Включить подсказчика") {
            ListCard {
                Row("Только когда вы сами включите",
                    subtitle: "Клавишей или в меню Mac Utils. Сам по себе, даже во время звонка или демонстрации, он не слушает.",
                    systemImage: "hand.tap") { Keycap(action: .copilot) }
                if let error = session.error {
                    FeatureStatusRow(tone: .danger, label: "Не включился", detail: error, actions: failureActions(session.failure))
                }
                Row("Отвечает: \(provider.title)", subtitle: Self.serviceSubtitle(provider), systemImage: "sparkles") {
                    Button("Изменить") { SettingsWindowController.shared.show(section: .ai) }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                }
            }
            GroupLabel("Что нужно для работы")
            ListCard {
                ForEach(readiness) { item in
                    FeatureStatusRow(tone: item.tone, label: item.label, detail: item.detail, actions: actions(item.fix))
                }
            }
            GroupLabel("Скорость")
            ListCard {
                ToggleRow("Реагировать на паузу", subtitle: "Не ждать, пока расшифровка закончит фразу: пауза 0,7 с (после «?» — 0,35 с), и ответ уже готовится. Быстрее на 1–2 с, иногда ловит начало фразы",
                          systemImage: "timer", isOn: $reactToPauses)
                ToggleRow("Быстрые модели", subtitle: "Малое «размышление» и быстрая модель: первая строка за пару секунд. Выключено — основные модели, ответы подробнее и медленнее",
                          systemImage: "hare", isOn: $fastModels)
                ToggleRow("Держать ИИ наготове", subtitle: "Пока подсказчик включён, программа Codex или Claude уже запущена: вопрос не ждёт запуска",
                          systemImage: "flame", isOn: $warm)
                ToggleRow("Гибрид: фраза и пункты отдельно", subtitle: "Первая строка — от быстрой модели, пункты — от основной, одновременно. Два запроса вместо одного: быстрее, но расходует подписку вдвое",
                          systemImage: "square.split.2x1", isOn: $hybrid)
                ToggleRow("Отвечать на вопросы сразу", subtitle: "Выключено — только по ⌥⇧A", systemImage: "bolt", isOn: $autoAnswer)
            }
            GroupLabel("Где панель")
            ListCard {
                Row("Где стоит панель", subtitle: "Мышь проходит сквозь неё; чтобы нажать в панели, держите ⌥", systemImage: "rectangle.topthird.inset.filled") {
                    Segmented(selection: $placement, options: CopilotPlacement.allCases.map { ($0.rawValue, $0.title) })
                }
                if placement == CopilotPlacement.secondScreen.rawValue {
                    Row("Экран для панели", subtitle: ScreenChoice.note(screens, preferred: screenID) ?? "iPad (Sidecar) или второй монитор; на основном ничего не появится",
                        systemImage: "ipad.landscape") {
                        Segmented(selection: $screenID, options: [("", "Первый не основной")] + screens.filter { !$0.isMain }.map { ($0.id, $0.name) })
                    }
                }
                Row("Язык встречи", systemImage: "globe") {
                    Segmented(selection: $meetingLanguage, options: CopilotSettings.languages.map { ($0.code ?? "", $0.title) })
                }
                Row("Язык ответов", systemImage: "character.bubble") {
                    Segmented(selection: $answerLanguage, options: [("", "Как во встрече")] + CopilotSettings.languages.dropFirst().map { ($0.code ?? "", $0.title) })
                }
            }
            GroupLabel("Клавиши")
            ListCard {
                Row("Ответить на последний вопрос", systemImage: "text.bubble") { Keycap(action: .copilotAnswer) }
                Row("Посмотреть экран и подсказать", subtitle: "Снимок экрана под курсором уходит в запрос только по этой клавише", systemImage: "camera.viewfinder") { Keycap(action: .copilotScreen) }
                Row("Показать или спрятать панель", systemImage: "eye") { Keycap(action: .copilotPanel) }
            }
            GroupLabel("Что ИИ знает о вас")
            ListCard {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("О себе и о встрече").font(DS.Font.rowTitle)
                    Text("Чтобы ответы были от вашего лица: роль, опыт, о чём встреча").font(DS.Font.rowSub).foregroundStyle(Color.dsMute)
                    TextEditor(text: $about).font(DS.Font.body).frame(minHeight: 72)
                        .scrollContentBackground(.hidden).padding(6)
                        .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.keycap, style: .continuous))
                }
                .padding(DS.Space.m)
            }
            Footnote("Собеседников слышно из звука программы звонка, вас — из микрофона; расшифровка идёт на самом Mac. Выключен — микрофон и звук звонка не слушаются вообще.")
        }
        .onAppear { if !demo { aiStatus.refreshIfStale(); permissions.refresh(); Task { await refreshTranscription() } } }
        .onChange(of: meetingLanguage) { if !demo { Task { await refreshTranscription() } } }
    }

    private var provider: AIProvider { demoProvider ?? AIProvider(stored: aiProvider) }

    /// Серым под «Отвечает: …». У Codex — честно о скорости (замер на настоящих сервисах: первое слово у Codex 7–10 с,
    /// у Claude ~0,6 с). Отдельного выбора сервиса у подсказчика нет: только подсказка, где он меняется.
    static func serviceSubtitle(_ provider: AIProvider) -> String {
        switch provider {
        case .codex: return "Codex начинает ответ примерно за 3–4 с. Claude — меньше чем за секунду: сервис меняется на странице «ИИ»."
        case .claude: return "Тот же ИИ, что у всех функций Mac Utils: выбор один — на странице «ИИ»"
        }
    }

    /// Состояние читается без системных окон: `AIStatus` (проверка входа в CLI) и `PermissionsModel` (только статус).
    private var readiness: [CopilotReadiness.Item] {
        if demo {
            return CopilotReadiness.items(service: provider.title, ai: .connected, microphone: .notAsked, screenAudio: false,
                                          transcription: .modelMissing(language: "ru", fallback: true))
        }
        let ai: CopilotReadiness.AIState
        if !aiEnabled { ai = .off } else {
            switch aiStatus.state(provider) {
            case .unknown, .checking: ai = .checking
            case .connected: ai = .connected
            case .notFound: ai = .notFound
            case .notLoggedIn: ai = .notLoggedIn
            case .problem(let message): ai = .problem(message)
            }
        }
        return CopilotReadiness.items(service: provider.title, ai: ai, microphone: permissions.microphone,
                                      screenAudio: permissions.screenRecording,
                                      transcription: downloading.map { .downloading(language: $0) } ?? transcription)
    }

    /// Кнопки только открывают нужное место: разрешения Mac спрашивает сам при первом включении.
    private func actions(_ fix: CopilotReadiness.Item.Fix?) -> [StatusAction] {
        switch fix {
        case .aiPage: return [StatusAction(title: "Страница «ИИ»") { SettingsWindowController.shared.show(section: .ai) }]
        case .microphone: return [StatusAction(title: "Открыть настройки") { Permissions.open(.microphone) }]
        case .downloadModel(let language): return [StatusAction(title: "Загрузить") { download(language) }]
        case .screenRecording, nil: return []
        }
    }

    /// Кнопка к причине, почему подсказчик не включился.
    private func failureActions(_ failure: CopilotListenFailure?) -> [StatusAction] {
        guard let action = failure?.action else { return [] }
        let title = CopilotListenFailure.actionTitle(action)
        switch action {
        case .downloadModel(let language): return [StatusAction(title: title) { download(language) }]
        case .openMicrophoneSettings: return [StatusAction(title: title) { Permissions.open(.microphone) }]
        case .openScreenRecordingSettings: return [StatusAction(title: title) { Permissions.open(.screenRecording) }]
        case .openSpeechSettings: return [StatusAction(title: title) { Permissions.open(.speechRecognition) }]
        case .chooseLanguage: return []   // «Язык встречи» — ниже на этой странице
        }
    }

    private var meetingLocale: Locale { Locale(identifier: CopilotLocale.identifier(for: meetingLanguage.isEmpty ? nil : meetingLanguage)) }

    /// Состояние расшифровки для языка встречи: без скачивания и без системных окон (статус модели, умеет ли macOS на устройстве).
    private func refreshTranscription() async {
        let locale = meetingLocale
        let language = StreamingTranscriber.languageCode(locale)
        let model = await StreamingTranscriber.modelState(for: locale)
        let fallback = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
        switch model {
        case .installed: transcription = .modelInstalled(language: language)
        case .downloadable: transcription = .modelMissing(language: language, fallback: fallback)
        case .downloading: transcription = .downloading(language: language)
        case .unsupported, nil: transcription = fallback ? .fallbackOnly(language: language) : .unsupported(language: language)
        }
    }

    /// Модель скачивается только по нажатию «Загрузить».
    private func download(_ language: String) {
        guard downloading == nil else { return }
        downloading = language
        Task { @MainActor in
            do { try await StreamingTranscriber.downloadModel(for: meetingLocale) } catch {
                Log.ai.error("Подсказчик: модель распознавания не скачалась: \(error.localizedDescription, privacy: .public)")
            }
            downloading = nil
            await refreshTranscription()
        }
    }
}

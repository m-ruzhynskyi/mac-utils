import AppKit
import SwiftUI
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
    @AppStorage(CopilotProviderChoice.key) private var providerChoice = CopilotProviderChoice.system.rawValue
    @ObservedObject private var aiStatus = AIStatus.shared
    @AppStorage(CopilotPrefs.screenID) private var screenID = ""
    @State private var screens = CopilotGlue.screens()
    @ObservedObject private var session = CopilotGlue.shared.session

    var body: some View {
        // Главный переключатель — не сохранённая настройка, а текущее состояние: включает только человек, после перезапуска выключено.
        SettingsPage(.copilot, isOn: Binding(get: { session.isOn }, set: { _ in CopilotGlue.shared.toggle() }),
                     toggleLabel: "Включить подсказчика") {
            ListCard {
                Row("Только когда вы сами включите",
                    subtitle: "Клавишей или в меню Mac Utils. Сам по себе, даже во время звонка или демонстрации, он не слушает.",
                    systemImage: "hand.tap") { Keycap(action: .copilot) }
                if let error = session.error {
                    FeatureStatusRow(tone: .danger, label: "Не включился", detail: error)
                }
                ToggleRow("Реагировать на паузу", subtitle: "Не ждать, пока расшифровка закончит фразу: пауза 0,7 с — и ответ уже готовится. Быстрее на 1–2 с, иногда ловит начало фразы",
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
                Row("Кто отвечает", subtitle: "Свой выбор для подсказчика: ответ нужен за пару секунд, а лучшая скорость — у Claude",
                    systemImage: "sparkles") {
                    Segmented(selection: $providerChoice, options: CopilotProviderChoice.allCases.map { ($0.rawValue, $0.title) })
                }
                if let advice = ProviderAdvice.suggest(effective: CopilotGlue.effectiveProvider().rawValue, stats: LatencyStats.load(),
                                                       claudeConnected: aiStatus.state(.claude).isReady) {
                    Row(advice.text, subtitle: advice.isPrior ? "Выбор остаётся как в Mac Utils, пока вы не переключите" : "По вашим последним ответам",
                        systemImage: "bolt.horizontal") {
                        Button("Переключить на Claude · быстрый") {
                            providerChoice = CopilotProviderChoice.claude.rawValue
                            fastModels = true
                        }
                            .buttonStyle(.graphite(.primary, size: .compact))
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
        .onAppear { aiStatus.refreshIfStale() }
    }
}

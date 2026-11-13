import AppKit
import SwiftUI
import MUAIBackend
import MUCore
import MUDesign
import MUDownloadsSorter
import MUScreenShare
import MUTextEditor

// MARK: - ИИ

struct AIPage: View {
    @ObservedObject private var hotKeys = HotKeyPrefs.shared
    @AppStorage(Pref.ai) private var enabled = true
    @AppStorage(Pref.aiProvider) private var provider = AIProvider.standard.rawValue
    @AppStorage(Pref.aiFallback) private var fallback = false
    @AppStorage(Pref.aiFixText) private var fixText = true
    @AppStorage(Pref.aiShotNames) private var shotNames = true
    @AppStorage(Pref.aiShotSearch) private var shotSearch = true
    @AppStorage(Pref.aiDownloads) private var downloads = true
    @AppStorage(Pref.aiDownloadsTags) private var downloadsTags = true
    @AppStorage(Pref.aiTasks) private var tasks = true
    @AppStorage(Pref.aiCleanup) private var cleanup = true
    @AppStorage(Pref.aiShelf) private var shelf = true
    @AppStorage(Pref.meetingsReport) private var meetings = true
    @ObservedObject private var status = AIStatus.shared
    @ObservedObject private var tagger = DocumentTagger.shared
    /// Демо для снимков интерфейса: не запускает codex и claude, состояния готовые.
    var demo = false

    var body: some View {
        SettingsPage(.ai, isOn: $enabled, toggleLabel: "ИИ-функции") {
            GroupLabel("Сервис")
            ListCard {
                Row("ИИ для всех функций", subtitle: "Через программу на этом Mac, под вашим аккаунтом.", systemImage: "sparkles") {
                    Segmented(selection: providerBinding,
                              options: AIProvider.allCases.map { (value: $0, title: $0.title) })
                }
                ForEach(AIProvider.allCases, id: \.self) { item in
                    AIConnectionRow(provider: item, connection: connection(item),
                                    check: demo ? nil : { status.refresh() })
                }
                ToggleRow("Запасной сервис",
                          subtitle: "Если \(selected.title) не ответил за \(Int(AI.fallbackSeconds)) с или ошибся — спросить \(selected.other.title).",
                          systemImage: "arrow.triangle.branch", isOn: $fallback)
            }
            .disabled(!enabled)
            GroupLabel("Функции")
            ListCard {
                ToggleRow("Исправить ошибки в выделенном тексте — \(HotKeyRegistry.combo(for: .fixText).title)",
                          subtitle: "Опечатки, орфография, пунктуация; выделение заменяется исправленным текстом.",
                          systemImage: "text.badge.checkmark", isOn: $fixText)
                ToggleRow("Умные имена снимков", subtitle: "По распознанному тексту: «Счёт за интернет 20.15.03.png».",
                          systemImage: "camera.viewfinder", isOn: $shotNames)
                ToggleRow("Поиск снимков по смыслу", subtitle: "«оплата» найдёт и «счёт», и «invoice».",
                          systemImage: "magnifyingglass", isOn: $shotSearch)
                ToggleRow("Папка для неизвестных типов в «Загрузках»", subtitle: "Кнопка «Предложить папку» в своих правилах.",
                          systemImage: "folder.badge.questionmark", isOn: $downloads)
                ToggleRow("Подписи файлов в «Загрузках»",
                          subtitle: "Каждому новому файлу при сортировке — короткая подпись по-английски в комментарии Spotlight: «📋 Spec — notch app for AI agents», «💿 Installer — Docker Desktop». Видно в ⌘I и в колонке «Комментарии», ищется через ⌘Пробел.",
                          systemImage: "tag", isOn: $downloadsTags)
                if downloadsTags {
                    Row(taggerTitle, systemImage: "tag.circle") {
                        HStack(spacing: DS.Space.s) {
                            if tagger.pending > 0 { ProgressView().controlSize(.small) }
                            Button("Подписать уже лежащие") { tagger.tagExisting(in: DownloadsSorter.shared.folder) }
                                .buttonStyle(.graphite(.secondary, size: .compact))
                                .disabled(tagger.pending > 0)
                        }
                    }
                }
                ToggleRow("Объяснения в диспетчере задач", subtitle: "Что за процесс и можно ли его закрыть; категории списка.",
                          systemImage: "list.bullet.rectangle", isOn: $tasks)
                ToggleRow("Разбор очистки диска", subtitle: "Что безопасно удалять и почему.",
                          systemImage: "externaldrive.badge.minus", isOn: $cleanup)
                ToggleRow("Группы на полке", subtitle: "Файлы на полке группируются по смыслу.",
                          systemImage: "tray.full", isOn: $shelf)
                ToggleRow("Отчёты о встречах", subtitle: "Итог, решения и задачи по расшифровке созвона.",
                          systemImage: "waveform.badge.mic", isOn: $meetings)
            }
            .disabled(!enabled)
        }
        .onAppear { if !demo { status.refresh() } }
    }

    private var selected: AIProvider { AIProvider(stored: provider) }

    private var providerBinding: Binding<AIProvider> {
        Binding(get: { AIProvider(stored: provider) }, set: { provider = $0.rawValue })
    }

    private func connection(_ provider: AIProvider) -> AIConnection {
        demo ? (provider == .codex ? .connected : .notLoggedIn) : status.state(provider)
    }

    private var taggerTitle: String {
        if tagger.pending > 0 { return "Осталось \(tagger.pending), помечено \(tagger.tagged)" }
        if tagger.tagged > 0 { return "Помечено документов: \(tagger.tagged)" }
        return "Подписи документов"
    }
}

/// Строка состояния сервиса: подключено / не найдено / как войти. Для страницы «ИИ» и быстрой панели.
struct AIConnectionRow: View {
    let provider: AIProvider
    let connection: AIConnection
    var check: (() -> Void)?

    var body: some View {
        let actions = check.map { [StatusAction(title: "Проверить", action: $0)] } ?? []
        switch connection {
        case .unknown, .checking:
            FeatureStatusRow(tone: .neutral, label: "\(provider.title): проверяю…")
        case .connected:
            FeatureStatusRow(tone: .success, label: "\(provider.title): подключено", actions: actions)
        case .notFound:
            FeatureStatusRow(tone: .warning, label: "\(provider.title): не найден", detail: provider.installHint, actions: actions)
        case .notLoggedIn:
            FeatureStatusRow(tone: .warning, label: "\(provider.title): не выполнен вход",
                             detail: "Войдите в Терминале: \(provider.loginCommand)",
                             actions: [StatusAction(title: "Скопировать команду") { Self.copy(provider.loginCommand) }] + actions)
        case .problem(let message):
            FeatureStatusRow(tone: .warning, label: "\(provider.title): \(message)", actions: actions)
        }
    }

    private static func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}

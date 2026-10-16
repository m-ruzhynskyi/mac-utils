import AppKit
import SwiftUI

// MARK: - ИИ

struct AIPage: View {
    @ObservedObject private var hotKeys = HotKeyPrefs.shared
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
    @ObservedObject private var tagger = DocumentTagger.shared
    /// Демо для снимков интерфейса: не опрашивает Ollama.
    var demo = false

    var body: some View {
        SettingsPage(.ai, isOn: $enabled, toggleLabel: "ИИ-функции") {
            GroupLabel("Модель")
            ListCard {
                statusRow
                Row("Модель", systemImage: "cpu") {
                    Picker("Модель", selection: $model) {
                        ForEach(Array(Set(ollama.models + [model])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .graphitePicker()
                    .onChange(of: model) { _, _ in ollama.refresh() }
                }
                if ollama.status == .noModel {
                    if let progress = ollama.pullProgress {
                        Row("Скачиваю \(model)…", systemImage: "arrow.down.circle") {
                            ProgressBar(value: progress).frame(width: 160)
                        }
                    } else {
                        Row("Скачать \(model)", subtitle: "qwen2.5:7b — около 4,7 ГБ.", systemImage: "arrow.down.circle") {
                            Button("Скачать \(model)") { ollama.pull() }.buttonStyle(.graphite(.primary, size: .compact))
                        }
                    }
                }
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
        .onAppear { if !demo { ollama.refresh() } }
    }

    private var taggerTitle: String {
        if tagger.pending > 0 { return "Осталось \(tagger.pending), помечено \(tagger.tagged)" }
        if tagger.tagged > 0 { return "Помечено документов: \(tagger.tagged)" }
        return "Подписи документов"
    }

    @ViewBuilder private var statusRow: some View {
        let check = StatusAction(title: "Проверить", action: { ollama.refresh() })
        switch ollama.status {
        case .unknown, .checking:
            FeatureStatusRow(tone: .neutral, label: "Проверяю Ollama…", actions: [check])
        case .ready:
            FeatureStatusRow(tone: .success, label: "Готово: \(model)", actions: [check])
        case .noServer:
            FeatureStatusRow(tone: .warning, label: "Ollama не запущена",
                             actions: [check, StatusAction(title: "Запустить Ollama", action: { ollama.launchServer() })])
        case .noModel:
            FeatureStatusRow(tone: .warning, label: "Модель \(model) не скачана", actions: [check])
        }
    }
}

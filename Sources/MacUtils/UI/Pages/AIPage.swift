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
                        Text("Исправить ошибки в выделенном тексте — \(HotKeyRegistry.combo(for: .fixText).title)")
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
                        Text("Подписи файлов в «Загрузках»")
                        Text("Каждому новому файлу при сортировке — короткая подпись по-английски в комментарии Spotlight: «📋 Spec — notch app for AI agents», «💿 Installer — Docker Desktop». Видно в ⌘I и в колонке «Комментарии», ищется через ⌘Пробел.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if downloadsTags {
                    HStack {
                        if tagger.pending > 0 {
                            ProgressView().controlSize(.small)
                            Text("Осталось \(tagger.pending), помечено \(tagger.tagged)").font(.caption).foregroundStyle(.secondary)
                        } else if tagger.tagged > 0 {
                            Text("Помечено документов: \(tagger.tagged)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Подписать уже лежащие") { tagger.tagExisting(in: DownloadsSorter.shared.folder) }
                            .disabled(tagger.pending > 0)
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

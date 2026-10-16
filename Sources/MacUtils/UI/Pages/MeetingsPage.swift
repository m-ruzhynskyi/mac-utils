import AppKit
import SwiftUI

// MARK: - Записи встреч

struct MeetingsPage: View {
    @AppStorage(Pref.meetings) private var enabled = true
    @AppStorage(Pref.meetingsMicrophone) private var microphone = true
    @AppStorage(Pref.meetingsLanguage) private var language = "auto"
    @AppStorage(Pref.meetingsEngine) private var engine = "whisper"
    @ObservedObject private var whisper = Whisper.shared
    @AppStorage(Pref.meetingsReport) private var report = true
    @ObservedObject private var recorder = MeetingRecorder.shared
    @State private var deleting: MeetingRecorder.Meeting?

    var body: some View {
        Form {
            Section {
                Toggle("Записи встреч", isOn: $enabled)
                Text("Записывает звук созвона (собеседников и ваш микрофон отдельно), расшифровывает прямо на Mac (Whisper или распознавание Apple), а локальная модель (Ollama) делает отчёт: итог, решения, задачи. Можно расшифровать и готовую запись. Ничего не уходит в интернет.")
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
                    ActionShortcutRow(action: .meeting, text: "старт / стоп")
                }
                if let error = recorder.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            Section("Расшифровка") {
                Picker("Движок", selection: $engine) {
                    Text("Whisper (лучше, рекомендуется)").tag("whisper")
                    Text("Apple (встроенный)").tag("apple")
                }
                if engine == "whisper" {
                    if Whisper.isReady {
                        Label("Whisper готов: large-v3-turbo, украинский, русский, английский", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if let progress = whisper.downloadProgress {
                        ProgressView(value: progress) { Text("Скачиваю модель Whisper…") }
                    } else {
                        HStack {
                            Text(whisper.message ?? "Whisper не установлен — пока используется распознавание Apple.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if whisper.installing { ProgressView().controlSize(.small) }
                            Button("Установить Whisper") { whisper.install() }.disabled(whisper.installing)
                        }
                        Text("whisper.cpp через Homebrew и модель около 550 МБ. Работает без интернета.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!enabled)
            Section("Настройки") {
                Toggle("Записывать мой микрофон", isOn: $microphone)
                Picker("Язык встреч", selection: $language) {
                    Text("Определять сам").tag("auto")
                    Text("Русский").tag("ru_RU")
                    Text("Українська").tag("uk_UA")
                    Text("English").tag("en_US")
                }
                Toggle("Отчёт ИИ после расшифровки", isOn: $report)
                Text("Нужны разрешения «Запись экрана» (звук системы) и «Микрофон». «Определять сам» — Whisper узнаёт язык по каждой дорожке.")
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
                        if meeting.hasTranscript {
                            Button { Task { await recorder.process(meeting, reportOnly: true) } } label: {
                                Image(systemName: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Сделать отчёт заново (расшифровка останется)")
                            .disabled(recorder.state != .idle)
                        }
                        Button { Task { await recorder.process(meeting) } } label: {
                            Image(systemName: meeting.hasReport ? "arrow.clockwise" : "text.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .help(meeting.hasReport ? "Расшифровать и сделать отчёт заново" : "Расшифровать и сделать отчёт")
                        .disabled(recorder.state != .idle)
                        Button { NSWorkspace.shared.open(meeting.folder) } label: { Image(systemName: "folder") }
                            .buttonStyle(.borderless)
                        Button { deleting = meeting } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help(recorder.busyFolder == meeting.folder ? "Сейчас расшифровывается" : "Удалить запись (в Корзину)")
                            .disabled(recorder.busyFolder == meeting.folder)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Записи встреч")
        .alert("Удалить запись «\(deleting?.title ?? "")»?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("В Корзину", role: .destructive) {
                if let meeting = deleting { recorder.delete(meeting) }
                deleting = nil
            }
            Button("Отмена", role: .cancel) { deleting = nil }
        } message: {
            Text("Звук, расшифровка и отчёт уйдут в Корзину.")
        }
        .onAppear { recorder.reload() }
    }
}

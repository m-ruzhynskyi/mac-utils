import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUMeetings
import MUScreenShare
import MUScreenshot

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
    /// Демо для снимков интерфейса: вместо записей этого Mac — несуществующие папки.
    var demo = false

    private var meetings: [MeetingRecorder.Meeting] {
        demo ? ["Планёрка команды", "Созвон с клиентом"].map { MeetingRecorder.Meeting(folder: URL(fileURLWithPath: "/nonexistent/\($0)")) }
             : recorder.meetings
    }

    var body: some View {
        SettingsPage(.meetings, isOn: $enabled, toggleLabel: "Записи встреч") {
            if let error = recorder.lastError {
                Banner(.warning, title: error)
            }
            ListCard {
                recordRow
                HintRow(action: .meeting, text: "старт / стоп")
            }
            Footnote("Можно расшифровать и готовую запись. Ничего не уходит в интернет.")
            GroupLabel("Расшифровка")
            ListCard {
                Row("Движок", systemImage: "waveform") {
                    Picker("Движок", selection: $engine) {
                        Text("Whisper (лучше, рекомендуется)").tag("whisper")
                        Text("Apple (встроенный)").tag("apple")
                    }
                    .graphitePicker()
                }
                if engine == "whisper" {
                    if Whisper.isReady {
                        FeatureStatusRow(tone: .success, label: "Whisper готов",
                                         detail: "large-v3-turbo, украинский, русский, английский")
                    } else if let progress = whisper.downloadProgress {
                        Row("Скачиваю модель Whisper…", systemImage: "arrow.down.circle") {
                            ProgressBar(value: progress).frame(width: 160)
                        }
                    } else {
                        Row(whisper.message ?? "Whisper не установлен — пока используется распознавание Apple.",
                            subtitle: "whisper.cpp через Homebrew и модель около 550 МБ. Работает без интернета.",
                            systemImage: "arrow.down.circle") {
                            HStack(spacing: DS.Space.s) {
                                if whisper.installing { ProgressView().controlSize(.small) }
                                Button("Установить Whisper") { whisper.install() }
                                    .buttonStyle(.graphite(.primary, size: .compact))
                                    .disabled(whisper.installing)
                            }
                        }
                    }
                }
            }
            .disabled(!enabled)
            GroupLabel("Настройки")
            ListCard {
                ToggleRow("Записывать мой микрофон", systemImage: "mic", isOn: $microphone)
                Row("Язык встреч", systemImage: "globe") {
                    Picker("Язык встреч", selection: $language) {
                        Text("Определять сам").tag("auto")
                        Text("Русский").tag("ru_RU")
                        Text("Українська").tag("uk_UA")
                        Text("English").tag("en_US")
                    }
                    .graphitePicker()
                }
                ToggleRow("Отчёт ИИ после расшифровки", systemImage: "doc.text", isOn: $report)
            }
            .disabled(!enabled)
            Footnote("Нужны разрешения «Запись экрана» (звук системы) и «Микрофон». «Определять сам» — Whisper узнаёт язык по каждой дорожке.")
            GroupLabel("Встречи")
            if meetings.isEmpty {
                ListCard { EmptyState("Пока нет записей", systemImage: "waveform", compact: true) }
            } else {
                ListCard {
                    ForEach(meetings) { meeting in meetingRow(meeting) }
                }
            }
        }
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
        .onAppear { if !demo { recorder.reload() } }
    }

    /// Состояние записи: начать / остановить со временем / идёт обработка.
    @ViewBuilder private var recordRow: some View {
        switch recorder.state {
        case .idle:
            Row("Записи встреч", systemImage: "record.circle") {
                HStack(spacing: DS.Space.s) {
                    Button { recorder.start() } label: { Label("Начать запись", systemImage: "record.circle") }
                        .buttonStyle(.graphite(.primary, size: .compact))
                        .fixedSize()
                    Button { recorder.importFile() } label: { Label("Расшифровать файл…", systemImage: "doc.badge.plus") }
                        .buttonStyle(.graphite(.secondary, size: .compact))
                        .fixedSize()
                        .help("Готовая запись созвона — аудио или видео")
                }
            }
        case .recording(let since):
            Row("Записи встреч", systemImage: "record.circle", tile: .record) {
                HStack(spacing: DS.Space.m) {
                    Text(since, style: .timer).font(DS.Font.mono).monospacedDigit().foregroundStyle(Color.dsRec)
                    Button { recorder.stop() } label: { Label("Остановить", systemImage: "stop.fill") }
                        .buttonStyle(.graphite(.danger, size: .compact))
                }
            }
        case .processing(let step):
            Row("Записи встреч", subtitle: step, systemImage: "waveform") {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// Готовые дорожки встречи («Собеседники.m4a», «Я.m4a»): две проверки файлов вместо чтения папки при каждой перерисовке.
    static func audioFiles(_ meeting: MeetingRecorder.Meeting) -> [URL] {
        [MeetingFiles.systemTrack, MeetingFiles.micTrack].map { meeting.folder.appendingPathComponent("\($0).m4a") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func meetingRow(_ meeting: MeetingRecorder.Meeting) -> some View {
        Row(meeting.title, systemImage: meeting.hasReport ? "doc.text.fill" : "waveform") {
            HStack(spacing: DS.Space.s) {
                if meeting.hasReport {
                    Button("Отчёт") { NSWorkspace.shared.open(meeting.report) }.buttonStyle(.graphite(.secondary, size: .compact))
                }
                if meeting.hasTranscript {
                    Button("Текст") { NSWorkspace.shared.open(meeting.transcript) }.buttonStyle(.graphite(.secondary, size: .compact))
                    IconButton("Сделать отчёт заново (расшифровка останется)", systemImage: "doc.text.magnifyingglass", compact: true) {
                        Task { await recorder.process(meeting, reportOnly: true) }
                    }
                    .disabled(recorder.state != .idle)
                }
                IconButton(meeting.hasReport ? "Расшифровать и сделать отчёт заново" : "Расшифровать и сделать отчёт",
                           systemImage: meeting.hasReport ? "arrow.clockwise" : "text.badge.plus", compact: true) {
                    Task { await recorder.process(meeting) }
                }
                .disabled(recorder.state != .idle)
                let audio = Self.audioFiles(meeting)
                if !audio.isEmpty {
                    IconButton("Слушать в плеере Mac Utils", systemImage: "play.circle", compact: true) { PlayerWindowController.open(audio) }
                }
                IconButton("Показать в Finder", systemImage: "folder", compact: true) { NSWorkspace.shared.open(meeting.folder) }
                IconButton(recorder.busyFolder == meeting.folder ? "Сейчас расшифровывается" : "Удалить запись (в Корзину)",
                           systemImage: "trash", compact: true) { deleting = meeting }
                    .disabled(recorder.busyFolder == meeting.folder)
            }
        }
    }
}

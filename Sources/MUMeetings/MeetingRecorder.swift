@preconcurrency import AVFoundation
import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import Speech
import SwiftUI
import MUCore
import MUDesign

/// Реплика расшифровки: кто и когда.
package struct TranscriptLine: Equatable {
    package var start: Double
    package var speaker: String
    package var text: String
}

/// Склейка и форматирование расшифровки (без UI — для тестов).
package enum MeetingText {
    /// Реплики двух дорожек по времени; соседние реплики одного человека — вместе.
    package static func merge(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        for line in lines.sorted(by: { $0.start < $1.start }) {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = result.last, last.speaker == line.speaker, line.start - last.start < 60 {
                last.text += " " + text
                result[result.count - 1] = last
            } else {
                result.append(TranscriptLine(start: line.start, speaker: line.speaker, text: text))
            }
        }
        return result
    }

    package static func timestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }

    package static func format(_ lines: [TranscriptLine]) -> String {
        lines.map { "[\(timestamp($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// Длинную расшифровку режем на куски по строкам, чтобы влезло в контекст модели.
    package static func chunks(_ text: String, limit: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// Запись созвона: звук системы (собеседники) и микрофон (вы) — отдельными дорожками,
/// затем локальная расшифровка и отчёт локальной моделью: итог, решения, задачи.
///
/// Запись и расшифровка независимы: пока идёт расшифровка, можно записывать следующую встречу (очередь `queue`).
/// Дорожки пишутся кусками (`MeetingFiles`), поэтому сбой или ⌘Q стоят не больше одного куска.
@MainActor
package final class MeetingRecorder: NSObject, ObservableObject {
    package static let shared = MeetingRecorder()

    package struct Meeting: Identifiable, Hashable {
        package init(folder: URL) {
            self.folder = folder
        }

        package let folder: URL
        package var id: URL { folder }
        package var title: String { folder.lastPathComponent }
        package var report: URL { folder.appendingPathComponent("Отчёт.md") }
        package var transcript: URL { folder.appendingPathComponent("Расшифровка.txt") }
        package var hasReport: Bool { FileManager.default.fileExists(atPath: report.path) }
        package var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcript.path) }
    }

    /// `.recording` — идёт запись (даже если параллельно что-то расшифровывается); `.processing` — записи нет, но идёт
    /// сохранение или расшифровка; `.idle` — ничего. Считается из `recordingSince`, активностей и очереди (`refreshState`).
    package enum State: Equatable {
        case idle
        case recording(since: Date)
        case processing(String)
    }

    @Published package fileprivate(set) var state: State = .idle
    @Published package private(set) var meetings: [Meeting] = []
    /// Встреча, которая сейчас расшифровывается (её нельзя удалить).
    @Published package private(set) var busyFolder: URL?
    @Published package private(set) var lastError: String?
    /// Запись прервалась (поток остановился): показывается в HUD, пока идёт перезапуск.
    @Published package fileprivate(set) var interruption: String?
    /// Давно нет звука от потока — запись может идти вхолостую.
    @Published package fileprivate(set) var audioStalled = false

    private var stream: SCStream?
    private var writer: MeetingWriter?
    private var echoFree: EchoFreeMicrophone?
    private var folder: URL?
    private var hud: NSPanel?
    private var microphoneWanted = false
    private var recordingSince: Date?
    private var starting = false
    private var restartAttempts = 0
    /// Когда поток последний раз перезапускали: после 10 минут ровной записи счётчик попыток обнуляется (N3).
    private var lastRestartAt: Date?
    private var watchdog: Timer?
    private var closingOld: Task<Void, Never>?
    private var recovered = false
    /// Папки, начатые в этом запуске: восстановление «оборванных» их не трогает, даже если `begin` ещё идёт (N6).
    private var sessionFolders: Set<URL> = []
    private var wakeObserver: NSObjectProtocol?

    // Очередь расшифровки и фоновые «активности» (сохранение записи, подготовка звука).
    private struct Job: Equatable { let folder: URL; let reportOnly: Bool }
    private struct Queued { let job: Job; let waiter: CheckedContinuation<Void, Never>? }
    private var queue: [Queued] = []
    private var currentJob: Job?
    private var worker: Task<Void, Never>?
    private var currentStep = ""
    private var activities: [Int: String] = [:]
    private var nextActivity = 0

    package static var root: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Встречи", isDirectory: true)
    }

    /// Папка встречи по имени из ссылки `macutils://meeting-report?<имя>`: только одно имя внутри корня встреч — без `/`, `..` и
    /// подмен через символические ссылки. Иначе nil.
    package nonisolated static func folder(named name: String, root: URL) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"), !name.contains("..") else { return nil }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent().path == base else { return nil }
        return folder
    }

    // MARK: - Состояние

    /// Единственное место, где меняется `state`.
    private func refreshState() {
        if let since = recordingSince {
            state = .recording(since: since)
        } else if let label = activities.sorted(by: { $0.key < $1.key }).first?.value {
            state = .processing(label)
        } else if currentJob != nil {
            let waiting = queue.count
            state = .processing(waiting > 0 ? "\(currentStep) (ещё в очереди: \(waiting))" : currentStep)
        } else {
            state = .idle
        }
    }

    private func beginActivity(_ label: String) -> Int {
        nextActivity += 1
        activities[nextActivity] = label
        refreshState()
        return nextActivity
    }

    private func endActivity(_ id: Int) {
        activities[id] = nil
        refreshState()
    }

    /// Идёт ли расшифровка или в очереди есть встречи.
    package var hasPendingWork: Bool { currentJob != nil || !queue.isEmpty || !activities.isEmpty }

    package func sync() {
        observeWake()
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.meeting)
        if UserDefaults.standard.bool(forKey: Pref.meetings) {
            center.register(id: HotKeyID.meeting, keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey) {
                AppRouter.shared.runHotKey(HotKeyID.meeting)
            }
            recoverUnfinishedOnce()
        }
        reload()
    }

    package func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        meetings = folders.filter { $0.hasDirectoryPath }.map(Meeting.init).sorted { $0.title > $1.title }
    }

    /// Встречу целиком (звук, расшифровка, отчёт) — в Корзину. Идущую расшифровку и ожидающую в очереди не трогаем.
    package func delete(_ meeting: Meeting) {
        guard currentJob?.folder != meeting.folder, !queue.contains(where: { $0.job.folder == meeting.folder }),
              folder != meeting.folder || recordingSince == nil else { return }
        try? FileManager.default.trashItem(at: meeting.folder, resultingItemURL: nil)
        reload()
    }

    package func toggle() {
        // Запись не зависит от расшифровки: ⌃⌥M во время расшифровки начинает новую запись.
        if recordingSince != nil { stop() } else { start() }
    }

    // MARK: - Запись

    package func start() {
        guard recordingSince == nil, !starting else { return }
        starting = true
        lastError = nil
        Task {
            defer { starting = false }
            let folder = MeetingFiles.uniqueFolder(in: Self.root, name: Self.folderName(for: Date()))
            sessionFolders.insert(folder.standardizedFileURL)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let wantsMic = UserDefaults.standard.bool(forKey: Pref.meetingsMicrophone)
                // Метка «запись идёт»: если приложение оборвётся, при следующем запуске запись восстановится из кусков.
                MeetingFiles.writeMarker(in: folder, startedAt: Date(), microphone: wantsMic)
                microphoneWanted = wantsMic
                try await begin(into: folder)
                self.folder = folder
                recordingSince = Date()
                restartAttempts = 0
                lastRestartAt = nil
                interruption = nil
                audioStalled = false
                refreshState()
                showHUD()
                startWatchdog()
                Toast.show("Записываю встречу. Остановить — ⌃⌥M", symbol: "record.circle", tint: .red)
            } catch {
                MeetingFiles.removeMarker(in: folder)
                if ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty {
                    try? FileManager.default.removeItem(at: folder)
                }
                Log.audio.error("Встреча: не началась: \(error.localizedDescription, privacy: .public)")
                lastError = "Не удалось начать запись: \(error.localizedDescription)"
                Toast.show("Нет разрешения «Запись экрана» или микрофона", symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    /// Папка по минуте: «2026-10-16 10.30» (повтор в ту же минуту получает « (2)» — см. `MeetingFiles.uniqueFolder`).
    package static func folderName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: date)
    }

    /// Запускает захват звука в папку (первый раз и после обрыва потока). Куски нумеруются дальше уже лежащих.
    private func begin(into folder: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display,
                                     excludingApplications: content.applications.filter { $0.processID == ownPID },
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        // Видео не нужно — минимальный кадр раз в секунду.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        let wantsMic = microphoneWanted

        let writer = MeetingWriter(folder: folder, microphone: wantsMic)
        writer.onFailure = { [weak self, weak writer] error in
            Task { @MainActor in
                guard let writer else { return }
                self?.streamFailed(error, from: writer)
            }
        }
        // Микрофон — с подавлением эха: голоса собеседников из динамиков не попадают в «Я».
        var echoFree: EchoFreeMicrophone?
        if wantsMic {
            let candidate = EchoFreeMicrophone { [weak writer] buffer, pts in
                writer?.queue.async { writer?.write(buffer, at: pts, track: .microphone) }
            }
            do {
                try candidate.start()
                echoFree = candidate
            } catch {
                Log.audio.error("Встреча: подавление эха недоступно: \(error.localizedDescription, privacy: .public)")
                if #available(macOS 15.0, *) { config.captureMicrophone = true }
            }
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: writer)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        if #available(macOS 15.0, *), wantsMic, echoFree == nil {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        try await stream.startCapture()
        self.echoFree = echoFree
        self.stream = stream
        self.writer = writer
        self.folder = folder
    }

    package func stop() {
        finishRecording(note: nil)
    }

    /// Останавливает запись, склеивает куски и ставит встречу в очередь расшифровки.
    private func finishRecording(note: String?) {
        guard recordingSince != nil, let folder else { return }
        let stream = self.stream, writer = self.writer
        self.stream = nil
        self.writer = nil
        echoFree?.stop()
        echoFree = nil
        hud?.orderOut(nil)
        hud = nil
        watchdog?.invalidate()
        watchdog = nil
        recordingSince = nil
        interruption = nil
        audioStalled = false
        self.folder = nil
        // В очередь — сразу, на диске: если приложение закроется во время сохранения, при запуске встреча
        // восстановится и расшифруется (MAJOR-1).
        MeetingFiles.writeQueueMarker(in: folder, reportOnly: false)
        let activity = beginActivity("Сохраняю запись…")
        let closing = closingOld
        Task {
            try? await stream?.stopCapture()
            await writer?.finish()
            await closing?.value
            await MeetingMerge.finalize(folder: folder)
            reload()
            // Запись в очередь и снятие «сохраняю» — без паузы между ними, чтобы состояние не мигало.
            enqueue(Job(folder: folder, reportOnly: false), waiter: nil)
            endActivity(activity)
            if let note { Toast.show(note, symbol: "exclamationmark.triangle.fill", tint: .orange) }
        }
    }

    // MARK: - Обрыв потока

    /// Поток ScreenCaptureKit остановился сам (отключили монитор, отозвали разрешение, сменилось устройство).
    fileprivate func streamFailed(_ error: Error, from failed: MeetingWriter) {
        guard writer === failed, recordingSince != nil, let folder else { return }
        Log.audio.error("Встреча: поток остановлен: \(error.localizedDescription, privacy: .public)")
        interruption = "Запись прервалась"
        stream = nil
        writer = nil
        echoFree?.stop()
        echoFree = nil
        Toast.show("Запись встречи прервалась — пробую продолжить", symbol: "exclamationmark.triangle.fill", tint: .orange)
        let closing = Task { await failed.finish() }
        closingOld = closing
        Task {
            await closing.value
            guard recordingSince != nil, writer == nil else { return }
            // Долгая встреча: обрывы раз в час (отключали монитор) не должны копиться до остановки записи.
            if let last = lastRestartAt, Date().timeIntervalSince(last) > 600 { restartAttempts = 0 }
            guard restartAttempts < 2 else {
                finishRecording(note: "Запись встречи прервалась. Записанное сохранено и расшифровывается.")
                return
            }
            restartAttempts += 1
            lastRestartAt = Date()
            do {
                // Другой экран и устройство: берём первый доступный, как при обычном старте.
                try await begin(into: folder)
                interruption = nil
                Toast.show("Запись встречи продолжена", symbol: "record.circle", tint: .red)
            } catch {
                Log.audio.error("Встреча: перезапуск не удался: \(error.localizedDescription, privacy: .public)")
                guard recordingSince != nil, writer == nil else { return }
                finishRecording(note: "Запись встречи прервалась. Записанное сохранено и расшифровывается.")
            }
        }
    }

    // MARK: - Сон

    /// После сна поток ScreenCaptureKit часто не падает, а молчит: запись шла бы в тот же кусок с «дырой».
    /// Через 5 с после пробуждения проверяем звук; если его нет — перезапускаем поток, как при обрыве (N5).
    private func observeWake() {
        guard wakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MeetingRecorder.shared.didWake() }
        }
        _ = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if MeetingRecorder.shared.recordingSince != nil { Log.audio.info("Встреча: Mac засыпает во время записи") }
            }
        }
    }

    private func didWake() {
        guard recordingSince != nil else { return }
        Log.audio.info("Встреча: Mac проснулся во время записи")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                let recorder = MeetingRecorder.shared
                guard recorder.recordingSince != nil, recorder.interruption == nil, let writer = recorder.writer,
                      writer.secondsSinceAudio > MeetingStall.threshold else { return }
                recorder.streamFailed(CocoaError(.userCancelled), from: writer)
            }
        }
    }

    /// Раз в 5 секунд: если поток молчит дольше 10 секунд, HUD предупреждает (запись могла пойти вхолостую).
    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { MeetingRecorder.shared.checkAudioFlow() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkAudioFlow() {
        guard recordingSince != nil, interruption == nil, let writer else {
            if audioStalled { audioStalled = false }
            return
        }
        let stalled = MeetingStall.isStalled(secondsSinceAudio: writer.secondsSinceAudio)
        if stalled != audioStalled { audioStalled = stalled }
    }

    // MARK: - Восстановление после сбоя

    /// При запуске: оборванные записи (сбой, ⌘Q во время сохранения) склеиваются из кусков, а встречи, которые стояли
    /// в очереди до выхода (метка «В очереди»), снова ставятся в очередь. Обо всём — одно уведомление.
    package func recoverUnfinishedOnce() {
        guard !recovered else { return }
        recovered = true
        let root = Self.root
        let skip = sessionFolders.union(folder.map { [$0.standardizedFileURL] } ?? [])
        let unfinished = MeetingFiles.unfinished(in: root).filter { !skip.contains($0.standardizedFileURL) }
        let queued = MeetingFiles.queued(in: root).filter { !skip.contains($0.folder.standardizedFileURL) }
        guard !unfinished.isEmpty || !queued.isEmpty else { return }
        Task {
            var restored: [URL] = []
            for folder in unfinished where !(await MeetingMerge.finalize(folder: folder)).isEmpty {
                restored.append(folder)
            }
            reload()
            let plan = MeetingRecovery.plan(restored: restored, queued: queued,
                                            hasTranscript: { Meeting(folder: $0).hasTranscript })
            for job in plan.resume { enqueue(Job(folder: job.folder, reportOnly: job.reportOnly), waiter: nil) }
            guard let message = plan.message else { return }
            let offer = plan.offer
            Toast.show(message, symbol: "arrow.counterclockwise.circle.fill", tint: .orange,
                       action: offer.isEmpty ? nil : Toast.Action(title: "Расшифровать") {
                           for folder in offer {
                               MeetingRecorder.shared.enqueue(Job(folder: folder, reportOnly: false), waiter: nil)
                           }
                       })
        }
    }

    // MARK: - Готовый файл

    /// Расшифровать готовую запись (Zoom, Telegram, диктофон — аудио или видео).
    package func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.prompt = "Расшифровать"
        panel.message = "Выберите запись встречи — аудио или видео"
        ScreenOutput.activateApp(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return }
        lastError = nil
        let activity = beginActivity("Готовлю звук…")
        Task {
            defer { endActivity(activity) }
            do {
                let name = source.deletingPathExtension().lastPathComponent
                let folder = MeetingFiles.uniqueFolder(in: Self.root, name: name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await Self.extractAudio(from: source, to: folder.appendingPathComponent("Собеседники.m4a"))
                reload()
                enqueue(Job(folder: folder, reportOnly: false), waiter: nil)
            } catch {
                lastError = "Не удалось прочитать звук: \(error.localizedDescription)"
            }
        }
    }

    /// Звуковая дорожка в M4A (из видео тоже).
    package nonisolated static func extractAudio(from source: URL, to target: URL) async throws {
        try? FileManager.default.removeItem(at: target)
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if #available(macOS 15.0, *) {
            try await export.export(to: target, as: .m4a)
        } else {
            export.outputURL = target
            export.outputFileType = .m4a
            await export.export()
            if let error = export.error { throw error }
        }
    }

    // MARK: - Очередь расшифровки и отчёта

    /// reportOnly — расшифровка уже есть, заново делаем только отчёт. Возвращается, когда эта встреча обработана.
    package func process(_ meeting: Meeting, reportOnly: Bool = false) async {
        let job = Job(folder: meeting.folder, reportOnly: reportOnly)
        guard !isQueued(job) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue(job, waiter: continuation)
        }
    }

    private func isQueued(_ job: Job) -> Bool { currentJob == job || queue.contains { $0.job == job } }

    private func enqueue(_ job: Job, waiter: CheckedContinuation<Void, Never>?) {
        guard !isQueued(job) else { waiter?.resume(); return }
        // Очередь живёт и на диске: после выхода или сбоя она подхватывается при запуске (MAJOR-1).
        MeetingFiles.writeQueueMarker(in: job.folder, reportOnly: job.reportOnly)
        queue.append(Queued(job: job, waiter: waiter))
        startWorker()
        refreshState()
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            while !queue.isEmpty {
                let item = queue.removeFirst()
                currentJob = item.job
                busyFolder = item.job.folder
                currentStep = "Расшифровываю…"
                refreshState()
                MeetingFiles.noteQueueAttempt(in: item.job.folder)
                await run(item.job)
                // Обработана (успешно или с понятной ошибкой) — после перезапуска не повторяется.
                // Метку оставляем, если та же встреча ждёт ещё раз (например, полная расшифровка после «только отчёта»).
                if !queue.contains(where: { $0.job.folder == item.job.folder }) {
                    MeetingFiles.removeQueueMarker(in: item.job.folder)
                }
                currentJob = nil
                busyFolder = nil
                item.waiter?.resume()
            }
            worker = nil
            refreshState()
        }
    }

    /// Расшифровка и отчёт одной встречи (очередь вызывает по одной).
    private func run(_ job: Job) async {
        let meeting = Meeting(folder: job.folder)
        if recordingSince != nil, folder == job.folder {
            lastError = "Эта встреча ещё записывается"
            return
        }
        // Куски дорожек (после остановки или сбоя) — в обычные файлы.
        await MeetingMerge.finalize(folder: meeting.folder)
        let tracks: [(file: String, speaker: String)] = [("Собеседники.m4a", "Собеседники"), ("Я.m4a", "Я")]
        do {
            var lines: [TranscriptLine] = []
            let existing = job.reportOnly ? try? String(contentsOf: meeting.transcript, encoding: .utf8) : nil
            for track in tracks where existing == nil {
                let url = meeting.folder.appendingPathComponent(track.file)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let step = "Расшифровываю: \(track.speaker.lowercased())"
                setStep(step + "…")
                if Whisper.isReady, UserDefaults.standard.string(forKey: Pref.meetingsEngine) != "apple" {
                    let language = UserDefaults.standard.string(forKey: Pref.meetingsLanguage) ?? "auto"
                    lines += try await Whisper.transcribe(url, speaker: track.speaker, language: language) { percent in
                        Task { @MainActor in MeetingRecorder.shared.setStep("\(step)… \(percent) %") }
                    }
                } else {
                    lines += try await Transcriber.transcribe(url, speaker: track.speaker)
                }
            }
            Log.audio.info("Встреча: \(lines.count) реплик")
            let transcript = existing ?? MeetingText.format(MeetingText.merge(lines))
            guard !transcript.isEmpty else {
                Log.audio.info("Встреча: речи не найдено")
                lastError = "В записи не нашлось речи"
                Toast.show("В записи не нашлось речи", symbol: "waveform.slash", tint: .orange)
                return
            }
            if existing == nil { try transcript.write(to: meeting.transcript, atomically: true, encoding: .utf8) }
            // На пару фраз отчёт не нужен — модель начнёт выдумывать.
            let words = transcript.split(whereSeparator: \.isWhitespace).count
            if words < 40 { try? FileManager.default.removeItem(at: meeting.report) }
            if Ollama.isOn(Pref.meetingsReport), words >= 40 {
                setStep("Готовлю отчёт…")
                let report = try await Self.report(for: transcript) { step in
                    Task { @MainActor in MeetingRecorder.shared.setStep(step) }
                }
                try ("# Встреча \(meeting.title)\n\n" + report).write(to: meeting.report, atomically: true, encoding: .utf8)
            }
            reload()
            let target = meeting.hasReport ? meeting.report : meeting.transcript
            Toast.show(meeting.hasReport ? "Отчёт о встрече готов" : "Расшифровка готова", symbol: "doc.text.fill",
                       action: Toast.Action(title: "Открыть") { NSWorkspace.shared.open(target) })
        } catch {
            Log.audio.error("Встреча: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            reload()
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private func setStep(_ step: String) {
        currentStep = step
        refreshState()
    }

    package static let reportSystem = """
    Ты опытный секретарь встреч. Тебе дают расшифровку созвона (речь может быть на украинском, русском \
    или английском; в расшифровке бывают ошибки распознавания — восстанавливай смысл по контексту).
    «Я» — владелец записи, «Собеседники» — остальные участники.
    Составь отчёт строго НА РУССКОМ (украинские и английские фразы переводи) в Markdown с разделами:
    ## Итог — 4–8 предложений: о чём встреча, ключевые факты, цифры, имена, договорённости.
    ## Темы — список обсуждённых тем, по одной строке с сутью каждой.
    ## Решения — что решили, по одному пункту.
    ## Задачи — поручения в виде «- [ ] исполнитель: действие», срок — только если он прямо назван в расшифровке.
    ## Открытые вопросы — что осталось нерешённым.
    Опирайся только на расшифровку, ничего не выдумывай и не добавляй того, чего в ней нет. \
    Если раздел пуст — «нет».
    """

    /// Длинные встречи — сначала конспект по частям, затем общий отчёт.
    package nonisolated static func report(for transcript: String,
                                   progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let parts = MeetingText.chunks(transcript, limit: 9_000)
        if parts.count == 1 {
            progress("Готовлю отчёт…")
            return try await Ollama.generate(transcript, system: reportSystem, temperature: 0.2, timeout: 900,
                                             context: 8_192, maxTokens: 1200)
        }
        var notes: [String] = []
        for (index, part) in parts.enumerated() {
            progress("Отчёт: часть \(index + 1) из \(parts.count)…")
            let note = try await Ollama.generate(
                part, system: "Это часть \(index + 1) из \(parts.count) расшифровки созвона (речь на украинском, русском "
                    + "или английском, возможны ошибки распознавания). Сжато законспектируй её строго по-русски списком "
                    + "до 12 пунктов: темы и ключевые факты (цифры, имена, даты), решения, задачи с исполнителями "
                    + "и сроками (только если названы), открытые вопросы. Ничего не выдумывай.",
                temperature: 0.2, timeout: 900, context: 8_192, maxTokens: 500)
            notes.append("Часть \(index + 1):\n\(note)")
        }
        progress("Отчёт: собираю итог…")
        return try await Ollama.generate(notes.joined(separator: "\n\n"), system: reportSystem,
                                         temperature: 0.2, timeout: 900, context: 8_192, maxTokens: 1200)
    }

    // MARK: - Индикатор записи

    private func showHUD() {
        guard let screen = NSScreen.main else { return }
        let host = FirstMouseHostingView(rootView: MeetingHUD(recorder: self))
        let size = host.fittingSize
        let panel = HUDPanel(contentRect: NSRect(x: screen.visibleFrame.maxX - size.width - 16,
                                                 y: screen.visibleFrame.maxY - size.height - 12,
                                                 width: size.width, height: size.height),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.orderFrontRegardlessOnScreen()
        hud = panel
    }
}

private struct MeetingHUD: View {
    @ObservedObject package var recorder: MeetingRecorder

    package var body: some View {
        var since: Date?
        if case .recording(let started) = recorder.state { since = started }
        return MeetingHUDContent(since: since, interruption: recorder.interruption, stalled: recorder.audioStalled) { recorder.stop() }
    }
}

/// Индикатор записи встречи: «ВСТРЕЧА», время, предупреждение (обрыв потока или «Нет звука») и «Стоп».
/// Значения готовые, без модели.
package struct MeetingHUDContent: View {
    package var since: Date?
    package var interruption: String?
    package var stalled = false
    package let stop: () -> Void

    package var body: some View {
        LiveIndicator(.meeting, since: interruption == nil ? since : nil,
                      warning: interruption ?? (stalled ? "Нет звука" : nil)) {
            HUDIconButton(symbol: "stop.fill", help: "Остановить и расшифровать (⌃⌥M)", kind: .stop, action: stop)
        }
        .help(stalled && interruption == nil ? "Поток звука молчит больше 10 секунд — проверьте, что звук воспроизводится" : "")
        .padding(2)
    }
}

/// Звук молчит дольше этого — HUD предупреждает.
package enum MeetingStall {
    package static let threshold: TimeInterval = 10
    package static func isStalled(secondsSinceAudio: TimeInterval, threshold: TimeInterval = MeetingStall.threshold) -> Bool {
        secondsSinceAudio > threshold
    }
}

// MARK: - Файлы дорожек

/// Дорожки M4A кусками (`MeetingFiles`): звук системы и микрофон с общей шкалой времени.
/// AVAudioFile пишет каждый кусок синхронно — ничего не теряется (AVAssetWriter в реальном
/// времени пропускал куски, когда был занят, и речь распознавалась обрывками).
/// Кусок закрывается каждые `MeetingChunking.seconds` секунд: M4A читается только закрытым,
/// а закрытые куски переживают сбой.
package final class MeetingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    package let queue = DispatchQueue(label: "macutils.meeting")
    package enum Track {
        case system, microphone
        package var name: String { self == .system ? MeetingFiles.systemTrack : MeetingFiles.micTrack }
    }

    private let folder: URL
    private let tracks: Set<Track>
    private var files: [Track: AVAudioFile] = [:]
    private var framesInPart: [Track: Int64] = [:]
    private var nextIndex: [Track: Int] = [:]
    private var start: CMTime?
    /// Первый кусок этого писателя у дорожки уже начат (тишина в начале — только в нём, N1).
    private var startedTracks: Set<Track> = []
    /// Сколько секунд записано этим писателем по каждой дорожке (с тишиной в начале) и формат последнего буфера.
    private var writtenSeconds: [Track: Double] = [:]
    private var lastFormat: [Track: AVAudioFormat] = [:]
    private var finished = false
    private var reportedFailure = false
    private let lock = NSLock()
    private var lastAudio = Date()
    /// Поток остановился сам или запись на диск не удалась (диск полон).
    package var onFailure: (@Sendable (Error) -> Void)?

    package init(folder: URL, microphone: Bool) {
        self.folder = folder
        tracks = microphone ? [.system, .microphone] : [.system]
        super.init()
        for track in tracks { nextIndex[track] = MeetingFiles.nextPartIndex(in: folder, track: track.name) }
    }

    /// Сколько секунд от последнего буфера звука.
    package var secondsSinceAudio: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastAudio)
    }

    package func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, type != .screen, let description = sampleBuffer.formatDescription,
              let buffer = Self.pcm(from: sampleBuffer, description: description) else { return }
        write(buffer, at: sampleBuffer.presentationTimeStamp, track: type == .audio ? .system : .microphone)
    }

    /// Вызывается на queue.
    package func write(_ buffer: AVAudioPCMBuffer, at pts: CMTime, track type: Track) {
        guard !finished, tracks.contains(type) else { return }
        lock.lock(); lastAudio = Date(); lock.unlock()
        if start == nil { start = pts }
        do {
            if files[type] == nil {
                let index = nextIndex[type] ?? 1
                nextIndex[type] = index + 1
                let format = buffer.format
                let file = try AVAudioFile(forWriting: MeetingFiles.partURL(folder: folder, track: type.name, index: index), settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount,
                    AVEncoderBitRateKey: 96_000,
                ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                files[type] = file
                framesInPart[type] = 0
                // Дорожка началась позже другой — дополняем тишиной, чтобы реплики совпадали по времени.
                // В первом куске каждого писателя (после перезапуска потока — тоже); следующие продолжают без разрыва.
                let lead = (pts - start!).seconds
                if startedTracks.insert(type).inserted, lead > 0.05 {
                    try Self.writeSilence(seconds: lead, format: format, to: file)
                    writtenSeconds[type, default: 0] += lead
                }
            }
            try files[type]?.write(from: buffer)
            framesInPart[type, default: 0] += Int64(buffer.frameLength)
            writtenSeconds[type, default: 0] += Double(buffer.frameLength) / buffer.format.sampleRate
            lastFormat[type] = buffer.format
            if MeetingChunking.shouldRotate(frames: framesInPart[type] ?? 0, sampleRate: buffer.format.sampleRate) {
                // Освобождение закрывает файл и дописывает заголовок: кусок становится читаемым.
                files[type] = nil
                framesInPart[type] = 0
            }
        } catch {
            Log.audio.error("Встреча: запись звука: \(error.localizedDescription, privacy: .public)")
            // Диск полон или папка пропала: сообщаем один раз, запись не продолжится.
            if !reportedFailure {
                reportedFailure = true
                onFailure?(error)
            }
        }
    }

    /// CMSampleBuffer → AVAudioPCMBuffer (копия данных).
    private static func pcm(from sampleBuffer: CMSampleBuffer, description: CMFormatDescription) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    package func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.audio.error("Встреча: поток остановлен: \(error.localizedDescription, privacy: .public)")
        onFailure?(error)
    }

    package func finish() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.finished = true
                self.padShorterTrack()
                // AVAudioFile закрывается и дописывает заголовок при освобождении.
                self.files.removeAll()
                continuation.resume()
            }
        }
    }

    /// Дорожки этого писателя к концу разной длины (например, микрофон замолчал раньше обрыва): короткую дополняем
    /// тишиной, иначе после перезапуска потока «Я» и «Собеседники» в склейке сдвинутся друг относительно друга (N1).
    private func padShorterTrack() {
        guard let longest = writtenSeconds.values.max() else { return }
        for (track, seconds) in writtenSeconds {
            let gap = MeetingAlignment.padding(written: seconds, longest: longest)
            guard gap > 0, let format = lastFormat[track] else { continue }
            do {
                let file: AVAudioFile
                if let open = files[track] {
                    file = open
                } else {
                    let index = nextIndex[track] ?? 1
                    nextIndex[track] = index + 1
                    file = try AVAudioFile(forWriting: MeetingFiles.partURL(folder: folder, track: track.name, index: index), settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount, AVEncoderBitRateKey: 96_000,
                    ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                    files[track] = file
                }
                try Self.writeSilence(seconds: gap, format: format, to: file)
            } catch {
                Log.audio.error("Встреча: выравнивание дорожек: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func writeSilence(seconds: Double, format: AVAudioFormat, to file: AVAudioFile) throws {
        // Кусками по секунде: тишина в несколько минут не должна занимать память одним буфером.
        var left = AVAudioFrameCount(seconds * format.sampleRate)
        let step = AVAudioFrameCount(format.sampleRate)
        while left > 0 {
            let frames = min(left, step)
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            silence.frameLength = frames
            for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            try file.write(from: silence)
            left -= frames
        }
    }
}

// MARK: - Локальная расшифровка

package enum Transcriber {
    package struct Failure: LocalizedError {
        package let errorDescription: String?
    }

    package static var locale: Locale {
        let setting = UserDefaults.standard.string(forKey: Pref.meetingsLanguage) ?? "auto"
        return Locale(identifier: setting == "auto" ? "ru_RU" : setting)
    }

    /// Расшифровка на устройстве: SpeechAnalyzer (macOS 26+), иначе SFSpeechRecognizer без сети.
    package static func transcribe(_ url: URL, speaker: String) async throws -> [TranscriptLine] {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return try await analyze(url, speaker: speaker)
        }
        #endif
        return try await recognize(url, speaker: speaker)
    }

    #if compiler(>=6.2)
    /// SpeechTranscriber (лучше для длинной речи), а если язык он не знает (русский, украинский) —
    /// DictationTranscriber. Оба работают на устройстве.
    @available(macOS 26.0, *)
    private static func analyze(_ url: URL, speaker: String) async throws -> [TranscriptLine] {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                           attributeOptions: [.audioTimeRange])
            return try await run(module, results: module.results.map { ($0.range.start.seconds, String($0.text.characters)) },
                                 url: url, speaker: speaker)
        }
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw Failure(errorDescription: "Язык \(Self.locale.identifier) не поддерживается расшифровкой")
        }
        let module = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                          reportingOptions: [], attributeOptions: [.audioTimeRange])
        return try await run(module, results: module.results.map { ($0.range.start.seconds, String($0.text.characters)) },
                             url: url, speaker: speaker)
    }

    @available(macOS 26.0, *)
    private static func run<Results: AsyncSequence & Sendable>(_ module: any SpeechModule, results: Results,
                                                               url: URL, speaker: String) async throws -> [TranscriptLine]
        where Results.Element == (Double, String) {
        // Языковая модель Apple скачивается один раз и дальше работает без сети.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        let file = try AVAudioFile(forReading: url)
        let collect = Task {
            var lines: [TranscriptLine] = []
            for try await (start, text) in results {
                lines.append(TranscriptLine(start: start, speaker: speaker, text: text))
            }
            return lines
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }
    #endif

    private static func recognize(_ url: URL, speaker: String) async throws -> [TranscriptLine] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure(errorDescription: "Нет разрешения на распознавание речи") }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            throw Failure(errorDescription: "Локальная расшифровка для этого языка недоступна")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                } else if let result, result.isFinal {
                    resumed = true
                    let lines = result.bestTranscription.segments.map {
                        TranscriptLine(start: $0.timestamp, speaker: speaker, text: $0.substring)
                    }
                    continuation.resume(returning: MeetingText.merge(lines))
                }
            }
        }
    }
}

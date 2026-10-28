@preconcurrency import AVFoundation
import Foundation
import MUCore

/// Файлы записи встречи: дорожки пишутся кусками, склеиваются при остановке и восстанавливаются после сбоя.
///
/// M4A читается только после закрытия файла, поэтому одна длинная дорожка при ⌘Q, падении или зависании пропала бы целиком.
/// Вместо этого каждые `MeetingChunking.seconds` секунд файл закрывается и начинается следующий: сбой стоит не больше одного куска.
package enum MeetingFiles {
    package static let systemTrack = "Собеседники"
    package static let micTrack = "Я"
    package static let markerName = "Идёт запись.json"

    /// «Имя», «Имя (2)», «Имя (3)»… — первое, которое не занято.
    package static func uniqueName(_ base: String, taken: (String) -> Bool) -> String {
        guard taken(base) else { return base }
        var index = 2
        while taken("\(base) (\(index))") { index += 1 }
        return "\(base) (\(index))"
    }

    /// Папка встречи, которой ещё нет: вторая запись в ту же минуту не должна затереть дорожки первой.
    package static func uniqueFolder(in root: URL, name: String, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let unique = uniqueName(name) { exists(root.appendingPathComponent($0, isDirectory: true)) }
        return root.appendingPathComponent(unique, isDirectory: true)
    }

    package static func partURL(folder: URL, track: String, index: Int) -> URL {
        folder.appendingPathComponent(String(format: "%@.part-%03d.m4a", track, index))
    }

    /// Номер куска из имени «Собеседники.part-003.m4a»; nil — это не кусок этой дорожки.
    package static func partIndex(of fileName: String, track: String) -> Int? {
        let prefix = "\(track).part-", suffix = ".m4a"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return nil }
        let number = fileName.dropFirst(prefix.count).dropLast(suffix.count)
        return number.isEmpty || !number.allSatisfy(\.isASCII) ? nil : Int(number)
    }

    /// Куски дорожки по порядку.
    package static func parts(in folder: URL, track: String) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name in partIndex(of: name, track: track).map { ($0, name) } }
            .sorted { $0.0 < $1.0 }
            .map { folder.appendingPathComponent($0.1) }
    }

    package static func nextPartIndex(in folder: URL, track: String) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return (names.compactMap { partIndex(of: $0, track: track) }.max() ?? 0) + 1
    }

    // MARK: Метка «запись идёт»

    /// Пока файла-метки нет, встреча закончена штатно; есть — запись оборвалась, и при запуске её восстановят.
    package static func writeMarker(in folder: URL, startedAt: Date, microphone: Bool) {
        let object: [String: Any] = ["startedAt": startedAt.timeIntervalSince1970, "microphone": microphone]
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: folder.appendingPathComponent(markerName), options: .atomic)
        }
    }

    package static func hasMarker(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(markerName).path)
    }

    package static func removeMarker(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(markerName))
    }

    /// Папки с незаконченной записью.
    package static func unfinished(in root: URL) -> [URL] {
        folders(in: root).filter { hasMarker(in: $0) }
    }

    package static func folders(in root: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        return folders.filter(\.hasDirectoryPath).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Метка «в очереди на расшифровку»

    package static let queueMarkerName = "В очереди.json"

    /// Задача очереди, пережившая перезапуск. `attempts` — сколько раз её начинали: если приложение падает
    /// на этой встрече, после второго раза она не запускается сама (только по кнопке) — без бесконечных повторов.
    package struct QueuedJob: Equatable {
        package let folder: URL
        package let reportOnly: Bool
        package let queuedAt: Date
        package let attempts: Int

        package static let maxAutoAttempts = 2
    }

    /// Встреча поставлена в очередь: метка лежит до конца обработки. Полная расшифровка важнее «только отчёта».
    package static func writeQueueMarker(in folder: URL, reportOnly: Bool, now: Date = Date()) {
        let previous = queueMarker(in: folder)
        let object: [String: Any] = [
            "reportOnly": reportOnly && (previous?.reportOnly ?? true),
            "queuedAt": (previous?.queuedAt ?? now).timeIntervalSince1970,
            "attempts": previous?.attempts ?? 0,
        ]
        writeQueueObject(object, in: folder)
    }

    /// Обработка встречи началась: ещё одна попытка.
    package static func noteQueueAttempt(in folder: URL) {
        guard let marker = queueMarker(in: folder) else { return }
        writeQueueObject(["reportOnly": marker.reportOnly, "queuedAt": marker.queuedAt.timeIntervalSince1970,
                          "attempts": marker.attempts + 1], in: folder)
    }

    package static func queueMarker(in folder: URL) -> QueuedJob? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(queueMarkerName)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return QueuedJob(folder: folder, reportOnly: object["reportOnly"] as? Bool ?? false,
                         queuedAt: Date(timeIntervalSince1970: object["queuedAt"] as? Double ?? 0),
                         attempts: object["attempts"] as? Int ?? 0)
    }

    package static func removeQueueMarker(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(queueMarkerName))
    }

    /// Встречи, которые стояли в очереди до выхода, — в прежнем порядке.
    package static func queued(in root: URL) -> [QueuedJob] {
        folders(in: root).compactMap { queueMarker(in: $0) }
            .sorted { ($0.queuedAt, $0.folder.lastPathComponent) < ($1.queuedAt, $1.folder.lastPathComponent) }
    }

    private static func writeQueueObject(_ object: [String: Any], in folder: URL) {
        guard FileManager.default.fileExists(atPath: folder.path),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        try? data.write(to: folder.appendingPathComponent(queueMarkerName), options: .atomic)
    }
}

/// Что делать при запуске с оборванными записями и встречами, оставшимися в очереди (MAJOR-1).
package enum MeetingRecovery {
    package struct Plan: Equatable {
        /// Снова в очередь сами: стояли в очереди до выхода.
        package var resume: [MeetingFiles.QueuedJob]
        /// Предложить кнопкой «Расшифровать»: восстановленные без расшифровки и те, на которых обработка уже дважды обрывалась.
        package var offer: [URL]
        /// Одно уведомление обо всём (nil — сообщать нечего).
        package var message: String?
    }

    package static func plan(restored: [URL], queued: [MeetingFiles.QueuedJob], hasTranscript: (URL) -> Bool) -> Plan {
        let resume = queued.filter { $0.attempts < MeetingFiles.QueuedJob.maxAutoAttempts }
        let stuck = queued.filter { $0.attempts >= MeetingFiles.QueuedJob.maxAutoAttempts }.map(\.folder)
        let queuedFolders = Set(queued.map { $0.folder.standardizedFileURL })
        let fresh = restored.filter { !queuedFolders.contains($0.standardizedFileURL) && !hasTranscript($0) }
        let offer = fresh + stuck
        var lines: [String] = []
        if restored.count == 1 {
            lines.append("Восстановлена оборванная запись встречи «\(restored[0].lastPathComponent)»")
        } else if restored.count > 1 {
            lines.append("Восстановлено оборванных записей встреч: \(restored.count)")
        }
        if !resume.isEmpty { lines.append("Продолжаю расшифровку встреч, ожидавших в очереди: \(resume.count)") }
        if !stuck.isEmpty { lines.append("Не расшифровались автоматически (обработка обрывалась): \(stuck.count)") }
        return Plan(resume: resume, offer: offer, message: lines.isEmpty ? nil : lines.joined(separator: ". "))
    }
}

/// Выравнивание дорожек одного писателя к концу записи (N1).
package enum MeetingAlignment {
    /// Сколько секунд тишины дописать дорожке, чтобы она сравнялась с самой длинной (меньше 50 мс — не нужно).
    package static func padding(written: Double, longest: Double) -> Double {
        let gap = longest - written
        return gap > 0.05 ? gap : 0
    }
}

package enum MeetingChunking {
    /// Длина куска: столько звука максимум пропадёт при сбое.
    package static let seconds: Double = 300

    package static func shouldRotate(frames: Int64, sampleRate: Double, seconds: Double = MeetingChunking.seconds) -> Bool {
        sampleRate > 0 && Double(frames) >= sampleRate * seconds
    }
}

package enum MeetingMerge {
    package struct Failure: LocalizedError { package let errorDescription: String? }

    /// Склеивает куски в один M4A (в том порядке, в котором даны). Нечитаемые куски (оборванный последний) пропускаются.
    /// Возвращает, сколько кусков вошло в результат. Один кусок просто переименовывается.
    @discardableResult
    package static func merge(parts: [URL], to target: URL) async throws -> Int {
        var readable: [(url: URL, asset: AVURLAsset, duration: CMTime)] = []
        for url in parts {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0.05,
                  let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { continue }
            readable.append((url, asset, duration))
        }
        guard !readable.isEmpty else { throw Failure(errorDescription: "В записи нет читаемого звука") }
        // Готовый файл заранее не удаляется: результат собирается рядом и встаёт на место одним переименованием.
        if readable.count == 1 {
            try install(readable[0].url, at: target)
            return 1
        }
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(target.deletingPathExtension().lastPathComponent + ".merging.m4a")
        try? FileManager.default.removeItem(at: temporary)
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure(errorDescription: "Не удалось собрать дорожку")
        }
        var cursor = CMTime.zero
        for part in readable {
            guard let track = try await part.asset.loadTracks(withMediaType: .audio).first else { continue }
            try compositionTrack.insertTimeRange(CMTimeRange(start: .zero, duration: part.duration), of: track, at: cursor)
            cursor = CMTimeAdd(cursor, part.duration)
        }
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetAppleM4A] {
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else { continue }
            do {
                if #available(macOS 15.0, *) {
                    try await export.export(to: temporary, as: .m4a)
                } else {
                    export.outputURL = temporary
                    export.outputFileType = .m4a
                    await export.export()
                    if let error = export.error { throw error }
                }
                guard await isReadable(temporary) else { throw Failure(errorDescription: "Склейка нечитаема") }
                try install(temporary, at: target)
                return readable.count
            } catch {
                // Убираем только свой временный файл: `target` (в том числе прежний) не трогаем.
                try? FileManager.default.removeItem(at: temporary)
            }
        }
        throw Failure(errorDescription: "Не удалось склеить куски записи")
    }

    /// Переносит `source` на место `target` одним переименованием (на том же томе — атомарно).
    private static func install(_ source: URL, at target: URL) throws {
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: target)
        }
    }

    /// В файле есть звуковая дорожка ненулевой длины.
    package static func isReadable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0.05,
              let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return false }
        return !tracks.isEmpty
    }

    /// Собирает дорожки встречи из кусков (после остановки или сбоя). Куски удаляются только после успешной склейки;
    /// метка «запись идёт» снимается, когда склеено всё. Возвращает названия дорожек, которые готовы.
    /// Одну папку склеивает только один вызов: повторный (восстановление, «Расшифровать», остановка) ждёт первого
    /// и получает его результат, а не начинает вторую склейку тех же кусков.
    @discardableResult
    package static func finalize(folder: URL) async -> [String] {
        await gate.run(folder.standardizedFileURL.path) { await finalizeNow(folder: folder) }
    }

    private static let gate = MergeGate()

    private static func finalizeNow(folder: URL) async -> [String] {
        var ready: [String] = []
        var failed = false
        for track in [MeetingFiles.systemTrack, MeetingFiles.micTrack] {
            let parts = MeetingFiles.parts(in: folder, track: track)
            let target = folder.appendingPathComponent("\(track).m4a")
            if parts.isEmpty {
                if FileManager.default.fileExists(atPath: target.path) { ready.append(track) }
                continue
            }
            do {
                try await merge(parts: parts, to: target)
                // Куски удаляются, только если готовый файл на месте и читается.
                guard await isReadable(target) else { throw Failure(errorDescription: "Склеенная дорожка нечитаема") }
                for part in parts { try? FileManager.default.removeItem(at: part) }
                ready.append(track)
            } catch {
                failed = true
                Log.audio.error("Встреча: склейка «\(track, privacy: .public)»: \(error.localizedDescription, privacy: .public)")
                // Звука нет вовсе (оборвалось в первые секунды): кусков не оставляем, иначе при каждом запуске всё повторится.
                if (error as? Failure)?.errorDescription == "В записи нет читаемого звука" {
                    for part in parts { try? FileManager.default.removeItem(at: part) }
                    failed = false
                }
            }
        }
        if !failed { MeetingFiles.removeMarker(in: folder) }
        return ready
    }
}

/// Последовательный исполнитель склеек: на одну папку — одна задача, остальные вызовы ждут её результата.
package actor MergeGate {
    private var running: [String: Task<[String], Never>] = [:]

    package func run(_ key: String, _ operation: @escaping @Sendable () async -> [String]) async -> [String] {
        if let task = running[key] { return await task.value }
        let task = Task { await operation() }
        running[key] = task
        let result = await task.value
        running[key] = nil
        return result
    }
}

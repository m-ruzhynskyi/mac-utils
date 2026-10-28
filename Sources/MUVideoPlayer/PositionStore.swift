import Foundation
import MUCore

/// Где остановились: `Application Support/Mac Utils/Player/positions.json`. Ключ — путь + размер + время изменения:
/// перезаписанный файл начинается сначала. Не запоминаем меньше 30 с и больше 95 % (досмотрели); старые записи
/// уходят первыми, всего — 500.
package final class PositionStore {
    package struct Entry: Codable, Equatable {
        package var key: String
        package var path: String
        package var position: Double
        package var duration: Double
        package var updated: Date
    }

    package static let limit = 500
    package static let minimumPosition: Double = 30
    package static let finishedFraction = 0.95

    @MainActor package static let shared = PositionStore(file: defaultFile)

    package static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Utils/Player/positions.json")
    }

    /// Новые — первыми.
    package private(set) var entries: [Entry] = []
    private let file: URL?
    private var loaded = false

    /// `file == nil` — только в памяти (тесты).
    package init(file: URL?) { self.file = file }

    // MARK: - Правила

    /// Стоит ли запоминать это место.
    package static func shouldRemember(position: Double, duration: Double) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        return position >= minimumPosition && position <= duration * finishedFraction
    }

    /// Досмотрели (больше 95 %) — для «просмотрено» в недавних.
    package static func isFinished(position: Double, duration: Double) -> Bool {
        duration > 0 && position > duration * finishedFraction
    }

    package static func key(path: String, size: Int64, modified: Date) -> String {
        "\(path)|\(size)|\(Int64((modified.timeIntervalSince1970 * 1000).rounded()))"
    }

    /// Ключ файла на диске; nil — файла нет (или это не файл).
    package static func key(for url: URL) -> String? {
        let standard = url.standardizedFileURL
        guard let values = try? standard.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return key(path: standard.path, size: Int64(size), modified: modified)
    }

    // MARK: - Чтение и запись

    /// Откуда продолжать; nil — сначала.
    package func resumePosition(for key: String) -> Double? {
        load()
        guard let entry = entries.first(where: { $0.key == key }),
              Self.shouldRemember(position: entry.position, duration: entry.duration) else { return nil }
        return entry.position
    }

    package func entry(forPath path: String) -> Entry? {
        load()
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return entries.first { $0.path == path }
    }

    /// Запомнить место. Меньше 30 с или досмотрели — прежняя запись убирается (в следующий раз — сначала).
    package func record(key: String, path: String, position: Double, duration: Double, now: Date = Date()) {
        load()
        let before = entries
        entries.removeAll { $0.key == key || $0.path == path }
        if Self.shouldRemember(position: position, duration: duration) {
            entries.insert(Entry(key: key, path: path, position: position, duration: duration, updated: now), at: 0)
            if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        }
        if entries != before { save() }
    }

    package func remove(path: String) {
        load()
        let count = entries.count
        entries.removeAll { $0.path == path }
        if entries.count != count { save() }
    }

    package func removeAll() {
        entries = []
        loaded = true
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = ((try? decoder.decode([Entry].self, from: data)) ?? []).sorted { $0.updated > $1.updated }
    }

    private func save() {
        guard let file else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

/// «Продолжить просмотр» в пустом окне: последние открытые файлы и какие из них досмотрены.
package enum PlayerRecent {
    package static let limit = 12

    package static var paths: [String] { UserDefaults.standard.stringArray(forKey: Pref.playerRecent) ?? [] }
    package static var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    package static var finished: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Pref.playerFinished) ?? []) }

    package static func add(_ url: URL, finished isFinished: Bool) {
        let path = url.standardizedFileURL.path
        var list = paths.filter { $0 != path }
        list.insert(path, at: 0)
        list = Array(list.prefix(limit))
        var done = finished.intersection(list)
        if isFinished { done.insert(path) } else { done.remove(path) }
        let defaults = UserDefaults.standard
        if defaults.stringArray(forKey: Pref.playerRecent) != list { defaults.set(list, forKey: Pref.playerRecent) }
        let sorted = done.sorted()
        if (defaults.stringArray(forKey: Pref.playerFinished) ?? []).sorted() != sorted { defaults.set(sorted, forKey: Pref.playerFinished) }
    }

    package static func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        UserDefaults.standard.set(paths.filter { $0 != path }, forKey: Pref.playerRecent)
    }

    package static func clear() {
        UserDefaults.standard.removeObject(forKey: Pref.playerRecent)
        UserDefaults.standard.removeObject(forKey: Pref.playerFinished)
    }
}

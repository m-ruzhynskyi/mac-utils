import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Журнал длинного снимка для разбора «плохо склеилось»: каждая съёмка — свой файл
/// `~/Library/Logs/MacUtils/scroll-<дата-время>.log`, хранятся последние 10. Только числа и имена режимов: размеры,
/// решение склейки по каждому кадру, события ввода — без пикселей, текста, названий окон и приложений.
///
/// Скрытая настройка `defaults write com.mruzhynskyi.macutils scrollDebugFrames -bool YES` ещё и сохраняет кадры
/// в `scroll-frames/<дата-время>/` (последние 3 съёмки) — только для локального разбора, по умолчанию выключена.
final class ScrollCaptureLog: @unchecked Sendable {
    static let framesKey = "scrollDebugFrames"
    static let keptLogs = 10
    static let keptFrameSessions = 3
    /// Предел строк в одном журнале: трекпад шлёт события ~100 раз в секунду, а съёмку могут забыть остановить.
    static let maxLines = 50_000

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MacUtils", isDirectory: true)
    }

    let url: URL
    /// Куда сохраняются кадры; nil — настройка выключена.
    let framesDirectory: URL?
    private let queue = DispatchQueue(label: "macutils.scroll-log", qos: .utility)
    private var handle: FileHandle?
    private var lines = 0

    /// nil — журнал не создать (нет доступа к папке): съёмка идёт и без него.
    init?(directory: URL = defaultDirectory, date: Date = Date(),
          saveFrames: Bool = UserDefaults.standard.bool(forKey: framesKey)) {
        let files = FileManager.default
        let stamp = Self.stamp(date)
        guard (try? files.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return nil }
        Self.prune(directory, keeping: Self.keptLogs - 1)
        var url = directory.appendingPathComponent("scroll-\(stamp).log")
        var suffix = 2
        while files.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("scroll-\(stamp)-\(suffix).log")
            suffix += 1
        }
        guard files.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.handle = handle
        if saveFrames {
            let root = directory.appendingPathComponent("scroll-frames", isDirectory: true)
            let frames = root.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
            if (try? files.createDirectory(at: frames, withIntermediateDirectories: true)) != nil {
                Self.pruneFrames(root, keeping: Self.keptFrameSessions, current: frames)
                framesDirectory = frames
            } else {
                framesDirectory = nil
            }
        } else {
            framesDirectory = nil
        }
    }

    deinit { try? handle?.close() }

    func write(_ line: String) {
        queue.async {
            guard let handle = self.handle else { return }
            self.lines += 1
            if self.lines > Self.maxLines {
                if self.lines == Self.maxLines + 1 { handle.write(Data("truncated\n".utf8)) }
                return
            }
            handle.write(Data((line + "\n").utf8))
        }
    }

    /// Кадр в PNG — только при включённой настройке; кодирование на очереди журнала, не на главном потоке.
    func saveFrame(_ image: CGImage, index: Int) {
        guard let framesDirectory else { return }
        let boxed = UncheckedSendable(image)
        queue.async {
            let url = framesDirectory.appendingPathComponent(String(format: "%04d.png", index))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, boxed.value, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    func close() {
        queue.async {
            try? self.handle?.close()
            self.handle = nil
        }
    }

    /// Дождаться записи всего отданного (тесты).
    func flush() { queue.sync {} }

    // MARK: - Строки журнала

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Ошибка — только домен и код: текст ошибки может содержать имена окон и приложений.
    static func code(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain)#\(error.code)"
    }

    static func number(_ value: Double, digits: Int = 1) -> String {
        String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// События кадра: `none` — сведений о вводе ещё не было (склейка по изображению), `0` — событий не было.
    static func describe(_ motion: Stitcher.Motion?) -> String {
        guard let motion else { return "none" }
        var parts: [String] = []
        if motion.pixels != 0 { parts.append("px=\(number(motion.pixels))") }
        if motion.lines != 0 { parts.append("lines=\(number(motion.lines, digits: 2))") }
        if motion.pages != 0 { parts.append("pages=\(number(motion.pages, digits: 0))") }
        if motion.unknown != 0 { parts.append("unknown=\(motion.unknown)") }
        return parts.isEmpty ? "0" : parts.joined(separator: ",")
    }

    static let frameColumns = "frame index t grab_ms add_ms result added height dir shift header footer source expected reason motion"

    static func frameLine(index: Int, time: Double, grabMs: Double, addMs: Double, result: Stitcher.Result, added: Int,
                          height: Int, trace: Stitcher.Trace, motion: Stitcher.Motion?) -> String {
        [
            "frame", "\(index)", number(time, digits: 3), number(grabMs), number(addMs), "\(result)", "+\(added)", "\(height)",
            trace.up ? "up" : "down", trace.shift.map { "\($0)" } ?? "-", "\(trace.header)", "\(trace.footer)", trace.source?.rawValue ?? "-",
            trace.expected.map { "\($0)" } ?? "-", trace.reason?.rawValue ?? "-", describe(motion),
        ].joined(separator: " ")
    }

    // MARK: - Хранение

    /// Оставить `count` самых новых журналов (имена с датой сортируются по времени).
    static func prune(_ directory: URL, keeping count: Int) {
        let files = FileManager.default
        let logs = ((try? files.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("scroll-") && $0.hasSuffix(".log") }
            .sorted()
        for name in logs.dropLast(max(0, count)) { try? files.removeItem(at: directory.appendingPathComponent(name)) }
    }

    /// Оставить кадры `count` последних съёмок, включая текущую.
    static func pruneFrames(_ root: URL, keeping count: Int, current: URL) {
        let files = FileManager.default
        let sessions = ((try? files.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("scroll-") && $0 != current.lastPathComponent }
            .sorted()
        for name in sessions.dropLast(max(0, count - 1)) { try? files.removeItem(at: root.appendingPathComponent(name)) }
    }
}

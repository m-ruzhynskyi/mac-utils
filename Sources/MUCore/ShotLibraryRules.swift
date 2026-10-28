import Foundation

/// Раскладка и поиск (без UI и диска — для тестов).
package enum ShotLibraryRules {
    /// «Мои снимки» включены в настройках.
    package static var libraryEnabled: Bool { UserDefaults.standard.bool(forKey: Pref.screenshotLibrary) }


    /// Папка снимка: «Снимки экрана/2026-10-07/Safari».
    package static func folder(root: URL, date: Date, app: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return root.appendingPathComponent("Снимки экрана", isDirectory: true)
            .appendingPathComponent(formatter.string(from: date), isDirectory: true)
            .appendingPathComponent(sanitized(app), isDirectory: true)
    }

    package static func sanitized(_ app: String) -> String {
        let cleaned = app.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Другое" : cleaned
    }

    /// Все слова запроса должны найтись в тексте, имени программы или дате.
    package static func matches(_ record: ShotRecord, query: String) -> Bool {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let haystack = (record.text + " " + record.app + " " + formatter.string(from: record.date)
                        + " " + record.url.lastPathComponent).lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Снимки и записи, которые можно забрать из корня папки: наши и системные.
    package static func isCapture(_ name: String) -> Bool {
        let lower = name.lowercased()
        let media = ["png", "jpg", "jpeg", "heic", "gif", "mp4", "mov"].contains((lower as NSString).pathExtension)
        let prefixes = ["screenshot", "снимок экрана", "знімок екрана", "recording", "screen recording",
                        "запись экрана", "длинный снимок", "qr "]
        return media && prefixes.contains { lower.hasPrefix($0) }
    }

    package static let smartFolderName = "Снимки экрана"

    /// Корень умной папки внутри папки снимков: «…/Снимки экрана».
    package static func smartRoot(in base: URL) -> URL {
        base.appendingPathComponent(smartFolderName, isDirectory: true)
    }

    /// Корень умной папки, в которой лежит снимок («Снимки экрана/дата/программа/файл»); nil — снимок не оттуда.
    package static func smartRoot(of record: ShotRecord) -> URL? {
        let root = record.url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.lastPathComponent == smartFolderName ? root : nil
    }

    /// Имя папки дня, как в `folder(root:date:app:)`.
    package static func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    package static func isDayName(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    package static func isExpired(_ record: ShotRecord, days: Int, now: Date = Date()) -> Bool {
        days > 0 && now.timeIntervalSince(record.date) > Double(days) * 86_400
    }

    package static func isVideo(_ url: URL) -> Bool {
        ["mp4", "mov", "m4v", "gif"].contains(url.pathExtension.lowercased())
    }

    /// Похоже на системный снимок (⌘⇧3/4): «Screenshot …» / «Снимок экрана …».
    package static func isSystemScreenshot(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".heic") else { return false }
        return lower.hasPrefix("screenshot") || lower.hasPrefix("снимок экрана") || lower.hasPrefix("знімок екрана")
    }
}

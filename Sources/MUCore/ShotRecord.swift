import Foundation

/// Запись в индексе: путь, день, программа и распознанный текст.
package struct ShotRecord: Codable, Hashable, Identifiable {
    package init(path: String, date: Date, app: String, text: String) { self.path = path; self.date = date; self.app = app; self.text = text }

    package var path: String
    package var date: Date
    package var app: String
    package var text: String

    package var id: String { path }
    package var url: URL { URL(fileURLWithPath: path) }
    /// Запись экрана (MP4 или GIF), а не снимок.
    package var isVideo: Bool { ShotLibraryRules.isVideo(url) }
}

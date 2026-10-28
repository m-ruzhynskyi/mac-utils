import Foundation

/// Недавние файлы редактора: 15 путей, последний — первым.
package enum EditorRecent {
    package static let limit = 15

    package static var paths: [String] { UserDefaults.standard.stringArray(forKey: Pref.editorRecent) ?? [] }

    package static var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    package static func add(_ url: URL) {
        var list = paths.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(limit)), forKey: Pref.editorRecent)
    }

    package static func remove(_ url: URL) {
        UserDefaults.standard.set(paths.filter { $0 != url.path }, forKey: Pref.editorRecent)
    }

    package static func clear() { UserDefaults.standard.removeObject(forKey: Pref.editorRecent) }

    /// «~/Documents/Формы» вместо полного пути (папка файла).
    package static func folderTitle(_ url: URL) -> String { folderTitle(ofFolder: url.deletingLastPathComponent()) }

    package static func folderTitle(ofFolder folder: URL) -> String {
        let path = folder.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

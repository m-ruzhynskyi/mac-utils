import Foundation
import MUCore

/// Настройки редактора поверх `UserDefaults` (ключи — в `Pref`).
enum EditorPrefs {
    private static var defaults: UserDefaults { .standard }

    static var newEncoding: TextEncoding {
        TextEncoding(rawValue: defaults.string(forKey: Pref.editorNewEncoding) ?? "") ?? .utf8
    }

    static var newLineEnding: LineEnding {
        LineEnding(rawValue: defaults.string(forKey: Pref.editorNewLineEnding) ?? "") ?? .lf
    }

    static var restoreSession: Bool { defaults.bool(forKey: Pref.editorRestoreSession) }
    static var autosaveDrafts: Bool { defaults.bool(forKey: Pref.editorAutosaveDrafts) }

    /// Ширина табуляции в пробелах (1…8, по умолчанию 4).
    static var tabWidth: Int {
        let value = defaults.integer(forKey: Pref.editorTabWidth)
        return value == 0 ? 4 : min(max(value, 1), 8)
    }

    static var zoom: CGFloat {
        get {
            let value = CGFloat(defaults.double(forKey: Pref.editorZoom))
            return value == 0 ? 1 : min(max(value, EditorStyle.zoomRange.lowerBound), EditorStyle.zoomRange.upperBound)
        }
        set { defaults.set(Double(newValue), forKey: Pref.editorZoom) }
    }
}

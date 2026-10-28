import os

/// Диагностика: `log stream --predicate 'subsystem == "com.mruzhynskyi.macutils"'`.
package enum Log {
    package static let scroll = Logger(subsystem: "com.mruzhynskyi.macutils", category: "scroll")
    package static let switcher = Logger(subsystem: "com.mruzhynskyi.macutils", category: "switcher")
    package static let capture = Logger(subsystem: "com.mruzhynskyi.macutils", category: "capture")
    package static let layout = Logger(subsystem: "com.mruzhynskyi.macutils", category: "layout")
    package static let window = Logger(subsystem: "com.mruzhynskyi.macutils", category: "window")
    package static let uninstall = Logger(subsystem: "com.mruzhynskyi.macutils", category: "uninstall")
    package static let ai = Logger(subsystem: "com.mruzhynskyi.macutils", category: "ai")
    package static let audio = Logger(subsystem: "com.mruzhynskyi.macutils", category: "audio")
    /// Видеоплеер: только коды и числа, без путей и имён файлов.
    package static let player = Logger(subsystem: "com.mruzhynskyi.macutils", category: "player")
}

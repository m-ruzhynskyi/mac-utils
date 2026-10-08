import os

/// Диагностика: `log stream --predicate 'subsystem == "com.mruzhynskyi.macutils"'`.
enum Log {
    static let scroll = Logger(subsystem: "com.mruzhynskyi.macutils", category: "scroll")
    static let switcher = Logger(subsystem: "com.mruzhynskyi.macutils", category: "switcher")
    static let capture = Logger(subsystem: "com.mruzhynskyi.macutils", category: "capture")
    static let layout = Logger(subsystem: "com.mruzhynskyi.macutils", category: "layout")
    static let window = Logger(subsystem: "com.mruzhynskyi.macutils", category: "window")
    static let uninstall = Logger(subsystem: "com.mruzhynskyi.macutils", category: "uninstall")
    static let ai = Logger(subsystem: "com.mruzhynskyi.macutils", category: "ai")
    static let audio = Logger(subsystem: "com.mruzhynskyi.macutils", category: "audio")
}

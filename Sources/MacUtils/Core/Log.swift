// SPDX-License-Identifier: GPL-3.0-or-later

import os

/// Диагностика: `log stream --predicate 'subsystem == "com.mruzhynskyi.macutils"'`.
enum Log {
    static let scroll = Logger(subsystem: "com.mruzhynskyi.macutils", category: "scroll")
    static let switcher = Logger(subsystem: "com.mruzhynskyi.macutils", category: "switcher")
    static let capture = Logger(subsystem: "com.mruzhynskyi.macutils", category: "capture")
    static let layout = Logger(subsystem: "com.mruzhynskyi.macutils", category: "layout")
    static let window = Logger(subsystem: "com.mruzhynskyi.macutils", category: "window")
}

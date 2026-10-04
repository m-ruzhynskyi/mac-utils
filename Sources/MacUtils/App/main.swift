// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}

import AppKit
import SwiftUI

/// Кнопки HUD должны нажиматься с первого клика: панель не активирует приложение.
/// Курсор над HUD — обычная стрелка, даже когда приложение неактивно.
package final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["cursor"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["cursor": true]))
    }

    package override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.arrow.set()
    }

    package override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        NSCursor.arrow.set()
    }
}

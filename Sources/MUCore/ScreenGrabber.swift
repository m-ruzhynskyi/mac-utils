import AppKit
import ScreenCaptureKit

@MainActor
package enum ScreenGrabber {
    /// `excluding` — номера своих окон, которых не должно быть в кадре (панель шагов, предпросмотр коллажа).
    package static func captureAllScreens(excluding hidden: [CGWindowID] = []) async throws -> [ScreenShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excluded = content.windows.filter { hidden.contains($0.windowID) }
        var shots: [ScreenShot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            shots.append(ScreenShot(screen: screen, image: image))
        }
        return shots
    }
}
package struct ScreenShot {
    package let screen: NSScreen
    package let image: CGImage
}

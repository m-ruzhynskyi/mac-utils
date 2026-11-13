import AppKit

/// Движок как управление для интерфейса (`HiddenScreenUI.controller = HiddenScreenEngine.shared`).
extension HiddenScreenEngine: HiddenScreenControlling {
    package var state: HiddenScreenState {
        HiddenScreenState(
            isEnabled: isEnabled,
            apps: statuses.map { HiddenScreenApp(bundleID: $0.bundleID, name: $0.app.name, windowCount: $0.hiddenWindows) },
            mirrorShown: mirrorShown, activeApp: mirroredBundleID, hidingVerified: hidingVerified)
    }

    package var mirrorHostWindow: NSWindow? { mirrorWindow }
}

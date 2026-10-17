import AppKit

/// Запоминает активное приложение перед тем, как Mac Utils забирает фокус,
/// и возвращает его потом. NSApp.hide не подходит: он прячет и плавающие панели.
@MainActor
enum FocusReturn {
    private static var previous: NSRunningApplication?

    static func remember() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previous = front
        }
    }

    /// Фокус остаётся у Mac Utils (открыто своё окно): прошлое приложение больше не возвращать.
    static func forget() {
        previous = nil
    }

    static func restore() {
        guard let app = previous, !app.isTerminated else { return }
        previous = nil
        app.activate(options: [])
    }
}

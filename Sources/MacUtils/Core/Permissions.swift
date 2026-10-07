import AppKit
import ApplicationServices

@MainActor
enum Permissions {
    /// «Универсальный доступ»: нужен для перехвата клавиш и прокрутки.
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// «Запись экрана»: нужна для снимков.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// «Полный доступ к диску»: пробуем прочитать защищённые TCC места.
    /// nil — проверить не на чем (ни одного такого пути нет).
    static var fullDiskAccess: Bool? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probes = [
            "\(home)/Library/Safari/CloudTabs.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "\(home)/Library/Containers/com.apple.stocks/Data",
            "\(home)/Library/Mail",
            "\(home)/Library/Safari",
        ]
        var sawProtected = false
        for path in probes {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if let dir = opendir(path) {
                    closedir(dir)
                    return true
                }
            } else {
                let fd = Darwin.open(path, O_RDONLY)
                if fd >= 0 {
                    close(fd)
                    return true
                }
            }
            if errno == EPERM || errno == EACCES { sawProtected = true }
        }
        return sawProtected ? false : nil
    }

    static func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Перезапуск: «Полный доступ к диску» вступает в силу только после него.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case automation = "Privacy_Automation"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}

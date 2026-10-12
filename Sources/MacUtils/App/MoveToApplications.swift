import AppKit

/// Если Mac Utils запущен не из «Программ» (из «Загрузок», с образа или из карантинной копии
/// AppTranslocation), предлагаем перенести его туда: иначе он не может обновляться сам.
@MainActor
enum MoveToApplications {
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Настоящий путь приложения, если macOS запустил его карантинную копию.
    private static func originalURL() -> URL {
        let current = Bundle.main.bundleURL
        guard isTranslocated,
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return current }
        typealias Function = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let function = unsafeBitCast(symbol, to: Function.self)
        return function(current as CFURL, nil)?.takeRetainedValue() as URL? ?? current
    }

    static func offerIfNeeded() {
        guard !isInApplications else { return }
        let alert = NSAlert()
        alert.messageText = "Перенести Mac Utils в «Программы»?"
        alert.informativeText = "Сейчас приложение запущено не из папки «Программы», поэтому не сможет само обновляться. Mac Utils перенесётся туда и перезапустится."
        alert.addButton(withTitle: "Перенести")
        alert.addButton(withTitle: "Не сейчас")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let source = originalURL()
        let target = URL(fileURLWithPath: "/Applications").appendingPathComponent(source.lastPathComponent)
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: target.path) {
                try manager.trashItem(at: target, resultingItemURL: nil)
            }
            // Из карантинной копии переносить нельзя — копируем оригинал.
            if isTranslocated || !manager.isDeletableFile(atPath: source.path) {
                try manager.copyItem(at: source, to: target)
            } else {
                try manager.moveItem(at: source, to: target)
            }
            removeQuarantine(target)
            relaunch(target)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Не удалось перенести"
            failure.informativeText = "Перетащите Mac Utils в «Программы» вручную в Finder и запустите оттуда.\n\n\(error.localizedDescription)"
            failure.runModal()
        }
    }

    private static func removeQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    private static func relaunch(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", url.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}

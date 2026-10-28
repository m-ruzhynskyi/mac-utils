import AppKit
import MUCore
import MUUpdate
import MUScreenshot

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

    static let suppressKey = "moveToApplicationsSuppressed"

    /// Спрашивать ли: не из «Программ», пользователь не отказался навсегда и это не сборка для разработки
    /// (её запускают из `build/`, вопрос при каждом запуске только мешает).
    static func shouldOffer(isInApplications: Bool, suppressed: Bool, isDevChannel: Bool) -> Bool {
        !isInApplications && !suppressed && !isDevChannel
    }

    /// Нужно ли сейчас задавать вопрос (без самого окна).
    static var wantsOffer: Bool {
        shouldOffer(isInApplications: isInApplications, suppressed: UserDefaults.standard.bool(forKey: suppressKey),
                    isDevChannel: Updater.shared.releaseChannel == .dev)
    }

    static func offerIfNeeded() {
        guard wantsOffer else { return }
        presentOffer()
    }

    /// Плашка в настройках: приложение не в «Программах» (и это не сборка для разработки). Показывается даже после
    /// «Больше не спрашивать»: отказ касается окна при запуске, а не возможности перенести позже.
    static var showsBanner: Bool {
        !isInApplications && Updater.shared.releaseChannel != .dev
    }

    /// Вопрос по кнопке (без проверки «не спрашивать»).
    static func presentOffer() {
        let alert = NSAlert()
        alert.messageText = "Перенести Mac Utils в «Программы»?"
        alert.informativeText = "Сейчас приложение запущено не из папки «Программы», поэтому не сможет само обновляться. Mac Utils перенесётся туда и перезапустится."
        alert.addButton(withTitle: "Перенести")
        alert.addButton(withTitle: "Не сейчас")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Больше не спрашивать"
        ScreenOutput.activateApp(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
            return
        }

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
            // Карантин снимаем только у копии с подписью того же издателя, что у запущенного приложения; не прошла — оставляем карантин
            // (macOS сам спросит при запуске).
            if verifiedCopy(target) { removeQuarantine(target) }
            relaunch(target)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Не удалось перенести"
            failure.informativeText = "Перетащите Mac Utils в «Программы» вручную в Finder и запустите оттуда.\n\n\(error.localizedDescription)"
            failure.runModal()
        }
    }

    /// Копия в «Программах» подписана тем же издателем, что запущенное приложение. Ad-hoc сборка (требование `cdhash`) не проверяется.
    private static func verifiedCopy(_ target: URL) -> Bool {
        guard let requirement = try? Updater.currentRequirement() else { return false }
        return (try? Updater.verifySignature(of: target, requirement: requirement)) != nil
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

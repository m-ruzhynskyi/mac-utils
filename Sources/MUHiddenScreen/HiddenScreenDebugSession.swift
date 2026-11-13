import AppKit
import MUCore

/// Отладочный запуск движка без интерфейса — для проверки на Mac пользователя:
/// `open -a "Mac Utils" --args --hidden-screen-debug` (ключи — `HiddenScreenOptions.debug`).
/// Включает скрытый экран, открывает окно-зеркало с переключателем программ в заголовке и пишет журнал
/// (`log stream --predicate 'subsystem == "com.mruzhynskyi.macutils" && category == "hidden-screen"'`).
/// Выход Mac Utils, ⌃C или `kill` (SIGTERM) — программы прячутся, дисплей снимается.
@MainActor
public final class HiddenScreenDebugSession {
    public let engine: HiddenScreenEngine
    private let picker = NSSegmentedControl()
    private var signalSources: [DispatchSourceSignal] = []

    public static func startIfRequested(arguments: [String] = CommandLine.arguments,
                                        defaults: UserDefaults = .standard) -> HiddenScreenDebugSession? {
        guard !AppEnvironment.isRunningTests,
              let options = HiddenScreenOptions.debug(arguments: arguments,
                                                      storedBundleIDs: defaults.stringArray(forKey: Pref.hiddenScreenApps)) else { return nil }
        let session = HiddenScreenDebugSession(engine: .shared, options: options)
        session.start()
        return session
    }

    init(engine: HiddenScreenEngine, options: HiddenScreenOptions) {
        self.engine = engine
        engine.options = options
        engine.useHelper = options.useHelper
        engine.mirrorHasTitleBar = true
    }

    private func start() {
        Log.hiddenScreen.info("отладка: программы \(self.engine.options.apps.map(\.name).joined(separator: ", "), privacy: .public), щелчок \(self.engine.options.clickMode.rawValue, privacy: .public), нажатие \(self.engine.options.pressMode.rawValue, privacy: .public), прокрутка \(self.engine.options.scrollMode.rawValue, privacy: .public), ⌘-сочетания \(self.engine.options.keyMode.rawValue, privacy: .public), помощник \(self.engine.options.useHelper ? "да" : "нет", privacy: .public)")
        engine.onLeak = { leak in Log.hiddenScreen.error("отладка: утечка \(String(describing: leak), privacy: .public)") }
        let previous = engine.onChange
        engine.onChange = { [weak self] in
            previous?()
            self?.changed()
        }
        installSignalHandlers()
        // Дисплей создаёт помощник — зеркало появится, когда он ответит (`changed` добавит переключатель).
        engine.setMirrorShown(true)
        changed()
    }

    private var accessoryAdded = false

    private func addPicker(to window: NSWindow) {
        guard !accessoryAdded else { return }
        accessoryAdded = true
        picker.segmentStyle = .texturedRounded
        picker.trackingMode = .selectOne
        picker.target = self
        picker.action = #selector(pick)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = picker
        accessory.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(accessory)
        window.title = "Скрытый экран — отладка"
    }

    public func stop() {
        engine.shutdown()
    }

    private var lastSummary = ""

    private func changed() {
        if let window = engine.mirrorWindow { addPicker(to: window) }
        let apps = engine.statuses
        picker.segmentCount = apps.count
        for (index, status) in apps.enumerated() {
            picker.setLabel("\(status.app.name) · \(status.hiddenWindows)", forSegment: index)
            picker.setEnabled(status.isRunning || NSWorkspace.shared.urlForApplication(withBundleIdentifier: status.bundleID) != nil,
                              forSegment: index)
            if status.app == engine.mirroredApp { picker.selectedSegment = index }
        }
        picker.sizeToFit()
        let summary = apps.map { "\($0.app.name) [\($0.bundleID)]: \($0.isRunning ? "\($0.hiddenWindows) окон" : "не запущена")" }.joined(separator: "; ")
            + "; зеркало \(engine.mirroredApp?.name ?? "—"); скрытие \(engine.hidingVerified.map { $0 ? "проверено" : "ВИДНО" } ?? "не проверено")"
        guard summary != lastSummary else { return }
        lastSummary = summary
        Log.hiddenScreen.info("отладка: \(String(describing: self.engine.phase), privacy: .public); \(summary, privacy: .public)")
    }

    @objc private func pick() {
        let index = picker.selectedSegment
        guard engine.statuses.indices.contains(index) else { return }
        engine.selectApp(engine.statuses[index].bundleID)
    }

    /// ⌃C в Терминале и `kill`: сначала спрятать программы и снять дисплей, потом выйти.
    private func installSignalHandlers() {
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    Log.hiddenScreen.info("отладка: сигнал \(signalNumber) — выход")
                    self?.stop()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

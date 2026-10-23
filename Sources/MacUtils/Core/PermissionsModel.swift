import ServiceManagement
import AppKit
import SwiftUI

@MainActor
final class PermissionsModel: NSObject, ObservableObject {
    static let shared = PermissionsModel()

    @Published private(set) var accessibility = Permissions.accessibility
    @Published private(set) var screenRecording = Permissions.screenRecording
    @Published private(set) var microphone = Permissions.microphone
    @Published private(set) var fullDiskAccess = Permissions.fullDiskAccess
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Опрос раз в 1,5 с — только пока экран с разрешениями виден и чего-то не хватает, или пока ждём выдачи после
    /// «Открыть настройки». В остальное время — при возврате в приложение и при открытии настроек (опрос держал ~4 % ядра).
    private var timer: Timer?
    private(set) var viewers = ViewerCount()
    /// До какого момента ждём выдачи разрешения после «Открыть настройки» (Системные настройки закрывают наше окно).
    private var waitingUntil: Date?
    static let pollInterval: TimeInterval = 1.5
    nonisolated static let waitForGrant: TimeInterval = 180

    var isPolling: Bool { timer != nil }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PermissionsModel.shared.refresh() }
        }
    }

    /// Вид с разрешениями появился на экране или ушёл с него (`onScreen`).
    func viewerChanged(_ shown: Bool) {
        viewers.update(shown)
        if shown { refresh() } else { updatePolling() }
    }

    /// Пользователь ушёл выдавать разрешение в Системные настройки: опрашиваем, пока оно не появится (не дольше 3 минут).
    func awaitGrant(for seconds: TimeInterval = waitForGrant) {
        waitingUntil = Date().addingTimeInterval(seconds)
        updatePolling()
    }

    /// Нужен ли опрос: что-то не выдано и его ждут на экране или после «Открыть настройки».
    static func pollNeeded(missing: Bool, onScreen: Bool, waiting: Bool) -> Bool {
        missing && (onScreen || waiting)
    }

    /// Не выдано то, что ловим опросом. Микрофон — по ответу на запрос и при возврате в приложение (проверка ~8 мс).
    var missing: Bool {
        !accessibility || !screenRecording || fullDiskAccess == false
    }

    private func updatePolling() {
        if let waitingUntil, waitingUntil < Date() { self.waitingUntil = nil }
        let needed = Self.pollNeeded(missing: missing, onScreen: viewers.any, waiting: waitingUntil != nil)
        if needed, timer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// Опрос — только того, чего не хватает: выданное перепроверяется при возврате в приложение и показе настроек.
    @objc private func tick() {
        if !accessibility, Permissions.accessibility { accessibility = true }
        if !screenRecording, Permissions.screenRecording { screenRecording = true }
        if fullDiskAccess == false, Permissions.fullDiskAccess == true { fullDiskAccess = true }
        if !missing { waitingUntil = nil }
        updatePolling()
    }

    /// `includingLogin` — ещё и «Открывать при входе» (запрос к службе входа дорогой; меняется из наших настроек или
    /// Системных, после чего мы снова становимся активными).
    func refresh(includingLogin: Bool = true) {
        let ax = Permissions.accessibility
        let screen = Permissions.screenRecording
        if ax != accessibility { accessibility = ax }
        if screen != screenRecording { screenRecording = screen }
        let mic = Permissions.microphone
        if mic != microphone { microphone = mic }
        let disk = Permissions.fullDiskAccess
        if disk != fullDiskAccess { fullDiskAccess = disk }
        if includingLogin {
            let login = SMAppService.mainApp.status == .enabled
            if login != launchAtLogin { launchAtLogin = login }
        }
        // Всё выдано — ждать больше нечего.
        if !missing { waitingUntil = nil }
        updatePolling()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Feedback.beep()
        }
        refresh()
    }
}

import AppKit
import CoreGraphics

/// Сила «тёплого» экрана по времени (без UI — для тестов).
enum WarmSchedule {
    /// Плавный вход и выход, в часах.
    static let ramp = 1.0

    /// 0…1: насколько сейчас включено (с плавным переходом у начала и конца).
    /// from/to — часы (from > to — через полночь, например 21 → 7).
    static func level(hour: Double, from: Double, to: Double) -> Double {
        guard from != to else { return 1 }
        let length = (to - from + 24).truncatingRemainder(dividingBy: 24)
        let sinceStart = (hour - from + 24).truncatingRemainder(dividingBy: 24)
        guard sinceStart < length else { return 0 }
        let untilEnd = length - sinceStart
        return min(1, sinceStart / ramp, untilEnd / ramp)
    }

    /// Множители каналов для силы 0…1: красный не трогаем, синий гасим сильнее зелёного.
    static func gains(strength: Double) -> (red: Double, green: Double, blue: Double) {
        let s = min(max(strength, 0), 1)
        return (1, 1 - 0.28 * s, 1 - 0.68 * s)
    }
}

/// Свой Night Shift: тёплый экран вечером, отдельная сила для внешних мониторов.
@MainActor
final class WarmScreen: ObservableObject {
    static let shared = WarmScreen()

    @Published private(set) var currentLevel: Double = 0
    /// Показать на 4 секунды, как будет выглядеть (из настроек).
    private var previewUntil: Date?
    private var timer: Timer?
    private var applied = false

    func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.warmScreen)
        if enabled {
            if timer == nil {
                let timer = Timer(timeInterval: 30, repeats: true) { _ in
                    MainActor.assumeIsolated { WarmScreen.shared.apply() }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
                NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                       object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { WarmScreen.shared.apply() }
                }
                NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                  object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { WarmScreen.shared.apply() }
                }
            }
            apply()
        } else {
            timer?.invalidate()
            timer = nil
            restore()
        }
    }

    func preview() {
        previewUntil = Date().addingTimeInterval(4)
        apply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) {
            MainActor.assumeIsolated { WarmScreen.shared.apply() }
        }
    }

    private func level(now: Date = Date()) -> Double {
        if let previewUntil, previewUntil > now { return 1 }
        let defaults = UserDefaults.standard
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        let hour = Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        return WarmSchedule.level(hour: hour, from: defaults.double(forKey: Pref.warmFrom),
                                  to: defaults.double(forKey: Pref.warmTo))
    }

    func apply() {
        guard UserDefaults.standard.bool(forKey: Pref.warmScreen) || previewUntil.map({ $0 > Date() }) == true else {
            restore()
            return
        }
        let level = level()
        currentLevel = level
        guard level > 0 else {
            restore()
            return
        }
        let defaults = UserDefaults.standard
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let strength = (CGDisplayIsBuiltin(id) != 0 ? defaults.double(forKey: Pref.warmStrength)
                            : defaults.double(forKey: Pref.warmExternalStrength)) * level
            let gains = WarmSchedule.gains(strength: strength)
            CGSetDisplayTransferByFormula(id, 0, CGGammaValue(gains.red), 1,
                                          0, CGGammaValue(gains.green), 1,
                                          0, CGGammaValue(gains.blue), 1)
        }
        applied = true
    }

    private func restore() {
        currentLevel = 0
        guard applied else { return }
        CGDisplayRestoreColorSyncSettings()
        applied = false
    }

    /// При выходе из программы возвращаем цвета.
    func shutdown() {
        restore()
    }
}

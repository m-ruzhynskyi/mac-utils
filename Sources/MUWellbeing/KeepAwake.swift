import AppKit
import IOKit.pwr_mgt
import MUCore

/// Запрет сна системы (подменяется в тестах).
package protocol SleepAssertionProviding {
    /// Идентификатор assertion или nil, если система отказала.
    func create(reason: String) -> UInt32?
    func release(_ id: UInt32)
}

/// Настоящий assertion: сон системы запрещён, сон дисплея — нет (как `caffeinate -i`).
package struct IOKitSleepAssertion: SleepAssertionProviding {
    package func create(reason: String) -> UInt32? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    package func release(_ id: UInt32) { IOPMAssertionRelease(id) }
}

extension Notification.Name {
    /// «Не засыпать» включили, выключили или сменили срок (значок в строке меню обновляет вид).
    package static let keepAwakeChanged = Notification.Name("MacUtils.keepAwakeChanged")
}

/// «Не засыпать»: Mac не уходит в сон, экран может гаснуть. Состояние не сохраняется — после запуска выключено.
@MainActor
package final class KeepAwake: ObservableObject {
    package static let shared = KeepAwake()
    package static let reason = "Mac Utils: не засыпать"

    /// nil — выключено; `.distantFuture` — без срока.
    @Published package private(set) var endsAt: Date?
    @Published package private(set) var failed = false
    /// Выбранный срок, пока включено.
    package private(set) var currentDuration: KeepAwakeDuration?

    private let provider: SleepAssertionProviding
    private let now: () -> Date
    private var assertion: UInt32?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    package init(provider: SleepAssertionProviding = IOKitSleepAssertion(), now: @escaping () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    package var isActive: Bool { assertion != nil }
    package var isIndefinite: Bool { endsAt == .distantFuture }

    /// Включить (или сменить срок, если уже включено).
    package func start(_ duration: KeepAwakeDuration) {
        if assertion == nil {
            guard let id = provider.create(reason: Self.reason) else {
                failed = true
                return
            }
            assertion = id
        }
        failed = false
        currentDuration = duration
        endsAt = duration.seconds.map { now().addingTimeInterval($0) } ?? .distantFuture
        scheduleTimer()
        changed()
    }

    /// Включить с последним выбранным сроком или выключить (macutils://keep-awake, пункт меню значка).
    package func toggle() {
        if isActive { stop(); return }
        let saved = UserDefaults.standard.string(forKey: Pref.keepAwakeDuration)
        start(saved.flatMap(KeepAwakeDuration.init(rawValue:)) ?? .indefinite)
    }

    package func stop() {
        timer?.invalidate()
        timer = nil
        if let assertion { provider.release(assertion) }
        assertion = nil
        endsAt = nil
        currentDuration = nil
        changed()
    }

    /// Выключить, если срок вышел (по таймеру и после пробуждения: таймер мог опоздать).
    package func expireIfNeeded() {
        guard let endsAt, endsAt != .distantFuture, endsAt <= now() else { return }
        stop()
    }

    /// Сколько осталось; nil — выключено или без срока.
    package func remaining() -> TimeInterval? {
        guard let endsAt, endsAt != .distantFuture else { return nil }
        return max(0, endsAt.timeIntervalSince(now()))
    }

    /// «Осталось 2 ч 15 мин», «Осталось 12 мин», «Осталось меньше минуты».
    package static func remainingText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if seconds <= 0 || minutes < 1 { return "Осталось меньше минуты" }
        if minutes < 60 { return "Осталось \(minutes) мин" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "Осталось \(hours) ч" : "Осталось \(hours) ч \(rest) мин"
    }

    /// Строка состояния для панели и подсказки значка.
    package func statusText() -> String {
        if let remaining = remaining() { return Self.remainingText(remaining) }
        return isActive ? "Mac не уснёт, пока вы не выключите" : "Выключено"
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard let endsAt, endsAt != .distantFuture else { return }
        let timer = Timer(fire: endsAt, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func changed() {
        NotificationCenter.default.post(name: .keepAwakeChanged, object: nil)
    }

    /// Один раз при запуске: срок проверяется и после сна. Повторный вызов ничего не делает.
    package func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
    }

    /// После сна: просроченное выключаем, иначе таймер ставим заново на `endsAt` (таймеры run loop время сна не считают
    /// и сработали бы позже срока).
    package func handleWake() {
        expireIfNeeded()
        if isActive { scheduleTimer() }
    }

    /// Когда сработает таймер окончания (nil — таймера нет: выключено или без срока).
    package var timerFireDate: Date? { timer?.isValid == true ? timer?.fireDate : nil }

    /// Только для тестов: таймер потерян (как после сна).
    package func simulateLostTimerForTests() { timer?.invalidate(); timer = nil }

    package func shutdown() {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        stop()
    }
}

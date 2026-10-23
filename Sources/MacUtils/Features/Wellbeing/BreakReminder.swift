import AppKit
import CoreAudio
import SwiftUI
import MUCore

/// Сколько уже работаем без перерыва (без UI — для тестов).
struct BreakSchedule {
    /// Отошёл от компьютера на столько — перерыв засчитан, счёт заново.
    var restAfter: TimeInterval = 5 * 60
    private(set) var worked: TimeInterval = 0

    /// Прошло dt секунд; idle — сколько секунд нет ввода. true — пора на перерыв.
    mutating func tick(dt: TimeInterval, idle: TimeInterval, interval: TimeInterval) -> Bool {
        if idle >= restAfter {
            worked = 0
            return false
        }
        if idle < 60 { worked += dt }
        return worked >= interval
    }

    mutating func reset(postpone: TimeInterval = 0) {
        worked = -postpone
    }
}

/// Когда экран перерыва показывать нельзя (без системных вызовов — для тестов).
/// Полноэкранный оверлей перекрыл бы запись, трансляцию или звонок: перерыв откладывается до их конца.
enum BreakGuard {
    /// Занятости Mac Utils, во время которых экран перерыва мешает (идёт запись или показ экрана).
    static let blockingReasons: [BusyRegistry.Reason] = [.screenRecording, .meetingRecording, .broadcast, .viewing, .scrollCapture]

    /// Почему перерыв откладывается (nil — можно показывать).
    static func deferReason(busy: [BusyRegistry.Reason], microphoneInUse: Bool) -> String? {
        if let reason = busy.first(where: blockingReasons.contains) { return "идёт \(reason.title)" }
        if microphoneInUse { return "микрофон занят (звонок)" }
        return nil
    }

    /// Что сделать, когда перерыв уже пора показать.
    enum Action: Equatable {
        case show
        case postpone(String)
        /// Микрофон занят дольше `microphoneLimit`: экран не показываем (возможно, идёт долгий звонок), но напоминаем.
        case remind
    }

    /// Отсрочка из-за микрофона не бесконечна: его могут постоянно держать фоновые программы (Krisp, шумоподавление,
    /// голосовые помощники), и тогда перерыв не появился бы никогда.
    static let microphoneLimit: TimeInterval = 30 * 60

    /// `microphoneSince` — с какого момента перерыв подряд откладывается из-за микрофона (хранит вызывающий).
    /// Запись и показ экрана Mac Utils откладывают без предела: они видны и заканчиваются.
    static func action(busy: [BusyRegistry.Reason], microphoneInUse: Bool, microphoneSince: inout Date?, now: Date) -> Action {
        if let reason = busy.first(where: blockingReasons.contains) { return .postpone("идёт \(reason.title)") }
        guard microphoneInUse else {
            microphoneSince = nil
            return .show
        }
        let since = microphoneSince ?? now
        microphoneSince = since
        guard now.timeIntervalSince(since) >= microphoneLimit else { return .postpone("микрофон занят (звонок)") }
        microphoneSince = nil
        return .remind
    }
}

/// Мягкое напоминание: каждые N минут работы — экран «встаньте, посмотрите вдаль».
@MainActor
final class BreakReminder: ObservableObject {
    static let shared = BreakReminder()

    @Published private(set) var remaining = 0
    @Published private(set) var workedMinutes = 0

    private var schedule = BreakSchedule()
    private var timer: Timer?
    private var countdown: Timer?
    private var panels: [NSPanel] = []
    /// Программа, которая была впереди до перерыва: панель забирает клавиатуру (для Esc), потом фокус возвращается.
    private var previousApp: NSRunningApplication?
    private var lastDeferReason: String?
    /// С какого момента перерыв подряд откладывается из-за занятого микрофона.
    private var microphoneSince: Date?
    private static let step: TimeInterval = 15

    func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.breakReminder)
        if enabled, timer == nil {
            schedule.reset()
            let timer = Timer(timeInterval: Self.step, repeats: true) { _ in
                MainActor.assumeIsolated { BreakReminder.shared.tick() }
            }
            timer.tolerance = 3
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !enabled {
            timer?.invalidate()
            timer = nil
            close()
        }
    }

    private func tick() {
        guard panels.isEmpty else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let minutes = max(5, UserDefaults.standard.integer(forKey: Pref.breakInterval))
        let due = schedule.tick(dt: Self.step, idle: idle, interval: TimeInterval(minutes * 60))
        workedMinutes = Int(schedule.worked / 60)
        guard due else { return }
        // Во время записи, показа экрана и звонка не мешаем: счёт не сбрасывается, перерыв покажем, когда они закончатся.
        // Занятый микрофон откладывает не дольше 30 минут подряд, потом — напоминание без экрана перерыва.
        switch BreakGuard.action(busy: BusyRegistry.shared.active, microphoneInUse: Self.microphoneInUse(),
                                 microphoneSince: &microphoneSince, now: Date()) {
        case .postpone(let reason):
            if reason != lastDeferReason { Log.window.info("Перерыв отложен: \(reason, privacy: .public)") }
            lastDeferReason = reason
        case .remind:
            lastDeferReason = nil
            schedule.reset()
            workedMinutes = 0
            Log.window.info("Перерыв: микрофон занят 30 минут подряд, вместо экрана — напоминание")
            Toast.show("Пора сделать перерыв. Микрофон занят, поэтому экран перерыва не показываю",
                       symbol: "figure.walk", tint: .orange,
                       action: Toast.Action(title: "Перерыв") { BreakReminder.shared.show() })
        case .show:
            lastDeferReason = nil
            show()
        }
    }

    /// Микрофон по умолчанию сейчас кем-то используется (звонок в Zoom, Meet, Telegram…).
    static func microphoneInUse() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// Показать перерыв сейчас (и из настроек — «Попробовать»).
    func show() {
        close()
        remaining = max(5, UserDefaults.standard.integer(forKey: Pref.breakDuration))
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            let panel = HUDPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = FirstMouseHostingView(rootView: BreakView(reminder: self))
            panel.setFrame(screen.frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardlessOnScreen()
            // Клавиатура — панели на экране с курсором: Esc закрывает перерыв, VoiceOver попадает в оверлей.
            if NSMouseInRect(mouse, screen.frame, false) { panel.makeKey() }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.6; panel.animator().alphaValue = 1 }
            panels.append(panel)
        }
        if !panels.contains(where: \.isKeyWindow) { panels.first?.makeKey() }
        let countdown = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let reminder = BreakReminder.shared
                reminder.remaining -= 1
                if reminder.remaining <= 0 { reminder.finish() }
            }
        }
        RunLoop.main.add(countdown, forMode: .common)
        self.countdown = countdown
    }

    func finish() {
        schedule.reset()
        close()
    }

    func postpone() {
        schedule.reset(postpone: 5 * 60 - TimeInterval(max(5, UserDefaults.standard.integer(forKey: Pref.breakInterval)) * 60))
        close()
    }

    private func close() {
        countdown?.invalidate()
        countdown = nil
        let closing = panels
        panels = []
        // Панель забирала клавиатуру: возвращаем её программе, в которой работали до перерыва.
        if !closing.isEmpty, let previousApp, !previousApp.isTerminated { previousApp.activate() }
        previousApp = nil
        for panel in closing {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
            }
        }
    }
}

private struct BreakView: View {
    @ObservedObject var reminder: BreakReminder

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.25)
            VStack(spacing: 16) {
                Image(systemName: "figure.walk").font(.system(size: 54, weight: .light))
                Text("Пора сделать перерыв").font(.system(size: 30, weight: .semibold))
                Text("Встаньте, разомнитесь и посмотрите вдаль — на что-нибудь в 6 метрах.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("\(reminder.remaining)").font(.system(size: 44, weight: .light).monospacedDigit())
                HStack(spacing: 12) {
                    Button("Через 5 минут") { reminder.postpone() }
                    Button("Пропустить") { reminder.finish() }
                        .keyboardShortcut(.cancelAction)
                        .help("Esc")
                }
                .controlSize(.large)
                Text("Esc — пропустить").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
            .padding(40)
        }
        .ignoresSafeArea()
    }
}

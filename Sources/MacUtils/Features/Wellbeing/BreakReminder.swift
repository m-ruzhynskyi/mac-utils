import AppKit
import SwiftUI

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
    private static let step: TimeInterval = 15

    func sync() {
        let enabled = UserDefaults.standard.bool(forKey: Pref.breakReminder)
        if enabled, timer == nil {
            schedule.reset()
            let timer = Timer(timeInterval: Self.step, repeats: true) { _ in
                MainActor.assumeIsolated { BreakReminder.shared.tick() }
            }
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
        // Во время записи экрана не мешаем — напомним чуть позже.
        if due, ScreenRecorder.current == nil { show() }
    }

    /// Показать перерыв сейчас (и из настроек — «Попробовать»).
    func show() {
        close()
        remaining = max(5, UserDefaults.standard.integer(forKey: Pref.breakDuration))
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
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.6; panel.animator().alphaValue = 1 }
            panels.append(panel)
        }
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
                }
                .controlSize(.large)
            }
            .foregroundStyle(.white)
            .padding(40)
        }
        .ignoresSafeArea()
    }
}

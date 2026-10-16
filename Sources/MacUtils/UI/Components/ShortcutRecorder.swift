import AppKit
import SwiftUI

/// Запись сочетания: нажмите кнопку, затем нужные клавиши (нужен ⌘, ⌥ или ⌃). Esc — отмена.
struct ShortcutRecorder: View {
    let hotKey: LayoutHotKey
    /// Пока идёт запись, старое сочетание нужно отключить, чтобы оно не сработало.
    var suspend: (Bool) -> Void = { LayoutFix.shared.suspendHotKey($0) }
    /// Почему сочетание нельзя сохранить (например, оно уже занято другой функцией Mac Utils); nil — можно.
    var validate: (LayoutHotKey) -> String? = { _ in nil }
    let onChange: (LayoutHotKey) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
            Button(recording ? "Нажмите сочетание…" : hotKey.title) {
                recording ? stop() : start()
            }
            .frame(minWidth: 140)
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        hint = nil
        suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            guard let key = LayoutHotKey(event: event) else {
                hint = "Нужен ⌘, ⌥ или ⌃"
                return nil
            }
            if let problem = validate(key) {
                hint = problem
                return nil
            }
            onChange(key)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            suspend(false)
        }
    }
}

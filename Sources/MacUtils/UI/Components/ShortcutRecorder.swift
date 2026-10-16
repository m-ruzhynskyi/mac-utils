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

    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if let hint {
                Text(hint).font(DS.Font.rowSub).foregroundStyle(DS.Tone.warning.text)
            }
            Button {
                recording ? stop() : start()
            } label: {
                // Как кейкап: запись — рамка `accLine` и подсказка вместо сочетания.
                Group {
                    if recording {
                        Text("Нажмите сочетание…").font(DS.Font.caption).foregroundStyle(.dsAccText)
                    } else {
                        Keycap.label(hotKey.title, compact: false).foregroundStyle(.dsText)
                    }
                }
                .padding(.vertical, 5)
                .padding(.horizontal, DS.Space.m)
                .frame(minWidth: 120)
                .background(hovered && enabled ? Color.dsField.opacity(0.7) : Color.dsField,
                            in: RoundedRectangle(cornerRadius: DS.Radius.keycap - 1, style: .continuous))
                .padding(EdgeInsets(top: 1, leading: 1, bottom: 3, trailing: 1))
                .background(recording ? Color.dsAccLine : Color.dsLine,
                            in: RoundedRectangle(cornerRadius: DS.Radius.keycap, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.keycap, style: .continuous))
            }
            .buttonStyle(PressScaleStyle())
            .onHover { hovered = $0 }
            .opacity(enabled ? 1 : DS.State.disabledOpacity)
            .help(recording ? "Esc — отмена" : "Нажмите и введите новое сочетание")
            .accessibilityLabel(recording ? "Нажмите сочетание" : Keycap.spoken(hotKey.keys))
            .accessibilityHint("Нажмите и введите новое сочетание")
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

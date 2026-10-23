import AppKit
import SwiftUI
import MUCore

// MARK: - Плавная прокрутка

struct SmoothScrollPage: View {
    @AppStorage(Pref.smoothScroll) private var enabled = true
    @AppStorage(Pref.smoothSpeed) private var speed = 1.0
    @AppStorage(Pref.smoothDuration) private var duration = 0.35
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = SmoothScroll.shared

    var body: some View {
        SettingsPage(.smoothScroll,
                     subtitle: "Колесо обычной мыши прокручивает плавно, как трекпад. Трекпад и Magic Mouse не затрагиваются.",
                     isOn: $enabled, toggleLabel: "Плавная прокрутка") {
            if enabled {
                ListCard { AccessibilityStatusRow(running: service.isRunning, readyText: "Плавная прокрутка работает") }
            }
            GroupLabel("Настройка")
            ListCard {
                SliderRow("Скорость", systemImage: "hare", value: $speed, in: 0.3...3) { String(format: "%.1f×", $0) }
                SliderRow("Плавность", systemImage: "waveform.path", value: $duration, in: 0.1...0.9) { String(format: "%.2f с", $0) }
            }
            .disabled(!enabled)
        }
    }
}

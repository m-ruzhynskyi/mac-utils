import AppKit
import SwiftUI

// MARK: - Плавная прокрутка

struct SmoothScrollPage: View {
    @AppStorage(Pref.smoothScroll) private var enabled = true
    @AppStorage(Pref.smoothSpeed) private var speed = 1.0
    @AppStorage(Pref.smoothDuration) private var duration = 0.35
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = SmoothScroll.shared

    var body: some View {
        Form {
            Section {
                Toggle("Плавная прокрутка", isOn: $enabled)
                Text("Колесо обычной мыши прокручивает плавно, как трекпад. Трекпад и Magic Mouse не затрагиваются.")
                    .foregroundStyle(.secondary)
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Плавная прокрутка работает")
                }
            }
            Section("Настройка") {
                LabeledContent("Скорость") {
                    HStack {
                        Slider(value: $speed, in: 0.3...3)
                        Text(String(format: "%.1f×", speed)).monospacedDigit().frame(width: 40)
                    }
                }
                .disabled(!enabled)
                LabeledContent("Плавность") {
                    HStack {
                        Slider(value: $duration, in: 0.1...0.9)
                        Text(String(format: "%.2f с", duration)).monospacedDigit().frame(width: 50)
                    }
                }
                .disabled(!enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Плавная прокрутка")
    }
}

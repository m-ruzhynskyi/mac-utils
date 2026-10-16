import AppKit
import SwiftUI

// MARK: - Перерывы и тёплый экран

struct WellbeingPage: View {
    @AppStorage(Pref.breakReminder) private var breaks = false
    @AppStorage(Pref.breakInterval) private var interval = 45
    @AppStorage(Pref.breakDuration) private var duration = 20
    @AppStorage(Pref.warmScreen) private var warm = false
    @AppStorage(Pref.warmStrength) private var strength = 0.5
    @AppStorage(Pref.warmExternalStrength) private var externalStrength = 0.5
    @AppStorage(Pref.warmFrom) private var from = 21
    @AppStorage(Pref.warmTo) private var to = 7
    @AppStorage(Pref.warmMode) private var warmMode = "schedule"
    @AppStorage(Pref.warmManualOn) private var manualOn = false
    @ObservedObject private var reminder = BreakReminder.shared
    @ObservedObject private var screen = WarmScreen.shared

    var body: some View {
        Form {
            Section("Напоминание о перерыве") {
                Toggle("Напоминать о перерыве", isOn: $breaks)
                Text("Каждые N минут работы — мягкий экран «встаньте, посмотрите вдаль». Если вы сами отошли от компьютера на 5 минут, отсчёт начнётся заново.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Group {
                    Picker("Каждые", selection: $interval) {
                        ForEach([20, 30, 45, 60, 90], id: \.self) { Text("\($0) мин").tag($0) }
                    }
                    Picker("Длительность", selection: $duration) {
                        ForEach([20, 30, 60, 120, 300], id: \.self) { Text($0 < 60 ? "\($0) с" : "\($0 / 60) мин").tag($0) }
                    }
                }
                .disabled(!breaks)
                HStack {
                    if breaks { Text("Работаете без перерыва: \(reminder.workedMinutes) мин").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Показать сейчас") { reminder.show() }
                }
            }
            Section("Тёплый экран вечером") {
                Toggle("Тёплый экран", isOn: $warm)
                Text("Свой Night Shift: вечером экран плавно желтеет и синий свет приглушается. Для встроенного экрана и внешних мониторов — своя сила.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Group {
                    Picker("Когда", selection: $warmMode) {
                        Text("По расписанию").tag("schedule")
                        Text("Вручную").tag("manual")
                    }
                    .pickerStyle(.segmented)
                    if warmMode == "manual" {
                        Toggle("Включён сейчас", isOn: $manualOn)
                        Text("Быстро: кнопка ☀︎ в шапке панели 🔧 или ссылка macutils://warm-toggle.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!warm)
                Group {
                    if warmMode == "schedule" {
                        Picker("С", selection: $from) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                        Picker("До", selection: $to) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                    }
                LabeledContent("Встроенный экран") {
                    Slider(value: $strength, in: 0.1...1) { _ in screen.apply() }
                }
                LabeledContent("Внешние мониторы") {
                    Slider(value: $externalStrength, in: 0.1...1) { _ in screen.apply() }
                }
                }
                .disabled(!warm)
                HStack {
                    Text(!warm ? "Выключен" : screen.currentLevel > 0 ? "Сейчас включён: \(Int(screen.currentLevel * 100)) %"
                         : warmMode == "manual" ? "Сейчас выключен" : "Включится в \(String(format: "%02d:00", from))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Показать, как будет") { screen.preview() }
                }
                Text("Вход и выход — плавно, в течение часа. Системный Night Shift лучше выключить, чтобы они не складывались.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Перерывы и тёплый экран")
        .onChange(of: from) { _, _ in screen.apply() }
        .onChange(of: warmMode) { _, _ in screen.apply() }
        .onChange(of: manualOn) { _, _ in screen.apply() }
        .onChange(of: to) { _, _ in screen.apply() }
    }
}

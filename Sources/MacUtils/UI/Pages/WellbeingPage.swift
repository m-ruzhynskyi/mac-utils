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

    private var warmStatus: String {
        !warm ? "Выключен" : screen.currentLevel > 0 ? "Сейчас включён: \(Int(screen.currentLevel * 100)) %"
            : warmMode == "manual" ? "Сейчас выключен" : "Включится в \(String(format: "%02d:00", from))"
    }

    var body: some View {
        SettingsPage(.wellbeing) {
            GroupLabel("Не засыпать")
            ListCard { KeepAwakeTicker() }
            Footnote(KeepAwakeRow.note + " Выключено при каждом запуске приложения; быстро: значок в строке меню (правая кнопка) или macutils://keep-awake.")
            GroupLabel("Напоминание о перерыве")
            ListCard {
                ToggleRow("Напоминать о перерыве",
                          subtitle: "Каждые N минут работы — мягкий экран «встаньте, посмотрите вдаль». Если вы сами отошли от компьютера на 5 минут, отсчёт начнётся заново.",
                          systemImage: "eyes", isOn: $breaks)
                Row("Каждые", systemImage: "timer") {
                    Picker("Каждые", selection: $interval) {
                        ForEach([20, 30, 45, 60, 90], id: \.self) { Text("\($0) мин").tag($0) }
                    }
                    .graphitePicker()
                }
                .disabled(!breaks)
                Row("Длительность", systemImage: "hourglass") {
                    Picker("Длительность", selection: $duration) {
                        ForEach([20, 30, 60, 120, 300], id: \.self) { Text($0 < 60 ? "\($0) с" : "\($0 / 60) мин").tag($0) }
                    }
                    .graphitePicker()
                }
                .disabled(!breaks)
                Row(breaks ? "Работаете без перерыва: \(reminder.workedMinutes) мин" : "Выключен", systemImage: "figure.walk") {
                    Button("Показать сейчас") { reminder.show() }.buttonStyle(.graphite(.secondary, size: .compact))
                }
            }
            GroupLabel("Тёплый экран вечером")
            ListCard {
                ToggleRow("Тёплый экран",
                          subtitle: "Свой Night Shift: вечером экран плавно желтеет и синий свет приглушается. Для встроенного экрана и внешних мониторов — своя сила.",
                          systemImage: "sun.horizon", isOn: $warm)
                Row("Когда", systemImage: "clock") {
                    Segmented(selection: $warmMode, options: [("schedule", "По расписанию"), ("manual", "Вручную")])
                }
                .disabled(!warm)
                if warmMode == "manual" {
                    ToggleRow("Включён сейчас", subtitle: "Быстро: кнопка ☀︎ в шапке панели 🔧 или ссылка macutils://warm-toggle.",
                              systemImage: "sun.max", isOn: $manualOn)
                        .disabled(!warm)
                }
                if warmMode == "schedule" {
                    Row("С", systemImage: "moon") {
                        Picker("С", selection: $from) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                            .graphitePicker()
                    }
                    .disabled(!warm)
                    Row("До", systemImage: "sunrise") {
                        Picker("До", selection: $to) { ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) } }
                            .graphitePicker()
                    }
                    .disabled(!warm)
                }
                Row("Встроенный экран", systemImage: "laptopcomputer") {
                    Slider(value: $strength, in: 0.1...1) { _ in screen.apply() }.frame(width: 180)
                }
                .disabled(!warm)
                Row("Внешние мониторы", systemImage: "display") {
                    Slider(value: $externalStrength, in: 0.1...1) { _ in screen.apply() }.frame(width: 180)
                }
                .disabled(!warm)
                Row(warmStatus, systemImage: "thermometer.sun") {
                    Button("Показать, как будет") { screen.preview() }.buttonStyle(.graphite(.secondary, size: .compact))
                }
            }
            Footnote("Вход и выход — плавно, в течение часа. Системный Night Shift лучше выключить, чтобы они не складывались.")
        }
        .onChange(of: from) { _, _ in screen.apply() }
        .onChange(of: warmMode) { _, _ in screen.apply() }
        .onChange(of: manualOn) { _, _ in screen.apply() }
        .onChange(of: to) { _, _ in screen.apply() }
    }
}

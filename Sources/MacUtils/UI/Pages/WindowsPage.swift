import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUWindowSnap
import MUScreenShare
import MUTextEditor

// MARK: - Окна

struct WindowsPage: View {
    @AppStorage(Pref.windowSnap) private var enabled = true
    @AppStorage(Pref.windowSnapDrag) private var drag = true
    @AppStorage(Pref.windowSnapGap) private var gap = 0
    @AppStorage(Pref.windowSnapModifier) private var modifier = WindowSnapModifier.controlOption.rawValue
    @ObservedObject private var permissions = PermissionsModel.shared
    @ObservedObject private var service = WindowTiler.shared

    /// Встроенная в macOS раскладка перетаскиванием (Рабочий стол и Dock).
    private var systemTiling: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
    }

    private var symbols: String { (WindowSnapModifier(rawValue: modifier) ?? .controlOption).symbols }

    var body: some View {
        SettingsPage(.windows,
                     subtitle: "Как в Windows: перетащите окно за заголовок к краю экрана — оно займёт половину, к углу — четверть, к верхнему краю — весь экран. Или горячими клавишами.",
                     isOn: $enabled, toggleLabel: "Раскладка окон") {
            if enabled {
                ListCard { AccessibilityStatusRow(running: service.isRunning, readyText: "Раскладка окон работает") }
            }
            GroupLabel("Настройка")
            ListCard {
                ToggleRow("Прилипание при перетаскивании", systemImage: "rectangle.lefthalf.inset.filled", isOn: $drag)
                Row("Отступ между окнами", systemImage: "rectangle.split.2x1") {
                    Picker("Отступ между окнами", selection: $gap) {
                        Text("Нет").tag(0)
                        Text("4 pt").tag(4)
                        Text("8 pt").tag(8)
                    }
                    .graphitePicker()
                }
                Row("Модификатор клавиш", systemImage: "command") {
                    Picker("Модификатор клавиш", selection: $modifier) {
                        ForEach(WindowSnapModifier.allCases) { option in
                            Text(option.symbols).tag(option.rawValue)
                        }
                    }
                    .graphitePicker()
                }
            }
            .disabled(!enabled)
            if drag && systemTiling {
                Banner(.warning, title: "В macOS тоже включена раскладка перетаскиванием — подсказки могут дублироваться.",
                       message: "Её можно выключить: Системные настройки → Рабочий стол и Dock → «Перетаскивать окна к краям экрана».")
            }
            if !service.failedHotKeys.isEmpty {
                Banner(.warning, title: "Заняты другим приложением: \(service.failedHotKeys.joined(separator: ", "))")
            }
            CollapsibleCard("Горячие клавиши") {
                ForEach(WindowTiler.bindings, id: \.label) { binding in
                    Row(binding.title) { Keycap(Array(symbols).map(String.init) + [binding.label]) }
                }
            }
            Footnote("Повторное нажатие той же половины переносит окно на следующий монитор.")
            WindowExtrasSections()
        }
    }
}

// MARK: - Окна: поверх всех и память по мониторам

struct WindowExtrasSections: View {
    @AppStorage(Pref.windowPin) private var pinEnabled = true
    @AppStorage(Pref.windowMemory) private var memoryEnabled = true
    @ObservedObject private var pin = WindowPin.shared
    @ObservedObject private var memory = WindowMemory.shared

    var body: some View {
        GroupLabel("Поверх всех окон")
        ListCard {
            ToggleRow("Закреплять окна поверх остальных",
                      subtitle: "Поверх остальных показывается живая копия окна. Клик по ней открывает настоящее окно, правый клик — прозрачность и «Открепить».",
                      systemImage: "pin", isOn: $pinEnabled)
            Row("Закрепить активное окно поверх всех или открепить его.") { Keycap(action: .windowPin) }
            ForEach(pin.pins) { item in
                Row(item.title, systemImage: "pin.fill", tile: .accent) {
                    Slider(value: Binding(get: { item.opacity }, set: { item.setOpacity($0) }), in: 0.2...1)
                        .tint(.dsAccLine)
                        .frame(width: 120)
                        .help("Прозрачность")
                        .accessibilityLabel("Прозрачность")
                    IconButton("Открепить", systemImage: "xmark", compact: true) { pin.unpin(item) }
                }
            }
        }
        GroupLabel("Окна по мониторам")
        ListCard {
            ToggleRow("Запоминать окна для каждого набора мониторов",
                      subtitle: "Подключили внешний монитор — окна сами встанут туда, где стояли при этом мониторе в прошлый раз.",
                      systemImage: "display.2", isOn: $memoryEnabled)
            Row("Сейчас: \(memory.monitorsDescription), запомнено наборов: \(memory.layouts.count)") {
                Button("Запомнить сейчас") { memory.snapshot(force: true) }.buttonStyle(.graphite(.secondary, size: .compact))
                Button("Расставить") { memory.restore() }.buttonStyle(.graphite(.secondary, size: .compact))
                Button("Забыть") { memory.forget() }.buttonStyle(.graphite(.ghost, size: .compact))
            }
            .disabled(!memoryEnabled)
        }
    }
}

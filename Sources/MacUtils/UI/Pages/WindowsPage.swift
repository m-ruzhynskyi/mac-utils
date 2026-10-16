import AppKit
import SwiftUI

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
        Form {
            Section {
                Toggle("Раскладка окон", isOn: $enabled)
                Text("Как в Windows: перетащите окно за заголовок к краю экрана — оно займёт половину, к углу — четверть, к верхнему краю — весь экран. Или горячими клавишами.")
                    .foregroundStyle(.secondary)
                if enabled {
                    accessibilityStatus(permissions, running: service.isRunning, readyText: "Раскладка окон работает")
                }
            }
            Section("Настройка") {
                Toggle("Прилипание при перетаскивании", isOn: $drag)
                if drag && systemTiling {
                    Text("В macOS тоже включена раскладка перетаскиванием — подсказки могут дублироваться. Её можно выключить: Системные настройки → Рабочий стол и Dock → «Перетаскивать окна к краям экрана».")
                        .foregroundStyle(.orange)
                }
                Picker("Отступ между окнами", selection: $gap) {
                    Text("Нет").tag(0)
                    Text("4 pt").tag(4)
                    Text("8 pt").tag(8)
                }
                Picker("Модификатор клавиш", selection: $modifier) {
                    ForEach(WindowSnapModifier.allCases) { option in
                        Text(option.symbols).tag(option.rawValue)
                    }
                }
                if !service.failedHotKeys.isEmpty {
                    Label("Заняты другим приложением: \(service.failedHotKeys.joined(separator: ", "))",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .disabled(!enabled)
            Section("Горячие клавиши") {
                ForEach(WindowTiler.bindings, id: \.label) { binding in
                    ShortcutRow(keys: Array(symbols).map(String.init) + [binding.label], text: binding.title)
                }
                Text("Повторное нажатие той же половины переносит окно на следующий монитор.")
                    .foregroundStyle(.secondary)
            }
            WindowExtrasSections()
        }
        .formStyle(.grouped)
        .navigationTitle("Окна")
    }
}

// MARK: - Окна: поверх всех и память по мониторам

struct WindowExtrasSections: View {
    @AppStorage(Pref.windowPin) private var pinEnabled = true
    @AppStorage(Pref.windowMemory) private var memoryEnabled = true
    @ObservedObject private var pin = WindowPin.shared
    @ObservedObject private var memory = WindowMemory.shared

    var body: some View {
        Section("Поверх всех окон") {
            Toggle("Закреплять окна поверх остальных", isOn: $pinEnabled)
            ActionShortcutRow(action: .windowPin, text: "Закрепить активное окно поверх всех или открепить его.")
            Text("Поверх остальных показывается живая копия окна. Клик по ней открывает настоящее окно, правый клик — прозрачность и «Открепить».")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(pin.pins) { item in
                HStack {
                    Image(systemName: "pin.fill").foregroundStyle(.blue)
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Slider(value: Binding(get: { item.opacity }, set: { item.setOpacity($0) }), in: 0.2...1)
                        .frame(width: 120)
                        .help("Прозрачность")
                    Button { pin.unpin(item) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Открепить")
                }
            }
        }
        Section("Окна по мониторам") {
            Toggle("Запоминать окна для каждого набора мониторов", isOn: $memoryEnabled)
            Text("Подключили внешний монитор — окна сами встанут туда, где стояли при этом мониторе в прошлый раз.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Сейчас: \(memory.monitorsDescription), запомнено наборов: \(memory.layouts.count)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Запомнить сейчас") { memory.snapshot(force: true) }
                Button("Расставить") { memory.restore() }
                Button("Забыть") { memory.forget() }
            }
            .disabled(!memoryEnabled)
        }
    }
}

import SwiftUI
import MUCore
import MUDesign

/// Строка «Не засыпать»: срок, переключатель и (пока включено) сколько осталось.
struct KeepAwakeRow: View {
    static let note = "Экран может гаснуть, Mac продолжает работать. При закрытой крышке без внешнего монитора Mac всё равно уснёт."

    /// Демо для снимков: не трогает систему, показывает «включено, осталось…».
    var demoRemaining: TimeInterval?

    @ObservedObject private var keepAwake = KeepAwake.shared
    @AppStorage(Pref.keepAwakeDuration) private var durationRaw = KeepAwakeDuration.indefinite.rawValue

    private var duration: KeepAwakeDuration { KeepAwakeDuration(rawValue: durationRaw) ?? .indefinite }
    private var active: Bool { demoRemaining != nil || keepAwake.isActive }

    var body: some View {
        Row("Не засыпать", subtitle: subtitle, systemImage: active ? "cup.and.saucer.fill" : "cup.and.saucer",
            tile: active ? .accent : .neutral) {
            Picker("Срок", selection: Binding(get: { duration }, set: setDuration)) {
                ForEach(KeepAwakeDuration.allCases) { Text($0.title).tag($0) }
            }
            .graphitePicker()
            Toggle("Не засыпать", isOn: Binding(get: { active }, set: { $0 ? keepAwake.start(duration) : keepAwake.stop() }))
                .toggleStyle(.graphite)
                .disabled(demoRemaining != nil)
        }
    }

    private var subtitle: String? {
        if let demoRemaining { return KeepAwake.remainingText(demoRemaining) }
        if keepAwake.failed { return "Система не разрешила запретить сон" }
        guard keepAwake.isActive else { return nil }
        // Минуты обновляются сами, пока строка на экране.
        return keepAwake.statusText()
    }

    private func setDuration(_ new: KeepAwakeDuration) {
        durationRaw = new.rawValue
        if keepAwake.isActive { keepAwake.start(new) }
    }
}

/// Строка + пояснение под ней для панели 🔧 (карточка `QuickGroup`).
struct KeepAwakeTicker: View {
    var body: some View {
        // Раз в 30 с перерисовываем подпись «Осталось…».
        TimelineView(.periodic(from: .now, by: 30)) { _ in KeepAwakeRow() }
    }
}

import Foundation

/// Разрешение на запись звука действует на весь процесс. «Нет разрешения» — только если ни один перехват за сессию
/// ни разу не получил звука и тишина длится долго; пауза в разговоре у приложения, которое держит вывод, разрешением не считается.
package struct PermissionWatch: Equatable {
    package init() {
    }

    package static let silentTicksToTrip = 10

    package private(set) var silentTicks = 0
    package private(set) var proven = false

    /// Один тик (раз в секунду). true — пора снимать перехваты и сообщить об отказе в разрешении.
    package mutating func record(anyPlaying: Bool, anySound: Bool) -> Bool {
        if anySound {
            proven = true
            silentTicks = 0
            return false
        }
        silentTicks = anyPlaying ? silentTicks + 1 : 0
        guard !proven, silentTicks >= Self.silentTicksToTrip else { return false }
        silentTicks = 0
        return true
    }

    /// Счётчик тишины заново (пользователь трогал громкость, перехватов нет); доказанное разрешение остаётся.
    package mutating func reset() { silentTicks = 0 }
}

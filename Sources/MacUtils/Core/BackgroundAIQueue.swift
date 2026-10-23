import Foundation

/// Сколько фоновых запросов к модели ещё впереди (теги документов и имена снимков). Пока их больше одного, модель
/// держится в памяти ~30 с между запросами; на последнем она выгружается сразу (`keep_alive: "0"`).
final class BackgroundAIQueue: @unchecked Sendable {
    static let shared = BackgroundAIQueue()
    nonisolated static let keepWhileBusy = "30s"

    private let lock = NSLock()
    private var outstanding = 0

    /// Элемент поставлен в очередь (или начал работу, если очереди нет).
    func enter() { lock.withLock { outstanding += 1 } }
    /// Элемент обработан или сброшен.
    func leave() { lock.withLock { outstanding = max(0, outstanding - 1) } }
    var count: Int { lock.withLock { outstanding } }
    var keepAlive: String { Self.keepAlive(outstanding: count) }

    /// `outstanding` включает текущий запрос: последний (1) и пустая очередь (0) → "0".
    nonisolated static func keepAlive(outstanding: Int) -> String {
        outstanding > 1 ? keepWhileBusy : "0"
    }
}

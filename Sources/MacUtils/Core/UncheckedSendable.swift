/// Обёртка для значений, которые безопасно передать между очередями вручную (SDK не помечает их Sendable).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

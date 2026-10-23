/// Обёртка для значений, которые безопасно передать между очередями вручную (SDK не помечает их Sendable).
package struct UncheckedSendable<Value>: @unchecked Sendable {
    package let value: Value
    package init(_ value: Value) { self.value = value }
}

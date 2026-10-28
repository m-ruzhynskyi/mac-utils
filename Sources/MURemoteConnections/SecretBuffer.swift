import Foundation

/// Байты секрета (пароля) вне `String`: затираются явно (`wipe()`) и при освобождении.
/// Не печатается, не кодируется и не сравнивается, чтобы случайно не попасть в журнал или файл.
public final class SecretBuffer: @unchecked Sendable {
    private var storage: UnsafeMutableRawBufferPointer
    private let lock = NSLock()

    public init<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        var copy = Array(bytes)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(copy.count, 1), alignment: 1)
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        copy.withUnsafeBytes { buffer.copyMemory(from: $0) }
        // Промежуточная копия тоже обнуляется.
        copy.withUnsafeMutableBytes { if let base = $0.baseAddress { _ = memset_s(base, $0.count, 0, $0.count) } }
        storage = buffer
        count = copy.count
    }

    deinit {
        wipe()
        storage.deallocate()
    }

    public private(set) var count: Int
    public var isEmpty: Bool { count == 0 }

    /// Доступ к байтам на время вызова; копию наружу не выносить.
    public func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(UnsafeRawBufferPointer(rebasing: storage[0..<count]))
    }

    /// Обнулить байты. После вызова буфер пуст.
    public func wipe() {
        lock.lock(); defer { lock.unlock() }
        if let base = storage.baseAddress { _ = memset_s(base, storage.count, 0, storage.count) }
        count = 0
    }
}

extension SecretBuffer: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "SecretBuffer(•••)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

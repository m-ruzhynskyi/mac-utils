import Foundation

/// Операция не уложилась в отведённое время.
package struct TimeLimitExceeded: Error, Equatable {
    package let seconds: TimeInterval
}

/// Предел времени для async-операции, которая может зависнуть (ScreenCaptureKit, сеть).
///
/// В отличие от группы задач, не ждёт зависшую операцию: по истечении срока она отменяется, вызывающий сразу
/// получает `TimeLimitExceeded`, а её запоздавший результат отбрасывается.
package enum TimeLimit {
    @MainActor
    package static func run<T>(seconds: TimeInterval,
                               _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let once = OnceResume<T>()
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            let work = Task { @MainActor in
                do { once.resume(.success(try await operation())) } catch { once.resume(.failure(error)) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.resume(.failure(TimeLimitExceeded(seconds: seconds))) { work.cancel() }
            }
        }
    }
}

/// Продолжение возобновляется ровно один раз: тем, кто успел первым (результат или срок).
private final class OnceResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }
}

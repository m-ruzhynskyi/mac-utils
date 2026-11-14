import Foundation

/// Фильтр «One Euro» (Casiez et al., 2012): почти неподвижный сигнал сглаживается сильно,
/// быстрый — слабо, поэтому нет ни дрожания, ни запаздывания на саккадах.
package struct OneEuroFilter: Sendable {
    package var minCutoff: Double
    package var beta: Double
    package var derivativeCutoff: Double
    private var value: Vec2?
    private var derivative = Vec2.zero

    package init(minCutoff: Double = 1.2, beta: Double = 0.6, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.derivativeCutoff = derivativeCutoff
    }

    package var current: Vec2? { value }

    package mutating func reset() { value = nil; derivative = .zero }

    package mutating func filter(_ x: Vec2, dt: Double) -> Vec2 {
        guard let prev = value, dt > 0 else { value = x; derivative = .zero; return x }
        let rawDerivative = (x - prev) / dt
        derivative = derivative + (rawDerivative - derivative) * Self.alpha(derivativeCutoff, dt)
        let cutoff = minCutoff + beta * derivative.length
        let next = prev + (x - prev) * Self.alpha(cutoff, dt)
        value = next
        return next
    }

    static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Плавный переход 0…1 за `duration` секунд; наружу отдаёт значение через smoothstep, без рывка в начале и конце.
package struct Fade: Sendable {
    package private(set) var linear: Double
    package init(_ value: Double = 0) { linear = value }
    package var value: Double { smoothstep(0, 1, linear) }

    package mutating func advance(toward target: Double, dt: Double, duration: Double) {
        guard duration > 0 else { linear = target; return }
        let step = dt / duration
        linear = target > linear ? min(target, linear + step) : max(target, linear - step)
    }
}

/// Экспоненциальное сглаживание с постоянной времени `tau`, независимое от частоты кадров.
package struct ExpSmoother: Sendable {
    package var tau: Double
    package private(set) var value: Vec2?
    package init(tau: Double) { self.tau = tau }
    package mutating func reset() { value = nil }
    package mutating func update(_ x: Vec2, dt: Double) -> Vec2 {
        guard let v = value else { value = x; return x }
        let next = v + (x - v) * (1 - exp(-max(dt, 0) / tau))
        value = next
        return next
    }
}

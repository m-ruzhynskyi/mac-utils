import Foundation

/// Детерминированный генератор (SplitMix64): одинаковое зерно — одинаковые движения, удобно в тестах.
package struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    package init(seed: UInt64) { state = seed }
    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// Микросаккады (быстрые скачки за ~40 мс через случайные паузы) плюс медленный дрейф между ними.
/// Смещение — в долях полуширины глаза, непрерывное по времени: между кадрами нет дрожания.
package struct MicroSaccades: Sendable {
    package static let saccadeSeconds = 0.04
    package static let driftTau = 1.2

    private var rng: SplitMix64
    private var from = Vec2.zero, to = Vec2.zero
    private var start = -1.0, nextEvent: Double?
    private var drift = Vec2.zero
    private var lastTime: Double?

    package init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    package mutating func offset(at time: Double, parameters p: FreedomParameters) -> Vec2 {
        let dt = lastTime.map { min(max(time - $0, 0), 0.2) } ?? 0
        lastTime = time
        if nextEvent == nil { nextEvent = time + interval(p) }
        if let n = nextEvent, time >= n {
            from = saccadePosition(at: time)
            // Новая точка внутри круга; половина веса тянет к центру, чтобы взгляд не уплывал.
            let angle = 2 * Double.pi * rng.unit()
            let radius = p.microAmplitude * rng.unit().squareRoot()
            to = from * 0.3 + Vec2(cos(angle), sin(angle)) * radius
            to = to.clampedLength(p.microAmplitude)
            start = time
            nextEvent = time + interval(p)
        }
        if dt > 0 {
            // Процесс Орнштейна — Уленбека: дрейф с ограниченной дисперсией.
            let k = (2 * dt / Self.driftTau).squareRoot() * p.driftAmplitude
            drift = drift - drift * (dt / Self.driftTau) + Vec2(rng.gaussian(), rng.gaussian()) * k
        }
        return saccadePosition(at: time) + drift
    }

    private func saccadePosition(at time: Double) -> Vec2 {
        guard start >= 0 else { return to }
        let t = smoothstep(0, 1, (time - start) / Self.saccadeSeconds)
        return from + (to - from) * t
    }

    private mutating func interval(_ p: FreedomParameters) -> Double {
        p.microInterval.lowerBound + (p.microInterval.upperBound - p.microInterval.lowerBound) * rng.unit()
    }
}

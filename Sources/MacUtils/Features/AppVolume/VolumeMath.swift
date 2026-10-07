import Foundation

/// Громкость приложения: проценты на ползунке ↔ множитель сигнала.
enum VolumeMath {
    static let maxPercent = 150

    /// 0…150 % → множитель 0…1.5 (линейно: так совпадает с подписью в процентах).
    static func gain(percent: Int, muted: Bool) -> Float {
        guard !muted else { return 0 }
        return Float(min(max(percent, 0), maxPercent)) / 100
    }

    /// Нужен ли перехват звука: только если громкость отличается от обычной.
    static func needsTap(percent: Int, muted: Bool) -> Bool {
        muted || percent != 100
    }

    /// Умножает отсчёты на множитель; выше 100 % — мягкое ограничение, без щелчков.
    static func apply(gain: Float, to samples: UnsafeMutableBufferPointer<Float>, from source: UnsafeBufferPointer<Float>) {
        let count = min(samples.count, source.count)
        guard count > 0 else { return }
        if gain <= 1 {
            for i in 0..<count { samples[i] = source[i] * gain }
        } else {
            for i in 0..<count { samples[i] = softClip(source[i] * gain) }
        }
    }

    /// tanh-подобное ограничение: до 0.8 — без изменений, выше — плавно к ±1.
    static func softClip(_ x: Float) -> Float {
        let threshold: Float = 0.8
        let a = abs(x)
        guard a > threshold else { return x }
        let over = (a - threshold) / (1 - threshold)
        let shaped = threshold + (1 - threshold) * tanh(over)
        return x < 0 ? -shaped : shaped
    }
}

/// Сохранённые громкости по bundle id.
struct VolumeStore: Equatable {
    struct Entry: Codable, Equatable {
        var percent: Int
        var muted: Bool
    }

    private(set) var entries: [String: Entry] = [:]

    init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    init(data: Data?) {
        if let data, let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    /// Консольные программы без bundle id («pid.123») сохраняются только до перезапуска.
    var data: Data? { try? JSONEncoder().encode(entries.filter { !$0.key.hasPrefix("pid.") }) }

    func entry(for bundleID: String) -> Entry {
        entries[bundleID] ?? Entry(percent: 100, muted: false)
    }

    /// Обычная громкость (100 %, без выключения) не хранится.
    mutating func set(_ entry: Entry, for bundleID: String) {
        let clamped = Entry(percent: min(max(entry.percent, 0), VolumeMath.maxPercent), muted: entry.muted)
        if VolumeMath.needsTap(percent: clamped.percent, muted: clamped.muted) {
            entries[bundleID] = clamped
        } else {
            entries[bundleID] = nil
        }
    }
}

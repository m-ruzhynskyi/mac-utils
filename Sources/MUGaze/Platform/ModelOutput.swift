import CoreML

/// Чтение выхода модели Core ML (fp32 или fp16) по плоскому индексу, с учётом шагов массива у вызывающего.
/// `Float16` в Swift есть только на arm64: универсальная сборка (arm64 + x86_64) на Intel-половине читает fp16
/// как 16 бит и переводит в fp32 сама (`halfToFloat`). На arm64 — как раньше, через `Float16`.
package enum ModelOutput {
    package static func float(_ arr: MLMultiArray, _ idx: Int) -> Float {
        guard arr.dataType == .float16 else { return arr.dataPointer.assumingMemoryBound(to: Float32.self)[idx] }
        #if arch(arm64)
        return Float(arr.dataPointer.assumingMemoryBound(to: Float16.self)[idx])
        #else
        return halfToFloat(arr.dataPointer.assumingMemoryBound(to: UInt16.self)[idx])
        #endif
    }

    /// IEEE 754 half → float без `Float16`: знак, порядок (смещение 15 → 127), мантисса; ±0, субнормальные, ∞ и NaN.
    package static func halfToFloat(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32(bits >> 10) & 0x1F
        let mantissa = UInt32(bits & 0x3FF)
        switch exponent {
        case 0:
            // Ноль или субнормальное: mantissa · 2^-24 (точно представимо в Float).
            let magnitude = Float(mantissa) * 0x1p-24
            return sign == 0 ? magnitude : -magnitude
        case 0x1F:
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        default:
            return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
        }
    }
}

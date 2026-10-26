import AVFoundation
import Foundation
import MUCore

/// Частоты, в которых бывает звук Mac: 48/44,1 кГц (динамики, AirPods), 24/16/8 кГц (Bluetooth-гарнитура в режиме звонка).
package enum ShareRates {
    package static let standard: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000]

    /// Ближайшая обычная частота, если измерение не дальше 3 % от неё; иначе nil (измерение шумное).
    package static func snap(_ measured: Double) -> Double? {
        guard measured > 0 else { return nil }
        return standard.first { abs($0 - measured) / $0 <= 0.03 }
    }

    /// Частоту буферов надо исправить: измеренная обычная частота не совпадает с той, по которой считает конвертер.
    package static func correction(converterRate: Double, measured: Double) -> Double? {
        guard let rate = snap(measured), abs(rate - converterRate) / max(converterRate, 1) > 0.01 else { return nil }
        return rate
    }
}

/// Частоты, которые сообщает система: номинальная частота устройства часов, агрегата, формат перехвата. Пишется из главного
/// потока (слушатели `NominalSampleRate`, сборка), читается в очереди IOProc.
package final class ShareReportedRates: @unchecked Sendable {
    private let lock = NSLock()
    private var rates: [Double] = []

    package init() {}

    package func set(_ values: [Double]) {
        lock.lock(); rates = values.filter { $0 > 0 }; lock.unlock()
    }

    package var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return rates
    }
}

/// Проверяет частоту потока по часам устройства: `mSampleTime` из `inInputTime` IOProc за время `mHostTime`. Пропущенный цикл IO
/// даёт скачок `mSampleTime`, а не «медленную частоту», поэтому пропуски буферов частоту не меняют (кадры за время считать
/// нельзя: пропуски 6–10 % выглядели бы как 44,1 кГц, 50 % — как 24 кГц). Поправка принимается только на частоту, которую
/// сообщает система (`reported`), и когда два окна подряд (не меньше секунды) дали одну и ту же.
package struct ShareRateMeter: Equatable {
    package static let window: TimeInterval = 1

    private var start: (sample: Double, time: TimeInterval)?
    private var candidate: Double?

    package init() {}

    /// `sampleTime` — `inInputTime.mSampleTime`, `time` — `mHostTime` в секундах. Возвращает частоту, когда её пора исправить.
    package mutating func add(sampleTime: Double, at time: TimeInterval, converterRate: Double, reported: [Double]) -> Double? {
        guard let begin = start else {
            start = (sampleTime, time)
            return nil
        }
        guard time - begin.time >= Self.window else { return nil }
        let measured = (sampleTime - begin.sample) / (time - begin.time)
        start = (sampleTime, time)
        guard let rate = ShareRates.correction(converterRate: converterRate, measured: measured),
              reported.contains(where: { abs($0 - rate) < 0.5 }) else {
            candidate = nil
            return nil
        }
        if candidate == rate {
            candidate = nil
            return rate
        }
        candidate = rate
        return nil
    }

    package mutating func reset() { self = ShareRateMeter() }

    package static func == (lhs: ShareRateMeter, rhs: ShareRateMeter) -> Bool {
        lhs.start?.sample == rhs.start?.sample && lhs.start?.time == rhs.start?.time && lhs.candidate == rhs.candidate
    }
}

/// Приведение моно-потока любой частоты к частоте трансляции. Частота может меняться посреди потока (звонок, смена выхода):
/// на каждую новую частоту строится свой конвертер, поэтому длительность звука и высота тона не меняются.
package final class ShareAudioResampler: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterRate: Double = 0
    private let lock = NSLock()

    package init(targetRate: Double = ShareProtocol.sampleRate) {
        target = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1)!
    }

    /// `samples` — моно Float на частоте `rate`; результат — на частоте трансляции.
    package func process(_ samples: [Float], rate: Double) -> [Float] {
        guard !samples.isEmpty, rate > 0 else { return [] }
        if abs(rate - target.sampleRate) < 0.5 { return samples }
        lock.lock(); defer { lock.unlock() }
        if converter == nil || abs(converterRate - rate) > 0.5 {
            guard let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return [] }
            converter = AVAudioConverter(from: input, to: target)
            converterRate = rate
        }
        guard let converter, let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / rate) + 32
        guard let result = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var consumed = false
        converter.convert(to: result, error: nil) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard result.frameLength > 0, let channel = result.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(result.frameLength)))
    }
}

/// Строки журнала о частотах (только числа).
package enum ShareAudioRateLog {
    package static func change(path: String, outputBefore: Double, outputNow: Double, buffers: Double, sent: Double) -> String {
        "Звук трансляции (\(path)): частоты сменились — выход \(Int(outputBefore))→\(Int(outputNow)) Гц, буферы \(Int(buffers)) Гц, отправка \(Int(sent)) Гц"
    }
}

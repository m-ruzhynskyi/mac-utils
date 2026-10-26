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

/// Измеряет настоящую частоту потока по числу кадров за время: заявленная форматом перехвата может отставать от настоящей
/// (выход ушёл с 48 на 24 кГц при звонке, а перехват всё ещё «говорит» 48). Окно — не меньше секунды; поправка — когда два окна
/// подряд дали одну и ту же частоту (один затор не считается).
package struct ShareRateMeter: Equatable {
    package static let window: TimeInterval = 1

    private var start: TimeInterval?
    private var frames = 0
    private var lastTime: TimeInterval = 0
    private var candidate: Double?

    package init() {}

    /// Кадры очередного буфера, пришедшего в момент `time` (секунды). Возвращает частоту, когда её пора исправить.
    package mutating func add(frames count: Int, at time: TimeInterval, converterRate: Double) -> Double? {
        guard let begin = start else {
            start = time
            lastTime = time
            return nil
        }
        // Кадры первого буфера пришли до его метки времени — считаем только следующие.
        frames += count
        lastTime = time
        guard time - begin >= Self.window else { return nil }
        let measured = Double(frames) / (time - begin)
        start = time
        frames = 0
        guard let rate = ShareRates.correction(converterRate: converterRate, measured: measured) else {
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

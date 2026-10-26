import AVFoundation
import XCTest
@testable import MUScreenShare

/// Смена частоты звука посреди трансляции (Bluetooth-гарнитура при звонке: 48 → 24 кГц): длительность и высота тона не меняются.
final class ShareAudioRateTests: XCTestCase {
    private func sine(_ hz: Double, rate: Double, seconds: Double, from start: Int = 0) -> [Float] {
        (0..<Int(rate * seconds)).map { Float(sin(2 * Double.pi * hz * Double(start + $0) / rate)) }
    }

    /// Частота тона по переходам через ноль снизу вверх.
    private func frequency(_ samples: [Float], rate: Double) -> Double {
        var crossings = 0
        for index in 1..<samples.count where samples[index - 1] < 0 && samples[index] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(samples.count) / rate)
    }

    private func feed(_ resampler: ShareAudioResampler, _ samples: [Float], rate: Double, chunk: Double = 0.01) -> [Float] {
        let size = Int(rate * chunk)
        var out: [Float] = []
        var index = 0
        while index < samples.count {
            let end = min(index + size, samples.count)
            out += resampler.process(Array(samples[index..<end]), rate: rate)
            index = end
        }
        return out
    }

    func testRateChangeMidStreamKeepsDurationAndPitch() {
        let resampler = ShareAudioResampler()
        // 2 с на 48 кГц, затем 2 с на 24 кГц (тон 1 кГц) — звонок включился посреди потока.
        let first = feed(resampler, sine(1000, rate: 48_000, seconds: 2), rate: 48_000)
        let second = feed(resampler, sine(1000, rate: 24_000, seconds: 2), rate: 24_000)
        let seconds = Double(first.count + second.count) / ShareProtocol.sampleRate
        XCTAssertEqual(seconds, 4, accuracy: 0.04, "длительность отправленного звука = настоящей (±1 %)")
        XCTAssertEqual(frequency(Array(first.dropFirst(480)), rate: ShareProtocol.sampleRate), 1000, accuracy: 15)
        XCTAssertEqual(frequency(Array(second.dropFirst(480)), rate: ShareProtocol.sampleRate), 1000, accuracy: 15, "после смены тон тот же")
    }

    func testOtherRatesToTarget() {
        for rate in [44_100.0, 16_000, 48_000, 24_000, 8_000] {
            let resampler = ShareAudioResampler()
            let out = feed(resampler, sine(1000, rate: rate, seconds: 2), rate: rate)
            XCTAssertEqual(Double(out.count) / ShareProtocol.sampleRate, 2, accuracy: 0.02, "\(rate)")
            XCTAssertEqual(frequency(Array(out.dropFirst(480)), rate: ShareProtocol.sampleRate), 1000, accuracy: 15, "\(rate)")
        }
    }

    func testMeterFindsRealRateWhenDeclaredIsStale() {
        // Перехват заявляет 48 кГц, а кадры идут по 24 кГц: 10 мс = 240 кадров.
        var meter = ShareRateMeter()
        var corrected: Double?
        var time = 0.0
        for _ in 0..<400 {
            time += 0.01
            if let rate = meter.add(frames: 240, at: time, converterRate: 48_000) { corrected = rate; break }
        }
        XCTAssertEqual(corrected, 24_000)
        XCTAssertGreaterThan(time, 1.9, "нужны два согласных окна подряд")
    }

    func testMeterIgnoresStallAndCorrectRate() {
        var meter = ShareRateMeter()
        var time = 0.0
        for _ in 0..<500 {
            time += 0.01
            XCTAssertNil(meter.add(frames: 480, at: time, converterRate: 48_000))
        }
        // Затор на полсекунды в одном окне не должен менять частоту.
        var meter2 = ShareRateMeter()
        time = 0
        var results: [Double?] = []
        for index in 0..<400 {
            time += (index == 50 ? 0.5 : 0.01)
            results.append(meter2.add(frames: 480, at: time, converterRate: 48_000))
        }
        XCTAssertTrue(results.allSatisfy { $0 == nil })
    }

    func testSnapAndCorrection() {
        XCTAssertEqual(ShareRates.snap(24_150), 24_000)
        XCTAssertEqual(ShareRates.snap(47_000), 48_000)
        XCTAssertNil(ShareRates.snap(36_000))
        XCTAssertNil(ShareRates.correction(converterRate: 48_000, measured: 48_300))
        XCTAssertEqual(ShareRates.correction(converterRate: 48_000, measured: 23_900), 24_000)
    }

    func testMonoMixOfStereoBuffers() {
        for interleaved in [true, false] {
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
            buffer.frameLength = 4
            let data = buffer.floatChannelData!
            for frame in 0..<4 {
                if interleaved { data[0][frame * 2] = 1; data[0][frame * 2 + 1] = 0.5 } else { data[0][frame] = 1; data[1][frame] = 0.5 }
            }
            XCTAssertEqual(ShareProtocol.monoSamples(buffer), [0.75, 0.75, 0.75, 0.75], "interleaved \(interleaved)")
        }
    }
}

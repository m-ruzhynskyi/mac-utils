import AudioToolbox
import CoreAudio
import Foundation

/// Общий интерфейс перехвата (сам перехват есть только с macOS 14.2).
protocol VolumeTapping: AnyObject {
    func stop()
}

/// Перехват звука одного приложения: Core Audio process tap глушит его обычный
/// вывод, а приватное агрегатное устройство (tap + текущий выход) проигрывает
/// тот же звук с нужной громкостью.
@available(macOS 14.2, *)
final class AppVolumeTap: VolumeTapping, @unchecked Sendable {
    let bundleID: String
    let processObjects: [AudioObjectID]
    let outputDevice: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "macutils.volume", qos: .userInteractive)
    /// Множитель громкости: пишется из главного потока, читается в аудиопотоке.
    private let gainPointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    /// Пики входа и выхода за последнее окно (для проверки и индикатора).
    private let levels = UnsafeMutablePointer<Float>.allocate(capacity: 2)

    var gain: Float {
        get { gainPointer.pointee }
        set { gainPointer.pointee = newValue }
    }

    /// (вход, выход) — пиковые уровни с прошлого чтения.
    func takeLevels() -> (input: Float, output: Float) {
        let result = (levels[0], levels[1])
        levels[0] = 0
        levels[1] = 0
        return result
    }

    enum TapError: LocalizedError {
        case status(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .status(let step, let status): return "\(step): ошибка Core Audio \(status)"
            }
        }
    }

    init(bundleID: String, processObjects: [AudioObjectID], outputDevice: AudioObjectID, gain: Float) throws {
        self.bundleID = bundleID
        self.processObjects = processObjects
        self.outputDevice = outputDevice
        gainPointer.initialize(to: gain)
        levels.initialize(repeating: 0, count: 2)
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
        gainPointer.deallocate()
        levels.deallocate()
    }

    private func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        description.name = "Mac Utils — \(bundleID)"
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.status("Перехват звука", status) }

        guard let outputUID = CoreAudioHelper.readString(outputDevice, kAudioDevicePropertyDeviceUID) else {
            throw TapError.status("Устройство вывода", -1)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mac Utils Volume",
            kAudioAggregateDeviceUIDKey: "com.mruzhynskyi.macutils.volume.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw TapError.status("Агрегатное устройство", status) }

        let gainPointer = self.gainPointer
        let levels = self.levels
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
            Self.render(input: input, output: output, gain: gainPointer.pointee, levels: levels)
        }
        guard status == noErr, procID != nil else { throw TapError.status("Обработчик звука", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.status("Запуск вывода", status) }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Копирует звук перехвата в выход с множителем. Буферы — float32;
    /// каналы сопоставляются по порядку, лишние каналы выхода — тишина.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>,
                               gain: Float, levels: UnsafeMutablePointer<Float>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for index in 0..<outputs.count {
            guard let outData = outputs[index].mData else { continue }
            let outCount = Int(outputs[index].mDataByteSize) / MemoryLayout<Float>.size
            let out = UnsafeMutableBufferPointer(start: outData.assumingMemoryBound(to: Float.self), count: outCount)
            guard index < inputs.count, let inData = inputs[index].mData else {
                out.update(repeating: 0)
                continue
            }
            let inCount = Int(inputs[index].mDataByteSize) / MemoryLayout<Float>.size
            let source = UnsafeBufferPointer(start: inData.assumingMemoryBound(to: Float.self), count: inCount)
            VolumeMath.apply(gain: gain, to: out, from: source)
            if outCount > inCount {
                UnsafeMutableBufferPointer(rebasing: out[inCount...]).update(repeating: 0)
            }
            var inPeak: Float = 0, outPeak: Float = 0
            for i in 0..<min(inCount, outCount) {
                inPeak = max(inPeak, abs(source[i]))
                outPeak = max(outPeak, abs(out[i]))
            }
            levels[0] = max(levels[0], inPeak)
            levels[1] = max(levels[1], outPeak)
        }
    }
}

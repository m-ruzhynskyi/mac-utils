import AudioToolbox
import CoreAudio
import Foundation
import MUCore

/// Общий интерфейс перехвата (сам перехват есть только с macOS 14.2).
package protocol VolumeTapping: AnyObject {
    func stop()
}

/// Перехват звука одного приложения: Core Audio process tap глушит его обычный
/// вывод, а приватное агрегатное устройство (tap + текущий выход) проигрывает
/// тот же звук с нужной громкостью.
@available(macOS 14.2, *)
package final class AppVolumeTap: VolumeTapping, @unchecked Sendable {
    package let bundleID: String
    package let processObjects: [AudioObjectID]
    package let outputDevice: AudioObjectID

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Входы подустройства выключены для IOProc: пишется до `AudioDeviceStart`, читается в колбэке.
    private let inputsOff = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    private let queue = DispatchQueue(label: "macutils.volume", qos: .userInteractive)
    /// Множитель громкости: пишется из главного потока, читается в аудиопотоке.
    private let gainPointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    /// Пики входа и выхода за последнее окно (для проверки и индикатора).
    private let levels = UnsafeMutablePointer<Float>.allocate(capacity: 2)

    package var gain: Float {
        get { gainPointer.pointee }
        set { gainPointer.pointee = newValue }
    }

    /// (вход, выход) — пиковые уровни с прошлого чтения.
    package func takeLevels() -> (input: Float, output: Float) {
        let result = (levels[0], levels[1])
        levels[0] = 0
        levels[1] = 0
        return result
    }

    package enum TapError: LocalizedError {
        case status(String, OSStatus)
        package var errorDescription: String? {
            switch self {
            case .status(let step, let status): return "\(step): ошибка Core Audio \(status)"
            }
        }
    }

    package init(bundleID: String, processObjects: [AudioObjectID], outputDevice: AudioObjectID, gain: Float) throws {
        self.bundleID = bundleID
        self.processObjects = processObjects
        self.outputDevice = outputDevice
        gainPointer.initialize(to: gain)
        inputsOff.initialize(to: false)
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
        inputsOff.deallocate()
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
        // Входы выхода (микрофон гарнитуры/AirPods) — свойство самого устройства; буфер перехвата — после них.
        let subdeviceInputs = AggregateStreams.inputStreamCount(outputDevice)
        let inputsOff = self.inputsOff
        inputsOff.pointee = false
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, output, _ in
            let count = Int(input.pointee.mNumberBuffers)
            let tapBuffer = AggregateStreams.tapBuffer(inputCount: count, subdeviceInputs: subdeviceInputs, subdeviceInputsOff: inputsOff.pointee)
            Self.render(input: input, tapBuffer: tapBuffer, output: output, gain: gainPointer.pointee, levels: levels)
        }
        guard status == noErr, let procID else { throw TapError.status("Обработчик звука", status) }
        // Входы подустройства IOProc не нужны: иначе у AirPods включается микрофон и звук становится «телефонным».
        inputsOff.pointee = AggregateStreams.disableSubdeviceInputs(aggregate: aggregateID, procID: procID, subdeviceInputs: subdeviceInputs)
            && subdeviceInputs > 0
        if subdeviceInputs > 0, !inputsOff.pointee {
            Log.audio.error("Громкость: входы устройства вывода не выключены — раскладка агрегата ещё не собрана")
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.status("Запуск вывода", status) }
    }

    package func stop() {
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

    /// Копирует звук перехвата (буфер `tapBuffer` входа агрегата) в первый буфер выхода с множителем; float32,
    /// остальные буферы выхода — тишина. Буферы до `tapBuffer` — вход подустройства (микрофон гарнитуры), их не трогаем.
    private static func render(input: UnsafePointer<AudioBufferList>, tapBuffer: Int?, output: UnsafeMutablePointer<AudioBufferList>,
                               gain: Float, levels: UnsafeMutablePointer<Float>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let tap = tapBuffer.flatMap { $0 < inputs.count ? inputs[$0] : nil }
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for index in 0..<outputs.count {
            guard let outData = outputs[index].mData else { continue }
            let outCount = Int(outputs[index].mDataByteSize) / MemoryLayout<Float>.size
            let out = UnsafeMutableBufferPointer(start: outData.assumingMemoryBound(to: Float.self), count: outCount)
            guard index == 0, let tap, let inData = tap.mData else {
                out.update(repeating: 0)
                continue
            }
            let inCount = Int(tap.mDataByteSize) / MemoryLayout<Float>.size
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

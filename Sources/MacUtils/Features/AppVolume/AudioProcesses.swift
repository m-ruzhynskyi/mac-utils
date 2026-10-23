import AppKit
import CoreAudio
import MUDesign

/// Чтение свойств Core Audio.
enum CoreAudioHelper {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
        var address = address(selector)
        var result = value
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? result : value
    }

    static func readArray(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &items) == noErr else { return [] }
        return items
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    static var defaultOutputDevice: AudioObjectID {
        read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(0))
    }
}

/// Где во входе агрегата (подустройство + перехват) звук перехвата. Входные потоки агрегата идут так: сначала потоки
/// подустройств (у USB-гарнитуры, AirPods или аудиоинтерфейса у выхода есть свой вход — микрофон), за ними — поток
/// перехвата. Буферы IOProc — по одному на поток, в том же порядке.
/// Состав агрегата HAL может собрать не сразу после создания, поэтому раскладка проверяется в каждом колбэке IOProc
/// по числу его буферов; входы подустройства — свойство настоящего устройства, оно стабильно.
enum AggregateStreams {
    /// Индекс буфера перехвата (последний: один поток после входов подустройства); nil — раскладка не сходится, и тогда
    /// звук не берём совсем (иначе можно взять микрофон). `subdeviceInputsOff` — входы подустройства выключены для IOProc
    /// (`inputStreamUsage`): если HAL их в списке буферов опускает, остаётся один буфер — перехват.
    static func tapBuffer(inputCount: Int, subdeviceInputs: Int, subdeviceInputsOff: Bool = false) -> Int? {
        guard subdeviceInputs >= 0, inputCount > 0 else { return nil }
        if inputCount == subdeviceInputs + 1 { return inputCount - 1 }
        if subdeviceInputsOff, inputCount == 1 { return 0 }
        return nil
    }

    /// Какие входные потоки агрегата включить для IOProc: только перехват, входы подустройства — нет (у AirPods включённый
    /// вход — это микрофон: Bluetooth уходит в режим звонка, звук становится «телефонным»). nil — раскладка не сошлась.
    static func inputStreamUsage(aggregateInputs: Int, subdeviceInputs: Int) -> [Bool]? {
        guard subdeviceInputs >= 0, aggregateInputs == subdeviceInputs + 1 else { return nil }
        return (0..<aggregateInputs).map { $0 == aggregateInputs - 1 }
    }

    static func inputStreamCount(_ device: AudioObjectID) -> Int {
        CoreAudioHelper.readArray(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).count
    }

    /// Выключить для IOProc входы подустройства (`kAudioDevicePropertyIOProcStreamUsage`); до `AudioDeviceStart`.
    /// false — не вышло (раскладка ещё не собрана или HAL отказал); тогда в колбэке всё равно берётся только перехват.
    static func disableSubdeviceInputs(aggregate: AudioObjectID, procID: AudioDeviceIOProcID, subdeviceInputs: Int) -> Bool {
        guard let usage = inputStreamUsage(aggregateInputs: inputStreamCount(aggregate), subdeviceInputs: subdeviceInputs) else { return false }
        // Входов у подустройства нет — выключать нечего.
        guard usage.count > 1 else { return true }
        let flags = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = flags + usage.count * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(usage.count), toByteOffset: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams)!,
                       as: UInt32.self)
        for (index, on) in usage.enumerated() {
            raw.storeBytes(of: on ? 1 : 0, toByteOffset: flags + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        var address = CoreAudioHelper.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        return AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), raw) == noErr
    }
}

/// Приложение, которое сейчас выводит звук (вместе со вспомогательными процессами:
/// у Safari и Chrome звук идёт из отдельных процессов).
struct AudioApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let icon: NSImage
    /// Объекты процессов Core Audio, звук которых относится к приложению.
    let processObjects: [AudioObjectID]
    let isPlaying: Bool

    var id: String { bundleID }

    static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.bundleID == b.bundleID && a.processObjects == b.processObjects && a.isPlaying == b.isPlaying
    }
}

@MainActor
enum AudioProcesses {
    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t

    /// Закрытая функция: «главный» процесс для вспомогательного (WebContent → Safari).
    private static let responsible: ResponsibleFor? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFor.self)
    }()

    /// Приложения со звуком; `including` — ещё и те, что сейчас молчат, но настроены.
    static func list(including configured: Set<String> = []) -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var groups: [String: (app: NSRunningApplication?, name: String, objects: [AudioObjectID], playing: Bool)] = [:]
        for object in CoreAudioHelper.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            let pid: pid_t = CoreAudioHelper.read(object, kAudioProcessPropertyPID, default: -1)
            guard pid > 0, pid != ownPID else { continue }
            let running: UInt32 = CoreAudioHelper.read(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            let ownerPID = responsible?(pid) ?? pid
            let owner = NSRunningApplication(processIdentifier: ownerPID > 0 ? ownerPID : pid)
                ?? NSRunningApplication(processIdentifier: pid)
            // Пустой bundle id (у консольных программ) считаем отсутствующим.
            let ownBundleID = CoreAudioHelper.readString(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            let bundleID = owner?.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
                ?? ownBundleID
                ?? "pid.\(pid)"
            guard bundleID != Bundle.main.bundleIdentifier else { continue }
            let name = owner?.localizedName.flatMap { $0.isEmpty ? nil : $0 }
                ?? (bundleID.hasPrefix("pid.") ? (ProcessInfo.processName(pid) ?? bundleID) : bundleID)
            var group = groups[bundleID] ?? (owner, name, [], false)
            group.objects.append(object)
            group.playing = group.playing || running != 0
            groups[bundleID] = group
        }
        return groups.compactMap { bundleID, group -> AudioApp? in
            guard group.playing || configured.contains(bundleID) else { return nil }
            let icon = group.app?.icon ?? NSWorkspace.shared.icon(for: .application)
            return AudioApp(bundleID: bundleID, name: group.name, icon: icon,
                            processObjects: group.objects.sorted(), isPlaying: group.playing)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension ProcessInfo {
    /// Имя процесса по pid (для консольных программ без приложения).
    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }
}

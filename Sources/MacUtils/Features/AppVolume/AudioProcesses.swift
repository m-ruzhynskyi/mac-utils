import AppKit
import CoreAudio

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

    static func readArray(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
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

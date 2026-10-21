import AVFoundation
import AppKit
import CoreAudio

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// Процесс, звук которого может попасть в трансляцию.
struct ShareAudioProcess: Equatable {
    /// Объект процесса Core Audio (0 — процесс из списка ScreenCaptureKit).
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    /// Программа, «ответственная» за процесс (Discord для Discord Helper); nil — не узнали.
    let ownerBundleID: String?
}

/// Что не передавать в трансляцию: заглушённые программы вместе с их помощниками и сам Mac Utils.
/// Звук звонка Discord играет не сама программа, а `com.hnc.Discord.helper*` без окон — ScreenCaptureKit
/// таких процессов в списке программ не знает, поэтому исключаем по процессам Core Audio.
enum ShareAudioExclusion {
    /// Программы звонков для «Не передавать звонки»: иначе собеседник слышит себя с задержкой.
    static let callApps: [String] = [
        "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary",
        "ru.keepcoder.Telegram", "com.tdesktop.Telegram", "com.viber.osx", "net.whatsapp.WhatsApp", "desktop.WhatsApp",
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.skype.skype", "com.tinyspeck.slackmacgap",
        "com.apple.FaceTime", "com.apple.avconferenced",
    ]

    /// Заглушённые bundle id: выбранные вручную и, если включено, программы звонков.
    static func muted(apps: Set<String>, calls: Bool) -> Set<String> {
        calls ? apps.union(callApps) : apps
    }

    static var currentMuted: Set<String> {
        muted(apps: Set(UserDefaults.standard.stringArray(forKey: Pref.shareMutedApps) ?? []),
              calls: UserDefaults.standard.bool(forKey: Pref.shareMuteCalls))
    }

    /// Совпадение по bundle id: сама программа или её помощник (`com.hnc.Discord.helper`), но не другая
    /// программа с тем же началом (`com.hnc.DiscordPTB` — не Discord).
    static func matches(_ bundleID: String?, _ muted: Set<String>) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return muted.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    static func excluded(_ processes: [ShareAudioProcess], muted: Set<String>, ownPID: pid_t,
                         ownBundleID: String? = Bundle.main.bundleIdentifier) -> [ShareAudioProcess] {
        let own: Set<String> = ownBundleID.map { [$0] } ?? []
        return processes.filter { process in
            process.pid == ownPID || matches(process.bundleID, own) || matches(process.ownerBundleID, own)
                || matches(process.bundleID, muted) || matches(process.ownerBundleID, muted)
        }
    }

    /// Программа, отвечающая за процесс (`responsibility_get_pid_responsible_for_pid`), — её bundle id.
    static func ownerBundleID(of pid: pid_t) -> String? {
        let owner = responsibility_get_pid_responsible_for_pid(pid)
        guard owner > 0, owner != pid else { return nil }
        return NSRunningApplication(processIdentifier: owner)?.bundleIdentifier
    }

    /// Все процессы, которые сейчас открыли звук в Core Audio (с помощниками и системными службами).
    static func audioProcesses() -> [ShareAudioProcess] {
        CoreAudioHelper.readArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).compactMap { object in
            let pid: pid_t = CoreAudioHelper.read(object, kAudioProcessPropertyPID, default: -1)
            guard pid > 0 else { return nil }
            let bundleID = CoreAudioHelper.readString(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
                ?? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            return ShareAudioProcess(object: object, pid: pid, bundleID: bundleID, ownerBundleID: ownerBundleID(of: pid))
        }
    }

    /// Строка для журнала: только число и bundle id (это не личные данные).
    static func summary(_ excluded: [ShareAudioProcess]) -> String {
        let ids = Set(excluded.map { $0.bundleID ?? "pid" }).sorted()
        return "\(excluded.count): \(ids.joined(separator: ", "))"
    }
}

/// Когда пересобирать список исключённых: программа запустилась или закрылась, процесс открыл или закрыл звук
/// (так начинается звонок — голос Discord появляется в отдельном процессе уже после старта трансляции),
/// сменился выход звука (перехват пересобирается на часах нового устройства).
/// Без опроса: только события, и только пока идёт трансляция со звуком.
@MainActor
final class ShareAudioWatcher {
    private let workspace: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var scheduled = false
    private let onChange: @MainActor () -> Void

    init(workspace: NotificationCenter = NSWorkspace.shared.notificationCenter, coreAudio: Bool = true,
         onChange: @escaping @MainActor () -> Void) {
        self.workspace = workspace
        self.onChange = onChange
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        guard coreAudio else { return }
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.schedule() }
            }
            var address = CoreAudioHelper.address(selector)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
                listeners.append((selector, listener))
            }
        }
    }

    /// Снять подписки (до освобождения: блок Core Audio держит систему, а не нас).
    func stop() {
        for observer in observers { workspace.removeObserver(observer) }
        observers = []
        for (selector, listener) in listeners {
            var address = CoreAudioHelper.address(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        listeners = []
    }

    /// Пачка событий (запуск программы — сразу несколько процессов) — одна пересборка.
    private func schedule() {
        guard !scheduled, !observers.isEmpty else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scheduled = false
                if !self.observers.isEmpty { self.onChange() }
            }
        }
    }
}

/// Звук системы для трансляции через Core Audio process tap (macOS 14.2+): весь вывод, кроме исключённых
/// процессов, моно; на выходе — тот же формат, что и у ScreenCaptureKit (24 кГц, Float → Int16 в пакете).
@available(macOS 14.2, *)
final class ShareAudioTap: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var uuid = UUID()
    private let queue = DispatchQueue(label: "macutils.share.tap", qos: .userInteractive)
    private let onSamples: @Sendable ([Float]) -> Void
    private var converter: AVAudioConverter?
    private let output = AVAudioFormat(standardFormatWithSampleRate: ShareProtocol.sampleRate, channels: 1)!
    /// Пик входа с прошлого чтения: пишется в `queue`, читается из главного потока (Float — без разрывов).
    private let peak = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var excluded: [AudioObjectID]
    /// Выход, на часах которого собран агрегат.
    private(set) var outputDevice = AudioObjectID(kAudioObjectUnknown)
    /// Буфер перехвата во входе агрегата (`AggregateStreams`); nil — не нашли, звук не передаём (но не микрофон).
    private var tapBuffer: Int?

    init(excluding objects: [AudioObjectID], onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        excluded = objects
        self.onSamples = onSamples
        peak.initialize(to: 0)
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
        peak.deallocate()
    }

    func takePeak() -> Float {
        let value = peak.pointee
        peak.pointee = 0
        return value
    }

    private func description(_ objects: [AudioObjectID]) -> CATapDescription {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: objects)
        description.uuid = uuid
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Mac Utils — трансляция"
        return description
    }

    private func start() throws {
        uuid = UUID()
        outputDevice = CoreAudioHelper.defaultOutputDevice
        var status = AudioHardwareCreateProcessTap(description(excluded), &tapID)
        guard status == noErr else { throw AppVolumeTap.TapError.status("Перехват звука", status) }
        var format = CoreAudioHelper.read(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        guard format.mSampleRate > 0, let input = AVAudioFormat(streamDescription: &format) else {
            throw AppVolumeTap.TapError.status("Формат перехвата", -1)
        }
        converter = AVAudioConverter(from: input, to: output)
        // Часы агрегата — от текущего выхода; сам выход не трогаем (пишем тишину).
        guard let outputUID = CoreAudioHelper.readString(outputDevice, kAudioDevicePropertyDeviceUID) else {
            throw AppVolumeTap.TapError.status("Устройство вывода", -1)
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mac Utils Share",
            kAudioAggregateDeviceUIDKey: "com.mruzhynskyi.macutils.share.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else { throw AppVolumeTap.TapError.status("Агрегатное устройство", status) }
        // Первым входом агрегата может быть микрофон выхода (USB-гарнитура): буфер перехвата — по его месту.
        tapBuffer = AggregateStreams.tapBufferIndex(aggregate: aggregateID, subdevices: [outputDevice])
        if tapBuffer == nil {
            Log.capture.error("Звук трансляции: поток перехвата среди входов агрегата не найден — звук не передаётся")
        }
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, outputData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            self?.convert(inputData, format: input)
        }
        guard status == noErr, procID != nil else { throw AppVolumeTap.TapError.status("Обработчик звука", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw AppVolumeTap.TapError.status("Запуск перехвата", status) }
    }

    /// Выход сменился — тот же перехват (с тем же списком исключённых) на часах нового устройства.
    func restart() throws {
        stop()
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    /// Новый список исключённых — на лету, тем же перехватом (без разрыва звука).
    func update(excluding objects: [AudioObjectID]) throws {
        guard objects != excluded else { return }
        var address = CoreAudioHelper.address(kAudioTapPropertyDescription)
        var value = description(objects)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == noErr else { throw AppVolumeTap.TapError.status("Список исключённых", status) }
        excluded = objects
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

    /// Вызывается в `queue`: вход перехвата → 24 кГц моно. Берётся только буфер перехвата, не весь вход агрегата.
    private func convert(_ inputData: UnsafePointer<AudioBufferList>, format: AVAudioFormat) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let tapBuffer, tapBuffer < list.count, list[tapBuffer].mDataByteSize > 0, let converter else { return }
        var single = AudioBufferList(mNumberBuffers: 1, mBuffers: list[tapBuffer])
        let frames = AVAudioFrameCount(single.mBuffers.mDataByteSize / max(1, format.streamDescription.pointee.mBytesPerFrame))
        let capacity = AVAudioFrameCount(Double(frames) * output.sampleRate / format.sampleRate) + 16
        guard frames > 0, let result = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        // Буфер без копии живёт, пока жив указатель на `single`, — вся конвертация внутри.
        withUnsafeMutablePointer(to: &single) { pointer in
            guard let source = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: pointer, deallocator: nil) else { return }
            source.frameLength = frames
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
        }
        guard result.frameLength > 0, let channel = result.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(result.frameLength)))
        var maximum: Float = 0
        for sample in samples { maximum = max(maximum, abs(sample)) }
        peak.pointee = max(peak.pointee, maximum)
        onSamples(samples)
    }
}

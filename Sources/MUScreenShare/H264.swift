import AVFoundation
import AppKit
import SwiftUI
import VideoToolbox
import MUCore

/// Трансляция видео H.264 (аппаратный кодек, как в Discord): передаются только изменения,
/// поэтому процессор и сеть нагружены в разы меньше, чем кадрами JPEG.
/// Пакет: [3][флаги: 1 — ключевой кадр][Annex B: 00 00 00 01 + NAL …].
package enum H264Packet {
    package static let type: UInt8 = 3

    /// AVCC (длина + NAL) → Annex B (стартовый код + NAL); у ключевого кадра впереди SPS и PPS.
    package static func annexB(from sample: CMSampleBuffer) -> (data: Data, key: Bool)? {
        guard let block = sample.dataBuffer, let format = sample.formatDescription else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        if key {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                      parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                      nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    out.append(contentsOf: start)
                    out.append(pointer, count: size)
                }
            }
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr, let pointer else { return nil }
        var offset = 0
        while offset + 4 <= length {
            var nalLength: UInt32 = 0
            memcpy(&nalLength, pointer + offset, 4)
            nalLength = CFSwapInt32BigToHost(nalLength)
            offset += 4
            guard offset + Int(nalLength) <= length else { break }
            out.append(contentsOf: start)
            out.append(Data(bytes: pointer + offset, count: Int(nalLength)))
            offset += Int(nalLength)
        }
        return (out, key)
    }

    /// Annex B → NAL-блоки без стартовых кодов.
    package static func units(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var index = 0
        var start: Int?
        while index + 3 <= bytes.count {
            let three = bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1
            let four = index + 4 <= bytes.count && bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 0 && bytes[index + 3] == 1
            if three || four {
                if let start { units.append(Data(bytes[start..<index])) }
                index += four ? 4 : 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count { units.append(Data(bytes[start...])) }
        return units.filter { !$0.isEmpty }
    }
}

/// Параметры видео трансляции Mac-ведущего: размер, скорость, ключевые кадры (чистые функции — для тестов).
package enum ShareVideo {
    /// Не больше 1920 точек по длинной стороне: текст на экране читаем, поток по силам сети.
    package static let maxDimension: CGFloat = 1920
    package static let minBitrate = 700_000
    package static let startBitrate = 6_000_000
    package static let maxBitrate = 12_000_000
    /// Целевая частота: 60 кадров/с; при перегрузке — `reducedFrameRate` (см. `ShareRateGovernor`).
    package static let frameRate = 60
    package static let reducedFrameRate = 30
    /// Сглаженная скорость (EMA ~2,5 с) дольше 3 с ниже этого — 60 кадров/с не держим: на 30 кадрах/с биты идут
    /// на качество, а не на частоту. Вернуться на 60 можно, когда сглаженная скорость не ниже `fullRateRecoverBitrate`.
    /// Числа — по модели канала (ведро + адаптация как в коде, 180 с): на 8 Мбит/с ~70% времени на 60, на 4–6 — 30
    /// почти всё время (без «пилы»), на 10 и выше — 60.
    package static let fullRateMinBitrate = 5_000_000
    package static let fullRateRecoverBitrate = 6_000_000
    /// Ключевой кадр — не реже раза в ~4 с: новый зритель и потерянный кадр восстанавливаются быстро.
    package static let keyFrameSeconds = 4
    /// Самый крупный кадр, байт: ретранслятор (Cloudflare) пересылает сообщения WebSocket до 1 МиБ — с запасом.
    package static let maxFrameBytes = 700_000

    /// Размер потока по размеру захватываемой области в пикселях: пропорции сохраняются, стороны чётные (нужно H.264).
    package static func streamSize(pixelWidth: CGFloat, pixelHeight: CGFloat) -> (width: Int, height: Int) {
        let scale = min(1, maxDimension / max(pixelWidth, 1), maxDimension / max(pixelHeight, 1))
        return (max(2, Int(pixelWidth * scale) / 2 * 2), max(2, Int(pixelHeight * scale) / 2 * 2))
    }

    /// Окно изменило размер (точки, `scale` — пикселей на точку): новый размер потока, если он заметно другой.
    /// Разница в 2 пикселя — округление, поток не трогаем.
    package static func resizedStreamSize(current: (width: Int, height: Int), window: CGSize, scale: CGFloat) -> (width: Int, height: Int)? {
        guard window.width >= 1, window.height >= 1 else { return nil }
        let size = streamSize(pixelWidth: window.width * scale, pixelHeight: window.height * scale)
        return abs(size.width - current.width) > 2 || abs(size.height - current.height) > 2 ? size : nil
    }

    /// `DataRateLimits` (пары «байт, секунд»): в среднем не больше 1,5× скорости за секунду (без всплесков,
    /// которые забивают сеть), и ни один кадр не больше `maxFrameBytes` (короткое окно 0,1 с).
    package static func dataRateLimits(bitrate: Int) -> [Double] {
        [Double(bitrate * 3 / 2 / 8), 1, Double(maxFrameBytes), 0.1]
    }

    /// Профиль: High лучше сохраняет мелкий текст при той же скорости — только у аппаратного кодера
    /// (программный High медленный); иначе Main, как раньше.
    package static func profile(hardware: Bool) -> CFString {
        hardware ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel
    }

    /// Подстройка скорости под сеть (как в Discord): очередь неотправленного растёт — снижаем, свободно — поднимаем.
    /// Пороги очереди растут вместе со скоростью: на 8 Мбит/с один ключевой кадр уже больше прежних 250 КБ.
    /// nil — оставить как есть.
    package static func adaptedBitrate(current: Int, pendingBytes: Int, secondsSinceLast: TimeInterval) -> Int? {
        let high = max(250_000, current / 8 / 2)   // больше ~0,5 с данных в очереди (на 4 Мбит/с — прежние 250 КБ)
        let low = max(60_000, current / 8 / 8)     // меньше ~1/8 с
        if pendingBytes > high, secondsSinceLast > 0.5 {
            return max(minBitrate, current * 7 / 10)
        }
        if pendingBytes < low, secondsSinceLast > 2, current < maxBitrate {
            return min(maxBitrate, current * 23 / 20)
        }
        return nil
    }
}

/// Частота кадров под нагрузку: 60 → 30 при перегрузке (очередь в сокете, кодер не успевает, скорость упала ниже
/// `fullRateMinBitrate`), обратно — после спокойного окна. Если перегрузка повторяется скоро после возврата,
/// окно удваивается (8 → 16 → 32 → 60 с), чтобы не мигать между режимами. Время — секунды, чистая логика для тестов.
package struct ShareRateGovernor {
    package static let baseHold: TimeInterval = 8
    package static let maxHold: TimeInterval = 60
    package private(set) var fps = ShareVideo.frameRate
    private var hold = baseHold
    private var lastTrouble = -TimeInterval.infinity
    private var lastRestored = -TimeInterval.infinity
    private var lastEncoded = -TimeInterval.infinity
    private var graceUntil = -TimeInterval.infinity
    private var ema: Double?
    private var lastSample = -TimeInterval.infinity
    private var lowSince: TimeInterval?
    package static let warmUpSeconds: TimeInterval = 2
    package static let lowSeconds: TimeInterval = 3
    package static let emaSeconds: TimeInterval = 2.5

    /// Старт, переподключение, новая сессия кодера: он прогревается, очередь тогда не считается перегрузкой.
    package mutating func warmUp(now: TimeInterval) { graceUntil = now + Self.warmUpSeconds }

    /// Выборка текущей скорости кодера (на каждый отправленный кадр). Перегрузка — сглаженная скорость ниже порога
    /// дольше `lowSeconds`. Возвращает true, если режим сменился на пониженный.
    @discardableResult
    package mutating func bitrateSample(_ bitrate: Int, now: TimeInterval) -> Bool {
        let value = Double(bitrate)
        if let current = ema {
            let alpha = 1 - exp(-max(0, now - lastSample) / Self.emaSeconds)
            ema = current + (value - current) * alpha
        } else { ema = value }
        lastSample = now
        guard let smooth = ema, smooth < Double(ShareVideo.fullRateMinBitrate) else { lowSince = nil; return false }
        let since = lowSince ?? now
        lowSince = since
        return now - since > Self.lowSeconds ? congested(now: now) : false
    }

    /// Перегрузка. Возвращает true, если режим сменился на пониженный.
    @discardableResult
    package mutating func congested(now: TimeInterval) -> Bool {
        guard now >= graceUntil else { return false }
        lastTrouble = now
        guard fps == ShareVideo.frameRate else { return false }
        hold = now - lastRestored < 30 ? min(Self.maxHold, hold * 2) : Self.baseHold
        fps = ShareVideo.reducedFrameRate
        return true
    }

    /// Всё спокойно. Возвращает true, если вернулись к полной частоте.
    @discardableResult
    package mutating func calm(now: TimeInterval) -> Bool {
        guard fps != ShareVideo.frameRate, now - lastTrouble >= hold,
              (ema ?? .infinity) >= Double(ShareVideo.fullRateRecoverBitrate) else { return false }
        fps = ShareVideo.frameRate
        lastRestored = now
        return true
    }

    /// Кодировать ли кадр с этой меткой (секунды): в пониженном режиме — каждый второй, по времени, а не по счёту.
    package mutating func shouldEncode(at time: TimeInterval) -> Bool {
        if fps == ShareVideo.frameRate { return true }
        guard time - lastEncoded >= 0.025 else { return false }
        lastEncoded = time
        return true
    }
}

/// Статистика видео ведущего для журнала: раз в минуту — частота, скорость, ключевые (всего и по просьбе), перегрузки,
/// сигналы зрителей «не успеваю», пропуски. Только числа. Время — секунды, чистая логика для тестов.
package struct ShareVideoStats: Equatable {
    package static let interval: TimeInterval = 60
    package var frames = 0, bytes = 0, keys = 0
    package var keyRequests = 0, congestion = 0, viewerSlow = 0, skipped = 0
    private var since: TimeInterval

    package init(now: TimeInterval) { since = now }

    package mutating func sent(bytes count: Int, key: Bool) {
        frames += 1
        bytes += count
        if key { keys += 1 }
    }

    /// Прошла минута — строка для журнала и новый отсчёт; иначе nil.
    package mutating func line(now: TimeInterval, fps: Int, bitrate: Int, mode: String?) -> String? {
        let seconds = now - since
        guard seconds >= Self.interval else { return nil }
        let line = "Трансляция: видео за \(Int(seconds.rounded())) с — кадров \(frames) (\(Int((Double(frames) / seconds).rounded())) в с), "
            + "передано \(Int((Double(bytes) * 8 / seconds / 1000).rounded())) кбит/с, кодер \(bitrate / 1000) кбит/с, режим \(fps) кадров/с \(mode ?? "-"), "
            + "ключевых \(keys), по просьбе \(keyRequests), перегрузок \(congestion), зритель не успевает \(viewerSlow), пропущено \(skipped)"
        self = ShareVideoStats(now: now)
        return line
    }
}

/// Аппаратное кодирование кадров экрана в H.264.
package final class H264Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var size: (Int32, Int32) = (0, 0)
    private var forceKey = true
    private let onPacket: (Data, Bool) -> Void

    package init(onPacket: @escaping (Data, Bool) -> Void) {
        self.onPacket = onPacket
    }

    package func requestKeyFrame() { forceKey = true }

    /// Кадры, отданные кодеру и ещё не вернувшиеся: растёт — кодер не успевает.
    private let flightLock = NSLock()
    private var flight = 0
    package var inFlight: Int { flightLock.lock(); defer { flightLock.unlock() }; return flight }
    private func flightChanged(_ delta: Int) { flightLock.lock(); flight += delta; flightLock.unlock() }

    /// Ожидаемая частота (подсказка кодеру для распределения скорости).
    package private(set) var frameRate = ShareVideo.frameRate
    /// Новая сессия кодера создана (первый кадр, смена размера): прогрев.
    package var onSession: (() -> Void)?
    package func setFrameRate(_ value: Int) {
        frameRate = value
        if let session { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: value as CFTypeRef) }
    }

    /// Скорость потока, бит/с: подстраивается под сеть (см. FrameSender).
    package private(set) var bitrate = ShareVideo.startBitrate
    /// Выбранный профиль (для журнала и проверки): High при аппаратном кодере, иначе Main.
    package private(set) var profile: CFString?
    /// Сессия кодирует аппаратно (видеокарта / медиадвижок); nil — сессии ещё нет. Для подписи у зрителей.
    package var usesHardware: Bool? { flightLock.lock(); defer { flightLock.unlock() }; return hardwareFlag }
    private var hardwareFlag: Bool?

    package func setBitrate(_ value: Int) {
        guard value != bitrate else { return }
        bitrate = value
        if let session { Self.applyBitrate(value, to: session) }
    }

    private static func applyBitrate(_ value: Int, to session: VTCompressionSession) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: value as CFTypeRef)
        // Жёсткие пределы: без всплесков, которые забивают сеть и копят задержку, и без кадров крупнее предела relay.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: ShareVideo.dataRateLimits(bitrate: value) as CFArray)
    }

    /// false — кадр не принят: кодер отстаёт больше чем на `maxInFlight` кадров (кадр пропущен, не копим задержку).
    @discardableResult
    package func encode(_ pixels: CVPixelBuffer, at time: CMTime) -> Bool {
        let width = Int32(CVPixelBufferGetWidth(pixels)), height = Int32(CVPixelBufferGetHeight(pixels))
        if session == nil || size != (width, height) { makeSession(width: width, height: height) }
        guard let session else { return false }
        guard inFlight < Self.maxInFlight || forceKey else { return false }
        let options: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        flightChanged(1)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            self?.flightChanged(-1)
            guard status == noErr, let sample, let packet = H264Packet.annexB(from: sample) else { return }
            self?.onPacket(packet.data, packet.key)
        }
        return true
    }

    package static let maxInFlight = 4

    private func makeSession(width: Int32, height: Int32) {
        invalidate()
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr,
              let created else { return }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: ShareVideo.frameRate * ShareVideo.keyFrameSeconds,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: ShareVideo.keyFrameSeconds,
            // Кадр уходит сразу, без очереди внутри кодека.
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
        ]
        for (key, value) in properties { VTSessionSetProperty(created, key: key, value: value as CFTypeRef) }
        // High — только если кодек аппаратный и принял профиль; иначе Main (как раньше). Зрители (страница, Windows,
        // Mac) берут профиль из SPS в потоке, их настраивать не нужно.
        let usingHardware = UnsafeMutablePointer<CFTypeRef?>.allocate(capacity: 1)
        usingHardware.initialize(to: nil)
        defer { usingHardware.deinitialize(count: 1); usingHardware.deallocate() }
        let hardware = VTSessionCopyProperty(created, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                             allocator: nil, valueOut: usingHardware) == noErr
            && (usingHardware.pointee as? Bool) == true
        var chosen = ShareVideo.profile(hardware: hardware)
        if VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: chosen) != noErr {
            chosen = kVTProfileLevel_H264_Main_AutoLevel
            VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: chosen)
        }
        profile = chosen
        flightLock.lock(); hardwareFlag = hardware; flightLock.unlock()
        Log.capture.info("Трансляция: H.264 \(width)×\(height), \(hardware ? "аппаратно" : "программно", privacy: .public), профиль \(chosen == kVTProfileLevel_H264_High_AutoLevel ? "High" : "Main", privacy: .public)")
        Self.applyBitrate(bitrate, to: created)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        size = (width, height)
        forceKey = true
        onSession?()
    }

    package func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    deinit { invalidate() }
}

/// Показ H.264 у зрителя: AVSampleBufferDisplayLayer декодирует аппаратно. Пакеты разбираются и попадают в слой
/// на своей последовательной очереди — главный поток (интерфейс, другие окна) не влияет на плавность.
/// `size` публикуется на главном потоке.
package final class H264Player: ObservableObject, @unchecked Sendable {
    package let layer = AVSampleBufferDisplayLayer()
    @Published package private(set) var size: CGSize?
    private let queue = DispatchQueue(label: "macutils.share.video", qos: .userInteractive)
    // Состояние разбора — только на `queue`.
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    /// Сокет, чьи пакеты показываем: пакеты оборванного соединения отбрасываются.
    private let sourceLock = NSLock()
    private var source: AnyObject?
    /// Что пришло с начала просмотра (для журнала, когда картинки нет): пакеты, ключевые, ключевые с SPS и PPS.
    package struct Received: Equatable { var packets = 0, keys = 0, withParameterSets = 0 }
    private var counts = Received()
    /// Пакеты, принятые к разбору и ещё не разобранные. Больше `limit` — новые отбрасываются до ключевого кадра:
    /// декодер или показ отстали (окно свёрнуто, Mac занят), и очередь не должна расти, пока не кончится память.
    private let pendingLock = NSLock()
    private var pending = 0
    private let limit: Int
    /// Кадры пропущены (очередь, слой не готов): дальше — только с ключевого, иначе картинка рассыпается. Только на `queue`.
    private var waitingForKey = false
    /// Сколько пакетов отброшено (для журнала и стендов).
    package private(set) var dropped = 0
    /// Пропускаем до ключевого — попросить его у ведущего сразу (`video-trouble`), не ждать планового (раз в 4 с).
    /// Вызывается на `queue`, не чаще раза в `keyAskInterval`. Задаётся до начала просмотра.
    package var onNeedKey: (() -> Void)?
    package static let keyAskInterval: TimeInterval = 1
    private var lastKeyAsk = -TimeInterval.infinity
    package private(set) var keyAsks = 0
    /// Вызывается на `queue`.
    private func askKey(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard now - lastKeyAsk >= Self.keyAskInterval else { return }
        lastKeyAsk = now
        keyAsks += 1
        onNeedKey?()
    }

    /// ≈ 1 с видео при 60 кадрах в секунду.
    package static let defaultLimit = 60

    package init(limit: Int = H264Player.defaultLimit) {
        self.limit = limit
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    /// Показывать пакеты этого соединения (nil — никакого). Последний кадр остаётся на экране.
    package func attach(_ socket: AnyObject?) {
        sourceLock.lock()
        source = socket
        sourceLock.unlock()
    }

    /// Новый просмотр: убрать картинку и формат. Вызывается с главного потока.
    package func reset() {
        size = nil
        queue.async {
            self.layer.flushAndRemoveImage()
            self.format = nil
            self.counts = Received()
        }
    }

    /// Счётчики пакетов с начала просмотра; `done` — на главном потоке.
    package func received(_ done: @escaping @MainActor (Received) -> Void) {
        queue.async {
            let counts = self.counts
            DispatchQueue.main.async { MainActor.assumeIsolated { done(counts) } }
        }
    }

    /// Пакет видео от `socket` (с любого потока): разбор и показ — на очереди проигрывателя.
    package func play(_ payload: Data, from socket: AnyObject) {
        sourceLock.lock()
        let current = source === socket
        sourceLock.unlock()
        guard current else { return }
        pendingLock.lock()
        let full = pending >= limit
        if !full { pending += 1 }
        pendingLock.unlock()
        guard !full else {
            queue.async { self.waitingForKey = true; self.dropped += 1; self.askKey() }
            return
        }
        queue.async {
            self.decodeAndShow(payload)
            self.pendingLock.lock()
            self.pending -= 1
            self.pendingLock.unlock()
        }
    }

    /// Вызывается на `queue`.
    private func decodeAndShow(_ payload: Data) {
        guard payload.count > 1 else { return }
        let key = payload.first == 1
        counts.packets += 1
        if key { counts.keys += 1 }
        // Слой не успевает (не показывается, декодер отстал): не копим кадры в нём, ждём ключевой.
        if !layer.isReadyForMoreMediaData {
            waitingForKey = true
            dropped += 1
            askKey()
            return
        }
        if waitingForKey {
            guard key else { dropped += 1; askKey(); return }
            waitingForKey = false
            layer.flush()
        }
        let units = H264Packet.units(payload.dropFirst())
        var frame: [Data] = []
        var sets = 0
        for unit in units {
            switch unit[unit.startIndex] & 0x1F {
            case 7: sps = unit; sets |= 1
            case 8: pps = unit; sets |= 2
            default: frame.append(unit)
            }
        }
        if sets == 3 { counts.withParameterSets += 1 }
        if let sps, let pps, format == nil || key { makeFormat(sps: sps, pps: pps) }
        guard let format, !frame.isEmpty else { return }
        // Annex B → AVCC (4 байта длины перед каждым NAL).
        var avcc = Data()
        for unit in frame {
            var length = CFSwapInt32HostToBig(UInt32(unit.count))
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(unit)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?
        var sampleSize = avcc.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        // `enqueue` можно звать с отдельной последовательной очереди (не обязательно с главной).
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }

    /// Вызывается на `queue`.
    private func makeFormat(sps: Data, pps: Data) {
        var created: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                                                                           parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &created)
            }
        }
        guard status == noErr, let created else { return }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: created) { return }
        format = created
        let dimensions = CMVideoFormatDescriptionGetDimensions(created)
        let newSize = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
        DispatchQueue.main.async { if self.size != newSize { self.size = newSize } }
    }
}

/// Слой видео в SwiftUI.
package struct H264View: NSViewRepresentable {
    package let player: H264Player

    package func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        player.layer.frame = view.bounds
        player.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(player.layer)
        return view
    }

    package func updateNSView(_ view: NSView, context: Context) {
        player.layer.frame = view.bounds
    }
}

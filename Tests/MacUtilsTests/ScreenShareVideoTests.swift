import CoreVideo
import VideoToolbox
import XCTest
@testable import MacUtils
@testable import MUScreenShare

/// Качество трансляции Mac-ведущего: размер потока, скорость и её подстройка, профиль, показ у зрителя вне главного потока.
final class ScreenShareVideoTests: XCTestCase {
    // MARK: - Размер потока

    func testStreamSizeCapsLongSideAt1920KeepingAspect() {
        // Retina 3024×1964 (MacBook Pro 14") → 1920 по ширине.
        let size = ShareVideo.streamSize(pixelWidth: 3024, pixelHeight: 1964)
        XCTAssertEqual(size.width, 1920)
        XCTAssertEqual(size.height, 1246)
        XCTAssertEqual(Double(size.width) / Double(size.height), 3024.0 / 1964.0, accuracy: 0.01)
        // 5K 5120×2880 → 1920×1080.
        let fiveK = ShareVideo.streamSize(pixelWidth: 5120, pixelHeight: 2880)
        XCTAssertEqual(fiveK.width, 1920)
        XCTAssertEqual(fiveK.height, 1080)
    }

    func testStreamSizeIsAlwaysEven() {
        for (w, h) in [(3456.0, 2234.0), (2559.0, 1599.0), (1001.0, 777.0), (3.0, 3.0), (1921.0, 1081.0)] {
            let size = ShareVideo.streamSize(pixelWidth: w, pixelHeight: h)
            XCTAssertEqual(size.width % 2, 0, "\(w)×\(h)")
            XCTAssertEqual(size.height % 2, 0, "\(w)×\(h)")
            XCTAssertGreaterThanOrEqual(size.width, 2)
            XCTAssertGreaterThanOrEqual(size.height, 2)
            XCTAssertLessThanOrEqual(size.width, 1920)
            XCTAssertLessThanOrEqual(size.height, 1920)
        }
    }

    func testStreamSizeDoesNotUpscaleSmallAreas() {
        let window = ShareVideo.streamSize(pixelWidth: 1280, pixelHeight: 800)
        XCTAssertEqual(window.width, 1280)
        XCTAssertEqual(window.height, 800)
        let full = ShareVideo.streamSize(pixelWidth: 1920, pixelHeight: 1080)
        XCTAssertEqual(full.width, 1920)
        XCTAssertEqual(full.height, 1080)
    }

    func testPortraitScreenLimitsHeight() {
        // Повёрнутый монитор 2160×3840 → по высоте 1920.
        let size = ShareVideo.streamSize(pixelWidth: 2160, pixelHeight: 3840)
        XCTAssertEqual(size.height, 1920)
        XCTAssertEqual(size.width, 1080)
    }

    func testDegenerateSizeDoesNotCrash() {
        let size = ShareVideo.streamSize(pixelWidth: 0, pixelHeight: 0)
        XCTAssertEqual(size.width, 2)
        XCTAssertEqual(size.height, 2)
    }

    // MARK: - Скорость

    func testBitrateRange() {
        XCTAssertEqual(ShareVideo.minBitrate, 700_000)
        XCTAssertEqual(ShareVideo.startBitrate, 6_000_000)
        XCTAssertEqual(ShareVideo.maxBitrate, 12_000_000)
        XCTAssertEqual(ShareVideo.frameRate, 60)
        XCTAssertEqual(ShareVideo.reducedFrameRate, 30)
        XCTAssertEqual(ShareVideo.keyFrameSeconds, 4)
    }

    func testDataRateLimitsFollowBitrateAndCapFrameSize() {
        let limits = ShareVideo.dataRateLimits(bitrate: 4_000_000)
        XCTAssertEqual(limits.count, 4, "пары «байт, секунд»")
        XCTAssertEqual(limits[0], 750_000, "1,5× средней скорости за секунду")
        XCTAssertEqual(limits[1], 1)
        XCTAssertEqual(limits[2], Double(ShareVideo.maxFrameBytes))
        XCTAssertEqual(limits[3], 0.1)
        XCTAssertEqual(ShareVideo.dataRateLimits(bitrate: 8_000_000)[0], 1_500_000)
        XCTAssertLessThan(ShareVideo.maxFrameBytes, 1 << 20, "кадр помещается в сообщение ретранслятора (1 МиБ)")
    }

    func testAdaptLowersWhenQueueGrows() {
        XCTAssertEqual(ShareVideo.adaptedBitrate(current: 4_000_000, pendingBytes: 300_000, secondsSinceLast: 1), 2_800_000)
        XCTAssertNil(ShareVideo.adaptedBitrate(current: 4_000_000, pendingBytes: 300_000, secondsSinceLast: 0.2),
                     "не чаще раза в 0,5 с")
        // Нижний порог прежний.
        XCTAssertEqual(ShareVideo.adaptedBitrate(current: 800_000, pendingBytes: 900_000, secondsSinceLast: 1), 700_000)
        XCTAssertEqual(ShareVideo.adaptedBitrate(current: 700_000, pendingBytes: 900_000, secondsSinceLast: 1), 700_000)
    }

    func testAdaptThresholdScalesWithBitrate() {
        // На 8 Мбит/с один ключевой кадр (~300 КБ) в очереди — не повод снижать: порог ~0,5 с данных.
        XCTAssertNil(ShareVideo.adaptedBitrate(current: 8_000_000, pendingBytes: 300_000, secondsSinceLast: 1))
        XCTAssertEqual(ShareVideo.adaptedBitrate(current: 8_000_000, pendingBytes: 600_000, secondsSinceLast: 1), 5_600_000)
        // На малой скорости порог не ниже прежних 250 КБ.
        XCTAssertNil(ShareVideo.adaptedBitrate(current: 1_000_000, pendingBytes: 200_000, secondsSinceLast: 1))
    }

    func testAdaptRaisesWhenFreeUpToCeiling() {
        XCTAssertEqual(ShareVideo.adaptedBitrate(current: 4_000_000, pendingBytes: 0, secondsSinceLast: 3), 4_600_000)
        XCTAssertNil(ShareVideo.adaptedBitrate(current: 4_000_000, pendingBytes: 0, secondsSinceLast: 1), "не чаще раза в 2 с")
        XCTAssertEqual(ShareVideo.adaptedBitrate(current: 11_000_000, pendingBytes: 0, secondsSinceLast: 3), 12_000_000)
        XCTAssertNil(ShareVideo.adaptedBitrate(current: 12_000_000, pendingBytes: 0, secondsSinceLast: 3), "потолок 12 Мбит/с")
        XCTAssertNil(ShareVideo.adaptedBitrate(current: 4_000_000, pendingBytes: 100_000, secondsSinceLast: 3),
                     "очередь не пуста — держим")
    }

    func testAdaptFromStartReachesCeilingAndFloor() {
        var up = ShareVideo.startBitrate
        while let next = ShareVideo.adaptedBitrate(current: up, pendingBytes: 0, secondsSinceLast: 3) { up = next }
        XCTAssertEqual(up, ShareVideo.maxBitrate)
        var down = ShareVideo.startBitrate
        for _ in 0..<20 { down = ShareVideo.adaptedBitrate(current: down, pendingBytes: 2_000_000, secondsSinceLast: 1) ?? down }
        XCTAssertEqual(down, ShareVideo.minBitrate)
    }

    func testRateGovernorFallsToHalfAndRecovers() {
        var g = ShareRateGovernor()
        XCTAssertEqual(g.fps, 60)
        XCTAssertTrue(g.shouldEncode(at: 0.000))
        XCTAssertTrue(g.shouldEncode(at: 0.0167), "на 60 кадров/с — все кадры")
        XCTAssertTrue(g.congested(now: 100))
        XCTAssertEqual(g.fps, 30)
        // В пониженном режиме проходит каждый второй кадр 60-кадрового входа.
        var passed = 0
        for i in 0..<60 where g.shouldEncode(at: 200 + Double(i) / 60) { passed += 1 }
        XCTAssertEqual(passed, 30)
        XCTAssertFalse(g.calm(now: 105), "окно 8 с ещё не прошло")
        XCTAssertFalse(g.congested(now: 106), "уже на 30")
        XCTAssertFalse(g.calm(now: 110), "перегрузка в 106 — окно считается от неё")
        XCTAssertTrue(g.calm(now: 114.5))
        XCTAssertEqual(g.fps, 60)
    }

    func testRateGovernorBacksOffWhenFlapping() {
        var g = ShareRateGovernor()
        g.congested(now: 0); XCTAssertTrue(g.calm(now: 9))
        g.congested(now: 20)                       // скоро после возврата — окно 16 с
        XCTAssertFalse(g.calm(now: 30))
        XCTAssertTrue(g.calm(now: 36.5))
        g.congested(now: 50)                       // окно 32 с
        XCTAssertFalse(g.calm(now: 80))
        XCTAssertTrue(g.calm(now: 82.5))
        g.congested(now: 400)                      // давно — окно снова 8 с
        XCTAssertTrue(g.calm(now: 408.5))
    }

    func testRateGovernorLowBitrateNeedsSustainedSmoothedLow() {
        var g = ShareRateGovernor()
        for t in stride(from: 0.0, to: 5.0, by: 0.1) { g.bitrateSample(8_000_000, now: t) }
        for t in stride(from: 5.0, to: 7.0, by: 0.1) { XCTAssertFalse(g.bitrateSample(2_000_000, now: t), "короткий провал — не перегрузка") }
        for t in stride(from: 7.0, to: 10.0, by: 0.1) { XCTAssertFalse(g.bitrateSample(8_000_000, now: t)) }
        XCTAssertEqual(g.fps, 60)
        var switched = false
        for t in stride(from: 10.0, to: 20.0, by: 0.1) where g.bitrateSample(2_000_000, now: t) { switched = true }
        XCTAssertTrue(switched, "сглаженная скорость держится ниже порога дольше 3 с")
        XCTAssertEqual(g.fps, 30)
        // На 5,5 Мбит/с (ниже порога возврата) остаёмся на 30 без «пилы».
        for t in stride(from: 20.0, to: 90.0, by: 0.1) { g.bitrateSample(5_500_000, now: t); g.calm(now: t) }
        XCTAssertEqual(g.fps, 30)
        for t in stride(from: 90.0, to: 120.0, by: 0.1) { g.bitrateSample(8_000_000, now: t); g.calm(now: t) }
        XCTAssertEqual(g.fps, 60, "скорость выросла — вернулись")
    }

    func testRateGovernorWarmUpIgnoresCongestion() {
        var g = ShareRateGovernor()
        g.warmUp(now: 0)
        XCTAssertFalse(g.congested(now: 1))
        XCTAssertEqual(g.fps, 60)
        XCTAssertTrue(g.congested(now: 2.1))
    }

    func testProfile() {
        XCTAssertEqual(ShareVideo.profile(hardware: true), kVTProfileLevel_H264_High_AutoLevel)
        XCTAssertEqual(ShareVideo.profile(hardware: false), kVTProfileLevel_H264_Main_AutoLevel)
    }

    // MARK: - Кодер и зритель

    /// Настоящая сессия VideoToolbox принимает пределы скорости (две пары) — иначе кодер молча работал бы без них.
    func testVideoToolboxAcceptsDataRateLimits() throws {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: 1920, height: 1080, codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { throw XCTSkip("H.264-кодер недоступен") }
        defer { VTCompressionSessionInvalidate(session) }
        let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                                          value: ShareVideo.dataRateLimits(bitrate: ShareVideo.maxBitrate) as CFArray)
        XCTAssertEqual(status, noErr)
    }

    /// Кадр 1920×1080 кодируется (High на аппаратном кодере, иначе Main) и показывается зрителем Mac;
    /// пакеты чужого (оборванного) соединения отбрасываются.
    func testEncodedFrameDecodesInViewer() throws {
        var pixels: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA, attrs, &pixels) == kCVReturnSuccess,
              let pixels else { throw XCTSkip("нет буфера") }
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 0x80, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])

        let got = expectation(description: "ключевой кадр")
        let lock = NSLock()
        var keyPacket: Data?
        let encoder = H264Encoder { data, key in
            lock.lock(); defer { lock.unlock() }
            if key, keyPacket == nil { keyPacket = data; got.fulfill() }
        }
        encoder.requestKeyFrame()
        encoder.encode(pixels, at: CMTime(value: 0, timescale: 30))
        wait(for: [got], timeout: 10)
        let annexB = try XCTUnwrap(lock.withLock { keyPacket })

        // SPS (NAL 7): profile_idc 100 — High, 77 — Main; по нему же настраиваются страница и Windows.
        let units = H264Packet.units(annexB)
        let sps = try XCTUnwrap(units.first { $0[$0.startIndex] & 0x1F == 7 })
        let profileIdc = sps[sps.startIndex + 1]
        if encoder.profile == kVTProfileLevel_H264_High_AutoLevel {
            XCTAssertEqual(profileIdc, 100)
        } else {
            XCTAssertEqual(profileIdc, 77)
        }

        let player = H264Player()
        let current = NSObject(), stale = NSObject()
        player.attach(current)
        let payload = Data([1]) + annexB
        player.play(payload, from: stale)
        player.play(payload, from: current)
        let deadline = Date().addingTimeInterval(5)
        while player.size == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(player.size, CGSize(width: 1920, height: 1080))

        let other = H264Player()
        other.attach(current)
        other.play(payload, from: stale)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(other.size, "пакет не того соединения не показывается")
    }

    /// Зритель Mac настраивает декодер только по SPS/PPS из потока: ключевой кадр без них (зритель пришёл позже
    /// единственного кадра с SPS) картинки не даёт, и счётчики для журнала это показывают. Поэтому страница ведущего
    /// подставляет SPS/PPS в каждый ключевой кадр (relay/tests/page-video.test.cjs).
    func testKeyFrameWithoutParameterSetsGivesNoPictureAndIsCounted() throws {
        var pixels: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, attrs, &pixels) == kCVReturnSuccess,
              let pixels else { throw XCTSkip("нет буфера") }
        let got = expectation(description: "ключевой кадр")
        let lock = NSLock()
        var keyPacket: Data?
        let encoder = H264Encoder { data, key in
            lock.lock(); defer { lock.unlock() }
            if key, keyPacket == nil { keyPacket = data; got.fulfill() }
        }
        encoder.requestKeyFrame()
        encoder.encode(pixels, at: CMTime(value: 0, timescale: 30))
        wait(for: [got], timeout: 10)
        let annexB = try XCTUnwrap(lock.withLock { keyPacket })
        let start = Data([0, 0, 0, 1])
        let stripped = H264Packet.units(annexB).filter { ($0[$0.startIndex] & 0x1F) != 7 && ($0[$0.startIndex] & 0x1F) != 8 }
            .reduce(Data()) { (out: Data, unit: Data) -> Data in out + start + unit }

        let player = H264Player()
        let socket = NSObject()
        player.attach(socket)
        player.play(Data([1]) + stripped, from: socket)
        player.play(Data([0]) + stripped, from: socket)
        let first = expectation(description: "счётчики")
        var counts = H264Player.Received()
        player.received { (value: H264Player.Received) in counts = value; first.fulfill() }
        wait(for: [first], timeout: 5)
        XCTAssertEqual(counts, H264Player.Received(packets: 2, keys: 1, withParameterSets: 0))
        XCTAssertNil(player.size, "без SPS/PPS декодер не настроить")

        player.play(Data([1]) + annexB, from: socket)
        let deadline = Date().addingTimeInterval(5)
        while player.size == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(player.size, CGSize(width: 640, height: 360))
        let second = expectation(description: "счётчики после SPS")
        player.received { (value: H264Player.Received) in counts = value; second.fulfill() }
        wait(for: [second], timeout: 5)
        XCTAssertEqual(counts, H264Player.Received(packets: 3, keys: 2, withParameterSets: 1))

        player.reset()
        let third = expectation(description: "сброс")
        player.received { (value: H264Player.Received) in counts = value; third.fulfill() }
        wait(for: [third], timeout: 5)
        XCTAssertEqual(counts, H264Player.Received(), "новый просмотр — счётчики с нуля")
    }
}

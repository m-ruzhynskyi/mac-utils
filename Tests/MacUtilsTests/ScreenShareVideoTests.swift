import CoreVideo
import VideoToolbox
import XCTest
@testable import MacUtils

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
        XCTAssertEqual(ShareVideo.startBitrate, 4_000_000)
        XCTAssertEqual(ShareVideo.maxBitrate, 8_000_000)
        XCTAssertEqual(ShareVideo.frameRate, 30)
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
        XCTAssertEqual(ShareVideo.adaptedBitrate(current: 7_500_000, pendingBytes: 0, secondsSinceLast: 3), 8_000_000)
        XCTAssertNil(ShareVideo.adaptedBitrate(current: 8_000_000, pendingBytes: 0, secondsSinceLast: 3), "потолок 8 Мбит/с")
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
}

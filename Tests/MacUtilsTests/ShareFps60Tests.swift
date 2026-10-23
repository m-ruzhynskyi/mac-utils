import XCTest
import CoreVideo
import CoreMedia
import VideoToolbox
@testable import MacUtils
@testable import MUAudio

/// Стенд частоты кадров кодера: синтетическое анимированное «демо-окно» (не экран пользователя) в H264Encoder.
final class ShareFps60Tests: XCTestCase {
    private func pixels(_ width: Int, _ height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        return buffer!
    }

    /// Рисуем движущиеся блоки в Y-плоскость и шумный UV: нагрузка близка к «окну с анимацией».
    private func draw(_ buffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let line = y + row * rowBytes
            for col in 0..<width {
                let block = ((col + frame * 9) / 48 + (row + frame * 5) / 48) & 1
                line[col] = UInt8(truncatingIfNeeded: block == 0 ? 40 + (col ^ row) & 15 : 200 - (col + row + frame) & 31)
            }
        }
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<CVPixelBufferGetHeightOfPlane(buffer, 1) { memset(uv + row * uvStride, Int32(100 + (frame + row) % 50), uvStride) }
    }

    private func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func t(_ v: timeval) -> Double { Double(v.tv_sec) + Double(v.tv_usec) / 1e6 }
        return t(usage.ru_utime) + t(usage.ru_stime)
    }

    func testEncoderKeepsSixtyFramesPerSecond() throws {
        // В виртуальной машине (раннеры CI) аппаратного кодера нет, замер скорости там ничего не говорит.
        var vmm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.hv_vmm_present", &vmm, &size, nil, 0) == 0, vmm == 1 {
            throw XCTSkip("виртуальная машина: замер частоты кодера пропущен")
        }
        for (w, h) in [(1920, 1080), (1920, 1200)] {
            let lock = NSLock()
            var count = 0, bytes = 0, keys = 0, biggest = 0
            let encoder = H264Encoder { data, key in
                lock.lock(); count += 1; bytes += data.count; if key { keys += 1 }; biggest = max(biggest, data.count); lock.unlock()
            }
            encoder.setBitrate(ShareVideo.startBitrate)
            // Кадры рисуем заранее (12 разных, по кругу): в замер входит кодер, а не отрисовка демо-картинки.
            let buffers = (0..<12).map { i -> CVPixelBuffer in let b = pixels(w, h); draw(b, frame: i); return b }
            let seconds = 3, total = seconds * 60
            let startCPU = cpuSeconds(), start = Date()
            var sent = 0
            for i in 0..<total {
                let target = start.addingTimeInterval(Double(i) / 60)
                let wait = target.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                let buffer = buffers[i % 12]
                if encoder.encode(buffer, at: CMTime(value: Int64(i), timescale: 60)) { sent += 1 }
            }
            Thread.sleep(forTimeInterval: 0.5)
            let elapsed = Date().timeIntervalSince(start) - 0.5
            let cpu = (cpuSeconds() - startCPU) / elapsed * 100
            lock.lock(); defer { lock.unlock() }
            print("FPS60 \(w)x\(h): подано \(sent)/\(total), выдано \(count) за \(String(format: "%.2f", elapsed)) с = \(String(format: "%.1f", Double(count) / elapsed)) кадр/с, "
                  + "\(String(format: "%.2f", Double(bytes) * 8 / elapsed / 1e6)) Мбит/с, ключевых \(keys), самый крупный \(biggest) Б, CPU процесса \(String(format: "%.0f", cpu))%, профиль \(encoder.profile.map { $0 == kVTProfileLevel_H264_High_AutoLevel ? "High" : "Main" } ?? "?")")
            // Без аппаратного кодера (профиль Main) частота зависит от машины — только печатаем.
            if encoder.profile == kVTProfileLevel_H264_High_AutoLevel { XCTAssertGreaterThan(Double(count) / elapsed, 55, "кодер держит ~60 кадров/с при \(w)×\(h)") }
            XCTAssertLessThan(biggest, ShareVideo.maxFrameBytes, "ключевой кадр не больше предела")
        }
    }
}

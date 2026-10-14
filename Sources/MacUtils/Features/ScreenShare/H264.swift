import AVFoundation
import AppKit
import SwiftUI
import VideoToolbox

/// Трансляция видео H.264 (аппаратный кодек, как в Discord): передаются только изменения,
/// поэтому процессор и сеть нагружены в разы меньше, чем кадрами JPEG.
/// Пакет: [3][флаги: 1 — ключевой кадр][Annex B: 00 00 00 01 + NAL …].
enum H264Packet {
    static let type: UInt8 = 3

    /// AVCC (длина + NAL) → Annex B (стартовый код + NAL); у ключевого кадра впереди SPS и PPS.
    static func annexB(from sample: CMSampleBuffer) -> (data: Data, key: Bool)? {
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
    static func units(_ data: Data) -> [Data] {
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

/// Аппаратное кодирование кадров экрана в H.264.
final class H264Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var size: (Int32, Int32) = (0, 0)
    private var forceKey = true
    private let onPacket: (Data, Bool) -> Void

    init(onPacket: @escaping (Data, Bool) -> Void) {
        self.onPacket = onPacket
    }

    func requestKeyFrame() { forceKey = true }

    func encode(_ pixels: CVPixelBuffer, at time: CMTime) {
        let width = Int32(CVPixelBufferGetWidth(pixels)), height = Int32(CVPixelBufferGetHeight(pixels))
        if session == nil || size != (width, height) { makeSession(width: width, height: height) }
        guard let session else { return }
        let options: CFDictionary? = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKey = false
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: options, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let packet = H264Packet.annexB(from: sample) else { return }
            self?.onPacket(packet.data, packet.key)
        }
    }

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
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: 2_500_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: 15,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 4,
        ]
        for (key, value) in properties { VTSessionSetProperty(created, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        size = (width, height)
        forceKey = true
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    deinit { invalidate() }
}

/// Показ H.264 у зрителя: AVSampleBufferDisplayLayer декодирует аппаратно.
@MainActor
final class H264Player: ObservableObject {
    let layer = AVSampleBufferDisplayLayer()
    @Published private(set) var size: CGSize?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
    }

    func reset() {
        layer.flushAndRemoveImage()
        format = nil
        size = nil
    }

    func play(_ payload: Data) {
        guard payload.count > 1 else { return }
        let units = H264Packet.units(payload.dropFirst())
        var frame: [Data] = []
        for unit in units {
            switch unit[unit.startIndex] & 0x1F {
            case 7: sps = unit
            case 8: pps = unit
            default: frame.append(unit)
            }
        }
        if let sps, let pps, format == nil || payload.first == 1 { makeFormat(sps: sps, pps: pps) }
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
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sample)
    }

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
        size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
    }
}

/// Слой видео в SwiftUI.
struct H264View: NSViewRepresentable {
    let player: H264Player

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        player.layer.frame = view.bounds
        player.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(player.layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        player.layer.frame = view.bounds
    }
}

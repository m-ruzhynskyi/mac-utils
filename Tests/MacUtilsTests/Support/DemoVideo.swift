import AVFoundation
import CoreMedia
import CoreText
import Foundation
import XCTest

/// Демо-медиа для тестов плеера: всё рисуется и звучит из кода, файлы — во временной папке теста и в репозиторий
/// не попадают. На каждом кадре — номер и таймкод текстом и номер двоичной полосой сверху (её читает
/// `frameNumber(in:)`, так тесты проверяют шаг по кадрам). Звук — тоны 440 Гц (ru) и 880 Гц (en),
/// субтитры — tx3g на двух языках, главы — дорожка глав QuickTime или атом Nero `chpl`.
enum DemoVideo {
    struct Cue: Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    struct Chapter: Equatable {
        let title: String
        let start: Double
    }

    struct Options {
        var duration: Double = 4
        var fps: Int32 = 24
        var width = 640
        var height = 360
        var fileType: AVFileType = .mp4
        /// Языки аудиодорожек по порядку; первая — по умолчанию. Тон: 440 Гц, 880 Гц, 1320 Гц…
        var audioLanguages: [String] = ["ru", "en"]
        /// Встроенные субтитры (tx3g) по языкам.
        var subtitles: [(language: String, cues: [Cue])] = [
            ("ru", [Cue(start: 0.5, end: 1.5, text: "Первая реплика"), Cue(start: 2, end: 3, text: "Вторая реплика")]),
            ("en", [Cue(start: 0.5, end: 1.5, text: "First line"), Cue(start: 2, end: 3, text: "Second line")]),
        ]
        /// Главы QuickTime (текстовая дорожка, связанная с видео как `chap`).
        var chapters: [Chapter] = []
        /// Главы Nero: атом `moov/udta/chpl`, дописанный побайтно после записи.
        var neroChapters: [Chapter] = []
        /// Без видео (только звук) — как запись встречи.
        var audioOnly = false

        init() {}
    }

    /// Временная папка теста; удалить — `cleanup(_:)` в `tearDown`.
    static func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacUtilsDemoVideo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanup(_ folder: URL?) {
        guard let folder, folder.lastPathComponent.hasPrefix("MacUtilsDemoVideo-") else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Записать демо-файл `name` в `folder`.
    static func make(_ options: Options = Options(), in folder: URL, name: String) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: options.fileType)
        // moov — в конце файла: атом `chpl` дописывается в него без сдвига смещений `stco`.
        writer.shouldOptimizeForNetworkUse = false

        var feeds: [Feed] = []
        var videoInput: AVAssetWriterInput?
        if !options.audioOnly {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: options.width,
                AVVideoHeightKey: options.height,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: Int(options.fps)],
            ])
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: options.width,
                kCVPixelBufferHeightKey as String: options.height,
            ])
            writer.add(input)
            videoInput = input
            feeds.append(VideoFeed(input: input, adaptor: adaptor, options: options))
        }

        var audioInputs: [AVAssetWriterInput] = []
        for (index, language) in options.audioLanguages.enumerated() {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: ToneFeed.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            input.languageCode = iso639_2(language)
            input.extendedLanguageTag = language
            writer.add(input)
            audioInputs.append(input)
            feeds.append(ToneFeed(input: input, frequency: 440 * Double(index + 1), duration: options.duration))
        }
        if audioInputs.count > 1 {
            writer.add(AVAssetWriterInputGroup(inputs: audioInputs, defaultInput: audioInputs[0]))
        }

        var subtitleInputs: [AVAssetWriterInput] = []
        for track in options.subtitles where !options.audioOnly {
            let format = try textFormat(mediaType: kCMMediaType_Subtitle)
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.languageCode = iso639_2(track.language)
            input.extendedLanguageTag = track.language
            writer.add(input)
            subtitleInputs.append(input)
            feeds.append(TextFeed(input: input, format: format, samples: textSamples(track.cues, duration: options.duration)))
        }
        if !subtitleInputs.isEmpty {
            writer.add(AVAssetWriterInputGroup(inputs: subtitleInputs, defaultInput: nil))
        }

        if !options.chapters.isEmpty, let videoInput {
            let format = try textFormat(mediaType: kCMMediaType_Text)
            let input = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = false
            writer.add(input)
            videoInput.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            let cues = options.chapters.enumerated().map { index, chapter in
                Cue(start: chapter.start, end: index + 1 < options.chapters.count ? options.chapters[index + 1].start : options.duration,
                    text: chapter.title)
            }
            feeds.append(TextFeed(input: input, format: format, samples: textSamples(cues, duration: options.duration, gaps: false)))
        }

        guard writer.startWriting() else { throw writer.error ?? DemoError.writer("startWriting") }
        writer.startSession(atSourceTime: .zero)
        // Входы пишутся по очереди: AVAssetWriter чередует их сам и не даёт одному убежать вперёд.
        while feeds.contains(where: { !$0.finished }) {
            var progressed = false
            for feed in feeds where !feed.finished && feed.input.isReadyForMoreMediaData {
                try feed.appendNext()
                progressed = true
            }
            if writer.status == .failed { throw writer.error ?? DemoError.writer("append") }
            if !progressed { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        writer.endSession(atSourceTime: CMTime(seconds: options.duration, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? DemoError.writer("finishWriting") }

        if !options.neroChapters.isEmpty {
            try appendNeroChapters(options.neroChapters, to: url)
        }
        return url
    }

    enum DemoError: Error {
        case writer(String)
        case format
        case mp4(String)
    }

    // MARK: - Номер кадра

    /// Полоса номера: 16 клеток во всю ширину сверху, белая — 1, старший бит слева.
    static let barcodeBits = 16
    static func barcodeHeight(_ height: Int) -> Int { max(8, height / 20) }

    /// Номер кадра по двоичной полосе (BGRA, как отдаёт `AVPlayerItemVideoOutput`).
    static func frameNumber(in buffer: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        // Верх картинки — первая строка буфера.
        let y = barcodeHeight(height) / 2
        var value = 0
        for bit in 0..<barcodeBits {
            let x = (bit * width + width / 2) / barcodeBits
            let offset = y * row + x * 4
            let luma = (Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])) / 3
            value = value << 1 | (luma > 128 ? 1 : 0)
        }
        return value
    }

    /// То же для картинки (снимок кадра).
    static func frameNumber(in image: CGImage) -> Int? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return frameNumber(in: buffer)
    }

    /// «00:00:01:05» — часы, минуты, секунды, кадр.
    static func timecode(frame: Int, fps: Int32) -> String {
        let fps = Int(fps)
        let seconds = frame / fps
        return String(format: "%02d:%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60, frame % fps)
    }

    // MARK: - Кадры

    fileprivate static func draw(frame: Int, in buffer: CVPixelBuffer, options: Options) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = options.width, height = options.height
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let w = CGFloat(width), h = CGFloat(height)
        // Фон — градиент, цвет плавно идёт по кругу: соседние кадры различимы и глазом.
        let hue = CGFloat(frame % 96) / 96
        let top = hsb(hue, 0.55, 0.45), bottom = hsb((hue + 0.25).truncatingRemainder(dividingBy: 1), 0.6, 0.2)
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        // Фигура едет слева направо — видно движение.
        let travel = CGFloat(frame % Int(options.fps * 4)) / CGFloat(options.fps * 4)
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.3, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: w * 0.05 + travel * w * 0.8, y: h * 0.12, width: h * 0.12, height: h * 0.12))

        text("#\(frame)", size: h * 0.22, at: CGPoint(x: w * 0.06, y: h * 0.45), in: context)
        text(timecode(frame: frame, fps: options.fps), size: h * 0.08, at: CGPoint(x: w * 0.06, y: h * 0.32), in: context)

        // Двоичная полоса номера сверху.
        let barHeight = CGFloat(barcodeHeight(height))
        for bit in 0..<barcodeBits {
            let on = frame >> (barcodeBits - 1 - bit) & 1 == 1
            context.setFillColor(on ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
            let x0 = CGFloat(bit * width / barcodeBits), x1 = CGFloat((bit + 1) * width / barcodeBits)
            context.fill(CGRect(x: x0, y: h - barHeight, width: x1 - x0, height: barHeight))
        }
    }

    private static func hsb(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> CGColor {
        let i = Int(hue * 6) % 6, f = hue * 6 - CGFloat(Int(hue * 6))
        let p = brightness * (1 - saturation), q = brightness * (1 - f * saturation), t = brightness * (1 - (1 - f) * saturation)
        let rgb: (CGFloat, CGFloat, CGFloat) = [(brightness, t, p), (q, brightness, p), (p, brightness, t),
                                                (p, q, brightness), (t, p, brightness), (brightness, p, q)][i]
        return CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }

    private static func text(_ string: String, size: CGFloat, at point: CGPoint, in context: CGContext) {
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = point
        CTLineDraw(line, context)
    }

    // MARK: - Текстовые дорожки (субтитры tx3g, главы)

    /// Описание текстового формата 3GPP (tx3g): для субтитров (`sbtl`) и глав (`text`).
    private static func textFormat(mediaType: CMMediaType) throws -> CMFormatDescription {
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: [
                kCMTextFormatDescriptionColor_Red: 0, kCMTextFormatDescriptionColor_Green: 0,
                kCMTextFormatDescriptionColor_Blue: 0, kCMTextFormatDescriptionColor_Alpha: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_FontSize: 24,
                kCMTextFormatDescriptionStyle_ForegroundColor: [
                    kCMTextFormatDescriptionColor_Red: 255, kCMTextFormatDescriptionColor_Green: 255,
                    kCMTextFormatDescriptionColor_Blue: 255, kCMTextFormatDescriptionColor_Alpha: 255,
                ],
            ],
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: nil, mediaType: mediaType, mediaSubType: kCMTextFormatType_3GText,
                                               extensions: extensions as CFDictionary, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw DemoError.format }
        return format
    }

    /// Реплики → образцы подряд: пустой образец закрывает промежутки (дорожка без дыр до конца файла).
    private static func textSamples(_ cues: [Cue], duration: Double, gaps: Bool = true) -> [(start: Double, end: Double, text: String)] {
        var samples: [(Double, Double, String)] = []
        var time = 0.0
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            if gaps, cue.start > time { samples.append((time, cue.start, "")) }
            samples.append((cue.start, cue.end, cue.text))
            time = cue.end
        }
        if gaps, time < duration { samples.append((time, duration, "")) }
        return samples.map { (start: $0.0, end: $0.1, text: $0.2) }
    }

    fileprivate static func textSample(_ text: String, start: Double, end: Double, format: CMFormatDescription) throws -> CMSampleBuffer {
        let utf8 = Array(text.utf8)
        var bytes: [UInt8] = [UInt8(utf8.count >> 8 & 0xFF), UInt8(utf8.count & 0xFF)] + utf8
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw DemoError.format }
        status = CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        var timing = CMSampleTimingInfo(duration: CMTime(seconds: end - start, preferredTimescale: 600),
                                        presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                      formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw DemoError.format }
        return sample
    }

    // MARK: - Главы Nero (chpl)

    /// Дописать `udta/chpl` в конец `moov` (moov — последний атом файла). Формат как у ffmpeg:
    /// версия 1, флаги, 4 байта резерва, число глав, для каждой — начало (u64, единицы 100 нс), длина и название.
    static func appendNeroChapters(_ chapters: [Chapter], to url: URL) throws {
        var data = try Data(contentsOf: url)
        var chpl = Data([1, 0, 0, 0, 0, 0, 0, 0, UInt8(chapters.count)])
        for chapter in chapters {
            chpl.append(bigEndian: UInt64((chapter.start * 10_000_000).rounded()))
            let title = Array(chapter.title.utf8.prefix(255))
            chpl.append(UInt8(title.count))
            chpl.append(contentsOf: title)
        }
        let chplBox = box("chpl", chpl)
        let udta = box("udta", chplBox)
        // Ищем moov среди атомов верхнего уровня.
        var offset = 0
        var moov: (offset: Int, size: Int)?
        while offset + 8 <= data.count {
            var size = Int(data.readUInt32(at: offset))
            let type = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
            // 1 — 64-битный размер следом за типом, 0 — до конца файла.
            if size == 1, offset + 16 <= data.count {
                size = Int(UInt64(data.readUInt32(at: offset + 8)) << 32 | UInt64(data.readUInt32(at: offset + 12)))
            } else if size == 0 {
                size = data.count - offset
            }
            guard size >= 8 else { throw DemoError.mp4("размер атома \(type)") }
            if type == "moov" { moov = (offset, size) }
            offset += size
        }
        guard let moov, moov.offset + moov.size == data.count else { throw DemoError.mp4("moov не последний") }
        data.append(udta)
        data.writeUInt32(UInt32(moov.size + udta.count), at: moov.offset)
        try data.write(to: url)
    }

    private static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(bigEndian: UInt32(8 + payload.count))
        data.append(contentsOf: Array(type.utf8))
        data.append(payload)
        return data
    }

    /// «ru» → «rus»: AVAssetWriterInput.languageCode — ISO 639-2/T.
    private static func iso639_2(_ language: String) -> String {
        ["ru": "rus", "en": "eng", "de": "deu", "fr": "fra", "uk": "ukr", "ja": "jpn"][language] ?? language
    }
}

// MARK: - Источники образцов

private class Feed {
    let input: AVAssetWriterInput
    var finished = false

    init(input: AVAssetWriterInput) { self.input = input }

    func appendNext() throws {}

    func finish() {
        finished = true
        input.markAsFinished()
    }
}

private final class VideoFeed: Feed {
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let options: DemoVideo.Options
    let total: Int
    var frame = 0

    init(input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, options: DemoVideo.Options) {
        self.adaptor = adaptor
        self.options = options
        total = Int((options.duration * Double(options.fps)).rounded())
        super.init(input: input)
    }

    override func appendNext() throws {
        guard frame < total else { return finish() }
        guard let pool = adaptor.pixelBufferPool else { throw DemoVideo.DemoError.writer("pixelBufferPool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw DemoVideo.DemoError.writer("pixelBuffer") }
        DemoVideo.draw(frame: frame, in: buffer, options: options)
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: options.fps)) else {
            throw DemoVideo.DemoError.writer("video append")
        }
        frame += 1
    }
}

private final class ToneFeed: Feed {
    static let sampleRate = 44_100
    static let chunk = 4_410
    let frequency: Double
    let total: Int
    var position = 0
    let format: CMAudioFormatDescription

    init(input: AVAssetWriterInput, frequency: Double, duration: Double) {
        self.frequency = frequency
        total = Int(duration * Double(Self.sampleRate))
        var description = AudioStreamBasicDescription(mSampleRate: Float64(Self.sampleRate), mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                                      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                                      mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        self.format = format!
        super.init(input: input)
    }

    override func appendNext() throws {
        guard position < total else { return finish() }
        let count = min(Self.chunk, total - position)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(position + i) / Double(Self.sampleRate)
            samples[i] = Int16(sin(2 * .pi * frequency * t) * 8_000)
        }
        let length = count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block)
        guard let block else { throw DemoVideo.DemoError.writer("audio block") }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: count,
                                                             presentationTimeStamp: CMTime(value: CMTimeValue(position),
                                                                                           timescale: CMTimeScale(Self.sampleRate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample, input.append(sample) else { throw DemoVideo.DemoError.writer("audio append") }
        position += count
    }
}

private final class TextFeed: Feed {
    let format: CMFormatDescription
    var samples: [(start: Double, end: Double, text: String)]

    init(input: AVAssetWriterInput, format: CMFormatDescription, samples: [(start: Double, end: Double, text: String)]) {
        self.format = format
        self.samples = samples
        super.init(input: input)
    }

    override func appendNext() throws {
        guard !samples.isEmpty else { return finish() }
        let next = samples.removeFirst()
        let sample = try DemoVideo.textSample(next.text, start: next.start, end: next.end, format: format)
        guard input.append(sample) else { throw DemoVideo.DemoError.writer("text append") }
    }
}

// MARK: - Субтитры файлами

/// Внешние субтитры для тестов: SRT и ASS в UTF-8 (с BOM и без) и Windows-1251, CRLF и «кривые» файлы.
enum DemoSubtitles {
    static let srt = """
    1
    00:00:00,500 --> 00:00:01,500
    Привет, это первая реплика

    2
    00:00:02,000 --> 00:00:03,000
    <i>Вторая</i> реплика
    в две строки

    """

    static let ass = """
    [Script Info]
    Title: Демо
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
    Style: Sign,Arial,18,&H0000FFFF,&H000000FF,&H00000000,&H00000000,-1,0,0,0,100,100,0,0,1,2,0,8,10,10,10,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.50,0:00:01.50,Default,,0,0,0,,Привет, {\\b1}жирный{\\b0} текст
    Dialogue: 0,0:00:02.00,0:00:03.00,Sign,,0,0,0,,{\\an8\\c&H0000FF&}Табличка\\Nвверху
    Comment: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,Комментарий не показывается

    """

    enum Encoding { case utf8, utf8BOM, windows1251 }

    static func data(_ text: String, _ encoding: Encoding, crlf: Bool = false) -> Data {
        let body = crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text
        switch encoding {
        case .utf8: return Data(body.utf8)
        case .utf8BOM: return Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
        case .windows1251:
            let cf = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue))
            return body.data(using: String.Encoding(rawValue: cf))!
        }
    }

    @discardableResult
    static func write(_ text: String, _ encoding: Encoding, crlf: Bool = false, to url: URL) throws -> URL {
        try data(text, encoding, crlf: crlf).write(to: url)
        return url
    }
}

// MARK: - Байты MP4

extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func append(bigEndian value: UInt64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        self[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for i in 0..<4 { self[offset + i] = UInt8(value >> (24 - 8 * i) & 0xFF) }
    }
}

import AVFoundation
import CoreMedia

/// Микрофон с системным подавлением эха (как в FaceTime): звук из динамиков, который микрофон
/// слышит в комнате, вычитается. Без этого в записи со звуком системы и микрофоном звук двоится.
/// Время буферов — по часам хоста, как у ScreenCaptureKit, поэтому дорожки совпадают.
final class EchoFreeMicrophone: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer, CMTime) -> Void

    private let engine = AVAudioEngine()
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws {
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // Не приглушать остальной звук системы, пока пишем.
        if #available(macOS 14.0, *) {
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
        // Оставляем один канал: голос моно, а у голосовой обработки бывает много «служебных» каналов.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: 1, interleaved: false) else { throw CocoaError(.featureUnsupported) }
        let handler = self.handler
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, time in
            guard let first = buffer.floatChannelData?[0],
                  let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            copy.floatChannelData?[0].update(from: first, count: Int(buffer.frameLength))
            let pts = time.isHostTimeValid
                ? CMClockMakeHostTimeFromSystemUnits(time.hostTime)
                : CMClockGetTime(CMClockGetHostTimeClock())
            handler(copy, pts)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    /// PCM-буфер → CMSampleBuffer для AVAssetWriter.
    static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at pts: CMTime) -> CMSampleBuffer? {
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: buffer.format.streamDescription, layoutSize: 0,
                                             layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                                   refcon: nil, formatDescription: format, sampleCount: CMItemCount(buffer.frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil,
                                                             blockBufferMemoryAllocator: nil, flags: 0,
                                                             bufferList: buffer.audioBufferList) == noErr else { return nil }
        return sample
    }
}

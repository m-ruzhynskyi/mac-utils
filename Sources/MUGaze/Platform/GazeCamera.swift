import AVFoundation
import MUCore

/// Камера Mac: 1280×720, 30 к/с, BGRA в IOSurface. Открыта только между start() и stop().
/// Виртуальные камеры (OBS Virtual Camera и т. п.) не берём: иначе картинка пошла бы по кругу.
final class GazeCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue: DispatchQueue
    private let handler: (CMSampleBuffer) -> Void
    private(set) var deviceName: String?

    init(queue: DispatchQueue, handler: @escaping (CMSampleBuffer) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    /// Не виртуальная ли это камера (по имени и модели). Чистая функция — в тестах.
    static func isVirtual(name: String, model: String) -> Bool {
        let s = (name + " " + model).lowercased()
        return ["obs", "virtual", "виртуальн", "snap camera", "camtwist", "mmhmm", "syphon", "ndi"].contains { s.contains($0) }
    }

    static func preferredDevice() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
            .filter { !isVirtual(name: $0.localizedName, model: $0.modelID) }
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
    }

    enum StartError: Error { case noCamera, cannotOpen }

    func start() throws {
        guard let device = Self.preferredDevice() else { throw StartError.noCamera }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        session.inputs.forEach { session.removeInput($0) }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration(); throw StartError.cannotOpen
        }
        session.addInput(input)
        if session.outputs.isEmpty {
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        if (try? device.lockForConfiguration()) != nil {
            let target = CMTime(value: 1, timescale: 30)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= target && target <= $0.maxFrameDuration }) {
                device.activeVideoMinFrameDuration = target
                device.activeVideoMaxFrameDuration = target
            }
            device.unlockForConfiguration()
        }
        session.commitConfiguration()
        deviceName = device.localizedName
        session.startRunning()
        Log.gaze.info("camera: started")
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
        Log.gaze.info("camera: stopped")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler(sampleBuffer)
    }
}

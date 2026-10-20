import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Видео: `AVPlayerLayer` на чёрном, кадр вписан. Клик — пауза сразу (на отпускание, чтобы можно было тащить окно
/// за видео), двойной — ±10 с по краям и полный экран посередине; движение мыши показывает плавающую панель.
final class PlayerVideoView: NSView, AVPictureInPictureControllerDelegate {
    let playerLayer = AVPlayerLayer()
    weak var controller: PlayerWindowController?
    private var pip: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var mouseDownEvent: NSEvent?
    private var dragged = false
    private var tracking: NSTrackingArea?

    /// PiP включён — кнопка лаймом.
    var onPictureInPictureChange: ((Bool) -> Void)?

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window as? PlayerWindow else {
            // Окно закрыли: PiP и наблюдение за ним больше не нужны.
            pip?.stopPictureInPicture()
            pipObservation?.invalidate()
            pipObservation = nil
            return
        }
        window.videoView = self
        if pip == nil { setUpPictureInPicture() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { MainActor.assumeIsolated { controller?.mouseMoved() } }
    override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { controller?.mouseMoved() } }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDownEvent = event
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, !dragged, let window, !window.styleMask.contains(.fullScreen) else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        if hypot(a.x - b.x, a.y - b.y) > 4 {
            dragged = true
            window.performDrag(with: down)
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !dragged else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let width = bounds.width
        MainActor.assumeIsolated { controller?.videoClicked(count: event.clickCount, x: x, width: width) }
    }

    // MARK: - Картинка в картинке

    private func setUpPictureInPicture() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: playerLayer)
        controller?.delegate = self
        pip = controller
        pipObservation = controller?.observe(\.isPictureInPictureActive, options: [.new]) { [weak self] pip, _ in
            let active = pip.isPictureInPictureActive
            DispatchQueue.main.async { self?.onPictureInPictureChange?(active) }
        }
    }

    var isPictureInPictureActive: Bool { pip?.isPictureInPictureActive ?? false }

    func togglePictureInPicture() {
        guard let pip else { return }
        if pip.isPictureInPictureActive { pip.stopPictureInPicture() } else if pip.isPictureInPicturePossible { pip.startPictureInPicture() }
    }

    func stopPictureInPicture() { pip?.stopPictureInPicture() }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        // Возврат из PiP — к окну плеера, если оно ещё открыто.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let controller = self.controller, !controller.isClosed { controller.present() }
            }
            completion(true)
        }
    }
}

/// Видео в SwiftUI.
struct PlayerVideoRepresentable: NSViewRepresentable {
    let model: PlayerModel
    let controller: PlayerWindowController
    @Binding var pictureInPicture: Bool

    func makeNSView(context: Context) -> PlayerVideoView {
        let view = PlayerVideoView(player: model.player)
        view.controller = controller
        view.onPictureInPictureChange = { active in pictureInPicture = active }
        return view
    }

    func updateNSView(_ view: PlayerVideoView, context: Context) {
        view.controller = controller
    }
}

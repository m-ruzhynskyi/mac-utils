import AppKit
import SwiftUI

extension View {
    /// Вид на экране: он в окне, окно показано и не закрыто другими окнами целиком. `changed` зовётся только при смене
    /// (true — показан, false — скрыт), поэтому пары «показан/скрыт» всегда сходятся и модели могут считать зрителей.
    /// В отличие от onAppear/onDisappear ловит и закрытие окна (окно настроек не освобождается при закрытии, и
    /// onDisappear не приходит), сворачивание, закрытие поповера и окно, целиком закрытое другим.
    func onScreen(_ changed: @escaping @MainActor (Bool) -> Void) -> some View {
        background(OnScreenProbe(changed: changed))
    }
}

private struct OnScreenProbe: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> OnScreenView {
        let view = OnScreenView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: OnScreenView, context: Context) {
        view.changed = changed
    }

    static func dismantleNSView(_ view: OnScreenView, coordinator: ()) {
        view.detach()
    }
}

final class OnScreenView: NSView {
    var changed: (@MainActor (Bool) -> Void)?
    private var shown = false
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.report(closing: note.name == NSWindow.willCloseNotification) }
                })
            }
        }
        report()
    }

    /// Вид убран из окна насовсем: сообщаем «скрыт», если ещё не сообщили.
    func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        set(false)
    }

    private func report(closing: Bool = false) {
        guard let window, !closing else { return set(false) }
        set(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
    }

    private func set(_ now: Bool) {
        guard now != shown else { return }
        shown = now
        changed?(now)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

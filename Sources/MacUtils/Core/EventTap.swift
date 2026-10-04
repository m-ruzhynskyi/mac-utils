// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation

/// Обёртка над CGEventTap на главном run loop.
/// Обработчик возвращает `true`, чтобы пропустить событие дальше,
/// и `false`, чтобы его поглотить.
@MainActor
final class EventTap {
    typealias Handler = @MainActor (CGEventType, CGEvent) -> Bool

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let mask: CGEventMask
    private let handler: Handler

    init(types: [CGEventType], handler: @escaping Handler) {
        mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        self.handler = handler
    }

    var isRunning: Bool { port != nil }

    @discardableResult
    func start() -> Bool {
        if let port {
            CGEvent.tapEnable(tap: port, enable: true)
            return true
        }
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let pass = MainActor.assumeIsolated { () -> Bool in
                    let tap = Unmanaged<EventTap>.fromOpaque(info).takeUnretainedValue()
                    return tap.dispatch(type: type, event: event)
                }
                return pass ? Unmanaged.passUnretained(event) : nil
            },
            userInfo: info
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        port = nil
        source = nil
    }

    private func dispatch(type: CGEventType, event: CGEvent) -> Bool {
        // macOS отключает «зависший» tap; включаем обратно.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return true
        }
        return handler(type, event)
    }
}

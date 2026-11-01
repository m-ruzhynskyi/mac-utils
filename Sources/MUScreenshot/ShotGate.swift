import Foundation

/// Можно ли начать снимок по ⌘⇧X (чистая логика). Нажатие никогда не теряется молча: либо снимок начинается
/// (при необходимости после сброса зависшего состояния), либо человек видит, чем занято приложение.
package enum ShotGate {
    /// Сколько ждать ScreenCaptureKit, прежде чем отменить захват и сказать об этом.
    package static let captureTimeout: TimeInterval = 5
    /// Захват «идёт» дольше этого — он завис мимо предела (задача не завершилась): состояние сбрасывается.
    package static let staleCapture: TimeInterval = 8
    /// Длинный снимок без панелей дольше этого — завис (у него свой предел на ответ системы — 8 с).
    package static let staleScroll: TimeInterval = 12

    /// Что осталось от прошлого снимка и мешает новому.
    package enum Stale: Equatable, CaseIterable {
        case capture, overlays, scroll
    }

    package enum Busy: Equatable {
        /// Экран ещё снимается (в пределах `captureTimeout`).
        case capturing
        /// Оверлей снимка уже открыт — поднять его.
        case overlayOpen
        /// Идёт длинный снимок с видимыми панелями.
        case scrollCapture
    }

    package enum Decision: Equatable {
        case proceed(reset: [Stale])
        case busy(Busy)
    }

    /// Состояние длинного снимка: видны ли его панели и сколько секунд он идёт.
    package struct Scroll: Equatable {
        package let showing: Bool
        package let age: TimeInterval
        package init(showing: Bool, age: TimeInterval) {
            self.showing = showing
            self.age = age
        }
    }

    package static func decide(capturingFor: TimeInterval?, overlays: Int, visibleOverlays: Int,
                               scroll: Scroll?) -> Decision {
        var reset: [Stale] = []
        if let capturingFor {
            if capturingFor < staleCapture { return .busy(.capturing) }
            reset.append(.capture)
        }
        if overlays > 0 {
            if visibleOverlays > 0 { return .busy(.overlayOpen) }
            reset.append(.overlays)
        }
        if let scroll {
            if scroll.showing || scroll.age < staleScroll { return .busy(.scrollCapture) }
            reset.append(.scroll)
        }
        return .proceed(reset: reset)
    }

    /// Текст тоста для занятого состояния (оверлей поднимается без тоста — он и есть ответ на нажатие).
    package static func message(_ busy: Busy) -> String? {
        switch busy {
        case .capturing: return "Снимок уже делается — подождите секунду"
        case .overlayOpen: return nil
        case .scrollCapture: return "Идёт длинный снимок: Enter — готово, Esc — отмена"
        }
    }

    package static let timeoutMessage = "Экран не снялся за 5 с — захват отменён. Нажмите ⌘⇧X ещё раз"
}

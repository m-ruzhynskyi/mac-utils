import CoreGraphics

/// Раскладка дисплеев: скрытый дисплей — за угол или под край Dock, только на сеанс (после выхода раскладка прежняя).
enum HiddenScreenLayout {
    enum Failure: Error, CustomStringConvertible {
        case configuration(CGError)
        var description: String {
            switch self { case let .configuration(error): return "CGDisplayConfiguration: \(error.rawValue)" }
        }
    }

    /// Поставить дисплей в `origin`. Возвращает фактическую рамку: macOS может поправить начало, чтобы раскладка
    /// осталась связной (13.11 дисплей встал справа сверху).
    ///
    /// Без затемнения: по умолчанию Quartz на время любой перестройки раскладки гасит все дисплеи (затемнение
    /// и проявление) — это и было «мигание» при ⌥⇧H (HSCR-43). Нулевое время затемнения — перестановка без него.
    static func place(_ id: CGDirectDisplayID, origin: CGPoint) throws -> CGRect {
        if CGDisplayBounds(id).origin == origin { return CGDisplayBounds(id) }
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { throw Failure.configuration(error) }
        _ = CGConfigureDisplayFadeEffect(config, 0, 0, 0, 0, 0)
        error = CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
        guard error == .success else {
            CGCancelDisplayConfiguration(config)
            throw Failure.configuration(error)
        }
        error = CGCompleteDisplayConfiguration(config, .forSession)
        guard error == .success else { throw Failure.configuration(error) }
        return CGDisplayBounds(id)
    }

    /// Начало «за углом» раскладки (`HiddenScreenGeometry.cornerOrigin`).
    static func cornerOrigin(_ id: CGDirectDisplayID) -> CGPoint {
        HiddenScreenGeometry.cornerOrigin(size: CGDisplayBounds(id).size, beside: HiddenDisplay.physicalDisplays(excluding: id))
    }
}

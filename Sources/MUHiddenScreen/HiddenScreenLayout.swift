import CoreGraphics

/// Раскладка дисплеев: скрытый дисплей — в угол, только на сеанс (после выхода раскладка прежняя).
enum HiddenScreenLayout {
    enum Failure: Error, CustomStringConvertible {
        case configuration(CGError)
        var description: String {
            switch self { case let .configuration(error): return "CGDisplayConfiguration: \(error.rawValue)" }
        }
    }

    /// Отодвинуть дисплей за угол раскладки (`HiddenScreenGeometry.cornerOrigin`). Возвращает фактическую рамку:
    /// macOS может поправить начало, чтобы раскладка осталась связной (13.11 дисплей встал справа сверху).
    static func moveBeyondCorner(_ id: CGDirectDisplayID, size: CGSize) throws -> CGRect {
        let others = HiddenDisplay.physicalDisplays(excluding: id)
        let origin = HiddenScreenGeometry.cornerOrigin(size: size, beside: others)
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { throw Failure.configuration(error) }
        error = CGConfigureDisplayOrigin(config, id, Int32(origin.x), Int32(origin.y))
        guard error == .success else {
            CGCancelDisplayConfiguration(config)
            throw Failure.configuration(error)
        }
        error = CGCompleteDisplayConfiguration(config, .forSession)
        guard error == .success else { throw Failure.configuration(error) }
        return CGDisplayBounds(id)
    }
}

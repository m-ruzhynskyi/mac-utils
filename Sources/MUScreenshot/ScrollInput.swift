import Foundation

/// События ввода для склейки длинного снимка: копит их со временем, раздаёт кадрам и помнит, что после щелчка колеса
/// или клавиши приложение может ещё прокручивать само (анимация). Чистая логика: время передаётся снаружи.
package struct ScrollInput {
    /// Сколько после события колеса без точных дельт, клавиши или щелчка мыши содержимое может ещё двигаться само:
    /// PageDown и пробел в браузерах, щелчок колеса в Firefox и программах с плавной прокруткой — до ~0,5 с.
    package static let animationTail: TimeInterval = 0.6

    /// Хоть одно событие уже было: с этого момента «событий нет» значит «прокрутки нет» (видео, анимация не клеятся).
    /// До первого события — только по изображению: монитор мог не заработать, а прокручивать можно и скриптом.
    package private(set) var sawInput = false
    private var pending: [(time: TimeInterval, motion: Stitcher.Motion)] = []
    private var lastAnimated = -TimeInterval.infinity

    /// `animated` — после события приложение может ещё прокручивать само (см. `animationTail`).
    package mutating func note(_ motion: Stitcher.Motion, at time: TimeInterval, animated: Bool = false) {
        sawInput = true
        pending.append((time, motion))
        if animated { lastAnimated = max(lastAnimated, time) }
    }

    /// События до момента `time` — очередному кадру; nil, пока событий не было (склейка только по изображению).
    /// Новых событий нет, а анимированная прокрутка ещё может идти — «прокрутка неизвестной величины».
    package mutating func take(upTo time: TimeInterval) -> Stitcher.Motion? {
        guard sawInput else { return nil }
        let taken = pending.prefix { $0.time <= time }
        pending.removeFirst(taken.count)
        var motion = taken.reduce(Stitcher.Motion()) { $0 + $1.motion }
        if motion.isEmpty, time - lastAnimated < Self.animationTail { motion.unknown = 1 }
        return motion
    }

    /// Событие колеса или трекпада. Над областью: точные дельты (трекпад, Magic Mouse, плавная прокрутка) — в пикселях
    /// кадра, щелчок колеса — в строках (приложение может прокручивать его анимацией). Мимо области прокручиваться
    /// может то же окно (выделена только колонка статьи): величина неизвестна, но «прокрутки нет» сказать нельзя.
    /// Положительная дельта — к началу документа; сдвиг склейки положителен при прокрутке вниз.
    package static func wheel(deltaY: Double, precise: Bool, scale: Double, overArea: Bool) -> (motion: Stitcher.Motion, animated: Bool)? {
        guard deltaY != 0 else { return nil }
        guard overArea else { return (Stitcher.Motion(unknown: 1), true) }
        return precise ? (Stitcher.Motion(pixels: -deltaY * scale), false) : (Stitcher.Motion(lines: -deltaY), true)
    }
}

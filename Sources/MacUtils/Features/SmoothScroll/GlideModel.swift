import Foundation

/// Математика плавной прокрутки без системных вызовов: сколько пикселей отдать в этом кадре.
/// Колесо добавляет «остаток» (сколько ещё прокрутить), каждый кадр отдаёт его долю с замедлением в конце;
/// дробные доли пикселя копятся в `carry` и не теряются.
struct GlideModel {
    /// Потолок остатка в пикселях по каждой оси: быстрый разгон колеса не должен катить страницу ещё полминуты.
    static let maxRemaining = 8000.0
    static let notchPixels = 50.0

    private(set) var remainingY = 0.0
    private(set) var remainingX = 0.0
    private var carryY = 0.0
    private var carryX = 0.0
    private(set) var streak = 0
    private var lastNotch: TimeInterval = 0

    var isIdle: Bool { remainingY == 0 && remainingX == 0 }

    /// Шаг колеса в пикселях: быстрое вращение (щелчки чаще 0.12 с) ускоряет прокрутку до +180 %.
    mutating func notchPixels(dy: Double, dx: Double, now: TimeInterval, speed: Double) -> (y: Double, x: Double) {
        streak = (now - lastNotch) < 0.12 ? min(streak + 1, 15) : 0
        lastNotch = now
        let step = Self.notchPixels * speed * (1 + Double(streak) * 0.12)
        return (dy * step, dx * step)
    }

    /// Добавить сдвиг в пикселях. Смена направления гасит остаток этой оси; остаток ограничен потолком.
    mutating func add(y: Double, x: Double) {
        if y != 0, remainingY * y < 0 { remainingY = 0; carryY = 0 }
        if x != 0, remainingX * x < 0 { remainingX = 0; carryX = 0 }
        remainingY = Self.clamp(remainingY + y)
        remainingX = Self.clamp(remainingX + x)
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, -maxRemaining), maxRemaining) }

    /// Один кадр: сколько целых пикселей отдать по осям. `duration` — время, за которое проходится ~98 % пути.
    mutating func step(dt rawDt: TimeInterval, duration rawDuration: Double) -> (y: Int32, x: Int32) {
        let dt = min(max(rawDt, 1.0 / 240.0), 1.0 / 30.0)
        let duration = min(max(rawDuration, 0.08), 1.5)
        let k = 1 - exp(-dt / (duration / 4))

        let moveY = abs(remainingY) < 1 ? remainingY : remainingY * k
        let moveX = abs(remainingX) < 1 ? remainingX : remainingX * k
        remainingY -= moveY
        remainingX -= moveX

        let totalY = moveY + carryY
        let totalX = moveX + carryX
        // В последнем кадре оси дробная часть округляется, а не теряется: за всю прокрутку отдаётся ровно столько, сколько просили (±0.5 px).
        let pixelsY = remainingY == 0 ? totalY.rounded() : totalY.rounded(.towardZero)
        let pixelsX = remainingX == 0 ? totalX.rounded() : totalX.rounded(.towardZero)
        carryY = remainingY == 0 ? 0 : totalY - pixelsY
        carryX = remainingX == 0 ? 0 : totalX - pixelsX
        return (Int32(pixelsY), Int32(pixelsX))
    }

    mutating func reset() {
        remainingY = 0; remainingX = 0
        carryY = 0; carryX = 0
    }
}

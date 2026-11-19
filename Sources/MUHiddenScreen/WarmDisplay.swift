import CoreGraphics
import Foundation

/// Когда снимать тёплый дисплей (HSCR-44, ревью 1111). Пока скрытый экран выключен, окна никто не переносит
/// (`sweep` работает только включённым), а курсор на дисплей не пускают — окно, попавшее туда, стало бы недоступным:
/// macOS могла поставить его туда при смене мониторов, программа ИИ — восстановить по старой рамке при запуске.
/// Снять дисплей надёжнее, чем переносить окна: macOS сама переносит окна со снятого дисплея на настоящие.
public enum WarmDisplayRules {
    /// Дольше этого тёплый дисплей не живёт: выигрыш (нет мигания) нужен при частых включениях подряд.
    public static let idleLimit: TimeInterval = 600
    /// Перестройку дисплеев, которую сделали мы сами (раскладка, создание), не считаем сменой мониторов.
    public static let ownChangeGrace: TimeInterval = 2
    /// Проверки окон после запуска программы ИИ: окна она восстанавливает не сразу.
    public static let launchChecks: [TimeInterval] = [1, 3, 6]
    /// Слои, где живут окна программ (−1 — быстрый чат Claude, 0 — обычные, до Dock — плавающие). Dock (20), строка
    /// меню и значки в ней (24–25) есть на каждом дисплее — не окна программ.
    public static let windowLayers = -1..<20

    public enum ScreensReaction: Equatable, Sendable {
        /// Наша же перестройка — ничего не делать.
        case ignore
        /// Мониторы те же (например, сменилось разрешение) — проверить окна на тёплом дисплее.
        case checkWindows
        /// Мониторы другие — снять тёплый дисплей.
        case release
    }

    /// `physical` — рамки настоящих дисплеев сейчас, `parked` — когда дисплей уходил за угол.
    public static func onScreensChanged(physical: [CGRect], parked: [CGRect], sinceOwnChange: TimeInterval) -> ScreensReaction {
        if sinceOwnChange < ownChangeGrace { return .ignore }
        return signature(physical) == signature(parked) ? .checkWindows : .release
    }

    /// Окна программ (не Mac Utils) на тёплом дисплее: по центру окна.
    public static func strayWindows(_ windows: [HiddenWindowInfo], on display: CGRect, selfPID: pid_t) -> [HiddenWindowInfo] {
        windows.filter { window in
            window.pid != selfPID && windowLayers.contains(window.layer) && HiddenWindowRules.isAppWindow(window)
                && display.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
        }
    }

    /// Простой истёк: дисплей тёплый дольше `idleLimit`.
    public static func idleExpired(parkedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - parkedAt >= idleLimit
    }

    private static func signature(_ rects: [CGRect]) -> [[CGFloat]] {
        rects.map { [$0.minX, $0.minY, $0.width, $0.height] }.sorted { $0.lexicographicallyPrecedes($1) }
    }
}

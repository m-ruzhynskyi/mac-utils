import CoreGraphics
import Foundation

/// Как щелчок из зеркала попадает в программу.
public enum ClickMode: String, Sendable, CaseIterable {
    /// Настоящий курсор на миг переносится на скрытый дисплей, нажатие — через HID (по умолчанию).
    case warp
    /// `postToPid` с номером окна в полях 91/92. На Mac пользователя (13.11) не работает ни в Claude, ни в ChatGPT — для опытов.
    case pid
}

/// Как прокрутка из зеркала попадает в программу.
public enum ScrollMode: String, Sendable, CaseIterable {
    /// Курсор переходит на скрытый дисплей на время жеста и возвращается после паузы (по умолчанию).
    case handoff
    /// `postToPid` — без переноса курсора; проверить, принимают ли его Claude и ChatGPT.
    case pid
}

/// Чем занят настоящий курсор на скрытом дисплее.
public enum HandoffKind: Equatable, Sendable {
    /// Перетаскивание (выделение текста, ползунок): до отпускания кнопки.
    case drag
    /// Меню по правой кнопке: до закрытия меню.
    case menu
    /// Прокрутка: до паузы в событиях прокрутки.
    case scroll
}

/// Шаг, который исполняет движок (`HiddenScreenEngine.run`). Описание без системы — для тестов.
public enum PointerStep: Equatable, Sendable {
    case hideCursor
    case showCursor
    /// Сделать программу ИИ активной и дождаться этого (строка меню основного экрана при этом не меняется — проверено с Sidecar).
    case activateTarget
    /// Вернуть активность Mac Utils: зеркало снова получает клавиатуру, а ввод уходит в программу через `postToPid`.
    case activateSelf
    /// `CGWarpMouseCursorPosition` (глобальные координаты Quartz).
    case warp(CGPoint)
    /// Событие на уровне HID (`.cghidEventTap`): WindowServer сам находит окно под курсором.
    case postHID(SyntheticEvent)
    case postToPid(SyntheticEvent)
    case beginHandoff(HandoffKind)
    case endHandoff(HandoffKind)
}

/// Мышь в зеркале → шаги для настоящего окна на скрытом дисплее.
///
/// Щелчок левой кнопкой выполняется по отпусканию (иначе не отличить от перетаскивания):
/// спрятать курсор → активировать ИИ → курсор в точку окна → нажатие и отпускание через HID → курсор назад → показать → активировать Mac Utils.
/// Всё — за один проход главного потока, в демонстрации курсор не сдвигается (он уходит с основного экрана на миллисекунды).
/// Перетаскивание и меню по правой кнопке требуют, чтобы курсор остался на скрытом дисплее («передача»):
/// физические движения мыши идут прямо в программу, зеркало рисует курсор-подсказку, конец передачи определяет `HandoffWatch`.
public struct PointerSession: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case pressed(down: CGPoint, target: CGPoint, clicks: Int, flags: CGEventFlags, cursor: CGPoint)
        case handoff(HandoffKind, activated: Bool)
    }

    public var clickMode: ClickMode
    public var scrollMode: ScrollMode
    /// Сдвиг (pt зеркала), после которого нажатие считается перетаскиванием.
    public var dragThreshold: CGFloat = 3
    /// Точек на «строку» колёсика без точной прокрутки.
    public var lineHeight: Double = 10
    public private(set) var state: State = .idle

    public init(clickMode: ClickMode = .warp, scrollMode: ScrollMode = .handoff) {
        self.clickMode = clickMode
        self.scrollMode = scrollMode
    }

    public var handoff: HandoffKind? {
        if case let .handoff(kind, _) = state { return kind }
        return nil
    }

    /// `cursor` — где сейчас настоящий курсор (над зеркалом), глобально.
    public mutating func down(_ button: MirrorInput.Button, at point: CGPoint, clicks: Int, flags: CGEventFlags,
                              mapping: MirrorMapping, windowNumber: CGWindowID, cursor: CGPoint) -> [PointerStep] {
        guard state == .idle, let target = mapping.toTarget(point) else { return [] }
        let clicks = max(clicks, 1)
        switch (button, clickMode) {
        case (.left, _):
            state = .pressed(down: point, target: target, clicks: clicks, flags: flags, cursor: cursor)
            return []
        case (.right, .pid):
            return [.postToPid(Self.mouse(.rightDown, target, clicks, flags, windowNumber)),
                    .postToPid(Self.mouse(.rightUp, target, clicks, flags, windowNumber))]
        case (.right, .warp):
            // Меню открывается по нажатию и живёт в своём цикле: курсор остаётся на скрытом дисплее, пока меню не закроется.
            state = .handoff(.menu, activated: true)
            return [.activateTarget, .warp(target),
                    .postHID(Self.mouse(.rightDown, target, clicks, flags, 0)),
                    .postHID(Self.mouse(.rightUp, target, clicks, flags, 0)),
                    .beginHandoff(.menu)]
        }
    }

    public mutating func dragged(to point: CGPoint, mapping: MirrorMapping) -> [PointerStep] {
        guard case let .pressed(down, target, clicks, flags, _) = state, clickMode == .warp,
              hypot(point.x - down.x, point.y - down.y) >= dragThreshold else { return [] }
        let now = mapping.toTarget(Self.clamp(point, to: mapping.contentRect)) ?? target
        state = .handoff(.drag, activated: true)
        return [.hideCursor, .activateTarget, .warp(target),
                .postHID(Self.mouse(.leftDown, target, clicks, flags, 0)),
                .postHID(Self.mouse(.leftDragged, now, 1, flags, 0)),
                .showCursor, .beginHandoff(.drag)]
    }

    public mutating func up(mapping: MirrorMapping, windowNumber: CGWindowID) -> [PointerStep] {
        guard case let .pressed(_, target, clicks, flags, cursor) = state else { return [] }
        state = .idle
        let down = Self.mouse(.leftDown, target, clicks, flags, clickMode == .pid ? windowNumber : 0)
        let up = Self.mouse(.leftUp, target, clicks, flags, clickMode == .pid ? windowNumber : 0)
        switch clickMode {
        case .pid:
            return [.postToPid(down), .postToPid(up)]
        case .warp:
            return [.hideCursor, .activateTarget, .warp(target), .postHID(down), .postHID(up), .warp(cursor), .showCursor, .activateSelf]
        }
    }

    public mutating func scroll(dx: Double, dy: Double, precise: Bool, at point: CGPoint,
                                mapping: MirrorMapping, windowNumber: CGWindowID) -> [PointerStep] {
        guard state == .idle, let target = mapping.toTarget(point) else { return [] }
        let factor = (precise ? 1 : lineHeight) / Double(max(mapping.scale, 0.01))
        let x = Int32((dx * factor).rounded()), y = Int32((dy * factor).rounded())
        guard x != 0 || y != 0 else { return [] }
        let kind = SyntheticEvent.Kind.scroll(dx: x, dy: y, pixels: true)
        switch scrollMode {
        case .pid:
            return [.postToPid(SyntheticEvent(kind: kind, location: target, windowNumber: windowNumber))]
        case .handoff:
            // Прокрутка идёт в окно под курсором; программу не активируем — macOS прокручивает и неактивные окна.
            state = .handoff(.scroll, activated: false)
            return [.warp(target), .postHID(SyntheticEvent(kind: kind, location: target)), .beginHandoff(.scroll)]
        }
    }

    /// Конец передачи: курсор возвращается в ту точку зеркала, что соответствует его месту на скрытом дисплее
    /// (рука пользователя «продолжает» движение), но не за край зеркала.
    public mutating func endHandoff(cursorNow: CGPoint, mapping: MirrorMapping, mirrorRect: CGRect) -> [PointerStep] {
        guard case let .handoff(kind, activated) = state else { return [] }
        state = .idle
        var steps: [PointerStep] = [.warp(Self.returnPoint(cursorNow, mapping: mapping, mirrorRect: mirrorRect))]
        if activated { steps.append(.activateSelf) }
        steps.append(.endHandoff(kind))
        return steps
    }

    /// Зеркало закрылось или окно пропало: забыть нажатие (передачу завершает `endHandoff`).
    public mutating func cancelPress() {
        if case .pressed = state { state = .idle }
    }

    public static func returnPoint(_ cursor: CGPoint, mapping: MirrorMapping, mirrorRect: CGRect) -> CGPoint {
        let view = clamp(mapping.toView(cursor), to: CGRect(origin: .zero, size: mapping.viewSize))
        return CGPoint(x: mirrorRect.minX + view.x, y: mirrorRect.minY + view.y)
    }

    static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), max(rect.maxX - 1, rect.minX)),
                y: min(max(point.y, rect.minY), max(rect.maxY - 1, rect.minY)))
    }

    static func mouse(_ kind: SyntheticEvent.Kind, _ location: CGPoint, _ clicks: Int, _ flags: CGEventFlags, _ window: CGWindowID) -> SyntheticEvent {
        SyntheticEvent(kind: kind, location: location, clicks: clicks, flags: flags, windowNumber: window)
    }
}

/// Когда заканчивать передачу курсора. Время — секунды (`ProcessInfo.systemUptime`), чтобы тесты не ждали.
public struct HandoffWatch: Sendable {
    public let kind: HandoffKind
    public let started: TimeInterval
    private(set) var lastActivity: TimeInterval
    private(set) var menuSeen = false
    private(set) var menuGoneSince: TimeInterval?
    private(set) var buttonReleased = false

    /// Пауза в прокрутке (с инерцией), после которой курсор возвращается.
    public static let scrollIdle: TimeInterval = 0.35
    /// Меню не появилось за это время (щелчок мимо, у веб-страницы своё меню) — возвращаем курсор.
    public static let menuAppearTimeout: TimeInterval = 1.0
    /// Меню пропало и не вернулось (подменю перерисовывается) — закрыто.
    public static let menuGoneGrace: TimeInterval = 0.15
    /// Предохранитель: курсор не остаётся «в плену» скрытого дисплея.
    public static let maximum: [HandoffKind: TimeInterval] = [.drag: 120, .menu: 60, .scroll: 10]

    public init(kind: HandoffKind, at time: TimeInterval) {
        self.kind = kind
        self.started = time
        self.lastActivity = time
    }

    /// Событие прокрутки (или движение) на скрытом дисплее.
    public mutating func noteActivity(at time: TimeInterval) { lastActivity = time }

    public mutating func noteButtonUp() { buttonReleased = true }

    /// Есть ли сейчас у программы меню (окно слоя ≥ `HiddenWindowRules.popupLayer`) на скрытом дисплее.
    public mutating func noteMenu(visible: Bool, at time: TimeInterval) {
        if visible {
            menuSeen = true
            menuGoneSince = nil
        } else if menuSeen, menuGoneSince == nil {
            menuGoneSince = time
        }
    }

    public func shouldEnd(at time: TimeInterval) -> Bool {
        if time - started >= Self.maximum[kind, default: 30] { return true }
        switch kind {
        case .drag:
            return buttonReleased
        case .scroll:
            return time - lastActivity >= Self.scrollIdle
        case .menu:
            if let gone = menuGoneSince { return time - gone >= Self.menuGoneGrace }
            return !menuSeen && time - started >= Self.menuAppearTimeout
        }
    }
}

import Foundation
import CoreGraphics

/// Логика мини-панели над выделением (T2): где её ставить, когда показывать и какая кнопка какую команду `DocFormatter` вызывает.
/// Вида плитки здесь нет — его рисует интерфейс (`DS`), он берёт отсюда место, видимость, список действий и их состояние.
/// Все точки — в одной системе координат с `y` вниз (страницы `DocPagesView` перевёрнуты).
package enum DocMiniBar {
    /// Кнопки: начертания, цвет и выделение цветом, маркер/список, ссылка.
    package enum Action: CaseIterable, Hashable {
        case bold, italic, underline, strike, color, highlight, bullet, numbered, link

        package var title: String {
            switch self {
            case .bold: return "Жирный"
            case .italic: return "Курсив"
            case .underline: return "Подчёркнутый"
            case .strike: return "Зачёркнутый"
            case .color: return "Цвет текста"
            case .highlight: return "Выделение цветом"
            case .bullet: return "Маркированный список"
            case .numbered: return "Нумерованный список"
            case .link: return "Ссылка"
            }
        }
    }

    /// Сейчас включено ли начертание у выделения (для нажатой кнопки).
    package static func isActive(_ action: Action, state: DocFormatState) -> Bool {
        switch action {
        case .bold: return state.bold
        case .italic: return state.italic
        case .underline: return state.underline
        case .strike: return state.strike
        default: return false
        }
    }

    /// Кнопка работает или нет и почему не работает (подсказка вместо тишины). Списки и ссылки в файл пока не пишутся: у «Документа»
    /// есть правка готовых пунктов, но не создание списка; ссылка — заглушка по плану.
    package static func availability(_ action: Action) -> (enabled: Bool, reason: String?) {
        switch action {
        case .bullet, .numbered: return (false, "Создание списка пока не поддерживается: правятся готовые пункты. Изменить это можно в режиме «Код»")
        case .link: return (false, "Ссылки пока нельзя вставить в «Документе»")
        default: return (true, nil)
        }
    }

    /// Те же команды, что и у панели форматирования и сочетаний клавиш: байты после кнопки и после ⌘B те же.
    @MainActor package static func perform(_ action: Action, color: RTFColor? = nil, formatter: DocFormatter) {
        switch action {
        case .bold: formatter.toggleBold()
        case .italic: formatter.toggleItalic()
        case .underline: formatter.toggleUnderline()
        case .strike: formatter.toggleStrike()
        case .color: formatter.setColor(color)
        case .highlight: formatter.setHighlight(color)
        case .bullet, .numbered, .link:
            if let reason = availability(action).reason { formatter.controller?.show(notice: reason) }
        }
    }

    // MARK: - Где ставить

    package enum Side: Equatable { case above, below, right, left }

    package struct Placement: Equatable {
        package var origin: CGPoint
        package var side: Side
        package var frame: CGRect
    }

    /// Место плитки `bar` у выделения `selection` в видимой области `bounds`. Над выделением по центру; не хватает места сверху —
    /// под ним; нет и там (выделение во всю высоту) — сбоку; нигде нет — `nil` (панель не показывается, выделение не закрывается).
    /// По горизонтали плитка не выходит за `bounds` (отступ `margin`), но выделения никогда не перекрывает.
    package static func placement(selection: CGRect, bar: CGSize, bounds: CGRect, gap: CGFloat = 8, margin: CGFloat = 8) -> Placement? {
        guard selection.width >= 0, selection.height >= 0, bar.width > 0, bar.height > 0,
              bar.width + 2 * margin <= bounds.width, bar.height + 2 * margin <= bounds.height else { return nil }
        let minX = bounds.minX + margin, maxX = bounds.maxX - margin - bar.width
        func centeredX() -> CGFloat { min(max(selection.midX - bar.width / 2, minX), maxX) }
        func placed(_ origin: CGPoint, _ side: Side) -> Placement? {
            let frame = CGRect(origin: origin, size: bar)
            guard bounds.insetBy(dx: margin, dy: margin).contains(frame), !frame.intersects(selection) else { return nil }
            return Placement(origin: origin, side: side, frame: frame)
        }
        if let above = placed(CGPoint(x: centeredX(), y: selection.minY - gap - bar.height), .above) { return above }
        if let below = placed(CGPoint(x: centeredX(), y: selection.maxY + gap), .below) { return below }
        let middleY = min(max(selection.midY - bar.height / 2, bounds.minY + margin), bounds.maxY - margin - bar.height)
        if let right = placed(CGPoint(x: selection.maxX + gap, y: middleY), .right) { return right }
        return placed(CGPoint(x: selection.minX - gap - bar.width, y: middleY), .left)
    }

    // MARK: - Когда показывать

    /// Через сколько после появления выделения плитка должна быть на экране (≤ 150 мс по плану).
    package static let showDelay: TimeInterval = 0.12
    /// Сколько нет набора, чтобы плитка вернулась после печати.
    package static let typingQuiet: TimeInterval = 0.6

    /// Показывать ли плитку: есть выделение, не идёт набор методом ввода, кнопка мыши отпущена (выделение закончено) и недавно не печатали.
    package static func isVisible(selectionLength: Int, composing: Bool, mouseDown: Bool, secondsSinceEdit: TimeInterval) -> Bool {
        selectionLength > 0 && !composing && !mouseDown && secondsSinceEdit >= typingQuiet
    }
}

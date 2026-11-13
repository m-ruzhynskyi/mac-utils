import CoreGraphics

/// Ввод в окне-зеркале (координаты зеркала: точки, начало слева сверху).
public enum MirrorInput: Equatable, Sendable {
    public enum Button: Equatable, Sendable { case left, right }
    public enum Phase: Equatable, Sendable { case down, up, dragged }

    case mouse(Phase, Button, at: CGPoint, clicks: Int, flags: CGEventFlags)
    case moved(at: CGPoint)
    /// Прокрутка в точках (`scrollingDeltaX/Y` при `hasPreciseScrollingDeltas`), иначе в строках.
    case scroll(dx: Double, dy: Double, precise: Bool, at: CGPoint)
    /// `characters` — строка из NSEvent зеркала: Mac Utils активна, поэтому строка посчитана по раскладке пользователя.
    case key(code: CGKeyCode, down: Bool, flags: CGEventFlags, characters: String?)
}

/// Событие, которое уйдёт в процесс программы (`CGEvent.postToPid`). Описание без CGEvent — чтобы проверять без системы.
public struct SyntheticEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case leftDown, leftUp, leftDragged, rightDown, rightUp, rightDragged, moved
        case scroll(dx: Int32, dy: Int32, pixels: Bool)
        case keyDown, keyUp
    }

    public var kind: Kind
    /// Глобальная точка на скрытом дисплее (у клавиш — nil).
    public var location: CGPoint?
    public var clicks: Int = 0
    public var keyCode: CGKeyCode = 0
    public var flags: CGEventFlags = []
    /// Текст вместо кода клавиши (`keyboardSetUnicodeString`): не зависит от раскладки, с которой работает программа.
    public var text: String?
    /// Номер окна для полей 91/92 (`mouseEventWindowUnderMousePointer…`): без них AppKit ищет окно по точке.
    public var windowNumber: CGWindowID = 0
}

/// Что делать с сочетанием клавиш в зеркале.
public enum ShortcutRoute: Equatable, Sendable {
    /// Отправить в программу (⌘V, ⌘C, ⌘A, ⌘Z, ⌘↩ …).
    case forward
    /// Оставить Mac Utils (⌘Tab, ⌘H, ⌘M, ⌘W закрывает зеркало, а не окно ИИ).
    case keepLocal
    /// Никуда: ⌘Q закрыл бы саму программу ИИ, она бы исчезла с виртуального дисплея и выдала себя при следующем запуске.
    case drop
}

public enum MirrorKeys {
    // Коды клавиш ANSI (kVK_*), чтобы не тянуть Carbon в чистую логику.
    public static let q: CGKeyCode = 12, w: CGKeyCode = 13, h: CGKeyCode = 4, m: CGKeyCode = 46, v: CGKeyCode = 9
    public static let tab: CGKeyCode = 48, `return`: CGKeyCode = 36, delete: CGKeyCode = 51, escape: CGKeyCode = 53
    public static let comma: CGKeyCode = 43, grave: CGKeyCode = 50

    public static func route(code: CGKeyCode, flags: CGEventFlags) -> ShortcutRoute {
        guard flags.contains(.maskCommand) else { return .forward }
        switch code {
        case q: return .drop
        case w, h, m, tab, grave, comma: return .keepLocal
        default: return .forward
        }
    }

    /// Печатный текст: не пустой, без управляющих символов и без «функциональной» области AppKit (стрелки, F-клавиши: U+F700…U+F8FF).
    static func isPrintable(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}

/// Перевод ввода зеркала в события для программы на скрытом дисплее.
public struct MirrorInputTranslator: Sendable {
    public var mapping: MirrorMapping
    public var windowNumber: CGWindowID
    /// Сколько точек даёт одна «строка» колёсика без точной прокрутки.
    public var lineHeight: Double = 10

    public init(mapping: MirrorMapping, windowNumber: CGWindowID) {
        self.mapping = mapping
        self.windowNumber = windowNumber
    }

    public func translate(_ input: MirrorInput) -> [SyntheticEvent] {
        switch input {
        case let .mouse(phase, button, point, clicks, flags):
            guard let location = mapping.toTarget(point) else { return [] }
            let kind: SyntheticEvent.Kind
            switch (phase, button) {
            case (.down, .left): kind = .leftDown
            case (.up, .left): kind = .leftUp
            case (.dragged, .left): kind = .leftDragged
            case (.down, .right): kind = .rightDown
            case (.up, .right): kind = .rightUp
            case (.dragged, .right): kind = .rightDragged
            }
            return [SyntheticEvent(kind: kind, location: location, clicks: max(clicks, 1), flags: flags, windowNumber: windowNumber)]
        case let .moved(point):
            guard let location = mapping.toTarget(point) else { return [] }
            return [SyntheticEvent(kind: .moved, location: location, windowNumber: windowNumber)]
        case let .scroll(dx, dy, precise, point):
            guard let location = mapping.toTarget(point) else { return [] }
            // Зеркало может быть уменьшено: прокрутка в точках зеркала → в точки окна.
            let factor = (precise ? 1 : lineHeight) / Double(max(mapping.scale, 0.01))
            let x = Int32((dx * factor).rounded()), y = Int32((dy * factor).rounded())
            guard x != 0 || y != 0 else { return [] }
            return [SyntheticEvent(kind: .scroll(dx: x, dy: y, pixels: true), location: location, windowNumber: windowNumber)]
        case let .key(code, down, flags, characters):
            guard MirrorKeys.route(code: code, flags: flags) == .forward else { return [] }
            var event = SyntheticEvent(kind: down ? .keyDown : .keyUp, keyCode: code, flags: flags)
            // Без ⌘/⌃ печатный символ идёт строкой (русский, «ё», эмодзи — без зависимости от раскладки программы).
            // Сочетания (⌘V из зеркала или Ctrl+V, который «Клавиши Windows» уже превратили в ⌘V) — кодом и флагами.
            if !flags.contains(.maskCommand), !flags.contains(.maskControl), MirrorKeys.isPrintable(characters) {
                event.text = characters
            }
            return [event]
        }
    }
}

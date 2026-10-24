import AppKit
import Carbon.HIToolbox
import MUCore

/// Действие плеера по клавише (§ 8.1 плана). Клавиши — только в окне плеера, без глобальных `HotKeyRegistry`.
enum PlayerAction: String, CaseIterable {
    case togglePlay
    case seekBackward, seekForward, seekBackwardMinute, seekForwardMinute, jumpBackward, jumpForward
    case frameBackward, frameForward
    case volumeUp, volumeDown, mute
    case slower, faster
    case skip, snapshot
    case subtitlesMenu, audioMenu, subtitlesEarlier, subtitlesLater
    case fullScreen, exitFullScreen, videoOnly, pictureInPicture, playlist
    case restart, undoSkip
    case open, openInNewWindow
}

/// Одна строка таблицы: название, раздел «Шпаргалки», клавиши для показа и для разбора событий.
struct PlayerShortcut: Equatable {
    struct Key: Hashable {
        let keyCode: Int
        let modifiers: NSEvent.ModifierFlags

        init(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags = []) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection(PlayerShortcuts.relevantModifiers)
        }

        static func == (a: Key, b: Key) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }
        func hash(into hasher: inout Hasher) {
            hasher.combine(keyCode)
            hasher.combine(modifiers.rawValue)
        }
    }

    let action: PlayerAction
    let title: String
    let section: String
    /// Как показать: «Пробел / K», «⇧S».
    let label: String
    let keys: [Key]
}

/// Единая таблица клавиш плеера: по ней работает обработчик окна, по ней же «Шпаргалка» показывает группу «Видеоплеер».
/// `PlayerShortcutsTests` сверяет таблицу и разбор событий в обе стороны.
enum PlayerShortcuts {
    static let relevantModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    static let playback = "Воспроизведение"
    static let navigation = "Перемотка"
    static let view = "Вид и дорожки"

    static let all: [PlayerShortcut] = [
        PlayerShortcut(action: .togglePlay, title: "Пауза / играть", section: playback, label: "Пробел / K",
                       keys: [.init(kVK_Space), .init(kVK_ANSI_K)]),
        PlayerShortcut(action: .seekBackward, title: "Назад на шаг перемотки", section: navigation, label: "←",
                       keys: [.init(kVK_LeftArrow)]),
        PlayerShortcut(action: .seekForward, title: "Вперёд на шаг; удерживать — 2×", section: navigation, label: "→",
                       keys: [.init(kVK_RightArrow)]),
        PlayerShortcut(action: .seekBackwardMinute, title: "Назад на 1 минуту", section: navigation, label: "⇧←",
                       keys: [.init(kVK_LeftArrow, .shift)]),
        PlayerShortcut(action: .seekForwardMinute, title: "Вперёд на 1 минуту", section: navigation, label: "⇧→",
                       keys: [.init(kVK_RightArrow, .shift)]),
        PlayerShortcut(action: .jumpBackward, title: "Назад на 10 с", section: navigation, label: "J",
                       keys: [.init(kVK_ANSI_J)]),
        PlayerShortcut(action: .jumpForward, title: "Вперёд на 10 с", section: navigation, label: "L",
                       keys: [.init(kVK_ANSI_L)]),
        PlayerShortcut(action: .frameBackward, title: "Кадр назад (на паузе)", section: navigation, label: ",",
                       keys: [.init(kVK_ANSI_Comma)]),
        PlayerShortcut(action: .frameForward, title: "Кадр вперёд (на паузе)", section: navigation, label: ".",
                       keys: [.init(kVK_ANSI_Period)]),
        PlayerShortcut(action: .restart, title: "С начала", section: navigation, label: "⌥←",
                       keys: [.init(kVK_LeftArrow, .option)]),
        PlayerShortcut(action: .skip, title: "Пропустить интро, титры (внутри отрезка)", section: navigation, label: "S / ↩",
                       keys: [.init(kVK_ANSI_S), .init(kVK_Return), .init(kVK_ANSI_KeypadEnter)]),
        PlayerShortcut(action: .undoSkip, title: "Вернуть пропущенное", section: navigation, label: "⌘Z",
                       keys: [.init(kVK_ANSI_Z, .command)]),
        PlayerShortcut(action: .volumeUp, title: "Громче", section: playback, label: "↑", keys: [.init(kVK_UpArrow)]),
        PlayerShortcut(action: .volumeDown, title: "Тише", section: playback, label: "↓", keys: [.init(kVK_DownArrow)]),
        PlayerShortcut(action: .mute, title: "Без звука", section: playback, label: "M", keys: [.init(kVK_ANSI_M)]),
        PlayerShortcut(action: .slower, title: "Медленнее на 0,25", section: playback, label: "[",
                       keys: [.init(kVK_ANSI_LeftBracket)]),
        PlayerShortcut(action: .faster, title: "Быстрее на 0,25", section: playback, label: "]",
                       keys: [.init(kVK_ANSI_RightBracket)]),
        PlayerShortcut(action: .snapshot, title: "Снимок кадра в «Мои снимки»", section: view, label: "⇧S",
                       keys: [.init(kVK_ANSI_S, .shift)]),
        PlayerShortcut(action: .subtitlesMenu, title: "Субтитры", section: view, label: "V", keys: [.init(kVK_ANSI_V)]),
        PlayerShortcut(action: .subtitlesEarlier, title: "Субтитры раньше на 0,1 с", section: view, label: "Z",
                       keys: [.init(kVK_ANSI_Z)]),
        PlayerShortcut(action: .subtitlesLater, title: "Субтитры позже на 0,1 с", section: view, label: "X",
                       keys: [.init(kVK_ANSI_X)]),
        PlayerShortcut(action: .audioMenu, title: "Аудиодорожка", section: view, label: "A", keys: [.init(kVK_ANSI_A)]),
        PlayerShortcut(action: .fullScreen, title: "Полный экран", section: view, label: "F", keys: [.init(kVK_ANSI_F)]),
        PlayerShortcut(action: .exitFullScreen, title: "Выйти из полного экрана, закрыть меню", section: view, label: "esc",
                       keys: [.init(kVK_Escape)]),
        PlayerShortcut(action: .videoOnly, title: "Только видео", section: view, label: "⌃⌘T",
                       keys: [.init(kVK_ANSI_T, [.control, .command])]),
        PlayerShortcut(action: .pictureInPicture, title: "Картинка в картинке", section: view, label: "P",
                       keys: [.init(kVK_ANSI_P)]),
        PlayerShortcut(action: .playlist, title: "Плейлист", section: view, label: "⌘L", keys: [.init(kVK_ANSI_L, .command)]),
        PlayerShortcut(action: .open, title: "Открыть…", section: view, label: "⌘O", keys: [.init(kVK_ANSI_O, .command)]),
        PlayerShortcut(action: .openInNewWindow, title: "Открыть в новом окне…", section: view, label: "⌥⌘O",
                       keys: [.init(kVK_ANSI_O, [.option, .command])]),
    ]

    private static let byKey: [PlayerShortcut.Key: PlayerAction] = {
        var map: [PlayerShortcut.Key: PlayerAction] = [:]
        for shortcut in all { for key in shortcut.keys { map[key] = shortcut.action } }
        return map
    }()

    /// Действие по клавише; `nil` — клавиша не плеера (пусть идёт дальше по цепочке).
    static func action(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> PlayerAction? {
        byKey[PlayerShortcut.Key(keyCode, modifiers)]
    }

    static func shortcut(for action: PlayerAction) -> PlayerShortcut? { all.first { $0.action == action } }

    /// Подпись клавиши для подсказок («Снимок кадра (⇧S)»).
    static func label(_ action: PlayerAction) -> String { shortcut(for: action)?.label ?? "" }

    /// Группа «Видеоплеер» для «Шпаргалки».
    static var cheatGroup: CheatGroup {
        CheatGroup(title: "Видеоплеер", items: all.map { CheatItem(title: $0.title, shortcut: $0.label) })
    }
}

// MARK: - Удержание →

/// → коротко — перемотка вперёд на отпускание; удержание ≥ 0,3 с — 2×, пока держите (§ 8.1).
/// Повторы клавиши (`isARepeat`) не учитываются. Чистый автомат: время — снаружи.
struct HoldToFastForward: Equatable {
    static let threshold: Double = 0.3

    enum Event: Equatable { case none, seekForward, beginHold, endHold }

    private(set) var pressedAt: Double?
    private(set) var holding = false

    mutating func keyDown(at time: Double, isRepeat: Bool) -> Event {
        guard !isRepeat, pressedAt == nil else { return .none }
        pressedAt = time
        return .none
    }

    /// Проверка по таймеру через `threshold` после нажатия.
    mutating func tick(at time: Double) -> Event {
        guard let pressedAt, !holding, time - pressedAt >= Self.threshold - 0.0001 else { return .none }
        holding = true
        return .beginHold
    }

    mutating func keyUp(at time: Double) -> Event {
        defer { reset() }
        if holding { return .endHold }
        guard let pressedAt else { return .none }
        return time - pressedAt < Self.threshold ? .seekForward : .none
    }

    /// Окно потеряло фокус посреди удержания — вернуть скорость.
    mutating func cancel() -> Event {
        defer { reset() }
        return holding ? .endHold : .none
    }

    private mutating func reset() {
        pressedAt = nil
        holding = false
    }

    /// Что сделать в начале удержания: скорость 2× (если выбрана меньше) и играть, если стояла пауза.
    static func boost(rate: Float, playing: Bool) -> (rate: Float?, play: Bool) {
        (rate >= 2 ? nil : 2, !playing)
    }
}

// MARK: - Клики по видео

/// Треть кадра под курсором: двойной клик слева — назад, справа — вперёд, посередине — полный экран.
enum ClickZone: Equatable {
    case left, middle, right

    static func at(x: CGFloat, width: CGFloat) -> ClickZone {
        guard width > 0 else { return .middle }
        if x < width / 3 { return .left }
        if x > width * 2 / 3 { return .right }
        return .middle
    }
}

/// Серия кликов по видео (§ 8.1): одиночный — пауза сразу; второй клик серии возвращает паузу как было и перематывает
/// на 10 с (или полный экран посередине); каждый следующий быстрый — ещё 10 с. `count` — `NSEvent.clickCount`.
struct ClickSeries: Equatable {
    static let step: Double = 10

    enum Action: Equatable {
        case togglePlay
        case restore(playing: Bool)
        case seek(Double)
        /// Подсказка у края: «‹‹ 20 с».
        case hint(ClickZone, seconds: Int)
        case fullScreen
    }

    private var playingBeforeSeries = false

    mutating func click(count: Int, zone: ClickZone, playing: Bool) -> [Action] {
        switch count {
        case ...1:
            playingBeforeSeries = playing
            return [.togglePlay]
        case 2:
            switch zone {
            case .middle: return [.restore(playing: playingBeforeSeries), .fullScreen]
            case .left, .right:
                return [.restore(playing: playingBeforeSeries), .seek(zone == .left ? -Self.step : Self.step),
                        .hint(zone, seconds: Int(Self.step))]
            }
        default:
            guard zone != .middle else { return [] }
            return [.seek(zone == .left ? -Self.step : Self.step), .hint(zone, seconds: Int(Self.step) * (count - 1))]
        }
    }
}

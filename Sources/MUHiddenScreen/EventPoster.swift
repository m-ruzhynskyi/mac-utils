import AppKit
import CoreGraphics

/// Куда уходят синтетические события. В тестах — запись в массив, в программе — `PidEventPoster`.
public protocol SyntheticEventSink: AnyObject {
    func post(_ events: [SyntheticEvent], to pid: pid_t)
}

/// `SyntheticEvent` → `CGEvent`.
enum SyntheticEventFactory {
    /// Метка своих событий (`eventSourceUserData`, «MUHS»): перехват нажатий над зеркалом их пропускает.
    static let marker: Int64 = 0x4D55_4853

    static func make(_ event: SyntheticEvent, source: CGEventSource?) -> CGEvent? {
        let cgEvent: CGEvent?
        switch event.kind {
        case .leftDown, .leftUp, .leftDragged, .rightDown, .rightUp, .rightDragged, .moved:
            let (type, button): (CGEventType, CGMouseButton) = {
                switch event.kind {
                case .leftDown: return (.leftMouseDown, .left)
                case .leftUp: return (.leftMouseUp, .left)
                case .leftDragged: return (.leftMouseDragged, .left)
                case .rightDown: return (.rightMouseDown, .right)
                case .rightUp: return (.rightMouseUp, .right)
                case .rightDragged: return (.rightMouseDragged, .right)
                default: return (.mouseMoved, .left)
                }
            }()
            cgEvent = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: event.location ?? .zero, mouseButton: button)
            cgEvent?.setIntegerValueField(.mouseEventClickState, value: Int64(max(event.clicks, 1)))
        case let .scroll(dx, dy, pixels):
            cgEvent = CGEvent(scrollWheelEvent2Source: source, units: pixels ? .pixel : .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            cgEvent?.setIntegerValueField(.scrollWheelEventIsContinuous, value: pixels ? 1 : 0)
            if let location = event.location { cgEvent?.location = location }
        case .keyDown, .keyUp:
            cgEvent = CGEvent(keyboardEventSource: source, virtualKey: event.keyCode, keyDown: event.kind == .keyDown)
            if let text = event.text {
                let units = Array(text.utf16)
                cgEvent?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
        }
        guard let cgEvent else { return nil }
        cgEvent.flags = event.flags
        cgEvent.setIntegerValueField(.eventSourceUserData, value: marker)
        if event.windowNumber != 0 {
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(event.windowNumber))
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(event.windowNumber))
        }
        return cgEvent
    }
}

/// `CGEvent.postToPid`: событие только в очередь процесса, курсор не двигается, программа не активируется.
/// Проверено менеджером 13.11: текст (кириллица), Backspace и ⌘V доходят до неактивных Claude и ChatGPT; щелчки — нет.
public final class PidEventPoster: SyntheticEventSink {
    private let source = CGEventSource(stateID: .privateState)

    public init() {}

    public func post(_ events: [SyntheticEvent], to pid: pid_t) {
        for event in events {
            SyntheticEventFactory.make(event, source: source)?.postToPid(pid)
        }
    }
}

/// Настоящий курсор и события уровня HID: перенос, скрытие, нажатия. Только для шагов `PointerStep`.
public final class HIDPointer {
    private let source: CGEventSource?
    private var hiddenCount = 0

    public init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Без задержки после переноса курсора: иначе физическая мышь «замирает» на 0,25 с после каждого щелчка в зеркале.
        source?.localEventsSuppressionInterval = 0
    }

    public var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    public func warp(to point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Снова связать мышь и курсор (после warp macOS разрывает их на время подавления).
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    public func post(_ event: SyntheticEvent) {
        SyntheticEventFactory.make(event, source: source)?.post(tap: .cghidEventTap)
    }

    /// Скрытие курсора действует, пока Mac Utils активна; счётчик держит пары hide/show в равновесии.
    public func hideCursor() {
        if CGDisplayHideCursor(CGMainDisplayID()) == .success { hiddenCount += 1 }
    }

    public func showCursor() {
        guard hiddenCount > 0 else { return }
        hiddenCount -= 1
        CGDisplayShowCursor(CGMainDisplayID())
    }

    /// На выходе: курсор не должен остаться спрятанным.
    public func restoreCursor() {
        while hiddenCount > 0 { showCursor() }
    }
}

/// ⌘V в программу на скрытом дисплее (вставка после перетаскивания или подмены буфера).
public enum PasteKeystroke {
    public static func events() -> [SyntheticEvent] {
        [SyntheticEvent(kind: .keyDown, keyCode: MirrorKeys.v, flags: .maskCommand),
         SyntheticEvent(kind: .keyUp, keyCode: MirrorKeys.v, flags: .maskCommand)]
    }
}

/// `NSPasteboard` как хранилище для `ClipboardSwap`.
public final class SystemPasteboard: PasteboardStore {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [String: Data] = [:]
            for type in item.types { copy[type.rawValue] = item.data(forType: type) }
            return copy
        }
    }

    @discardableResult
    public func replace(with items: [[String: Data]]) -> Int {
        pasteboard.clearContents()
        let objects = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pasteboard.writeObjects(objects)
        return pasteboard.changeCount
    }
}

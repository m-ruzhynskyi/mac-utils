import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MUCore

/// Где был фокус, когда запрос ушёл к модели: программа, поле (AX-элемент) и выделение. Нужен, чтобы не вставить текст
/// «не туда» и не заменить выделение, которое пользователь успел сделать другим.
struct FocusSnapshot: Equatable {
    var pid: pid_t
    /// Хеш AX-элемента в фокусе; nil — программа не отдаёт его (часть Electron/Java): сверять можно только программу.
    var field: Int?
    /// Выделенный текст в этом поле на момент снимка; nil — прочитать нельзя.
    var selection: String?

    init(pid: pid_t, field: Int?, selection: String? = nil) {
        self.pid = pid
        self.field = field
        self.selection = selection
    }

    enum PasteDecision: Equatable {
        case paste
        case clipboard(reason: String)
    }

    /// Вставлять только если пользователь остался в той же программе и том же поле **и** выделено всё то же:
    /// - выделение читается — оно обязано совпасть с исходным текстом (другое выделение или курсор без выделения → буфер);
    /// - не читается (Chrome, Electron) — проверить нечем, поэтому любое нажатие или клик после запроса → буфер.
    /// `original` nil — старая проверка только по программе и полю (для тестов).
    static func decide(before: FocusSnapshot?, now: FocusSnapshot?, original: String? = nil,
                       inputSinceRequest: Bool = false) -> PasteDecision {
        guard let before, let now else { return .clipboard(reason: "Не удалось определить, где вы сейчас") }
        guard before.pid == now.pid else { return .clipboard(reason: "Вы перешли в другую программу") }
        if let was = before.field {
            guard let isNow = now.field else { return .clipboard(reason: "Поле ввода изменилось") }
            guard was == isNow else { return .clipboard(reason: "Вы перешли в другое поле") }
        }
        guard let original else { return .paste }
        if let selection = now.selection {
            return selection == original ? .paste : .clipboard(reason: "Выделение изменилось")
        }
        return inputSinceRequest ? .clipboard(reason: "Вы продолжили работу, не могу проверить выделение") : .paste
    }

    /// Было ли нажатие клавиши или клик за последние `seconds` секунд.
    static func hadInput(within seconds: TimeInterval) -> Bool {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown].contains { type in
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) < seconds
        }
    }

    @MainActor
    static func capture() -> FocusSnapshot? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        // Запрос к конкретной программе с коротким таймаутом: глобальный таймаут AX не меняем.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        var field: Int?
        var selection: String?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            field = Int(bitPattern: CFHash(focused))
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success {
                selection = value as? String
            }
        }
        return FocusSnapshot(pid: pid, field: field, selection: selection)
    }
}

/// ⌃⌥E: исправить ошибки и опечатки в выделенном тексте локальной моделью и заменить выделение.
@MainActor
final class TextFixer {
    static let shared = TextFixer()

    private var busy = false
    private var task: Task<Void, Never>?
    /// Номер уведомления «Исправляю…»: убираем только его, не чужое (например, прогресс GIF).
    private var fixToast: Int?

    static let system = """
    Ты корректор. Исправь орфографию, опечатки, пунктуацию и грамматику в тексте пользователя. \
    Сохрани язык, смысл, стиль, регистр, разметку и переносы строк. Ничего не добавляй и не объясняй. \
    Если ошибок нет — верни текст без изменений. Ответь только исправленным текстом.
    """

    func sync() {
        let center = HotKeyCenter.shared
        guard Ollama.isOn(Pref.aiFixText) else {
            center.unregister(id: HotKeyID.fixText)
            return
        }
        center.register(id: HotKeyID.fixText, keyCode: kVK_ANSI_E, modifiers: controlKey | optionKey) {
            AppAction(hotKey: .fixText).run()
        }
    }

    /// Почему ⌃⌥E сейчас не сработает (nil — можно). Secure Input включают поля паролей и некоторые терминалы:
    /// в них macOS не отдаёт выделение и не принимает вставку от других программ.
    nonisolated static func blockedMessage(secureInput: Bool) -> String? {
        secureInput ? "В этом поле исправление недоступно (защищённый ввод — пароль или терминал)" : nil
    }

    /// ⌘Z шлём, только если пользователь всё ещё в той программе, куда вставили текст: иначе отменится чужое действие.
    nonisolated static func canUndo(pastedIn: pid_t?, frontmost: pid_t?) -> Bool {
        guard let pastedIn, let frontmost else { return false }
        return pastedIn == frontmost
    }

    func fix() {
        guard !busy else { return }
        if let message = Self.blockedMessage(secureInput: IsSecureEventInputEnabled()) {
            Toast.show(message, symbol: "lock.fill", tint: .orange)
            return
        }
        busy = true
        task = Task {
            defer { busy = false; task = nil }
            var text = LayoutFix.selectedTextViaAX()
            if text?.isEmpty ?? true { text = await LayoutFix.selectedTextViaCopy() }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Toast.show("Выделите текст, который нужно исправить", symbol: "text.cursor", tint: .orange)
                return
            }
            guard text.count <= 6000 else {
                Toast.show("Слишком длинный текст — выделите поменьше", symbol: "exclamationmark.triangle.fill", tint: .orange)
                return
            }
            // Фокус запоминаем до запроса: ответ модели может прийти через десятки секунд.
            let before = FocusSnapshot.capture()
            let startedAt = Date()
            let toast = Toast.show("Исправляю…", symbol: "sparkles", tint: .purple,
                                   action: Toast.Action(title: "Отмена") { TextFixer.shared.cancel() }, sticky: true)
            fixToast = toast
            do {
                let answer = try await Ollama.generate(text, system: Self.system, temperature: 0, maxTokens: max(200, text.count))
                try Task.checkCancellation()
                let fixed = AIParsing.keepingEdges(of: text, AIParsing.cleanedText(answer))
                guard !fixed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { Toast.dismiss(token: toast); return }
                if fixed == text {
                    Toast.show("Ошибок не найдено", symbol: "checkmark.circle.fill")
                    return
                }
                let waited = Date().timeIntervalSince(startedAt)
                let decision = FocusSnapshot.decide(before: before, now: FocusSnapshot.capture(), original: text,
                                                    inputSinceRequest: FocusSnapshot.hadInput(within: waited))
                switch decision {
                case .paste:
                    await Self.paste(fixed)
                    let pastedIn = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    Toast.show("Текст исправлен", symbol: "sparkles", tint: .purple, action: Toast.Action(title: "Отменить") {
                        guard Self.canUndo(pastedIn: pastedIn, frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier) else {
                            Toast.show("Вы перешли в другую программу — отмените вставку там (⌘Z)",
                                       symbol: "exclamationmark.triangle.fill", tint: .orange)
                            return
                        }
                        Self.undo()
                    })
                case .clipboard(let reason):
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fixed, forType: .string)
                    Toast.show("\(reason): исправленный текст в буфере (прежнее содержимое буфера заменено)", symbol: "doc.on.clipboard", tint: .purple)
                }
            } catch is CancellationError {
                Toast.dismiss(token: toast)
            } catch let error as URLError where error.code == .cancelled {
                Toast.dismiss(token: toast)
            } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
    }

    /// «Отмена» в уведомлении «Исправляю…»: запрос к модели прерывается, ничего не вставляется.
    func cancel() {
        task?.cancel()
        Toast.dismiss(token: fixToast)
    }

    /// Вставка через буфер обмена (надёжно для длинного текста с переносами), затем буфер возвращается.
    static func paste(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        press(kVK_ANSI_V, flags: .maskCommand)
        try? await Task.sleep(nanoseconds: 400_000_000)
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }

    private static func undo() {
        press(kVK_ANSI_Z, flags: .maskCommand)
    }

    private static func press(_ key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cgSessionEventTap)
        }
    }
}

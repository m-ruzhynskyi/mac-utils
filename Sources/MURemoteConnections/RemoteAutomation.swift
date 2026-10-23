import Foundation

// Всё, чем подключение трогает систему, — протоколами: в приложении AXUIElement, NSWorkspace и CGEvent,
// в тестах — дерево значений и записи нажатий. Модуль сам ничего не запускает и не вводит.

/// Элемент интерфейса чужой программы. Значение поля пароля не читается никогда — только его длина.
public protocol AXNode: AnyObject {
    var role: String? { get }
    var subrole: String? { get }
    /// Заголовок окна, кнопки, галочки или текст надписи (`AXStaticText`). У полей ввода — nil.
    var label: String? { get }
    var children: [AXNode] { get }
    var processID: Int32? { get }
    /// Сколько символов в поле; nil — не прочиталось.
    var valueLength: Int? { get }
    /// Состояние галочки; nil — не галочка.
    var isChecked: Bool? { get }
    /// Кнопка по умолчанию окна (`AXDefaultButton`).
    var defaultButton: AXNode? { get }

    func isSame(as other: AXNode) -> Bool
    /// Записать секрет в поле (`AXValue`). Строка для AX создаётся из байтов прямо перед вызовом.
    func setSecretValue(_ secret: SecretBuffer) -> Bool
    func clearValue() -> Bool
    func focus() -> Bool
    func press() -> Bool

    /// Подсказка пустого поля (`AXPlaceholderValue`): у полей веб-интерфейса TeamViewer подписи часто только в ней.
    var placeholder: String? { get }
    /// `AXDescription`: подпись кнопок и полей веб-интерфейса, у которых нет заголовка.
    var detail: String? { get }
    /// Записать в обычное поле не секретный текст (ID компьютера).
    func setText(_ text: String) -> Bool
}

extension AXNode {
    public var placeholder: String? { nil }
    public var detail: String? { nil }
    public func setText(_ text: String) -> Bool { false }
}

/// Доступ к дереву интерфейса («Универсальный доступ»).
public protocol AXAccess: AnyObject {
    /// Разрешение уже выдано. Модуль его не запрашивает.
    var isTrusted: Bool { get }
    func windows(ofProcess pid: Int32) -> [AXNode]
    /// Элемент с фокусом клавиатуры в этом процессе.
    func focusedElement(ofProcess pid: Int32) -> AXNode?
}

/// Программы на компьютере: есть ли, открыть ссылку, какой процесс впереди.
public protocol AppLauncher: AnyObject {
    func isInstalled(bundleID: String) -> Bool
    /// Открыть ссылку подключения (`anydesk:…`). Пароль в ссылке не передаётся.
    func open(_ url: URL) -> Bool
    func runningProcess(bundleID: String) -> Int32?
    func bundleID(ofProcess pid: Int32) -> String?
    /// Team ID действительной подписи процесса; nil — подпись не проверилась.
    func teamID(ofProcess pid: Int32) -> String?
    var frontmostProcess: Int32? { get }
    func activate(process pid: Int32)
}

/// Нажатия клавиш — только в процесс `pid`.
public protocol KeyboardSender: AnyObject {
    /// Один символ: 1–2 единицы UTF-16. Буфер затирается вызывающим сразу после вызова.
    func type(_ units: UnsafeBufferPointer<UInt16>, to pid: Int32)
    func pressReturn(to pid: Int32)
}

/// Часы и ожидание. В тестах время идёт мгновенно.
public protocol RemoteClock: AnyObject {
    /// Миллисекунды от любой точки отсчёта.
    var milliseconds: Int { get }
    /// Бросает при отмене задачи.
    func sleep(milliseconds: Int) async throws
}

public final class SystemClock: RemoteClock {
    private let start = DispatchTime.now().uptimeNanoseconds

    public init() {}

    public var milliseconds: Int { Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }

    public func sleep(milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(milliseconds, 0)) * 1_000_000)
    }
}

// MARK: - Поиск по дереву

enum AXTree {
    static let maxDepth = 14
    static let maxNodes = 600

    static func isSecureField(_ node: AXNode) -> Bool {
        node.subrole == "AXSecureTextField" || node.role == "AXSecureTextField"
    }

    static func isTextInput(_ node: AXNode) -> Bool {
        !isSecureField(node) && ["AXTextField", "AXComboBox", "AXSearchField"].contains(node.role ?? "")
    }

    /// Все подписи элемента: заголовок, описание, подсказка.
    static func names(of node: AXNode) -> [String] {
        [node.label, node.detail, node.placeholder].compactMap { $0 }
    }

    /// Предки `target` от корня до него самого; nil — его нет в дереве.
    static func path(to target: AXNode, in root: AXNode) -> [AXNode]? {
        var stack: [AXNode] = []
        var found: [AXNode]?
        visit(root) { node, depth in
            stack.removeSubrange(min(depth, stack.count)...)
            stack.append(node)
            if node.isSame(as: target) { found = stack; return false }
            return true
        }
        return found
    }

    /// Подходящий элемент, ближайший к `target`: в самом тесном общем контейнере.
    static func nearest(to target: AXNode, in root: AXNode, where match: (AXNode) -> Bool) -> AXNode? {
        guard let path = path(to: target, in: root) else { return nil }
        for ancestor in path.reversed() {
            if let hit = first(in: ancestor, where: match) { return hit }
        }
        return nil
    }

    /// Обход в глубину с пределами: у чужой программы дерево может быть огромным или зацикленным.
    static func visit(_ root: AXNode, _ body: (AXNode, Int) -> Bool) {
        var budget = maxNodes
        func walk(_ node: AXNode, _ depth: Int) -> Bool {
            budget -= 1
            guard budget >= 0, body(node, depth) else { return false }
            guard depth < maxDepth else { return true }
            for child in node.children where !walk(child, depth + 1) { return false }
            return true
        }
        _ = walk(root, 0)
    }

    static func first(in root: AXNode, where match: (AXNode) -> Bool) -> AXNode? {
        var found: AXNode?
        visit(root) { node, _ in
            if match(node) { found = node; return false }
            return true
        }
        return found
    }

    static func all(in root: AXNode, where match: (AXNode) -> Bool) -> [AXNode] {
        var out: [AXNode] = []
        visit(root) { node, _ in
            if match(node) { out.append(node) }
            return true
        }
        return out
    }

    /// Структура окна для разбора «поле не найдено»: только роли и глубина, без заголовков и значений.
    static func structure(of root: AXNode, limit: Int = 80) -> [String] {
        var lines: [String] = []
        visit(root) { node, depth in
            guard lines.count < limit else { return false }
            let role = node.role ?? "?"
            let sub = node.subrole.map { "/\($0)" } ?? ""
            lines.append(String(repeating: "  ", count: depth) + role + sub)
            return true
        }
        return lines
    }
}

import AppKit

/// «Строка меню»: прячет лишние значки, как Hidden Bar. Два своих значка:
/// стрелка (свернуть/развернуть) и разделитель. Всё, что левее разделителя,
/// при сворачивании уезжает за край экрана: разделитель становится очень длинным.
/// Пока функция выключена, у Mac Utils значков в строке меню нет.
@MainActor
final class MenuBarHider: NSObject, ObservableObject {
    static let shared = MenuBarHider()

    @Published private(set) var isCollapsed = false
    @Published private(set) var isRunning = false
    /// Разделитель оказался правее стрелки — свернуть нельзя, иначе пропадёт и стрелка.
    @Published private(set) var misplaced = false

    static let collapsedLength: CGFloat = 10_000
    private static let separatorLength: CGFloat = 10

    private var toggleItem: NSStatusItem?
    private var separatorItem: NSStatusItem?
    private var collapseTimer: Timer?

    private override init() {
        super.init()
    }

    // MARK: - Включение

    func sync() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: Pref.menuBarHider)
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.menuBarToggle)

        guard enabled else {
            removeItems()
            isRunning = false
            return
        }
        createItemsIfNeeded()
        let key = LayoutHotKey.load(codeKey: Pref.menuBarKeyCode, modifiersKey: Pref.menuBarModifiers,
                                    default: .controlOptionM)
        center.register(id: HotKeyID.menuBarToggle, keyCode: key.keyCode, modifiers: key.modifiers) {
            MenuBarHider.shared.toggle()
        }
        isRunning = true
        updateChevron()
    }

    private func createItemsIfNeeded() {
        guard toggleItem == nil else { return }
        // Новые значки встают левее старых: сначала стрелка, затем разделитель слева от неё.
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "MacUtilsMenuBarToggle"
        toggle.behavior = []
        if let button = toggle.button {
            button.target = self
            button.action = #selector(toggleClicked)
            button.toolTip = "Mac Utils: показать или спрятать значки"
        }
        let separator = NSStatusBar.system.statusItem(withLength: Self.separatorLength)
        separator.autosaveName = "MacUtilsMenuBarSeparator"
        separator.behavior = []
        if let button = separator.button {
            button.image = Self.separatorImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Значки левее этой черты прячутся. Перетаскивайте значки с ⌘."
            button.appearsDisabled = false
        }
        toggleItem = toggle
        separatorItem = separator
        isCollapsed = false
    }

    private func removeItems() {
        collapseTimer?.invalidate()
        collapseTimer = nil
        if let separatorItem { NSStatusBar.system.removeStatusItem(separatorItem) }
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        separatorItem = nil
        toggleItem = nil
        isCollapsed = false
        misplaced = false
    }

    // MARK: - Свернуть / развернуть

    @objc private func toggleClicked() {
        toggle()
    }

    func toggle() {
        guard isRunning else { return }
        isCollapsed ? expand() : collapse()
    }

    func collapse() {
        guard let separatorItem, !isCollapsed else { return }
        guard separatorIsLeftOfToggle else {
            misplaced = true
            Toast.show("Разделитель стоит правее стрелки — перетащите его левее (с ⌘)",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        misplaced = false
        separatorItem.length = Self.collapsedLength
        isCollapsed = true
        collapseTimer?.invalidate()
        updateChevron()
    }

    func expand() {
        guard let separatorItem, isCollapsed else { return }
        separatorItem.length = Self.separatorLength
        isCollapsed = false
        updateChevron()
        scheduleAutoCollapse()
    }

    /// Длина разделителя: для проверки и настроек.
    var separatorLengthValue: CGFloat { separatorItem?.length ?? 0 }

    private var separatorIsLeftOfToggle: Bool {
        guard let separator = separatorItem?.button?.window?.frame,
              let toggle = toggleItem?.button?.window?.frame else { return true }
        return separator.minX <= toggle.minX
    }

    private func scheduleAutoCollapse() {
        collapseTimer?.invalidate()
        let seconds = UserDefaults.standard.integer(forKey: Pref.menuBarAutoCollapse)
        guard seconds > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(seconds), repeats: false) { _ in
            MainActor.assumeIsolated { MenuBarHider.shared.collapse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        collapseTimer = timer
    }

    private func updateChevron() {
        guard let toggleItem else { return }
        // Свёрнуто — стрелка влево («показать»), развёрнуто — вправо («спрятать»).
        let symbol = isCollapsed ? "chevron.left" : "chevron.right"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: isCollapsed ? "Показать значки" : "Спрятать значки")
        image?.isTemplate = true
        toggleItem.button?.image = image
        let hideChevron = UserDefaults.standard.bool(forKey: Pref.menuBarHideChevron)
        toggleItem.isVisible = !(isCollapsed && hideChevron)
    }

    private static func separatorImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 2, height: 16), flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

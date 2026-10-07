import AppKit

/// «Строка меню»: прячет лишние значки, как Hidden Bar. Два своих значка:
/// стрелка (свернуть/развернуть) и разделитель. При сворачивании разделитель
/// растягивается ровно на свободное место до меню приложения (или до «чёлки»),
/// и значкам левее него не остаётся места — macOS их прячет. Слишком длинный
/// разделитель (10 000 pt, как в Hidden Bar) новые macOS просто убирают целиком.
/// Пока функция выключена, у Mac Utils значков в строке меню нет.
@MainActor
final class MenuBarHider: NSObject, ObservableObject {
    static let shared = MenuBarHider()

    @Published private(set) var isCollapsed = false
    @Published private(set) var isRunning = false

    private static let separatorLength: CGFloat = 10
    /// Развёрнуто и ⌘ не зажата: черта не видна, остаётся узкий невидимый промежуток.
    private static let hiddenSeparatorLength: CGFloat = 2
    private var flagsMonitors: [Any] = []
    private var commandHeld = false
    /// Правый край разделителя от правого края экрана (запоминается при сворачивании).
    private var rightOffset: CGFloat?

    private var toggleItem: NSStatusItem?
    private var separatorItem: NSStatusItem?
    private var collapseTimer: Timer?
    /// Пока свёрнуто: следим, на каком экране работают, и пересчитываем длину под него.
    private var screenTimer: Timer?
    private var lengthScreen: NSScreen?

    /// С macOS 26 строку меню рисует система и умеет прятать значки сама
    /// (Системные настройки → Строка меню → «Разрешить в строке меню»).
    /// Там свой способ надёжнее: длина значка общая для всех мониторов,
    /// и растянутая черта оставляет пустоты и системную стрелку «».
    static var systemManaged: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }

    /// Раздел «Строка меню» в Системных настройках.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private override init() {
        super.init()
        // Меню нового активного приложения другой ширины — пересчитываем длину.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(environmentChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(environmentChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func environmentChanged() {
        guard isCollapsed else { return }
        // Даём строке меню перестроиться под новое приложение.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated { MenuBarHider.shared.applyCollapsedLength() }
        }
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
            // Без подсветки при наведении и нажатии: в свёрнутом виде это пустое место.
            button.isBordered = false
            (button.cell as? NSButtonCell)?.highlightsBy = []
            // Клик по пустому месту разворачивает значки, как стрелка.
            button.target = self
            button.action = #selector(separatorClicked)
        }
        toggleItem = toggle
        separatorItem = separator
        isCollapsed = false
        // Черта нужна только чтобы перетаскивать значки с ⌘ — показываем её, пока ⌘ зажата.
        let handler: (NSEvent) -> Void = { event in
            let held = event.modifierFlags.contains(.command)
            MainActor.assumeIsolated { MenuBarHider.shared.commandChanged(held) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            flagsMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { handler($0); return $0 }) {
            flagsMonitors.append(local)
        }
        updateSeparator()
    }

    private func commandChanged(_ held: Bool) {
        guard held != commandHeld else { return }
        commandHeld = held
        updateSeparator()
    }

    /// Развёрнутое состояние: черта видна только с зажатой ⌘.
    private func updateSeparator() {
        guard let separatorItem, !isCollapsed else { return }
        separatorItem.length = commandHeld ? Self.separatorLength : Self.hiddenSeparatorLength
        separatorItem.button?.image = commandHeld ? Self.separatorImage() : nil
    }

    private func removeItems() {
        screenTimer?.invalidate()
        screenTimer = nil
        for monitor in flagsMonitors { NSEvent.removeMonitor(monitor) }
        flagsMonitors.removeAll()
        commandHeld = false
        collapseTimer?.invalidate()
        collapseTimer = nil
        if let separatorItem { NSStatusBar.system.removeStatusItem(separatorItem) }
        if let toggleItem { NSStatusBar.system.removeStatusItem(toggleItem) }
        separatorItem = nil
        toggleItem = nil
        isCollapsed = false
    }

    // MARK: - Свернуть / развернуть

    @objc private func toggleClicked() {
        toggle()
    }

    @objc private func separatorClicked() {
        if isCollapsed { expand() }
    }

    func toggle() {
        guard isRunning else { return }
        isCollapsed ? expand() : collapse()
    }

    func collapse() {
        guard let separatorItem, !isCollapsed else { return }
        // Порядок значков не проверяем: в новых macOS система сообщает условные
        // координаты, и проверка ошибочно блокировала сворачивание.
        if let window = separatorItem.button?.window, let screen = window.screen {
            rightOffset = screen.frame.maxX - window.frame.maxX
        }
        isCollapsed = true
        separatorItem.button?.image = nil
        applyCollapsedLength()
        startScreenWatch()
        collapseTimer?.invalidate()
        updateChevron()
    }

    func expand() {
        guard separatorItem != nil, isCollapsed else { return }
        isCollapsed = false
        screenTimer?.invalidate()
        screenTimer = nil
        updateSeparator()
        updateChevron()
        scheduleAutoCollapse()
    }

    /// Длина «свёрнутого» разделителя: всё место от меню приложения (или «чёлки»)
    /// до правого края разделителя. Берём самый тесный из экранов: длина значка
    /// общая для всех строк меню, а не поместившийся значок macOS убирает целиком.
    func applyCollapsedLength() {
        guard let separatorItem, isCollapsed, let rightOffset else { return }
        // Длина значка одна на все строки меню, а слишком длинный разделитель
        // система убирает вместе со своей «» — поэтому считаем под экран, на котором
        // работают: на встроенном до «чёлки», на внешнем до меню активного приложения.
        // Небольшой запас система упирает в меню сама. При переходе — пересчёт.
        guard let screen = Self.currentScreen else { return }
        lengthScreen = screen
        var left = Self.frontmostMenusWidth()
        if let notch = screen.auxiliaryTopRightArea, notch.width > 0 {
            left = max(left, notch.minX - screen.frame.minX)
        }
        let available = screen.frame.width - rightOffset - left
        let length = max(Self.separatorLength, available + 24)
        separatorItem.length = length
        Log.window.debug("Строка меню: разделитель \(Int(length)) pt для экрана \(Int(screen.frame.width)) (слева \(Int(left)), отступ \(Int(rightOffset)))")
    }

    private static var currentScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func startScreenWatch() {
        screenTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let hider = MenuBarHider.shared
                guard hider.isCollapsed else { return }
                if Self.currentScreen != hider.lengthScreen { hider.applyCollapsedLength() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        screenTimer = timer
    }

    /// Ширина меню активного приложения (от левого края экрана), по Accessibility.
    private static func frontmostMenusWidth() -> CGFloat {
        guard let app = NSWorkspace.shared.frontmostApplication else { return 0 }
        // Свои меню через Accessibility не прочитать — считаем по заголовкам.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            let font = NSFont.menuBarFont(ofSize: 0)
            let titles = NSApp.mainMenu?.items.map(\.title) ?? []
            let text = titles.dropFirst().reduce(CGFloat(0)) {
                $0 + ($1 as NSString).size(withAttributes: [.font: font]).width + 20
            }
            return 52 + text // меню Apple и название приложения жирным — с запасом
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return 0 }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return 0 }
        var minX = CGFloat.greatestFiniteMagnitude, maxX: CGFloat = 0
        for item in items {
            var position: CFTypeRef?, size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
                  let position, let size else { continue }
            var origin = CGPoint.zero, extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
            minX = min(minX, origin.x)
            maxX = max(maxX, origin.x + extent.width)
        }
        // Меню начинаются у левого края своего экрана: ширина = maxX − этот край.
        guard maxX > 0 else { return 0 }
        let screenMinX = NSScreen.screens.first { $0.frame.minX <= minX && minX < $0.frame.maxX }?.frame.minX ?? 0
        return maxX - screenMinX
    }

    /// Длина разделителя: для проверки и настроек.
    var separatorLengthValue: CGFloat { separatorItem?.length ?? 0 }

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

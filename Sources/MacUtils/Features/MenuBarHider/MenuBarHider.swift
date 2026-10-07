import AppKit

/// «Строка меню»: прячет лишние значки, как Hidden Bar. Один свой значок —
/// стрелка. Всё, что левее неё, прячется: при сворачивании значок растягивается
/// влево ровно на свободное место (до меню приложения или «чёлки»), значкам левее
/// не остаётся места, и macOS убирает их в свой список «». Стрелка рисуется у
/// правого края растянутого значка, поэтому её нельзя «перепутать» с разделителем.
/// Пока функция выключена, у Mac Utils значков для неё в строке меню нет.
@MainActor
final class MenuBarHider: NSObject, ObservableObject {
    static let shared = MenuBarHider()

    @Published private(set) var isCollapsed = false
    @Published private(set) var isRunning = false

    private static let chevronLength: CGFloat = 24

    /// Правый край значка от правого края экрана (запоминается при сворачивании).
    private var rightOffset: CGFloat?
    private var item: NSStatusItem?
    private var collapseTimer: Timer?
    /// Пока свёрнуто: следим, на каком экране работают, и пересчитываем длину под него.
    private var screenTimer: Timer?
    private var lengthScreen: NSScreen?

    /// С macOS 26 строку меню рисует система; см. страницу настроек.
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
        let enabled = UserDefaults.standard.bool(forKey: Pref.menuBarHider)
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.menuBarToggle)
        guard enabled else {
            removeItem()
            isRunning = false
            return
        }
        createItemIfNeeded()
        let key = LayoutHotKey.load(codeKey: Pref.menuBarKeyCode, modifiersKey: Pref.menuBarModifiers,
                                    default: .controlOptionM)
        center.register(id: HotKeyID.menuBarToggle, keyCode: key.keyCode, modifiers: key.modifiers) {
            MenuBarHider.shared.toggle()
        }
        isRunning = true
        redraw()
    }

    /// Пересоздать стрелку (например, чтобы она встала левее нового значка).
    func recreate() {
        guard item != nil else { return }
        removeItem()
        sync()
    }

    private func createItemIfNeeded() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: Self.chevronLength)
        item.autosaveName = "MacUtilsMenuBarToggle"
        item.behavior = []
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.isBordered = false
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.toolTip = "Mac Utils: значки левее стрелки прячутся. Перетаскивайте их с ⌘."
        }
        self.item = item
        isCollapsed = false
    }

    private func removeItem() {
        collapseTimer?.invalidate()
        collapseTimer = nil
        screenTimer?.invalidate()
        screenTimer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        isCollapsed = false
    }

    // MARK: - Свернуть / развернуть

    @objc private func clicked() {
        toggle()
    }

    func toggle() {
        guard isRunning else { return }
        isCollapsed ? expand() : collapse()
    }

    func collapse() {
        guard let item, !isCollapsed else { return }
        if let window = item.button?.window, let screen = window.screen {
            rightOffset = screen.frame.maxX - window.frame.maxX
        }
        isCollapsed = true
        collapseTimer?.invalidate()
        applyCollapsedLength()
        startScreenWatch()
    }

    func expand() {
        guard let item, isCollapsed else { return }
        isCollapsed = false
        screenTimer?.invalidate()
        screenTimer = nil
        item.length = Self.chevronLength
        redraw()
        scheduleAutoCollapse()
    }

    /// Длина свёрнутого значка: всё место от меню (или «чёлки») до его правого края
    /// на экране, где работают. Длина одна на все мониторы; при переходе — пересчёт.
    func applyCollapsedLength() {
        guard let item, isCollapsed, let rightOffset else { return }
        guard let screen = Self.currentScreen else { return }
        lengthScreen = screen
        var left = Self.frontmostMenusWidth()
        if let notch = screen.auxiliaryTopRightArea, notch.width > 0 {
            left = max(left, notch.minX - screen.frame.minX)
        }
        let available = screen.frame.width - rightOffset - left
        // Небольшой запас: лишнее система упирает в меню; слишком большой — убрала бы значок целиком.
        let length = max(Self.chevronLength, available + 8)
        item.length = length
        redraw()
        Log.window.debug("Строка меню: значок \(Int(length)) pt для экрана \(Int(screen.frame.width)) (слева \(Int(left)), отступ \(Int(rightOffset)))")
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

    /// Длина значка: для проверки.
    var itemLength: CGFloat { item?.length ?? 0 }

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

    /// Стрелка у правого края значка: свёрнуто — «‹» (показать), развёрнуто — «›» (спрятать).
    private func redraw() {
        guard let item, let button = item.button else { return }
        let width = max(item.length, Self.chevronLength)
        let symbol = isCollapsed ? "chevron.left" : "chevron.right"
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let chevron = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let image = NSImage(size: NSSize(width: width - 4, height: 18), flipped: false) { rect in
            let size = chevron.size
            chevron.draw(in: NSRect(x: rect.maxX - Self.chevronLength / 2 - size.width / 2 + 2,
                                    y: (rect.height - size.height) / 2,
                                    width: size.width, height: size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isCollapsed ? "Показать значки" : "Спрятать значки"
        button.image = image
    }
}

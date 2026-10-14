import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Режим «Фокус» (⌃⌥F): выбранная программа остаётся чёткой, а всё позади её окон —
/// другие окна и рабочий стол — размывается и чуть затемняется.
/// Размытие — прозрачные окна на каждом экране, которые держатся сразу под окном программы.
@MainActor
final class FocusBlur: ObservableObject {
    static let shared = FocusBlur()

    /// Программа в фокусе (bundle id); nil — режим выключен.
    @Published private(set) var target: String?
    @Published private(set) var targetName = ""

    private var overlays: [NSWindow] = []
    private var timer: Timer?
    private var observer: Any?
    private var visible = false

    static var follow: Bool { UserDefaults.standard.bool(forKey: Pref.focusFollow) }
    static var strength: Double { UserDefaults.standard.double(forKey: Pref.focusStrength) }

    var isOn: Bool { target != nil }

    func sync() {
        let center = HotKeyCenter.shared
        center.unregister(id: HotKeyID.focus)
        guard UserDefaults.standard.bool(forKey: Pref.focus) else {
            stop()
            return
        }
        center.register(id: HotKeyID.focus, keyCode: kVK_ANSI_F, modifiers: controlKey | optionKey) {
            FocusBlur.shared.toggle()
        }
        if isOn { applyStyle() }
    }

    /// ⌃⌥F: включить для активной программы или выключить.
    func toggle() {
        if isOn { stop() } else if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() {
            start(app)
        }
    }

    func start(_ app: NSRunningApplication) {
        guard let bundle = app.bundleIdentifier else { return }
        target = bundle
        targetName = app.localizedName ?? bundle
        buildOverlays()
        if observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    FocusBlur.shared.activated(app)
                }
            }
        }
        if timer == nil {
            // Окна программы меняют порядок (новое окно, клик) — держим размытие сразу под ними.
            let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { FocusBlur.shared.update() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        update()
    }

    func stop() {
        target = nil
        timer?.invalidate()
        timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        fade(in: false)
    }

    private func activated(_ app: NSRunningApplication?) {
        guard isOn, let app, app.processIdentifier != getpid() else { return }
        // «Следовать за активной программой» — фокус переходит на неё.
        if Self.follow, let bundle = app.bundleIdentifier, bundle != target {
            target = bundle
            targetName = app.localizedName ?? bundle
        }
        update()
    }

    private func update() {
        guard let target,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: target).first else {
            if isOn { stop() }
            return
        }
        // Работаете в другой программе — размытие прячем, чтобы не мешало.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let below = Self.lowestFrontWindow(of: app.processIdentifier) else {
            fade(in: false)
            return
        }
        if overlays.count != NSScreen.screens.count { buildOverlays() }
        for overlay in overlays {
            overlay.order(.below, relativeTo: below)
        }
        fade(in: true)
    }

    /// Самое нижнее из подряд идущих сверху окон программы: размытие встанет под всеми ними.
    private static func lowestFrontWindow(of pid: pid_t) -> Int? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let ownPID = getpid()
        var lowest: Int?
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != ownPID else { continue }
            if owner == pid {
                lowest = info[kCGWindowNumber as String] as? Int
            } else if lowest != nil {
                break
            }
        }
        return lowest
    }

    // MARK: - Окна размытия

    private func buildOverlays() {
        for overlay in overlays { overlay.orderOut(nil) }
        overlays = NSScreen.screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .normal
            window.isExcludedFromWindowsMenu = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            blur.blendingMode = .behindWindow
            blur.material = .fullScreenUI
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            let tint = NSView(frame: blur.bounds)
            tint.wantsLayer = true
            tint.autoresizingMask = [.width, .height]
            blur.addSubview(tint)
            window.contentView = blur
            window.setFrame(screen.frame, display: false)
            window.alphaValue = 0
            return window
        }
        visible = false
        applyStyle()
    }

    /// Сила: прозрачность размытия и затемнение поверх.
    private func applyStyle() {
        let strength = max(0.2, min(1, Self.strength))
        for overlay in overlays {
            if let tint = overlay.contentView?.subviews.first {
                tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12 + 0.25 * strength).cgColor
            }
        }
        if visible {
            for overlay in overlays { overlay.alphaValue = 0.55 + 0.45 * strength }
        }
    }

    private func fade(in show: Bool) {
        guard show != visible else { return }
        visible = show
        let target = show ? 0.55 + 0.45 * max(0.2, min(1, Self.strength)) : 0
        for overlay in overlays {
            if show && !overlay.isVisible { overlay.alphaValue = 0 }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                overlay.animator().alphaValue = target
            }) {
                MainActor.assumeIsolated {
                    if !FocusBlur.shared.visible { overlay.orderOut(nil) }
                }
            }
        }
        if !show, target == 0, !isOn {
            // Режим выключен — окна больше не нужны.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    let focus = FocusBlur.shared
                    guard !focus.isOn else { return }
                    for overlay in focus.overlays { overlay.orderOut(nil) }
                    focus.overlays = []
                }
            }
        }
    }

    func restyle() {
        applyStyle()
    }
}

// MARK: - Настройки

struct FocusPage: View {
    @AppStorage(Pref.focus) private var enabled = true
    @AppStorage(Pref.focusFollow) private var follow = false
    @AppStorage(Pref.focusStrength) private var strength = 0.6
    @ObservedObject private var focus = FocusBlur.shared
    @State private var apps: [NSRunningApplication] = []

    var body: some View {
        Form {
            Section {
                Toggle("Режим «Фокус»", isOn: $enabled)
                Text("Выбранная программа остаётся чёткой, а всё позади её окон размывается и чуть затемняется — ничего не отвлекает. Клик по размытому фону переключает на ту программу, как обычно.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Сейчас") {
                HStack {
                    if focus.isOn {
                        Label("В фокусе: \(focus.targetName)", systemImage: "scope").foregroundStyle(Color.accentColor)
                        Spacer()
                        Button("Выключить") { focus.stop() }
                    } else {
                        Text("Выключен").foregroundStyle(.secondary)
                        Spacer()
                        Menu("Выбрать программу…") {
                            ForEach(apps, id: \.processIdentifier) { app in
                                Button(app.localizedName ?? "") { focus.start(app); app.activate() }
                            }
                        }
                        .frame(width: 200)
                    }
                }
                ShortcutRow(keys: ["⌃", "⌥", "F"], text: "Включить для активной программы или выключить.")
            }
            .disabled(!enabled)
            Section("Настройка") {
                LabeledContent("Сила размытия") {
                    Slider(value: $strength, in: 0.2...1) { _ in focus.restyle() }
                }
                Toggle("Следовать за активной программой", isOn: $follow)
                Text(follow ? "Переключились на другую программу — в фокусе становится она."
                            : "Фокус остаётся на выбранной программе; когда работаете в другой, размытие прячется.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!enabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Фокус")
        .onAppear {
            apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        }
    }
}

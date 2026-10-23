import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUAudio
import MUTextEditor

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    /// Открыть настройки сразу на нужном разделе.
    func show(section: SettingsSection) {
        show()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .openSettingsSection, object: section)
        }
    }

    func show() {
        let window = self.window ?? makeWindow()
        if !window.isVisible { FocusReturn.remember() }
        ScreenOutput.activateApp()
        window.makeKeyAndOrderFrontOnScreen()
        PermissionsModel.shared.refresh()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: DS.Size.settingsWindow),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Mac Utils"
        // Graphite: «светофор» над боковой панелью, без полосы заголовка (название окна — для Mission Control и меню «Окно»).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentViewController = NSHostingController(rootView: SettingsRootView())
        window.setContentSize(DS.Size.settingsWindow)
        window.minSize = DS.Size.settingsWindowMin
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // Возвращаем фокус предыдущему приложению.
        FocusReturn.restore()
    }
}

/// Содержимое окна настроек: на первом запуске — вводные шаги (`OnboardingView`) вместо разделов, затем — `SettingsView`.
/// Решение за `FirstRun.needsOnboarding`; нового окна нет.
struct SettingsRootView: View {
    @State private var onboarding = FirstRun.needsOnboarding(done: UserDefaults.standard.object(forKey: Pref.onboardingDone) as? Bool)

    var body: some View {
        // Разрешения на страницах настроек обновляются, только пока окно на экране.
        main.onScreen { PermissionsModel.shared.viewerChanged($0) }
    }

    @ViewBuilder private var main: some View {
        if onboarding {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: Pref.onboardingDone)
                onboarding = false
            }
        } else {
            SettingsView()
        }
    }
}

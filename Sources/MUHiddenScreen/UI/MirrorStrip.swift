import AppKit
import SwiftUI
import MUCore
import MUDesign

/// Модель полоски: состояние и действия от движка.
@MainActor
package final class HiddenScreenStore: ObservableObject {
    @Published package private(set) var state: HiddenScreenState
    package let controller: HiddenScreenControlling

    package init(_ controller: HiddenScreenControlling) {
        self.controller = controller
        self.state = controller.state
        let previous = controller.onChange
        controller.onChange = { [weak self] in
            previous?()
            guard let self else { return }
            self.state = self.controller.state
        }
    }
}

/// Тонкая полоска над окном-зеркалом: вкладки программ и отметка «не видно в звонке».
struct MirrorStripView: View {
    @ObservedObject var store: HiddenScreenStore

    var body: some View {
        let state = store.state
        let badge = HiddenScreenRules.badge(state)
        HStack(spacing: DS.Space.s) {
            ForEach(state.apps) { app in
                let selected = app.bundleID == state.activeApp
                Button { store.controller.selectApp(app.bundleID) } label: {
                    Text(app.name)
                        .font(DS.Font.caption)
                        .foregroundStyle(selected ? Color.dsText : Color.dsMute)
                        .padding(.horizontal, DS.Space.m).padding(.vertical, 3)
                        .background(selected ? Color.dsField : .clear, in: Capsule())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel(app.name)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
            Spacer(minLength: DS.Space.m)
            Pill(badge == .hidden ? .success : badge == .visible ? .danger : .neutral, HiddenScreenRules.badgeText(badge))
                .accessibilityLabel(HiddenScreenRules.badgeText(badge))
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: MirrorStripPanel.height)
        .background(Color.dsBg)
    }
}

/// Своё окно полоски. Не попадает в демонстрацию экрана (`sharingType = .none`); сама картинка — окно движка под ним.
@MainActor
package final class MirrorStripPanel: NSPanel {
    package static let height: CGFloat = 30

    package init(store: HiddenScreenStore) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: Self.height),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        sharingType = .none
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentView = FirstMouseHostingView(rootView: MirrorStripView(store: store))
        setAccessibilityLabel("Полоска скрытого экрана")
    }

    package override var canBecomeKey: Bool { false }

    /// Зеркало, к которому цепляется полоска: едет вместе с ним, за пустое место полоски его можно двигать.
    private weak var host: NSWindow?

    package override func mouseDown(with event: NSEvent) {
        if let host { host.performDrag(with: event) } else { super.mouseDown(with: event) }
    }

    package func attach(to window: NSWindow?) {
        if host !== window {
            host?.removeChildWindow(self)
            host = window
        }
        guard let window else { orderOut(nil); return }
        setFrame(Self.frame(above: window.frame), display: true)
        if parent !== window { window.addChildWindow(self, ordered: .above) }
    }

    /// Ставит полоску вплотную над рамкой окна-зеркала (координаты экрана, начало внизу слева).
    package static func frame(above mirror: CGRect) -> CGRect {
        CGRect(x: mirror.minX, y: mirror.maxY, width: mirror.width, height: height)
    }

    package func attach(to mirror: CGRect?) {
        guard let mirror else { orderOut(nil); return }
        setFrame(Self.frame(above: mirror), display: true)
        orderFrontRegardless()
    }
}

/// Показывает полоску, пока зеркало на экране.
@MainActor
package final class MirrorStripController {
    private let store: HiddenScreenStore
    private var panel: MirrorStripPanel?

    package init(_ controller: HiddenScreenControlling) { store = HiddenScreenStore(controller) }

    package func refresh() {
        let c = store.controller
        if c.state.isEnabled, c.state.mirrorShown, let frame = c.mirrorFrame {
            let panel = self.panel ?? MirrorStripPanel(store: store)
            self.panel = panel
            if let window = c.mirrorHostWindow { panel.attach(to: window) } else { panel.attach(to: frame) }
        } else {
            panel?.attach(to: nil as NSWindow?)
        }
    }
}

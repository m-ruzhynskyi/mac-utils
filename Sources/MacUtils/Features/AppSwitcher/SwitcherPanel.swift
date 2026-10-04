// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

@MainActor
final class SwitcherPanelController {
    private var panel: NSPanel?
    private var host: NSHostingView<SwitcherView>?

    func show() {
        let panel = self.panel ?? makePanel()
        guard let host else { return }
        let screen = NSScreen.withMouse ?? NSScreen.main
        let maxWidth = (screen?.visibleFrame.width ?? 1200) - 80
        host.rootView = SwitcherView(model: AppSwitcher.shared, maxWidth: maxWidth)
        let size = host.fittingSize
        if let frame = screen?.visibleFrame {
            panel.setFrame(NSRect(x: frame.midX - size.width / 2,
                                  y: frame.midY - size.height / 2 + frame.height * 0.1,
                                  width: size.width, height: size.height),
                           display: true)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: SwitcherView(model: AppSwitcher.shared, maxWidth: 1200))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 140),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }
}

struct SwitcherView: View {
    @ObservedObject var model: AppSwitcher
    let maxWidth: CGFloat

    private var iconSize: CGFloat {
        let count = CGFloat(max(model.items.count, 1))
        let perItem = (maxWidth - 32) / count - 12
        return min(72, max(32, perItem - 12))
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    Image(nsImage: item.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: iconSize, height: iconSize)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(index == model.selected ? Color.primary.opacity(0.18) : .clear)
                        )
                        .overlay(alignment: .bottom) {
                            if item.app.isHidden {
                                Circle().fill(.secondary).frame(width: 5, height: 5).offset(y: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { model.selected = index }
                        }
                        .onTapGesture { model.choose(index) }
                }
            }
            if model.items.indices.contains(model.selected) {
                Text(model.items[model.selected].name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(6)
    }
}

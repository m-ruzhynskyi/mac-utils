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

    @AppStorage(Pref.switcherPreviews) private var showPreviews = true

    private let thumbSize = CGSize(width: 200, height: 125)
    private let spacing: CGFloat = 8

    private var columns: Int {
        let cardWidth = (showPreviews ? thumbSize.width : 72) + 16
        let fit = Int((maxWidth - 40) / (cardWidth + spacing))
        return max(1, min(model.items.count, fit))
    }

    var body: some View {
        let grid = Array(repeating: GridItem(.fixed((showPreviews ? thumbSize.width : 72) + 16), spacing: spacing),
                         count: columns)
        LazyVGrid(columns: grid, spacing: spacing) {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                card(item, selected: index == model.selected)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { model.selected = index }
                    }
                    .onTapGesture { model.choose(index) }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(6)
    }

    @ViewBuilder
    private func card(_ item: SwitcherItem, selected: Bool) -> some View {
        let preview = item.windowID.flatMap { model.previews[$0] }
        VStack(spacing: 6) {
            if showPreviews {
                ZStack(alignment: .bottomTrailing) {
                    Group {
                        if let preview {
                            Image(nsImage: preview)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .shadow(radius: 2)
                                .opacity(item.isMinimized || item.isHidden ? 0.6 : 1)
                        } else {
                            Image(nsImage: item.icon)
                                .resizable()
                                .frame(width: 72, height: 72)
                        }
                    }
                    .frame(width: thumbSize.width, height: thumbSize.height)

                    if preview != nil {
                        Image(nsImage: item.icon)
                            .resizable()
                            .frame(width: 34, height: 34)
                            .shadow(radius: 2)
                            .offset(x: 4, y: 6)
                    }
                }
            } else {
                Image(nsImage: item.icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
            }
            HStack(spacing: 4) {
                if item.isMinimized {
                    Image(systemName: "minus.square").font(.system(size: 9))
                } else if item.isHidden {
                    Image(systemName: "eye.slash").font(.system(size: 9))
                }
                Text(item.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: (showPreviews ? thumbSize.width : 72))
            .help(item.title.isEmpty ? item.appName : "\(item.appName) — \(item.title)")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}

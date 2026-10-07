import AppKit
import SwiftUI

/// Плавающая панель с вырезанными файлами, видна только пока активен Finder.
@MainActor
final class CutPanelController {
    private var panel: NSPanel?
    private var host: NSHostingView<CutPanelView>?

    func show() {
        let panel = self.panel ?? makePanel()
        if let host {
            let size = host.fittingSize
            let screen = NSScreen.withMouse ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrame(NSRect(x: frame.maxX - size.width - 20,
                                      y: frame.minY + 20,
                                      width: size.width, height: size.height),
                               display: true)
            }
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: CutPanelView(model: FinderCutPaste.shared))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        self.panel = panel
        self.host = host
        return panel
    }
}

struct CutPanelView: View {
    @ObservedObject var model: FinderCutPaste

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "scissors")
                    .foregroundStyle(Color.accentColor)
                Text("Вырезано: \(model.items.count) \(plural(model.items.count, "объект", "объекта", "объектов"))")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Button {
                    model.cancelCut()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Отменить вырезание")
            }

            ForEach(model.items.prefix(3), id: \.self) { url in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 16, height: 16)
                    Text(url.lastPathComponent)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if model.items.count > 3 {
                Text("и ещё \(model.items.count - 3)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Text(model.isBusy ? "Перемещаю…" : "⌘V — переместить в открытую папку")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(4)
    }
}

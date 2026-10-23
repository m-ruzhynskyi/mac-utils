import AppKit
import SwiftUI
import MUCore
import MUDesign

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
        panel.orderFrontRegardlessOnScreen()
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
        CutPanelContent(items: model.items, isBusy: model.isBusy, cancel: { model.cancelCut() })
    }
}

/// Панель вырезанных файлов (Graphite: `panel`, обводка `line`, радиус 20). Без модели — для снимков интерфейса.
struct CutPanelContent: View {
    let items: [URL]
    var isBusy = false
    var cancel: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "scissors").font(.system(size: 14, weight: .medium)).foregroundStyle(.dsAccText)
                    .accessibilityHidden(true)
                Text("Вырезано: \(items.count) \(plural(items.count, "объект", "объекта", "объектов"))")
                    .font(DS.Font.rowTitle).foregroundStyle(.dsText)
                Spacer(minLength: DS.Space.m)
                Button(action: cancel) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(.dsMute)
                        .frame(width: 26, height: 26)
                        .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Отменить вырезание")
                .accessibilityLabel("Отменить вырезание")
            }

            ForEach(items.prefix(3), id: \.self) { url in
                HStack(spacing: 6) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(url.lastPathComponent)
                        .font(DS.Font.manrope(12, .semibold, relativeTo: .caption))
                        .foregroundStyle(.dsText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if items.count > 3 {
                Text("и ещё \(items.count - 3)")
                    .font(DS.Font.rowSub)
                    .foregroundStyle(.dsMute)
            }

            Text(isBusy ? "Перемещаю…" : "⌘V — переместить в открытую папку")
                .font(DS.Font.rowSub)
                .foregroundStyle(.dsMute)
        }
        .padding(DS.Space.l)
        .frame(width: 300, alignment: .leading)
        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .padding(4)
    }
}

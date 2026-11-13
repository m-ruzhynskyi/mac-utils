import AppKit
import SwiftUI
import MUCore
import MUDesign

/// Панель подсказчика: полоска «Слушаю», при вопросе раскрывается ответом (по макету `.audit/meeting-copilot-design`).
struct CopilotPanelView: View {
    @ObservedObject var session: CopilotSession
    let placement: CopilotPlacement
    var expandedOverride: Bool?

    private var expanded: Bool { expandedOverride ?? (session.expandedAt != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            if expanded { answerView } else { strip }
        }
        .padding(.horizontal, DS.Space.m).padding(.vertical, expanded ? DS.Space.s : 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.dsBg.opacity(0.94), in: RoundedRectangle(cornerRadius: expanded ? DS.Radius.card : 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: expanded ? DS.Radius.card : 13, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
    }

    private var strip: some View {
        HStack(spacing: DS.Space.s) {
            Circle().fill(session.isOn ? Color.dsAccLine : Color.dsMute).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(session.isAnswering ? "Думаю…" : session.error ?? (session.isOn ? "Слушаю · вопросов нет" : "Выключено"))
                .font(DS.Font.caption).foregroundStyle(session.error == nil ? Color.dsMute : DS.Tone.danger.text)
            Spacer(minLength: 0)
            Pill(.success, "не видно в звонке")
        }
    }

    private var answerView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let q = session.question {
                Text(q).font(DS.Font.rowSub).foregroundStyle(Color.dsMute).lineLimit(2)
            }
            let a = session.answer
            if !a.say.isEmpty {
                Text(a.say).font(DS.Font.body.weight(.semibold)).foregroundStyle(Color.dsText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if session.isAnswering {
                Text("Думаю…").font(DS.Font.body).foregroundStyle(Color.dsMute)
            }
            if placement != .underCamera || true {
                ForEach(Array(a.points.enumerated()), id: \.offset) { _, p in
                    Text("• " + p).font(DS.Font.caption).foregroundStyle(Color.dsMute).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text(session.lastLatency.map { String(format: "%.1f с", $0) } ?? "").font(DS.Font.caption).foregroundStyle(Color.dsMute)
                Spacer()
                Text("⌥ — нажимать · Esc — свернуть · исчезнет через 20 с").font(DS.Font.caption).foregroundStyle(Color.dsMute)
            }
        }
    }
}

/// Окно панели: не попадает в демонстрацию, мышь проходит сквозь него (с ⌥ нажимается).
@MainActor
package final class CopilotPanel: NSPanel {
    private let session: CopilotSession
    private var timer: Timer?
    private var flagsMonitor: Any?

    package init(session: CopilotSession) {
        self.session = session
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 128),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        sharingType = .none
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        setAccessibilityLabel("Подсказчик на встрече")
    }

    package override var canBecomeKey: Bool { false }

    package func show(placement: CopilotPlacement, on screen: NSScreen?) {
        contentView = FirstMouseHostingView(rootView: CopilotPanelView(session: session, placement: placement))
        layout(placement: placement, on: screen)
        orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(placement: placement, screen: screen) }
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.ignoresMouseEvents = CopilotPanelRules.ignoresMouse(optionHeld: event.modifierFlags.contains(.option)) }
        }
    }

    package func hide() {
        timer?.invalidate(); timer = nil
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        orderOut(nil)
    }

    private func tick(placement: CopilotPlacement, screen: NSScreen?) {
        if CopilotPanelRules.shouldCollapse(expandedAt: session.expandedAt, now: Date(), isAnswering: session.isAnswering,
                                            holdingOption: NSEvent.modifierFlags.contains(.option)) { session.collapse() }
        layout(placement: placement, on: screen)
    }

    private func layout(placement: CopilotPlacement, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let notch = screen.safeAreaInsets.top
        setFrame(CopilotPanelRules.frame(placement: placement, expanded: session.expandedAt != nil, in: screen.frame, notchHeight: notch), display: true)
    }
}

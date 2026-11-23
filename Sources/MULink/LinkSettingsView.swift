import AppKit
import MUDesign
import SwiftUI

/// Блок «Связь с ПК» на странице «Windows-ПК» (макет: доска «Настройки»): состояние канала, связанный ПК и сопряжение
/// по коду с экрана ПК. Сам блок ничего не хранит: пара — в `LinkClient`.
package struct LinkSettingsView: View {
    @ObservedObject private var client: LinkClient
    private let defaultHost: String?
    @State private var host = ""
    @State private var code = ""
    @State private var busy = false
    @State private var result: LinkClient.PairOutcome?
    @State private var showForm = false

    /// `defaultHost` — адрес ПК из Moonlight (если есть), подставляется в «Адрес ПК».
    package init(client: LinkClient, defaultHost: String?) {
        self.client = client
        self.defaultHost = defaultHost
    }

    package var body: some View {
        GroupLabel("Связь с ПК")
        ListCard {
            FeatureStatusRow(tone: tone, label: client.state.text, detail: detail)
            if let pair = client.pair {
                Row(pair.pcName.isEmpty ? "ПК" : pair.pcName,
                    subtitle: "\(pair.host) · ключ \(LinkCrypto.fingerprint(pair.pcKey) ?? "?")", systemImage: "pc") {
                    HStack(spacing: 8) {
                        if case .offline = client.state {
                            Button("Повторить") { client.retryNow() }.buttonStyle(.graphite(.secondary, size: .compact))
                        }
                        Button("Забыть ПК") { client.forget(); showForm = true }.buttonStyle(.graphite(.secondary, size: .compact))
                    }
                }
            }
        }

        if client.pair == nil || showForm || client.state == .offline(.forgotten, retryIn: nil) {
            GroupLabel(client.pair == nil ? "Связать с ПК" : "Связать заново")
            Card {
                Text("На ПК: значок Mac Utils Share в трее → «Связать с Mac…». Появится код из 6 цифр, он действует 2 минуты.")
                    .font(DS.Font.caption).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
                Text("Адрес ПК").font(DS.Font.rowTitle).foregroundStyle(.dsText)
                TextField("", text: $host, prompt: Text("100.x.y.z или имя в Tailscale"))
                    .textFieldStyle(.graphiteMono)
                    .frame(maxWidth: 320, alignment: .leading)
                    .accessibilityLabel("Адрес ПК")
                Text("Код с ПК").font(DS.Font.rowTitle).foregroundStyle(.dsText)
                HStack(spacing: 10) {
                    TextField("", text: $code, prompt: Text("000000"))
                        .textFieldStyle(.graphiteMono)
                        .frame(width: 120, alignment: .leading)
                        .accessibilityLabel("Код с ПК")
                        .onChange(of: code) { let digits = String(code.filter(\.isNumber).prefix(6)); if digits != code { code = digits } }
                        .onSubmit(pair)
                    Button(busy ? "Связываю…" : "Связать", action: pair)
                        .buttonStyle(.graphite(.primary, size: .compact))
                        .disabled(busy || code.count != 6 || host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let result {
                    Text(result.text).font(DS.Font.caption)
                        .foregroundStyle(result.isSuccess ? Color.dsText : Color.dsRecInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Footnote("Связь идёт напрямую Mac ↔ ПК через Tailscale, без серверов. Mac только подключается к ПК; Sunshine, AnyDesk и Tailscale Mac Utils не меняет.")
            .onAppear { if host.isEmpty { host = client.pair?.host ?? defaultHost ?? "" } }
    }

    private func pair() {
        guard !busy, code.count == 6 else { return }
        busy = true
        result = nil
        client.pair(host: host, code: code) { outcome in
            busy = false
            result = outcome
            if outcome.isSuccess { code = ""; showForm = false }
        }
    }

    private var tone: DS.Tone {
        switch client.state {
        case .online: return .success
        case .connecting, .pairing: return .info
        case .notPaired: return .neutral
        case .offline(.forgotten, _), .offline(.otherPC, _): return .warning
        case .offline: return .danger
        }
    }

    private var detail: String? {
        switch client.state {
        case .notPaired: return "Свяжите Mac с ПК один раз — дальше связь поднимается сама"
        case .online:
            guard let s = client.status else { return nil }
            return "\(s.os) · работает \(Self.uptime(s.uptime)) · Mac Utils Share \(s.version)"
        case .offline(_, let retry?) where retry > 0: return "Повтор через \(Int(retry.rounded())) с"
        case .connecting(let attempt) where attempt > 1: return "Попытка \(attempt)"
        default: return nil
        }
    }

    /// «3 ч 12 мин», «2 дн 4 ч», «45 с».
    package static func uptime(_ seconds: Int) -> String {
        let d = seconds / 86_400, h = seconds % 86_400 / 3600, m = seconds % 3600 / 60
        if d > 0 { return "\(d) дн \(h) ч" }
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин" }
        return "\(seconds) с"
    }
}

extension LinkClient.PairOutcome {
    package var isSuccess: Bool { if case .paired = self { return true }; return false }
}

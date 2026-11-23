import Foundation

/// Самопроверка MU Link без ПК (`--mu-link-selftest`): в процессе поднимается двойник ПК на 127.0.0.1, клиент проходит
/// сопряжение, пульс, `status`, отказ чужому ключу, «выключение ПК» и переподключение. Пара хранится в памяти —
/// настоящие настройки не трогаются. Слушает только двойник и только на петле: брандмауэр macOS петлю не фильтрует,
/// окна «разрешить входящие» нет. Каждый шаг — строкой в журнал (`Log.link`, «самопроверка: …») с числами.
package enum LinkSelfTest {
    package static let flag = "--mu-link-selftest"

    package struct Step: Equatable, Sendable {
        package var name: String
        package var ok: Bool
        package var detail: String
    }

    /// `signer` — ключ устройства (в приложении — `ShareIdentity`). `timeScale` < 1 ускоряет повторы (тесты).
    @MainActor
    package static func run(signer: LinkSigner, appVersion: String, macName: String, log: @escaping (String) -> Void,
                            timeScale: Double = 1) async -> [Step] {
        var steps: [Step] = []
        func step(_ name: String, _ ok: Bool, _ detail: String) {
            steps.append(Step(name: name, ok: ok, detail: detail))
            log("самопроверка: \(ok ? "ok" : "СБОЙ") · \(name) · \(detail)")
        }
        let core = LinkPCCore(key: LinkKey(), name: "ПК-двойник", version: appVersion)
        let twin = LinkTwinServer(core: core)
        do { try twin.start() } catch {
            step("двойник ПК на 127.0.0.1", false, "\(error)")
            return steps
        }
        defer { twin.stop() }
        step("двойник ПК на 127.0.0.1", true, "порт \(twin.port), слушает только петлю")

        let delays = LinkWire.retryDelays.map { $0 * timeScale }
        let client = LinkClient(signer: signer, storage: MemoryLinkPairStorage(), appVersion: appVersion, macName: macName,
                                port: twin.port, retryDelays: delays, pingInterval: LinkWire.pingInterval * timeScale,
                                silenceTimeout: LinkWire.silenceTimeout * timeScale, log: { log("клиент: \($0)") })
        defer { client.stop() }
        client.start()

        // 1. Неверный код — отказ с числом оставшихся попыток.
        guard let code = core.openPairing() else { step("код сопряжения", false, "двойник заблокирован"); return steps }
        let wrong = code == "000000" ? "111111" : "000000"
        let bad = await client.pair(host: "127.0.0.1", code: wrong)
        step("неверный код отклонён", bad == .badCode(attemptsLeft: LinkPCCore.maxAttempts - 1), bad.text)

        // 2. Сопряжение верным кодом.
        let t0 = Date()
        let outcome = await client.pair(host: "127.0.0.1", code: code)
        let pairMs = ms(since: t0)
        step("сопряжение", outcome == .paired(pcName: core.name) && client.pair?.pcKey == core.key.publicKey,
             "\(outcome.text) за \(pairMs) мс; ключ ПК \(LinkCrypto.fingerprint(core.key.publicKey) ?? "?")")

        // 3. На связи, status.
        let online = await wait(10) { if case .online = client.state { return true }; return false }
        step("на связи", online, client.state.text)
        let gotStatus = await wait(5) { client.status != nil }
        if let s = client.status {
            step("status от ПК", gotStatus, "имя «\(s.name)», аптайм \(s.uptime) с, Share \(s.version), питание \(s.power.source.rawValue)")
        } else {
            step("status от ПК", false, "не пришёл")
        }

        // 4. Пульс: отклик ping → pong.
        let pinged = await wait(LinkWire.pingInterval * timeScale + 5) { if case .online(let p?) = client.state { return p >= 0 }; return false }
        step("пульс", pinged, client.state.text)

        // 5. Чужой ключ: ПК не знает этот Mac — отказ, без повторов.
        let strangerStore = MemoryLinkPairStorage(LinkPair(host: "127.0.0.1", pcKey: core.key.publicKey, pcName: core.name))
        let stranger = LinkClient(signer: LinkKey(), storage: strangerStore, appVersion: appVersion, macName: "чужой Mac",
                                  port: twin.port, retryDelays: delays, log: { log("чужой: \($0)") })
        stranger.start()
        let refused = await wait(5) { stranger.state == .offline(.forgotten, retryIn: nil) }
        step("чужой ключ отклонён", refused, stranger.state.text)
        stranger.stop()

        // 6. ПК «выключился» и вернулся на том же адресе — связь поднимается сама.
        let readyBefore = twin.readyCount
        let port = twin.port
        twin.stop()
        let dropped = await wait(LinkWire.silenceTimeout * timeScale + 5) { if case .offline = client.state { return true }; return false }
        step("обрыв замечен", dropped, client.state.text)
        try? await Task.sleep(nanoseconds: UInt64(3 * timeScale * 1_000_000_000))
        let t1 = Date()
        do { try twin.start(port: port) } catch { step("ПК вернулся", false, "двойник не поднялся: \(error)"); return steps }
        let back = await wait(40 * timeScale + 5) { if case .online = client.state { return twin.readyCount > readyBefore }; return false }
        step("переподключение", back, "через \(ms(since: t1)) мс после возвращения ПК; \(client.state.text)")

        let failed = steps.filter { !$0.ok }.count
        log("самопроверка: итог — \(failed == 0 ? "всё в порядке" : "сбоев: \(failed)") (\(steps.count) шагов)")
        return steps
    }

    private static func ms(since date: Date) -> Int { Int((Date().timeIntervalSince(date) * 1000).rounded()) }

    /// Ждать условие на главной очереди (там меняются `@Published`), шаг 50 мс.
    @MainActor
    private static func wait(_ seconds: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}

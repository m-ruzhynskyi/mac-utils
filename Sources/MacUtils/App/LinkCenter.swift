import AppKit
import Foundation
import MUCore
import MULink
import MUScreenShare

/// MU Link в приложении: один клиент на весь Mac Utils, ключ устройства — ключ трансляции `ShareIdentity`.
/// Пара хранится в `~/Library/Application Support/Mac Utils/mu-link.json`. Без пары в сеть не ходит.
@MainActor
enum LinkCenter {
    static let client = LinkClient(signer: ShareIdentitySigner(), storage: FileLinkPairStorage.standard,
                                   appVersion: appVersion, macName: macName)

    private static var wakeObserver: NSObjectProtocol?

    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    /// Имя компьютера (как в «Общий доступ»), уходит только на свой связанный ПК.
    static var macName: String { Host.current().localizedName ?? "Mac" }

    /// Запуск приложения: держать связь, если ПК уже связан. После сна — сразу повтор.
    static func start() {
        client.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            client.retryNow()
        }
    }

    static func stop() { client.stop() }

    /// `--mu-link-selftest`: двойник ПК на 127.0.0.1, сопряжение, пульс, status, отказ чужому, обрыв и переподключение.
    /// Пара — в памяти, настоящая не трогается. Итог — в журнал, затем выход.
    static func runSelfTestIfRequested() {
        guard CommandLine.arguments.contains(LinkSelfTest.flag) else { return }
        Task { @MainActor in
            let steps = await LinkSelfTest.run(signer: ShareIdentitySigner(), appVersion: appVersion, macName: macName,
                                               log: { Log.link.info("\($0, privacy: .public)") })
            Log.link.info("самопроверка: выход (\(steps.filter(\.ok).count, privacy: .public)/\(steps.count, privacy: .public) ok)")
            AppTermination.terminate()
        }
    }
}

/// Ключ трансляции как ключ устройства MU Link (подписывает только строки `mu-link/1`).
struct ShareIdentitySigner: LinkSigner {
    /// false — ключ живёт только в памяти (нет доступа к файлу ключа): связывать нельзя, пара сломалась бы после перезапуска.
    static var isPersistent: Bool { ShareIdentity.shared.isPersistent }
    var publicKey: String { ShareIdentity.shared.publicKey }
    func sign(link message: String) -> String { ShareIdentity.shared.sign(link: message) }
}

/// Адрес ПК из Moonlight-qt (`com.moonlight-stream.Moonlight`): только ключи адреса хостов, никогда — сертификаты и ключи пары.
/// Предпочтение — адресу Tailscale (100.64.0.0/10). Только чтение.
enum MoonlightHosts {
    static let domain = "com.moonlight-stream.Moonlight" as CFString

    static func defaultAddress(read: (String) -> String? = { key in CFPreferencesCopyAppValue(key as CFString, domain) as? String },
                               count: () -> Int = { (CFPreferencesCopyAppValue("hosts.size" as CFString, domain) as? NSNumber)?.intValue ?? 0 }) -> String? {
        var found: [String] = []
        for i in 1...max(1, min(count(), 16)) {
            for key in ["manualaddress", "remoteaddress", "localaddress"] {
                if let raw = read("hosts.\(i).\(key)") { let a = stripPort(raw); if !a.isEmpty { found.append(a) } }
            }
        }
        return found.first(where: isTailscale) ?? found.first
    }

    /// `100.110.229.14:47989` → `100.110.229.14`; `[fd7a::1]:47989` → `fd7a::1`.
    static func stripPort(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("["), let end = s.firstIndex(of: "]") { return String(s[s.index(after: s.startIndex)..<end]) }
        if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") { return String(s[..<colon]) }
        return s
    }

    /// 100.64.0.0/10 или fd7a:115c:a1e0::/48.
    static func isTailscale(_ address: String) -> Bool {
        if address.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

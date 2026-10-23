import AppKit
import SwiftUI
import MUCore

/// Что сейчас играет в системе (любая программа: браузер, Музыка, Spotify, Telegram…)
/// и управление: пауза, следующий и предыдущий трек, перемотка.
/// Данные MediaRemote с macOS 15.4 доступны только системным процессам, поэтому их читает
/// помощник MUNowPlaying.dylib, загруженный в /usr/bin/perl.
@MainActor
final class NowPlaying: NSObject, ObservableObject {
    static let shared = NowPlaying()

    struct Track: Equatable {
        var title = ""
        var artist = ""
        var album = ""
        var app = ""
        var bundle = ""
        var duration: Double = 0
        var elapsed: Double = 0
        var playing = false
        var receivedAt = Date()

        /// Позиция «сейчас» — между обновлениями помощника время идёт само.
        func position(at date: Date = Date()) -> Double {
            guard playing else { return elapsed }
            let value = elapsed + date.timeIntervalSince(receivedAt)
            return duration > 0 ? min(value, duration) : value
        }
    }

    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var failed = false
    /// Что играло последним — показываем, когда сейчас тишина.
    @Published private(set) var last: Track?
    @Published private(set) var lastArtwork: NSImage?

    private static var lastArtworkURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac Utils", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("last-artwork.png")
    }

    override init() {
        super.init()
        if let saved = UserDefaults.standard.dictionary(forKey: Pref.musicLast) {
            var track = Track()
            track.title = saved["title"] as? String ?? ""
            track.artist = saved["artist"] as? String ?? ""
            track.app = saved["app"] as? String ?? ""
            track.bundle = saved["bundle"] as? String ?? ""
            if !track.title.isEmpty { last = track }
        }
        lastArtwork = NSImage(contentsOf: Self.lastArtworkURL)
    }

    private static let artworkQueue = DispatchQueue(label: "macutils.nowplaying.artwork", qos: .utility)

    /// Хеш обложки, лежащей в `last-artwork.png` (или показанной как «последняя»).
    private var storedArtworkHash: String?

    private func remember(_ track: Track, artwork: NSImage?, artworkHash: String?, artworkData: Data?) {
        if last?.title != track.title || last?.artist != track.artist {
            UserDefaults.standard.set(["title": track.title, "artist": track.artist, "app": track.app, "bundle": track.bundle],
                                      forKey: Pref.musicLast)
            last = track
        }
        // Обложка приходит с каждым событием помощника: на диск пишем, только если изменилось содержимое,
        // и не на главном потоке.
        guard let artwork, let artworkHash, let artworkData,
              ArtworkFingerprint.shouldStore(newHash: artworkHash, lastStoredHash: storedArtworkHash) else { return }
        storedArtworkHash = artworkHash
        lastArtwork = artwork
        let url = Self.lastArtworkURL
        // Одна очередь по порядку и атомарная запись: две быстрые смены обложки не перепутаются, недописанный файл не прочитается.
        Self.artworkQueue.async {
            guard let png = NSBitmapImageRep(data: artworkData)?.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url, options: .atomic)
        }
    }

    /// Продолжить то, что играло: команда «играть» системному плееру; если программы уже нет — открываем её.
    func resumeLast() {
        guard let last else { return }
        if !last.bundle.isEmpty, NSRunningApplication.runningApplications(withBundleIdentifier: last.bundle).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: last.bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { NowPlaying.shared.send("play") }
            }
        } else {
            send("play")
        }
    }

    func openLastApp() {
        guard let bundle = last?.bundle, !bundle.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// Плеер, выбранный в настройках: программа (bundle id) или сайт (https://…).
    static var preferredPlayer: String { UserDefaults.standard.string(forKey: Pref.musicPlayer) ?? "com.apple.Music" }

    static func playerTitle(_ value: String) -> String {
        if value.hasPrefix("http") { return URL(string: value)?.host ?? value }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) else { return value }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    func openPreferredPlayer() {
        let value = Self.preferredPlayer
        if value.hasPrefix("http"), let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    private var process: Process?
    private var input: FileHandle?
    private var users = 0
    private var stopWork: DispatchWorkItem?
    private var lines = LineBuffer()
    private var outputHandle: FileHandle?
    /// Хеш данных обложки текущего трека: по нему решаем, пересоздавать ли NSImage.
    private var artworkHash: String?

    /// Вид с плеером появился / исчез: помощник работает, только пока плеер на экране (+ минута).
    func attach() {
        users += 1
        stopWork?.cancel()
        start()
    }

    func detach() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.users == 0 else { return }
                self.stop()
            }
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func start() {
        guard process == nil,
              let dylib = Bundle.main.url(forResource: "MUNowPlaying", withExtension: "dylib") else {
            if Bundle.main.url(forResource: "MUNowPlaying", withExtension: "dylib") == nil { failed = true }
            return
        }
        let script = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $sym = DynaLoader::dl_find_symbol($lib, "mu_now_playing") or die "no symbol";
        DynaLoader::dl_install_xsub("main::run", $sym);
        main::run();
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", script, dylib.path]
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            // Конец потока (помощник завершился): без снятия обработчик вызывается без остановки и занимает ядро.
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NowPlaying.shared.receive(data) }
            }
        }
        process.terminationHandler = { finished in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let player = NowPlaying.shared
                    // Намеренная остановка (stop) уже обнулила process: это не сбой.
                    guard player.process === finished else { return }
                    player.process = nil
                    player.input = nil
                    player.helperDied()
                }
            }
        }
        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
            outputHandle = output.fileHandleForReading
            lines.reset()
            failed = false
        } catch {
            failed = true
        }
    }

    private func stop() {
        outputHandle?.readabilityHandler = nil
        outputHandle = nil
        send("quit")
        process?.terminate()
        process = nil
        input = nil
        lines.reset()
    }

    /// Помощник умер сам (perl не загрузил dylib, сбой): данные устарели, показывать трек и тикать времени нельзя.
    private func helperDied() {
        Log.audio.error("Музыка: помощник завершился сам")
        lines.reset()
        track = nil
        artwork = nil
        artworkHash = nil
        failed = true
    }

    private func receive(_ data: Data) {
        for line in lines.feed(data) {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let title = json["title"] as? String ?? ""
            guard !title.isEmpty else {
                track = nil
                artwork = nil
                artworkHash = nil
                continue
            }
            var next = Track()
            next.title = title
            next.artist = json["artist"] as? String ?? ""
            next.album = json["album"] as? String ?? ""
            next.app = json["app"] as? String ?? ""
            next.bundle = json["bundle"] as? String ?? ""
            next.duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
            next.elapsed = (json["elapsed"] as? NSNumber)?.doubleValue ?? 0
            next.playing = (json["playing"] as? Bool) ?? false
            if track?.title != next.title || track?.artist != next.artist {
                artwork = nil
                artworkHash = nil
            }
            var artworkData: Data?
            if let base64 = json["artwork"] as? String, let data = Data(base64Encoded: base64) {
                let hash = ArtworkFingerprint.hash(data)
                // Та же обложка — не декодируем и не пересоздаём NSImage (иначе обновляется весь вид).
                if hash != artworkHash || artwork == nil {
                    artwork = NSImage(data: data)
                    artworkHash = hash
                }
                artworkData = data
            }
            track = next
            remember(next, artwork: artwork, artworkHash: artworkHash, artworkData: artworkData)
        }
    }

    fileprivate func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    func toggle() {
        track?.playing.toggle()
        send("toggle")
    }

    func next() { send("next") }
    func previous() { send("prev") }

    func seek(to seconds: Double) {
        track?.elapsed = seconds
        track?.receivedAt = Date()
        send("seek \(max(0, seconds))")
    }

    func skip(_ delta: Double) {
        guard let track else { return }
        seek(to: track.position() + delta)
    }

    /// Открыть программу, которая играет.
    func openPlayer() {
        guard let bundle = track?.bundle, !bundle.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Вид

struct NowPlayingView: View {
    @ObservedObject var player = NowPlaying.shared
    var compact = false
    /// Демо для снимков интерфейса: не подключается к системному плееру.
    var demo = false
    @State private var scrubbing: Double?

    var body: some View {
        ToolsPageFrame(.music, compact: compact) {
            Group {
                if let track = player.track {
                    content(track)
                } else {
                    idle
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(compact ? Color.clear : Color.dsPanel, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay {
                if !compact { RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1) }
            }
        }
        .onAppear { if !demo { player.attach() } }
        .onDisappear { if !demo { player.detach() } }
    }

    private func artworkView(_ image: NSImage?, side: CGFloat, glyph: CGFloat) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.dsField
                    Image(systemName: "music.note").font(.system(size: glyph, weight: .medium)).foregroundStyle(.dsMute)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// Сейчас тишина: что играло последним (продолжить) и быстрый запуск своего плеера.
    private var idle: some View {
        VStack(spacing: DS.Space.l) {
            if let last = player.last {
                Text("Играло последним".uppercased()).font(DS.Font.groupLabel)
                    .tracking(DS.Font.tracking(0.12, size: 11)).foregroundStyle(.dsMute)
                artworkView(player.lastArtwork, side: compact ? 130 : 170, glyph: 34).opacity(0.9)
                VStack(spacing: DS.Space.xxs) {
                    Text(last.title).font(DS.Font.headline).foregroundStyle(.dsText).lineLimit(1)
                    Text([last.artist, last.app].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(DS.Font.body).foregroundStyle(.dsMute).lineLimit(1)
                }
                .padding(.horizontal)
                HStack(spacing: DS.Space.m) {
                    Button { player.resumeLast() } label: { Label("Продолжить", systemImage: "play.fill") }
                        .buttonStyle(.graphite(.primary))
                    if !last.app.isEmpty {
                        Button { player.openLastApp() } label: { Label("Открыть \(last.app)", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.graphite(.secondary))
                    }
                }
            } else {
                EmptyState(player.failed ? "Не удалось подключиться к системному плееру" : "Сейчас ничего не играет",
                           systemImage: "music.note", compact: true)
            }
            Button { player.openPreferredPlayer() } label: {
                Label("Открыть \(NowPlaying.playerTitle(NowPlaying.preferredPlayer))", systemImage: "music.note.list")
            }
            .buttonStyle(.graphite(.ghost, size: .compact))
            if !compact {
                PlayerPicker()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xl)
    }

    private func content(_ track: NowPlaying.Track) -> some View {
        VStack(spacing: DS.Space.l) {
            artworkView(player.artwork, side: compact ? 180 : 220, glyph: 44).shadow(color: .black.opacity(0.25), radius: 10, y: 4)

            VStack(spacing: DS.Space.xs) {
                Text(track.title).font(DS.Font.headline).foregroundStyle(.dsText).lineLimit(1)
                Text(track.artist.isEmpty ? track.app : track.artist).font(DS.Font.body).foregroundStyle(.dsMute).lineLimit(1)
                if !track.app.isEmpty {
                    Button { player.openPlayer() } label: {
                        Label(track.app, systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.graphite(.ghost, size: .compact))
                    .help("Открыть программу")
                }
            }
            .padding(.horizontal)

            if track.duration > 0 {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let position = scrubbing ?? track.position(at: context.date)
                    VStack(spacing: DS.Space.xs) {
                        Slider(value: Binding(get: { position }, set: { scrubbing = $0 }), in: 0...track.duration) { editing in
                            if !editing, let value = scrubbing {
                                player.seek(to: value)
                                scrubbing = nil
                            }
                        }
                        .controlSize(.small)
                        .tint(.dsAccLine)
                        HStack {
                            Text(NowPlaying.time(position))
                            Spacer()
                            Text("−" + NowPlaying.time(track.duration - position))
                        }
                        .font(DS.Font.mono(11, relativeTo: .caption2)).foregroundStyle(.dsMute)
                    }
                }
                .padding(.horizontal, 24)
            }

            HStack(spacing: DS.Space.m) {
                IconButton("Назад на 15 секунд", systemImage: "gobackward.15", compact: true) { player.skip(-15) }
                    .disabled(track.duration <= 0)
                IconButton("Предыдущий", systemImage: "backward.fill", compact: true) { player.previous() }
                Button { player.toggle() } label: {
                    Image(systemName: track.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.dsAccInk)
                        .frame(width: 56, height: 56)
                        .background(Color.dsAcc, in: Circle())
                }
                .buttonStyle(PressScaleStyle())
                .help(track.playing ? "Пауза" : "Играть")
                .accessibilityLabel(track.playing ? "Пауза" : "Играть")
                IconButton("Следующий", systemImage: "forward.fill", compact: true) { player.next() }
                IconButton("Вперёд на 15 секунд", systemImage: "goforward.15", compact: true) { player.skip(15) }
                    .disabled(track.duration <= 0)
            }
        }
        .padding(.vertical, DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Выбор своего плеера: программа или сайт.
private struct PlayerPicker: View {
    @AppStorage(Pref.musicPlayer) private var player = "com.apple.Music"
    @State private var site = ""

    private static let known = ["com.apple.Music", "com.spotify.client", "ru.yandex.desktop.music", "com.apple.podcasts",
                                "com.tidal.desktop", "com.deezer.deezer-desktop"]

    private var installed: [String] {
        var list = Self.known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        if !player.hasPrefix("http"), !list.contains(player) { list.append(player) }
        return list
    }

    var body: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.m) {
                Text("Плеер по умолчанию").font(DS.Font.bodyStrong).foregroundStyle(.dsText)
                Picker("Плеер по умолчанию", selection: $player) {
                    ForEach(installed, id: \.self) { Text(NowPlaying.playerTitle($0)).tag($0) }
                    if player.hasPrefix("http") { Text(NowPlaying.playerTitle(player)).tag(player) }
                }
                .graphitePicker()
            }
            HStack(spacing: DS.Space.s) {
                Button("Другая программа…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.application]
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { player = id }
                }
                .buttonStyle(.graphite(.secondary, size: .compact))
                TextField("", text: $site, prompt: Text("или сайт: music.youtube.com"))
                    .textFieldStyle(.graphite).frame(width: 220)
                    .onSubmit {
                        let trimmed = site.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        player = trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed
                        site = ""
                    }
            }
        }
    }
}

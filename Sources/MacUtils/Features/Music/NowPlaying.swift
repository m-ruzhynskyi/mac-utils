import AppKit
import SwiftUI

/// Что сейчас играет в системе (любая программа: браузер, Музыка, Spotify, Telegram…)
/// и управление: пауза, следующий и предыдущий трек, перемотка.
/// Данные MediaRemote с macOS 15.4 доступны только системным процессам, поэтому их читает
/// помощник MUNowPlaying.dylib, загруженный в /usr/bin/perl.
@MainActor
final class NowPlaying: ObservableObject {
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

    private var process: Process?
    private var input: FileHandle?
    private var users = 0
    private var stopWork: DispatchWorkItem?
    private var buffer = Data()

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
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { NowPlaying.shared.receive(data) }
            }
        }
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let player = NowPlaying.shared
                    player.process = nil
                    player.input = nil
                }
            }
        }
        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
            failed = false
        } catch {
            failed = true
        }
    }

    private func stop() {
        send("quit")
        process?.terminate()
        process = nil
        input = nil
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            let title = json["title"] as? String ?? ""
            guard !title.isEmpty else {
                track = nil
                artwork = nil
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
            if track?.title != next.title || track?.artist != next.artist { artwork = nil }
            if let base64 = json["artwork"] as? String, let data = Data(base64Encoded: base64) {
                artwork = NSImage(data: data)
            }
            track = next
        }
    }

    private func send(_ command: String) {
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
    @State private var scrubbing: Double?

    var body: some View {
        Group {
            if let track = player.track {
                content(track)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text(player.failed ? "Не удалось подключиться к системному плееру" : "Сейчас ничего не играет")
                        .foregroundStyle(.secondary)
                    Text("Включите музыку или видео в любой программе — здесь появится управление.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
        }
        .onAppear { player.attach() }
        .onDisappear { player.detach() }
    }

    private func content(_ track: NowPlaying.Track) -> some View {
        VStack(spacing: 14) {
            Group {
                if let artwork = player.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [.purple.opacity(0.5), .blue.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note").font(.system(size: 44)).foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .frame(width: compact ? 180 : 220, height: compact ? 180 : 220)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 8, y: 3)

            VStack(spacing: 3) {
                Text(track.title).font(.headline).lineLimit(1)
                Text(track.artist.isEmpty ? track.app : track.artist).foregroundStyle(.secondary).lineLimit(1)
                if !track.app.isEmpty {
                    Button { player.openPlayer() } label: {
                        Label(track.app, systemImage: "arrow.up.forward.app").font(.caption)
                    }
                    .buttonStyle(.link)
                    .help("Открыть программу")
                }
            }
            .padding(.horizontal)

            if track.duration > 0 {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let position = scrubbing ?? track.position(at: context.date)
                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { position }, set: { scrubbing = $0 }), in: 0...track.duration) { editing in
                            if !editing, let value = scrubbing {
                                player.seek(to: value)
                                scrubbing = nil
                            }
                        }
                        .controlSize(.small)
                        HStack {
                            Text(NowPlaying.time(position))
                            Spacer()
                            Text("−" + NowPlaying.time(track.duration - position))
                        }
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
            }

            HStack(spacing: 22) {
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    .help("Назад на 15 секунд").disabled(track.duration <= 0)
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    .help("Предыдущий")
                Button { player.toggle() } label: {
                    Image(systemName: track.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 40))
                }
                .help(track.playing ? "Пауза" : "Играть")
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                    .help("Следующий")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    .help("Вперёд на 15 секунд").disabled(track.duration <= 0)
            }
            .font(.system(size: 18))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

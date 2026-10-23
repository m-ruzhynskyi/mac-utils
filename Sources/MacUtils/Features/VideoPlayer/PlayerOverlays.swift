import AppKit
import AVFoundation
import SwiftUI
import MUDesign
import MUAudio
import MUCore
import MUScreenshot

/// Всё, что поверх видео: подсказки (v08b, v14b), тосты (v08a, v08c, v14c), кнопка «Пропустить…» (v14),
/// карточка следующей серии (v15), меню субтитров, дорожек и скорости (v04, v05).
struct PlayerOverlays: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var skip: SkipController
    @ObservedObject var ui: PlayerUIState
    let controller: PlayerWindowController

    /// Над плавающей панелью — выше.
    private var bottomInset: CGFloat {
        guard ui.floatingChrome, ui.chromeVisible else { return DS.Space.l }
        return ui.fullScreen ? 150 : 128
    }

    var body: some View {
        ZStack {
            // Подсказки сверху по центру.
            VStack {
                if ui.stepping {
                    ProgressView().controlSize(.small).padding(8).floating(.pill)
                } else if let hud = ui.hud {
                    HUDView(hud: hud).transition(.opacity)
                }
                Spacer()
            }
            .padding(.top, ui.fullScreen ? 70 : DS.Space.xl)
            .allowsHitTesting(false)

            if let hint = ui.seekHint { SeekHintView(zone: hint.zone, seconds: hint.seconds) }

            // Снизу слева — тосты; справа — снимок, «Пропустить…», следующая серия.
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Spacer()
                if let resumed = model.resumedFrom {
                    ResumeToast(position: resumed) { model.restartFromBeginning() } dismiss: { model.resumedFrom = nil }
                }
                if let skipped = skip.skippedToast {
                    SkippedToast(segment: skipped) { skip.undo() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DS.Space.l)
            .padding(.bottom, bottomInset)

            VStack(alignment: .trailing, spacing: DS.Space.s) {
                Spacer()
                if let snapshot = ui.snapshot { SnapshotToast(result: snapshot) }
                skipControl
                if let menu = ui.menu { menuView(menu) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, DS.Space.l)
            .padding(.bottom, bottomInset)
        }
        .animation(.easeOut(duration: 0.15), value: ui.hud)
    }

    @ViewBuilder private var skipControl: some View {
        switch skip.decision {
        case .button(_, let title, let fresh) where fresh || ui.pointerActive || (ui.floatingChrome && ui.chromeVisible):
            SkipButton(title: title, source: skip.currentSegment?.sourceTitle ?? "") {
                skip.skipCurrent()
            } hide: {
                skip.hideInFolder()
            }
        case .countdown(_, let remaining):
            if let next = model.playlist.next(automatic: false) {
                NextEpisodeCard(next: next, position: positionTitle(of: next), remaining: remaining) {
                    skip.cancelCountdown()
                } play: {
                    skip.playNext()
                }
            }
        default:
            EmptyView()
        }
    }

    private func positionTitle(of item: Playlist.Item) -> String {
        guard let index = model.playlist.items.firstIndex(of: item) else { return "" }
        return "\(index + 1) из \(model.playlist.count)"
    }

    @ViewBuilder private func menuView(_ menu: PlayerUIState.Menu) -> some View {
        switch menu {
        case .subtitles: SubtitlesMenu(subtitles: model.subtitles, controller: controller)
        case .audio: AudioMenu(model: model)
        case .speed: SpeedMenu(model: model)
        }
    }
}

// MARK: - Подсказки

private struct HUDView: View {
    let hud: PlayerUIState.HUD

    var body: some View {
        Group {
            switch hud {
            case .frame(let number, let timecode):
                HStack(spacing: DS.Space.m) {
                    Keycap([","], compact: true)
                    VStack(spacing: 0) {
                        Text("Кадр \(PlayerFormat.grouped(number))").font(DS.Font.manrope(15, .heavy, relativeTo: .headline))
                            .foregroundStyle(.dsText)
                        Text("\(timecode) · пауза").font(DS.Font.mono(11.5, relativeTo: .caption)).foregroundStyle(.dsMute)
                    }
                    Keycap(["."], compact: true)
                }
            case .boost:
                HStack(spacing: DS.Space.s) {
                    Text("2×").font(DS.Font.manrope(14, .heavy, relativeTo: .headline))
                    Image(systemName: "forward.fill").font(.system(size: 12, weight: .bold))
                    Text("пока держите").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                    Keycap(["→"], compact: true)
                }
                .foregroundStyle(.dsText)
            case .volume(let percent, let muted):
                HStack(spacing: DS.Space.s) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.system(size: 13, weight: .semibold))
                    Text(muted ? "Без звука" : "Громкость \(percent) %").font(DS.Font.bodyStrong)
                }
                .foregroundStyle(.dsText)
            case .rate(let title):
                Text("Скорость \(title)").font(DS.Font.bodyStrong).foregroundStyle(.dsText)
            case .subtitleDelay(let title), .message(let title):
                Text(title).font(DS.Font.bodyStrong).foregroundStyle(.dsText)
            }
        }
        .floating(.pill)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }
}

/// Двойной клик у края (v14b): «волна» и «‹‹ 20 с».
private struct SeekHintView: View {
    let zone: ClickZone
    let seconds: Int

    var body: some View {
        GeometryReader { geometry in
            let left = zone == .left
            ZStack {
                Ellipse().fill(Color.white.opacity(0.16)).frame(width: geometry.size.height * 1.6, height: geometry.size.height * 1.6)
                    .offset(x: left ? -geometry.size.width * 0.18 : geometry.size.width * 0.18)
                VStack(spacing: 4) {
                    HStack(spacing: -4) {
                        ForEach(0..<3) { index in
                            Image(systemName: left ? "arrowtriangle.backward.fill" : "arrowtriangle.forward.fill")
                                .font(.system(size: 13, weight: .bold))
                                .opacity(left ? [1, 0.7, 0.4][index] : [0.4, 0.7, 1][index])
                        }
                    }
                    Text("\(seconds) с").font(DS.Font.manrope(15, .heavy, relativeTo: .headline))
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4)
            }
            .frame(width: geometry.size.width / 3, height: geometry.size.height)
            .clipped()
            .frame(maxWidth: .infinity, alignment: left ? .leading : .trailing)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - Тосты

private struct ToastTile: View {
    let symbol: String
    let tone: DS.Tone

    var body: some View {
        Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(tone.ink)
            .frame(width: 44, height: 44)
            .background(tone.fill, in: RoundedRectangle(cornerRadius: DS.Radius.tile, style: .continuous))
    }
}

/// «Продолжаем с 23:10» с «С начала ⌥←» (v08a), 5 с.
private struct ResumeToast: View {
    let position: Double
    let restart: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ToastTile(symbol: "clock.arrow.circlepath", tone: .success)
            VStack(alignment: .leading, spacing: 2) {
                Text("Продолжаем с \(PlayerFormat.time(position))").font(DS.Font.headline).foregroundStyle(.dsText)
                Text("Здесь вы остановились в прошлый раз").font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
            Spacer(minLength: DS.Space.l)
            Button("С начала ⌥←", action: restart).buttonStyle(.graphite(.secondary, size: .compact))
        }
        .frame(width: 440)
        .floating()
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .task(id: position) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { dismiss() }
        }
    }
}

/// «Интро пропущено · 1:05–2:35 · по главе „Opening“» с «Вернуть ⌘Z» (v14c).
private struct SkippedToast: View {
    let segment: SkipSegment
    let undo: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            ToastTile(symbol: "forward.end.fill", tone: .info)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.kind == .recap ? "Пересказ пропущен" : "Интро пропущено").font(DS.Font.headline).foregroundStyle(.dsText)
                Text(detail).font(DS.Font.rowSub).foregroundStyle(.dsMute)
            }
            Spacer(minLength: DS.Space.l)
            Button("Вернуть ⌘Z", action: undo).buttonStyle(.graphite(.secondary, size: .compact))
        }
        .frame(width: 440)
        .floating()
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }

    private var detail: String {
        let range = "\(PlayerFormat.time(segment.range.lowerBound))–\(PlayerFormat.time(segment.range.upperBound))"
        return segment.label.isEmpty ? range : "\(range) · по главе «\(segment.label)»"
    }
}

/// «Кадр сохранён» (v08c): миниатюра, размер, время, «Показать».
private struct SnapshotToast: View {
    let result: PlayerSnapshot.Result

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(nsImage: result.thumbnail).resizable().aspectRatio(contentMode: .fit).frame(width: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Tone.success.line)
                    Text(ShotLibraryRules.libraryEnabled ? "Кадр сохранён в «Мои снимки»" : "Кадр сохранён в папку снимков")
                        .font(DS.Font.bodyStrong).foregroundStyle(.dsText)
                }
                Text("\(Int(result.size.width)) × \(Int(result.size.height)) · \(PlayerFormat.time(result.time)) · скопирован в буфер")
                    .font(DS.Font.rowSub).foregroundStyle(.dsMute)
                Button("Показать") { PlayerSnapshot.reveal(result.url) }.buttonStyle(.graphite(.secondary, size: .compact))
            }
        }
        .floating()
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
    }
}

// MARK: - Пропуск

/// Капсула «⏭ Пропустить интро  S» (v14); правый клик — «Не показывать в этой папке».
private struct SkipButton: View {
    let title: String
    let source: String
    let action: () -> Void
    let hide: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "forward.end.fill").font(.system(size: 12, weight: .bold))
                Text(title).font(DS.Font.manrope(14, .heavy, relativeTo: .headline))
                Keycap(["S"], compact: true)
            }
            .foregroundStyle(.dsText)
            .padding(.vertical, 4)
            .floating(.pill)
        }
        .buttonStyle(PressScaleStyle())
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .help("\(title) (S или ↩)\(source.isEmpty ? "" : " · \(source)")")
        .contextMenu {
            Button("Не показывать в этой папке", action: hide)
        }
    }
}

/// «Следующая серия через 5» (v15): миниатюра с кольцом отсчёта, имя, «Смотреть титры esc», «Дальше ↩».
private struct NextEpisodeCard: View {
    let next: Playlist.Item
    let position: String
    let remaining: Double
    let watchCredits: () -> Void
    let play: () -> Void

    @ObservedObject private var info = PlayerMediaInfoCache.shared

    var body: some View {
        let seconds = Int(remaining.rounded(.up))
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                PlayerThumbnail(url: next.url, width: 112, height: 63)
                    .overlay {
                        ZStack {
                            Circle().fill(Color.black.opacity(0.45))
                            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3)
                            Circle().trim(from: 0, to: CGFloat(max(0, remaining) / SkipPlanner.countdownSeconds))
                                .stroke(Color.dsAcc, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(seconds)").font(DS.Font.manrope(15, .heavy, relativeTo: .headline)).foregroundStyle(.white)
                        }
                        .frame(width: 38, height: 38)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Следующая серия через \(seconds)").font(DS.Font.headline).foregroundStyle(.dsText).lineLimit(1).fixedSize()
                    EpisodeTitle(name: next.url.lastPathComponent, font: DS.Font.rowSub, color: .dsMute)
                    Text(detail).font(DS.Font.mono(11, relativeTo: .caption)).foregroundStyle(.dsMute)
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button("Смотреть титры  esc", action: watchCredits).buttonStyle(.graphite(.ghost, size: .compact))
                Button("Дальше ↩", action: play).buttonStyle(.graphite(.primary, size: .compact))
            }
        }
        .fixedSize()
        .floating()
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var detail: String {
        guard let duration = info.duration(of: next.url) else { return position }
        return "\(position) · \(PlayerFormat.time(duration))"
    }
}

// MARK: - Пустое окно, ошибки

/// Пустое окно (v07): зона «Перетащите видео», «Открыть… ⌘O», «Продолжить просмотр».
struct EmptyPlayerView: View {
    let controller: PlayerWindowController

    @State private var recent = PlayerRecent.urls
    @ObservedObject private var info = PlayerMediaInfoCache.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                VStack(spacing: DS.Space.s) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 30, weight: .regular)).foregroundStyle(.dsAccText)
                    Text("Перетащите видео или откройте файл").font(DS.Font.headline).foregroundStyle(.dsText)
                    Text("MP4, MOV, M4V и аудио; MKV, WebM и AVI macOS не открывает")
                        .font(DS.Font.rowSub).foregroundStyle(.dsMute).multilineTextAlignment(.center)
                    Button("Открыть… ⌘O") { PlayerWindowController.openPanel() }
                        .buttonStyle(.graphite(.primary, size: .compact))
                        .padding(.top, DS.Space.s)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .background(Color.dsPanel.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(Color.dsLine, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                if !recent.isEmpty {
                    GroupLabel("Продолжить просмотр")
                    ListCard(style: .field) {
                        ForEach(recent.prefix(6), id: \.self) { url in row(url) }
                    }
                }
            }
            .padding(DS.Space.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.dsBg)
    }

    @ViewBuilder private func row(_ url: URL) -> some View {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let entry = PositionStore.shared.entry(forPath: url.path)
        let finished = PlayerRecent.finished.contains(url.standardizedFileURL.path)
        Button {
            if exists {
                controller.model.open([url])
            } else {
                PlayerRecent.remove(url)
                recent = PlayerRecent.urls
            }
        } label: {
            RowContainer(url.lastPathComponent, subtitle: subtitle(url, exists: exists, entry: entry, finished: finished)) {
                PlayerThumbnail(url: url, width: 56, height: 32).opacity(exists ? 1 : 0.4)
            } trailing: {
                if !exists {
                    Image(systemName: "xmark.circle").foregroundStyle(.dsMute).help("Убрать из списка")
                } else if let entry {
                    ProgressBar(value: entry.position / max(entry.duration, 1)).frame(width: 90)
                } else if finished {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Tone.success.line)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func subtitle(_ url: URL, exists: Bool, entry: PositionStore.Entry?, finished: Bool) -> String {
        let folder = EditorRecent.folderTitle(url)
        guard exists else { return "\(folder) · файл не найден — нажмите, чтобы убрать" }
        if let entry { return "\(folder) · остановились на \(PlayerFormat.time(entry.position)) из \(PlayerFormat.time(entry.duration))" }
        return finished ? "\(folder) · просмотрено" : folder
    }
}

/// Формат не поддерживается (v09, вариант MVP): объяснение, без установки чего-либо.
struct UnsupportedCard: View {
    let url: URL
    @ObservedObject var model: PlayerModel
    let controller: PlayerWindowController

    var body: some View {
        let format = PlayerMedia.formatName(url)
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                ToastTile(symbol: "film.stack", tone: .warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(format) не открывается встроенным плеером macOS").font(DS.Font.headline).foregroundStyle(.dsText)
                    Text("Встроенный плеер macOS играет MP4, MOV и M4V, а MKV, WebM и AVI — нет. Файл можно открыть в другой программе.")
                        .font(DS.Font.body).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.graphite(.ghost))
                Spacer()
                Button("Отмена") { if let item = model.playlist.current { model.remove(item) } }
                    .buttonStyle(.graphite(.secondary))
                Button("Открыть в другой программе…") { controller.openElsewhere(url) }
                    .buttonStyle(.graphite(.primary))
            }
        }
        .frame(width: 520)
        .floating()
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }
}

/// Битый или недописанный файл: понятная ошибка, приложение живо.
struct FailedCard: View {
    let message: String
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                ToastTile(symbol: "exclamationmark.triangle.fill", tone: .danger)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Не удалось открыть «\(model.info.title)»").font(DS.Font.headline).foregroundStyle(.dsText)
                    Text(message).font(DS.Font.body).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                if let url = model.currentURL, FileManager.default.fileExists(atPath: url.path) {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.graphite(.ghost))
                }
                Spacer()
                Button("Убрать из плейлиста") { if let item = model.playlist.current { model.remove(item) } }
                    .buttonStyle(.graphite(.secondary))
            }
        }
        .frame(width: 480)
        .floating()
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }
}

// MARK: - Миниатюры и длительности

/// Миниатюры и длительности файлов плейлиста и недавних: считаются по запросу, хранятся, пока открыт плеер.
@MainActor
final class PlayerMediaInfoCache: ObservableObject {
    static let shared = PlayerMediaInfoCache()
    static let limit = 200

    @Published private var thumbnails: [URL: NSImage] = [:]
    @Published private var durations: [URL: Double] = [:]
    private var requested: Set<URL> = []
    /// Растёт при `clear()`: запросы, начатые до очистки, свои результаты уже не записывают.
    private var generation = 0

    func thumbnail(of url: URL) -> NSImage? { thumbnails[url] }
    func duration(of url: URL) -> Double? { durations[url] }

    func request(_ url: URL) {
        guard !requested.contains(url), !PlayerMedia.isUnsupported(url), FileManager.default.fileExists(atPath: url.path) else { return }
        if requested.count >= Self.limit { clear() }
        requested.insert(url)
        let generation = generation
        Task {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration))?.seconds
            guard generation == self.generation else { return }
            if let duration, duration.isFinite { durations[url] = duration }
            guard (try? await asset.loadTracks(withMediaType: .video))?.isEmpty == false, generation == self.generation else { return }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            let at = CMTime(seconds: min(10, (duration ?? 0) * 0.1), preferredTimescale: 600)
            if let image = try? await generator.image(at: at).image, generation == self.generation {
                thumbnails[url] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    /// Последнее окно плеера закрыли — память не держим.
    func clear() {
        generation += 1
        thumbnails = [:]
        durations = [:]
        requested = []
    }
}

struct PlayerThumbnail: View {
    let url: URL
    let width: CGFloat
    let height: CGFloat

    @ObservedObject private var cache = PlayerMediaInfoCache.shared

    var body: some View {
        ZStack {
            Color.dsField
            if let image = cache.thumbnail(of: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: PlayerMedia.isVideo(url) ? "film" : "waveform").font(.system(size: height * 0.4)).foregroundStyle(.dsMute)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onAppear { cache.request(url) }
    }
}

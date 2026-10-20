import AppKit
import AVFoundation
import SwiftUI

/// Окно плеера (макеты v01–v07): заголовок 50 pt, видео на чёрном, панель под видео, плейлист справа.
/// В полном экране и в режиме «Только видео» заголовка нет, панель плавает поверх видео.
struct PlayerRootView: View {
    @ObservedObject var model: PlayerModel
    let clock: PlayerClock
    @ObservedObject var ui: PlayerUIState
    let controller: PlayerWindowController

    @State private var pictureInPicture = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if !ui.floatingChrome { PlayerTitleBar(model: model, ui: ui) }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PlayerStage(model: model, clock: clock, ui: ui, controller: controller, pictureInPicture: $pictureInPicture)
                    if !ui.floatingChrome, model.phase != .empty {
                        PlayerControls(model: model, clock: clock, skip: model.skip, subtitles: model.subtitles, ui: ui,
                                       controller: controller, pictureInPicture: pictureInPicture, floating: false)
                    }
                }
                if ui.playlistVisible, !ui.fullScreen {
                    Rectangle().fill(Color.dsLine).frame(width: 1)
                    PlaylistPanel(model: model, controller: controller).frame(width: 272)
                }
            }
        }
        .background(model.phase == .empty && !ui.floatingChrome ? Color.dsBg : Color.black)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 3).padding(2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            PlayerWindowController.loadURLs(providers) { controller.dropped($0) }
            return true
        }
        .ignoresSafeArea()
    }
}

// MARK: - Заголовок

struct PlayerTitleBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var ui: PlayerUIState

    var body: some View {
        HStack(spacing: DS.Space.m) {
            // Место под «светофор».
            Color.clear.frame(width: 64, height: 1)
            if model.phase == .empty {
                Text("Видеоплеер").font(DS.Font.manrope(14, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    EpisodeTitle(name: model.info.title, font: DS.Font.manrope(13.5, .heavy, relativeTo: .headline))
                    if let subtitle {
                        Text(subtitle).font(DS.Font.manrope(11, .regular, relativeTo: .caption)).foregroundStyle(.dsMute).lineLimit(1)
                    }
                }
                if let position = model.playlist.positionTitle { Pill(.neutral, position) }
            }
            Spacer(minLength: 0)
            IconButton("Плейлист (⌘L)", systemImage: "list.bullet", active: ui.playlistVisible, compact: true) {
                ui.playlistVisible.toggle()
            }
        }
        .padding(.horizontal, DS.Space.l)
        .frame(height: PlayerWindow.titleBarHeight)
        .background(Color.dsSide)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.dsLine).frame(height: 1) }
    }

    private var subtitle: String? {
        switch model.phase {
        case .unsupported(let url): return "\(PlayerMedia.formatName(url)) · формат не поддерживается системой"
        case .failed: return "не открылся"
        case .loading: return "открывается…"
        default: return model.info.codecs.isEmpty ? nil : model.info.codecs
        }
    }
}

// MARK: - Видео и всё поверх него

struct PlayerStage: View {
    @ObservedObject var model: PlayerModel
    let clock: PlayerClock
    @ObservedObject var ui: PlayerUIState
    let controller: PlayerWindowController
    @Binding var pictureInPicture: Bool

    var body: some View {
        ZStack {
            if model.phase == .empty {
                if ui.floatingChrome { Color.black } else { EmptyPlayerView(controller: controller) }
            } else {
                Color.black
                PlayerVideoRepresentable(model: model, controller: controller, pictureInPicture: $pictureInPicture)
                    .opacity(model.info.hasVideo ? 1 : 0)
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            LoadingIndicator()
        case .unsupported(let url):
            UnsupportedCard(url: url, model: model, controller: controller)
        case .failed(let message):
            FailedCard(message: message, model: model)
        case .ready:
            if !model.info.hasVideo { AudioOnlyView(title: model.info.title) }
            SubtitleOverlay(clock: clock, subtitles: model.subtitles, videoSize: model.info.size,
                            liftedBy: ui.floatingChrome && ui.chromeVisible ? (ui.fullScreen ? 120 : 100) : 0)
            PlayerOverlays(model: model, skip: model.skip, ui: ui, controller: controller)
            if ui.floatingChrome, ui.chromeVisible {
                if ui.fullScreen { FullScreenTopBar(model: model).frame(maxHeight: .infinity, alignment: .top) }
                PlayerControls(model: model, clock: clock, skip: model.skip, subtitles: model.subtitles, ui: ui,
                               controller: controller, pictureInPicture: pictureInPicture, floating: true)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, ui.fullScreen ? DS.Space.xl : DS.Space.l)
                    .transition(.opacity)
            }
        case .empty:
            EmptyView()
        }
    }
}

private struct LoadingIndicator: View {
    @State private var visible = false

    var body: some View {
        ProgressView().controlSize(.large).tint(.white).opacity(visible ? 1 : 0)
            .task {
                // Короткая загрузка не мигает индикатором.
                try? await Task.sleep(nanoseconds: 300_000_000)
                visible = true
            }
    }
}

private struct AudioOnlyView: View {
    let title: String

    var body: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "waveform").font(.system(size: 44, weight: .regular)).foregroundStyle(Color.dsAcc)
            Text(title).font(DS.Font.headline).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
            Text("Только звук").font(DS.Font.rowSub).foregroundStyle(.white.opacity(0.6))
        }
        .padding(DS.Space.xl)
        .allowsHitTesting(false)
    }
}

/// Полный экран (v06): сверху на градиенте — имя, место в плейлисте и следующий файл, «esc — выйти».
private struct FullScreenTopBar: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.info.title).font(DS.Font.manrope(15, .heavy, relativeTo: .headline)).lineLimit(1)
                if let line { Text(line).font(DS.Font.rowSub).opacity(0.75).lineLimit(1) }
            }
            Spacer()
            HStack(spacing: 6) {
                Keycap(["esc"], compact: true)
                Text("выйти из полного экрана").font(DS.Font.rowSub).opacity(0.75)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DS.Space.xxl)
        .padding(.top, DS.Space.l)
        .padding(.bottom, 40)
        .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }

    private var line: String? {
        guard let position = model.playlist.positionTitle else { return nil }
        guard let next = model.playlist.next(automatic: false), next.id != model.playlist.current?.id else { return position }
        return "\(position) · дальше \(next.url.lastPathComponent)"
    }
}

// MARK: - Субтитры

/// Субтитры поверх нижней части кадра: белый Manrope Bold с тенью, без подложки (решение 7); размер S/M/L.
struct SubtitleOverlay: View {
    @ObservedObject var clock: PlayerClock
    @ObservedObject var subtitles: SubtitleController
    let videoSize: CGSize
    /// Поднять над плавающей панелью.
    var liftedBy: CGFloat = 0

    @AppStorage(Pref.playerSubtitleSize) private var size = 1
    @AppStorage(Pref.playerSubtitleBackground) private var background = false

    var body: some View {
        let cues = subtitles.cues(at: clock.time)
        GeometryReader { geometry in
            let frame = videoFrame(in: geometry.size)
            let fontSize = max(13, frame.height * [0.042, 0.052, 0.064][min(max(size, 0), 2)])
            ZStack {
                ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                    cueView(cue, fontSize: fontSize, frame: frame, resolution: subtitles.activeTrack?.playResolution)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    private func videoFrame(in size: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return CGRect(origin: .zero, size: size) }
        return AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: size))
    }

    @ViewBuilder
    private func cueView(_ cue: SubtitleCue, fontSize: CGFloat, frame: CGRect, resolution: CGSize?) -> some View {
        let column = (cue.alignment - 1) % 3, row = (cue.alignment - 1) / 3
        let text = Text(attributed(cue, fontSize: fontSize))
            .multilineTextAlignment(column == 0 ? .leading : column == 2 ? .trailing : .center)
            .shadow(color: .black.opacity(0.9), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.6), radius: 6)
            .padding(.horizontal, background ? fontSize * 0.4 : 0)
            .padding(.vertical, background ? fontSize * 0.15 : 0)
            .background(background ? Color.black.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: fontSize * 0.25))
            .frame(maxWidth: frame.width * 0.9)
            .fixedSize(horizontal: false, vertical: true)
        if let position = cue.position, let resolution, resolution.width > 0, resolution.height > 0 {
            text.position(x: frame.minX + position.x / resolution.width * frame.width,
                          y: frame.minY + position.y / resolution.height * frame.height)
        } else {
            let margin = fontSize * 1.1
            let bottomLift = max(0, liftedBy - (frame.minY))
            text.padding(.horizontal, margin)
                .padding(.top, row == 2 ? margin : 0)
                .padding(.bottom, row == 0 ? margin + bottomLift : 0)
                .frame(width: frame.width, height: frame.height,
                       alignment: Alignment(horizontal: column == 0 ? .leading : column == 2 ? .trailing : .center,
                                            vertical: row == 0 ? .bottom : row == 1 ? .center : .top))
                .position(x: frame.midX, y: frame.midY)
        }
    }

    private func attributed(_ cue: SubtitleCue, fontSize: CGFloat) -> AttributedString {
        var result = AttributedString()
        for run in cue.runs {
            var part = AttributedString(run.text)
            var font = DS.Font.manrope(fontSize, run.bold ? .heavy : .bold, relativeTo: .title3)
            if run.italic { font = font.italic() }
            part.font = font
            part.foregroundColor = run.color.map { Color(red: Double($0.red) / 255, green: Double($0.green) / 255,
                                                         blue: Double($0.blue) / 255, opacity: Double($0.alpha) / 255) } ?? .white
            if run.underline { part.underlineStyle = .single }
            if run.strike { part.strikethroughStyle = .single }
            result += part
        }
        return result
    }
}

// MARK: - Панель управления

/// Панель управления (v01): шкала со временем, «Пауза», ±шаг, громкость; справа скорость, субтитры, дорожка,
/// снимок кадра, PiP, полный экран. В окне — под видео; в полном экране и «Только видео» — плавает, крупнее.
struct PlayerControls: View {
    @ObservedObject var model: PlayerModel
    let clock: PlayerClock
    @ObservedObject var skip: SkipController
    @ObservedObject var subtitles: SubtitleController
    @ObservedObject var ui: PlayerUIState
    let controller: PlayerWindowController
    let pictureInPicture: Bool
    let floating: Bool

    @AppStorage(Pref.playerSeekStep) private var seekStep = 5.0

    private var large: Bool { floating && ui.fullScreen }
    private var button: CGFloat { large ? 34 : 30 }

    var body: some View {
        let ready = model.phase == .ready
        VStack(spacing: floating ? 8 : 6) {
            HStack(spacing: DS.Space.s) {
                TimeLabel(clock: clock, duration: model.duration, remaining: false)
                SeekBar(model: model, clock: clock, skip: skip, thick: large ? 6 : 5)
                TimeLabel(clock: clock, duration: model.duration, remaining: true)
            }
            HStack(spacing: floating ? 8 : 6) {
                if large {
                    PlayerButton(symbol: stepSymbol(back: true), help: "Назад \(Int(seekStep)) с (←)", size: button) { controller.perform(.seekBackward) }
                    PlayButton(playing: model.isPlaying, size: 42) { model.togglePlay() }
                } else {
                    PlayButton(playing: model.isPlaying, size: 36) { model.togglePlay() }
                    PlayerButton(symbol: stepSymbol(back: true), help: "Назад \(Int(seekStep)) с (←)", size: button) { controller.perform(.seekBackward) }
                }
                PlayerButton(symbol: stepSymbol(back: false), help: "Вперёд \(Int(seekStep)) с (→)", size: button) { controller.perform(.seekForward) }
                VolumeControl(model: model, large: large)
                Spacer(minLength: 0)
                if let segment = skip.currentSegment, !floating {
                    HStack(spacing: 5) {
                        Capsule().fill(DS.Tone.info.line.opacity(0.75)).frame(width: 14, height: 5)
                        Text(segment.sourceTitle).font(DS.Font.rowSub).foregroundStyle(.dsMute).lineLimit(1)
                    }
                    .padding(.trailing, DS.Space.s)
                }
                SpeedChip(rate: model.rate, open: ui.menu == .speed) { controller.toggleMenu(.speed) }
                PlayerButton(symbol: "captions.bubble", help: "Субтитры (V)", active: subtitles.selection != .off || ui.menu == .subtitles,
                             size: button) { controller.toggleMenu(.subtitles) }
                PlayerButton(symbol: "waveform", help: "Аудиодорожка (A)", active: ui.menu == .audio, size: button) {
                    controller.toggleMenu(.audio)
                }
                PlayerButton(symbol: "camera.viewfinder", help: "Снимок кадра (⇧S)", size: button) { controller.perform(.snapshot) }
                    .disabled(!model.info.hasVideo)
                PlayerButton(symbol: pictureInPicture ? "pip.exit" : "pip.enter", help: "Картинка в картинке (P)", active: pictureInPicture,
                             size: button) { controller.perform(.pictureInPicture) }
                    .disabled(!model.info.hasVideo)
                PlayerButton(symbol: ui.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                             help: ui.fullScreen ? "Выйти из полного экрана (F)" : "Полный экран (F)", size: button) {
                    controller.toggleFullScreen()
                }
            }
            .disabled(!ready)
        }
        .modifier(ControlsChrome(floating: floating, width: large ? 640 : 560))
        .opacity(ready ? 1 : 0.6)
        .onHover { inside in controller.window.isMouseOverControls = inside }
    }

    private func stepSymbol(back: Bool) -> String {
        let step = [5, 10, 30].contains(Int(seekStep)) ? Int(seekStep) : 5
        return back ? "gobackward.\(step)" : "goforward.\(step)"
    }
}

/// Под видео — полоса цвета боковых панелей; поверх видео — плавающая панель Graphite.
private struct ControlsChrome: ViewModifier {
    let floating: Bool
    let width: CGFloat

    func body(content: Content) -> some View {
        if floating {
            content.frame(width: width).floating().shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        } else {
            content
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, 9)
                .background(Color.dsSide)
                .overlay(alignment: .top) { Rectangle().fill(Color.dsLine).frame(height: 1) }
        }
    }
}

private struct TimeLabel: View {
    @ObservedObject var clock: PlayerClock
    let duration: Double
    let remaining: Bool

    var body: some View {
        Text(remaining ? PlayerFormat.remaining(clock.time, of: duration) : PlayerFormat.time(clock.time))
            .font(DS.Font.mono(11.5, relativeTo: .caption))
            .foregroundStyle(remaining ? Color.dsMute : Color.dsText)
            .monospacedDigit()
            .frame(minWidth: 44, alignment: remaining ? .trailing : .leading)
            .accessibilityLabel(remaining ? "Осталось" : "Прошло")
    }
}

/// Шкала: просмотрено — лайм, загружено — серым, отрезки пропуска — полосами, главы — зазорами, белая ручка.
/// Клик и перетаскивание — перемотка; при наведении — время и название главы.
struct SeekBar: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var clock: PlayerClock
    @ObservedObject var skip: SkipController
    var thick: CGFloat = 5

    @State private var scrubbing: Double?
    @State private var hover: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(model.duration, 0.001)
            let played = CGFloat(min(1, max(0, (scrubbing ?? clock.time) / duration)))
            let buffered = CGFloat(min(1, max(0, clock.buffered / duration)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dsOff).frame(height: thick)
                Capsule().fill(Color.dsMute.opacity(0.45)).frame(width: width * buffered, height: thick)
                ForEach(Array(skip.segments.enumerated()), id: \.offset) { _, segment in
                    Capsule().fill(DS.Tone.info.line.opacity(0.75))
                        .frame(width: max(2, width * CGFloat((segment.range.upperBound - segment.range.lowerBound) / duration)), height: thick)
                        .offset(x: width * CGFloat(segment.range.lowerBound / duration))
                }
                Capsule().fill(Color.dsAccLine).frame(width: width * played, height: thick)
                ForEach(Array(skip.chapters.dropFirst().enumerated()), id: \.offset) { _, chapter in
                    Rectangle().fill(Color.dsSide).frame(width: 2, height: thick).offset(x: width * CGFloat(chapter.start / duration) - 1)
                }
                Circle().fill(Color.white).frame(width: thick + 9, height: thick + 9)
                    .overlay(Circle().strokeBorder(Color.dsAccLine, lineWidth: 2.5))
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: width * played - (thick + 9) / 2)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let time = Double(min(1, max(0, value.location.x / max(width, 1)))) * model.duration
                    scrubbing = time
                    model.seek(to: time)
                }
                .onEnded { value in
                    let time = Double(min(1, max(0, value.location.x / max(width, 1)))) * model.duration
                    model.seek(to: time, exact: true)
                    scrubbing = nil
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = point.x
                case .ended: hover = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let hover, model.duration > 0 {
                    let time = Double(min(1, max(0, hover / max(width, 1)))) * model.duration
                    Text(hoverTitle(time)).font(DS.Font.mono(11, relativeTo: .caption)).foregroundStyle(.dsText)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.dsPanel, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.dsLine, lineWidth: 1))
                        .fixedSize()
                        .offset(x: min(max(0, hover - 30), max(0, width - 120)), y: -28)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel("Шкала воспроизведения")
        .accessibilityValue(PlayerFormat.time(clock.time))
        .accessibilityAdjustableAction { direction in
            model.seek(by: direction == .increment ? PlayerPrefs.seekStep : -PlayerPrefs.seekStep)
        }
    }

    private func hoverTitle(_ time: Double) -> String {
        let chapter = skip.chapters.last { $0.start <= time && time < $0.end }
        guard let title = chapter?.title, !title.isEmpty else { return PlayerFormat.time(time) }
        return "\(PlayerFormat.time(time)) · \(title)"
    }
}

/// Громкость: значок (клик — без звука) и ползунок Graphite.
private struct VolumeControl: View {
    @ObservedObject var model: PlayerModel
    let large: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.isMuted.toggle()
            } label: {
                Image(systemName: symbol).font(.system(size: large ? 14 : 13, weight: .semibold)).foregroundStyle(.dsText)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.isMuted ? "Включить звук (M)" : "Без звука (M)")
            .accessibilityLabel(model.isMuted ? "Включить звук" : "Выключить звук")
            PlayerSlider(value: Binding(get: { Double(model.isMuted ? 0 : model.volume) },
                                        set: { model.isMuted = false; model.volume = Float($0) }),
                         label: "Громкость")
                .frame(width: large ? 90 : 74)
        }
        .padding(.leading, 6)
    }

    private var symbol: String {
        if model.isMuted || model.volume == 0 { return "speaker.slash.fill" }
        return model.volume < 0.34 ? "speaker.wave.1.fill" : model.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// Ползунок Graphite: дорожка `off`, заливка лаймом, белая ручка.
struct PlayerSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let label: String

    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let x = width * min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.dsOff).frame(height: 4)
                Capsule().fill(Color.dsAccLine).frame(width: x, height: 4)
                Circle().fill(Color.white).frame(width: 15, height: 15)
                    .overlay(Circle().strokeBorder(dragging ? Color.dsAccLine : Color.black.opacity(0.18), lineWidth: dragging ? 3 : 1))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: x - 7.5)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragging = true
                    let fraction = Double(min(1, max(0, drag.location.x / max(width, 1))))
                    value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in dragging = false })
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 100).rounded())) %")
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step)))
        }
    }
}

/// Кнопка панели: без подложки, включённая — лайм.
struct PlayerButton: View {
    let symbol: String
    let help: String
    var active = false
    var size: CGFloat = 30
    let action: () -> Void

    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 0.47, weight: .semibold))
                .foregroundStyle(active ? Color.dsAccInk : Color.dsText)
                .frame(width: size, height: size)
                .background(active ? Color.dsAcc : (hovered && enabled ? Color.dsField : .clear),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .opacity(enabled ? 1 : DS.State.disabledOpacity)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Круглая лаймовая «Пауза» / «Играть».
struct PlayButton: View {
    let playing: Bool
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.dsAccInk)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.dsAcc))
        }
        .buttonStyle(PressScaleStyle())
        .help(playing ? "Пауза (пробел)" : "Воспроизвести (пробел)")
        .accessibilityLabel(playing ? "Пауза" : "Воспроизвести")
    }
}

/// «1×» — открывает меню скорости.
private struct SpeedChip: View {
    let rate: Float
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(PlaybackRate.title(rate)).font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(open ? Color.dsAccInk : Color.dsText)
                .padding(.horizontal, 8).frame(height: 24)
                .background(open ? Color.dsAcc : Color.dsField, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(open ? Color.clear : Color.dsLine, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Скорость ([ и ])")
        .accessibilityLabel("Скорость \(PlaybackRate.title(rate))")
    }
}

/// Имя файла в одну строку: номер серии («s01e03») не сокращается никогда, сокращается то, что перед ним;
/// короткий хвост после номера («_demo.mp4») тоже виден. Без номера — сокращение посередине.
struct EpisodeTitle: View {
    let name: String
    let font: Font
    var color: Color = .dsText

    var body: some View {
        if let parts = EpisodeName.split(name) {
            HStack(spacing: 0) {
                if !parts.before.isEmpty {
                    // Начало названия хотя бы «Оче…»: по нему видно, какой это сериал.
                    Text(parts.before).lineLimit(1).truncationMode(.tail).frame(minWidth: 40, alignment: .leading).layoutPriority(0)
                }
                Text(parts.marker).lineLimit(1).fixedSize().layoutPriority(3)
                if parts.after.count <= 16 {
                    Text(parts.after).lineLimit(1).fixedSize().layoutPriority(2)
                } else {
                    Text(parts.after).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                }
            }
            .font(font)
            .foregroundStyle(color)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
        } else {
            Text(name).font(font).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
        }
    }
}

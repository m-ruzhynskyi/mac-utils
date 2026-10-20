import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Пункт меню

/// Пункт плавающего меню: ✓ и лайм у текущего, подзаголовок, клавиша справа.
struct PlayerMenuItem: View {
    let title: String
    var subtitle: String?
    var current = false
    var symbol: String?
    var width: CGFloat = 230
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol ?? "checkmark").font(.system(size: 10, weight: .heavy))
                    .opacity(current || symbol != nil ? 1 : 0).frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(current ? DS.Font.bodyStrong : DS.Font.body).lineLimit(1).truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle).font(DS.Font.manrope(11, .regular, relativeTo: .caption))
                            .foregroundStyle(current ? Color.dsAccInk.opacity(0.75) : Color.dsMute).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(current ? Color.dsAccInk : Color.dsText)
            .padding(.horizontal, 8)
            .frame(width: width, height: subtitle == nil ? 26 : 36)
            .background(current ? Color.dsAcc : (hovered ? Color.dsField : .clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

private struct MenuHeader: View {
    let title: String
    let keys: [String]

    var body: some View {
        HStack {
            Text(title).font(DS.Font.manrope(15, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
            Spacer()
            ForEach(keys, id: \.self) { Keycap([$0], compact: true) }
        }
        .padding(.bottom, 6)
    }
}

private struct MenuSetting<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title).font(DS.Font.manrope(12.5, .semibold, relativeTo: .callout)).foregroundStyle(.dsText)
            Spacer(minLength: 0)
            content
        }
        .frame(height: 32)
    }
}

private struct MenuDivider: View {
    var body: some View { Rectangle().fill(Color.dsLine).frame(height: 1).padding(.vertical, 6) }
}

private extension View {
    func playerMenu(width: CGFloat) -> some View {
        frame(width: width).floating().shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }
}

/// Компактные вкладки S / M / L: равные доли, выбранная — лайм.
private struct CompactTabs: View {
    let titles: [String]
    @Binding var selected: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { index in
                let on = index == selected
                Button { selected = index } label: {
                    Text(titles[index])
                        .font(DS.Font.manrope(12.5, on ? .heavy : .bold, relativeTo: .callout))
                        .foregroundStyle(on ? Color.dsAccInk : Color.dsMute)
                        .frame(maxWidth: .infinity).frame(height: 26)
                        .background(on ? Color.dsAcc : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
    }
}

// MARK: - Субтитры (v04)

struct SubtitlesMenu: View {
    @ObservedObject var subtitles: SubtitleController
    let controller: PlayerWindowController

    @AppStorage(Pref.playerSubtitleSize) private var size = 1
    @AppStorage(Pref.playerSubtitleBackground) private var background = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(title: "Субтитры", keys: ["V"])
            PlayerMenuItem(title: "Выключены", current: subtitles.selection == .off, width: 280) { subtitles.select(.off) }
            ForEach(subtitles.embedded) { track in
                PlayerMenuItem(title: track.title, subtitle: "встроенные · \(track.codec)", current: subtitles.selection == .embedded(track.id),
                               width: 280) { subtitles.select(.embedded(track.id)) }
            }
            ForEach(subtitles.external) { file in
                PlayerMenuItem(title: file.title, subtitle: file.nearby ? "рядом с видео · загружены сами" : "добавлены вручную",
                               current: subtitles.selection == .external(file.id), width: 280) { subtitles.select(.external(file.id)) }
            }
            PlayerMenuItem(title: "Добавить файл… (SRT, ASS, VTT)", symbol: "plus", width: 280) { addFile() }
            if let error = subtitles.lastError {
                Text(error).font(DS.Font.rowSub).foregroundStyle(DS.Tone.danger.text).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            MenuDivider()
            MenuSetting(title: "Сдвиг") {
                HStack(spacing: 6) {
                    Button { subtitles.shiftDelay(-0.1) } label: { Keycap(["Z"], compact: true) }.buttonStyle(.plain)
                        .help("Раньше на 0,1 с (Z)")
                    Text(delayText).font(DS.Font.mono(13, relativeTo: .body)).foregroundStyle(.dsText).frame(minWidth: 56)
                        .onTapGesture(count: 2) { subtitles.resetDelay() }
                        .help("Двойной клик — без сдвига")
                    Button { subtitles.shiftDelay(0.1) } label: { Keycap(["X"], compact: true) }.buttonStyle(.plain)
                        .help("Позже на 0,1 с (X)")
                }
            }
            MenuSetting(title: "Размер") { CompactTabs(titles: ["S", "M", "L"], selected: $size).frame(width: 120) }
            MenuSetting(title: "Подложка") { Toggle("Подложка", isOn: $background).toggleStyle(.graphite).labelsHidden() }
            if let file = subtitles.selectedExternal {
                MenuSetting(title: "Кодировка файла") {
                    Picker("Кодировка файла", selection: Binding(get: { file.encoding }, set: { subtitles.reencode($0) })) {
                        ForEach(TextEncoding.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .graphitePicker()
                    .fixedSize()
                }
                Text("Кодировку определяет ядро текстового редактора").font(DS.Font.rowSub).foregroundStyle(.dsMute).padding(.top, 4)
            }
        }
        .playerMenu(width: 280)
    }

    private var delayText: String {
        let value = (subtitles.delay * 10).rounded() / 10
        guard value != 0 else { return "0 с" }
        return String(format: "%+.1f с", value).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−")
    }

    private func addFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
        panel.message = "Субтитры SRT, ASS или VTT"
        if let folder = controller.model.currentURL?.deletingLastPathComponent() { panel.directoryURL = folder }
        panel.beginSheetModal(for: controller.window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { subtitles.addExternal(url) }
        }
    }
}

// MARK: - Аудиодорожка и скорость (v05)

struct AudioMenu: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(title: "Аудиодорожка", keys: ["A"])
            if model.audioOptions.isEmpty {
                Text(model.info.hasVideo ? "В файле нет звука" : "Одна дорожка").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                    .padding(.horizontal, 8)
            }
            ForEach(model.audioOptions) { option in
                PlayerMenuItem(title: option.title, subtitle: option.detail.isEmpty ? nil : option.detail,
                               current: model.selectedAudio == option.id, width: 240) { model.selectAudio(option.id) }
            }
        }
        .playerMenu(width: 240)
    }
}

struct SpeedMenu: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuHeader(title: "Скорость", keys: ["[", "]"])
            ForEach(PlaybackRate.presets, id: \.self) { rate in
                PlayerMenuItem(title: rate == 1 ? "1× — обычная" : PlaybackRate.title(rate), current: model.rate == rate, width: 200) {
                    model.setRate(rate)
                }
            }
            MenuDivider()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Своя").font(DS.Font.manrope(12.5, .semibold, relativeTo: .callout)).foregroundStyle(.dsText)
                    Spacer(minLength: 0)
                    Text(PlaybackRate.title(model.rate)).font(DS.Font.mono(11.5, relativeTo: .caption))
                        .foregroundStyle(PlaybackRate.presets.contains(model.rate) ? Color.dsMute : Color.dsAccText)
                }
                PlayerSlider(value: Binding(get: { Double(model.rate) }, set: { model.setRate(Float($0)) }),
                             range: Double(PlaybackRate.range.lowerBound)...Double(PlaybackRate.range.upperBound), label: "Своя скорость")
            }
            HStack {
                Text("Сохранять тон").font(DS.Font.manrope(12.5, .semibold, relativeTo: .callout)).foregroundStyle(.dsText)
                Spacer()
                Toggle("Сохранять тон", isOn: $model.keepsPitch).toggleStyle(.graphite).labelsHidden()
            }
            .padding(.top, 6)
        }
        .playerMenu(width: 200)
    }
}

// MARK: - Плейлист (v03)

struct PlaylistPanel: View {
    @ObservedObject var model: PlayerModel
    let controller: PlayerWindowController

    @ObservedObject private var info = PlayerMediaInfoCache.shared
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Text("Плейлист").font(DS.Font.manrope(16, .heavy, relativeTo: .headline)).foregroundStyle(.dsText)
                Spacer(minLength: 0)
                if !model.playlist.isEmpty { Pill(.neutral, summary) }
            }
            List(selection: $selection) {
                ForEach(model.playlist.items) { item in
                    row(item)
                        .tag(item.id)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Играть") { model.play(item) }
                            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Divider()
                            Button("Убрать из плейлиста") { model.remove(item) }
                        }
                }
                .onMove { model.movePlaylist(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onDeleteCommand { if let id = selection, let item = model.playlist.items.first(where: { $0.id == id }) { model.remove(item) } }
            .overlay {
                if model.playlist.isEmpty {
                    Text("Пусто").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                }
            }
            HStack(spacing: DS.Space.s) {
                IconButton(repeatTitle, systemImage: model.playlist.repeatMode == .one ? "repeat.1" : "repeat",
                           active: model.playlist.repeatMode != .off, compact: true) { model.cycleRepeat() }
                IconButton("Перемешать", systemImage: "shuffle", active: model.playlist.isShuffled, compact: true) { model.toggleShuffle() }
                Spacer()
                IconButton("Добавить файлы или папку", systemImage: "plus", compact: true) { addFiles() }
            }
            Text("Перетащите файлы сюда или меняйте порядок мышью").font(DS.Font.rowSub).foregroundStyle(.dsMute)
        }
        .padding(DS.Space.m)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.dsSide)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            PlayerWindowController.loadURLs(providers) { urls in model.append(urls.filter { !PlayerMedia.isSubtitle($0) }) }
            return true
        }
    }

    private var repeatTitle: String {
        switch model.playlist.repeatMode {
        case .off: return "Повтор выключен"
        case .all: return "Повтор: весь список"
        case .one: return "Повтор: один файл"
        }
    }

    /// «6 · 2:39:25» — когда известны все длительности; иначе только число.
    private var summary: String {
        let durations = model.playlist.items.map { info.duration(of: $0.url) }
        let count = model.playlist.count
        guard durations.allSatisfy({ $0 != nil }) else { return "\(count)" }
        return "\(count) · \(PlayerFormat.time(durations.compactMap { $0 }.reduce(0, +)))"
    }

    private func row(_ item: Playlist.Item) -> some View {
        let current = item.id == model.playlist.current?.id
        let unsupported = PlayerMedia.isUnsupported(item.url)
        let finished = PlayerRecent.finished.contains(item.url.standardizedFileURL.path)
        return HStack(spacing: DS.Space.s) {
            PlayerThumbnail(url: item.url, width: 64, height: 36)
                .overlay {
                    if current, model.isPlaying {
                        Image(systemName: "waveform").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                    }
                }
                .opacity(unsupported ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).font(DS.Font.manrope(12.5, current ? .heavy : .semibold, relativeTo: .callout))
                    .foregroundStyle(unsupported ? Color.dsMute : Color.dsText).lineLimit(1).truncationMode(.middle)
                if unsupported {
                    Text("\(PlayerMedia.formatName(item.url)) — не открывается в macOS").font(DS.Font.manrope(10.5, .semibold, relativeTo: .caption2))
                        .foregroundStyle(DS.Tone.warning.text).lineLimit(1)
                } else if current, model.duration > 0 {
                    CurrentProgress(clock: model.clock, duration: model.duration)
                } else if let duration = info.duration(of: item.url) {
                    Text(finished ? "\(PlayerFormat.time(duration)) · просмотрено" : PlayerFormat.time(duration))
                        .font(DS.Font.manrope(10.5, .regular, relativeTo: .caption2)).foregroundStyle(.dsMute)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .background(current ? Color.dsPanel : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay { if current { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.dsAccLine, lineWidth: 1.5) } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.play(item) }
        .help(item.url.path)
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.audiovisualContent]
        panel.beginSheetModal(for: controller.window) { response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { model.append(urls) }
        }
    }
}

/// «23:10 из 48:10» у текущего файла.
private struct CurrentProgress: View {
    @ObservedObject var clock: PlayerClock
    let duration: Double

    var body: some View {
        HStack(spacing: 6) {
            ProgressBar(value: clock.time / max(duration, 1)).frame(width: 60).scaleEffect(y: 0.6)
            Text("\(PlayerFormat.time(clock.time)) из \(PlayerFormat.time(duration))")
                .font(DS.Font.manrope(10.5, .regular, relativeTo: .caption2)).foregroundStyle(.dsMute)
        }
    }
}

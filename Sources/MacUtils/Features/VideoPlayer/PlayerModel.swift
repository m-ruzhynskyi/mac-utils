import AVFoundation
import Combine
import Foundation

/// Время воспроизведения отдельно от модели: часто меняется (≈ 30 раз в секунду во время игры),
/// и перерисовываются только шкала, время и субтитры, а не всё окно.
@MainActor
final class PlayerClock: ObservableObject {
    @Published var time: Double = 0
    @Published var buffered: Double = 0
}

/// Модель одного окна плеера: очередь, текущий файл и его состояние, скорость, громкость, позиции.
/// Наблюдатели за `AVPlayer` (время, статус, конец файла) живут только пока открыт файл; `shutdown()` — окно
/// закрыли — снимает все и отпускает файл. Без окна модель ничего не делает.
@MainActor
final class PlayerModel: ObservableObject {
    enum Phase: Equatable {
        /// Пустое окно (v07).
        case empty
        case loading
        case ready
        /// Контейнер, который AVFoundation не открывает (MKV, WebM, AVI) — экран v09.
        case unsupported(URL)
        /// Битый или недописанный файл — понятная ошибка, приложение живо.
        case failed(String)
    }

    struct MediaInfo: Equatable {
        var title = ""
        var codecs = ""
        var hasVideo = false
        var size = CGSize.zero
        var fps: Double = 0
    }

    let player = AVPlayer()
    let clock = PlayerClock()

    @Published private(set) var playlist = Playlist()
    @Published private(set) var phase: Phase = .empty
    @Published private(set) var info = MediaInfo()
    @Published private(set) var duration: Double = 0
    /// Идёт воспроизведение (по `timeControlStatus`, ожидание буфера тоже считается).
    @Published private(set) var isPlaying = false
    /// Выбранная скорость (без временных 2× при удержании →).
    @Published private(set) var rate: Float = 1
    /// Временная скорость поверх выбранной (удержание →); nil — нет.
    @Published private(set) var boostRate: Float?
    @Published var volume: Float = PlayerPrefs.volume {
        didSet {
            player.volume = volume
            PlayerPrefs.volume = volume
        }
    }
    @Published var isMuted = false { didSet { player.isMuted = isMuted || silent } }
    @Published var keepsPitch = PlayerPrefs.keepPitch {
        didSet {
            UserDefaults.standard.set(keepsPitch, forKey: Pref.playerKeepPitch)
            player.currentItem?.audioTimePitchAlgorithm = pitchAlgorithm
        }
    }
    /// Продолжили с запомненного места: тост «Продолжаем с 23:10» (v08a).
    @Published var resumedFrom: Double?
    /// Файл доиграл до конца и следующего нет: пробел начнёт сначала.
    @Published private(set) var reachedEnd = false

    /// Для снимка кадра и проверки шага: ровно показанный кадр.
    private(set) var videoOutput: AVPlayerItemVideoOutput?
    /// Текущий файл (ключ позиции считается при открытии, до того как файл могли перезаписать).
    private(set) var currentURL: URL?
    private var positionKey: String?

    /// Без звука навсегда (тесты: на Mac пользователя не должно ничего звучать).
    private let silent: Bool
    private let positions: PositionStore
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var wantsToPlay = false

    /// Колбэки окна: смена файла, начало и конец воспроизведения, конец файла.
    var onItemChange: (() -> Void)?
    var onPlayingChange: ((Bool) -> Void)?
    /// Файл доиграл сам; `true` — модель уже перешла к следующему.
    var onFinish: ((Bool) -> Void)?

    /// Сколько наблюдателей сейчас стоит (для `IdleCPUTests`).
    var activeObserverCount: Int { (timeObserver == nil ? 0 : 1) + observations.count + (endObserver == nil ? 0 : 1) }

    init(silent: Bool = false, positions: PositionStore? = nil) {
        self.silent = silent
        self.positions = positions ?? PositionStore.shared
        player.volume = volume
        player.isMuted = silent
        player.actionAtItemEnd = .pause
        // Обычный плеер: экран не гаснет — своим утверждением (`PlayerSystem`), не системным для внешнего видео.
        player.preventsDisplaySleepDuringVideoPlayback = false
    }

    private var pitchAlgorithm: AVAudioTimePitchAlgorithm { keepsPitch ? .spectral : .varispeed }

    var currentTime: Double {
        let time = player.currentTime().seconds
        return time.isFinite ? time : 0
    }

    var effectiveRate: Float { boostRate ?? rate }

    // MARK: - Очередь

    /// Открыть файлы: встают после текущего, первый начинает играть (уже открытый — переход к нему).
    func open(_ urls: [URL]) {
        let media = PlayerMedia.expand(urls)
        guard !media.isEmpty, let first = playlist.insertAfterCurrent(media) else { return }
        play(first)
    }

    /// Добавить в конец, не прерывая текущий («+» в плейлисте). Если ничего не играло — начать с первого.
    func append(_ urls: [URL]) {
        let media = PlayerMedia.expand(urls)
        let wasEmpty = playlist.current == nil
        playlist.append(media)
        if wasEmpty, let first = media.first.flatMap(playlist.item(for:)) { play(first) }
    }

    func play(_ item: Playlist.Item, autoplay: Bool = true) {
        savePosition()
        playlist.select(item.id)
        load(item.url, autoplay: autoplay)
    }

    func remove(_ item: Playlist.Item) {
        let wasCurrent = item.id == playlist.current?.id
        if wasCurrent { savePosition() }
        playlist.remove(item.id)
        guard wasCurrent else { return }
        if let next = playlist.current { load(next.url, autoplay: wantsToPlay) } else { clear() }
    }

    func movePlaylist(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        playlist.move(fromOffsets: offsets, toOffset: destination)
    }

    func cycleRepeat() { playlist.repeatMode = playlist.repeatMode.next }

    func toggleShuffle() {
        if playlist.isShuffled { playlist.unshuffle() } else { playlist.shuffle() }
    }

    /// «Дальше» (кнопка, ⏭, «Следующая серия»).
    func next() {
        guard let item = playlist.next(automatic: false), item.id != playlist.current?.id else { return }
        play(item)
    }

    /// ⏮: в начале файла — предыдущий, иначе — к началу текущего (как в музыкальных плеерах).
    func previous() {
        if currentTime > 3 || playlist.previous() == nil {
            seek(to: 0)
            return
        }
        if let item = playlist.previous() { play(item) }
    }

    // MARK: - Загрузка

    private func load(_ url: URL, autoplay: Bool) {
        resetItem()
        currentURL = url
        positionKey = PositionStore.key(for: url)
        info = MediaInfo(title: url.lastPathComponent)
        reachedEnd = false
        onItemChange?()
        if PlayerMedia.isUnsupported(url) {
            phase = .unsupported(url)
            return
        }
        phase = .loading
        wantsToPlay = autoplay
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        loadTask = Task { [weak self] in
            do {
                let (playable, duration, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
                let info = await Self.describe(tracks, title: url.lastPathComponent)
                guard let self, !Task.isCancelled, self.currentURL == url else { return }
                guard playable else {
                    self.phase = PlayerMedia.isVideo(url) ? .unsupported(url) : .failed("Этот файл не открывается встроенным плеером macOS")
                    return
                }
                self.info = info
                self.duration = duration.seconds.isFinite ? duration.seconds : 0
                self.attach(AVPlayerItem(asset: asset), autoplay: autoplay)
            } catch {
                guard let self, !Task.isCancelled, self.currentURL == url else { return }
                Log.player.error("Файл не открылся: \((error as NSError).code, privacy: .public)")
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    private func attach(_ item: AVPlayerItem, autoplay: Bool) {
        item.audioTimePitchAlgorithm = pitchAlgorithm
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        videoOutput = output
        observe(item)
        player.replaceCurrentItem(with: item)
    }

    private func observe(_ item: AVPlayerItem) {
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] item, _ in
                let status = item.status
                let error = item.error
                Task { @MainActor in self?.statusChanged(status, error: error) }
            },
            item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] item, _ in
                let end = item.loadedTimeRanges.map { $0.timeRangeValue.end.seconds }.max() ?? 0
                Task { @MainActor in self?.clock.buffered = end.isFinite ? end : 0 }
            },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let playing = player.timeControlStatus != .paused
                Task { @MainActor in self?.playingChanged(playing) }
            },
        ]
        // ≈ 30 раз в секунду: субтитры и шкала. Во время паузы AVPlayer этот наблюдатель не вызывает.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.clock.time = seconds.isFinite ? seconds : 0 }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finished() }
        }
    }

    private func statusChanged(_ status: AVPlayerItem.Status, error: Error?) {
        switch status {
        case .readyToPlay:
            guard phase == .loading else { return }
            phase = .ready
            if PlayerPrefs.rememberPosition, let key = positionKey, let position = positions.resumePosition(for: key),
               position < duration - 1 {
                seek(to: position, exact: true)
                resumedFrom = position
            }
            if wantsToPlay { play() }
        case .failed:
            Log.player.error("Воспроизведение не началось: \((error as NSError?)?.code ?? 0, privacy: .public)")
            phase = .failed(error.map(Self.message(for:)) ?? "Файл не воспроизводится")
        default:
            break
        }
    }

    private func playingChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        onPlayingChange?(playing)
        if !playing { savePosition() }
    }

    /// Файл доиграл: следующий по плейлисту (повтор одного — тот же сначала) или стоп в конце.
    private func finished() {
        clock.time = duration
        savePosition(finished: true)
        if let next = playlist.next(automatic: true) {
            if next.id == playlist.current?.id {
                seek(to: 0)
                play()
            } else {
                play(next)
            }
            onFinish?(true)
        } else {
            reachedEnd = true
            wantsToPlay = false
            onFinish?(false)
        }
    }

    /// Отпустить файл: наблюдатели сняты, загрузка отменена.
    private func resetItem() {
        loadTask?.cancel()
        loadTask = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.forEach { $0.invalidate() }
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        boostRate = nil
        resumedFrom = nil
        duration = 0
        clock.time = 0
        clock.buffered = 0
        if isPlaying {
            isPlaying = false
            onPlayingChange?(false)
        }
    }

    private func clear() {
        resetItem()
        currentURL = nil
        positionKey = nil
        info = MediaInfo()
        phase = .empty
        onItemChange?()
    }

    /// Окно закрыли: место запомнено, звук сразу стих, наблюдателей нет, очередь пуста.
    func shutdown() {
        savePosition()
        wantsToPlay = false
        clear()
        playlist.removeAll()
    }

    // MARK: - Управление

    func play() {
        guard phase == .ready else { return }
        if reachedEnd || currentTime >= duration - 0.05 {
            reachedEnd = false
            seek(to: 0)
        }
        wantsToPlay = true
        player.defaultRate = effectiveRate
        player.play()
        player.rate = effectiveRate
    }

    func pause() {
        wantsToPlay = false
        player.pause()
    }

    func togglePlay() {
        if isPlaying || player.rate != 0 { pause() } else { play() }
    }

    /// Выбранная скорость 0,25–4×.
    func setRate(_ value: Float) {
        rate = PlaybackRate.clamp(value)
        applyRate()
    }

    func stepRate(_ direction: Int) { setRate(PlaybackRate.stepped(rate, by: direction)) }

    /// Временная скорость (удержание →); nil — вернуть выбранную.
    func setBoost(_ value: Float?) {
        boostRate = value
        applyRate()
    }

    private func applyRate() {
        player.defaultRate = effectiveRate
        if player.rate != 0 { player.rate = effectiveRate }
    }

    /// Перемотка на `seconds` (в пределах файла). `exact` — до кадра (шаг, пропуск отрезка); иначе — быстро, ±0,1 с.
    func seek(to seconds: Double, exact: Bool = false, toleranceBefore: Double? = nil) {
        guard phase == .ready || phase == .loading else { return }
        let target = min(max(0, seconds), max(0, duration - (exact ? 0 : 0.05)))
        reachedEnd = false
        let time = CMTime(seconds: target, preferredTimescale: 600)
        let before = toleranceBefore.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? (exact ? .zero : CMTime(value: 1, timescale: 10))
        let after = exact || toleranceBefore != nil ? CMTime.zero : CMTime(value: 1, timescale: 10)
        clock.time = target
        player.seek(to: time, toleranceBefore: before, toleranceAfter: after)
    }

    func seek(by delta: Double) { seek(to: currentTime + delta) }

    /// Кадр вперёд или назад на паузе (`,` и `.`). Где шаг назад не поддерживается — точная перемотка на кадр раньше.
    func stepFrame(forward: Bool) {
        guard phase == .ready, let item = player.currentItem else { return }
        pause()
        let fps = info.fps > 0 ? info.fps : 25
        if forward ? item.canStepForward : item.canStepBackward {
            item.step(byCount: forward ? 1 : -1)
        } else {
            seek(to: currentTime + (forward ? 1 : -1) / fps, exact: true)
        }
    }

    /// Номер текущего кадра (для подсказки «Кадр N»).
    var frameNumber: Int {
        let fps = info.fps > 0 ? info.fps : 25
        return Int((currentTime * fps + 0.001).rounded(.down))
    }

    // MARK: - Позиции

    /// Запомнить место (пауза, смена файла, закрытие). Без настройки «Запоминать место» файл позиций не пишется.
    func savePosition(finished: Bool = false) {
        guard let url = currentURL, phase == .ready, duration > 0 else { return }
        let position = finished ? duration : currentTime
        if PlayerPrefs.rememberPosition, let key = positionKey {
            positions.record(key: key, path: url.standardizedFileURL.path, position: position, duration: duration)
        }
        PlayerRecent.add(url, finished: PositionStore.isFinished(position: position, duration: duration))
    }

    /// «С начала ⌥←» в тосте продолжения.
    func restartFromBeginning() {
        resumedFrom = nil
        seek(to: 0, exact: true)
    }

    // MARK: - Описание файла

    private static func describe(_ tracks: [AVAssetTrack], title: String) async -> MediaInfo {
        var info = MediaInfo(title: title)
        var parts: [String] = []
        if let video = tracks.first(where: { $0.mediaType == .video }) {
            info.hasVideo = true
            let (formats, size, transform, fps) = (try? await video.load(.formatDescriptions, .naturalSize, .preferredTransform,
                                                                         .nominalFrameRate)) ?? ([], .zero, .identity, Float(0))
            let rect = CGRect(origin: .zero, size: size).applying(transform)
            info.size = CGSize(width: abs(rect.width), height: abs(rect.height))
            info.fps = Double(fps)
            if let format = formats.first { parts.append(CodecDescription.video(format.mediaSubType.rawValue)) }
            if info.size.width > 0 { parts.append("\(Int(info.size.width)) × \(Int(info.size.height))") }
            if let rate = CodecDescription.frameRate(fps) { parts.append(rate) }
        }
        if let audio = tracks.first(where: { $0.mediaType == .audio }),
           let format = (try? await audio.load(.formatDescriptions))?.first {
            var line = CodecDescription.audio(format.mediaSubType.rawValue)
            if let channels = format.audioStreamBasicDescription.flatMap({ CodecDescription.channels($0.mChannelsPerFrame) }),
               channels != "стерео" {
                line += " " + channels
            }
            parts.append(line)
        }
        info.codecs = parts.joined(separator: " · ")
        return info
    }

    /// Понятный текст ошибки без системных подробностей.
    static func message(for error: Error) -> String {
        let code = (error as NSError).code
        switch code {
        case AVError.fileFormatNotRecognized.rawValue, AVError.unknown.rawValue, -12848, -11829:
            return "Файл повреждён или записан не до конца"
        case AVError.decoderNotFound.rawValue, AVError.formatUnsupported.rawValue:
            return "macOS не умеет декодировать этот формат"
        case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
            return "Файл не найден — его переместили или удалили"
        case NSFileReadNoPermissionError:
            return "Нет доступа к файлу"
        default:
            return "Файл не воспроизводится (код \(code))"
        }
    }
}

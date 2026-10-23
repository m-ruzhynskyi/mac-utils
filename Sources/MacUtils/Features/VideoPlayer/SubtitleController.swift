import AVFoundation
import Foundation
import MUCore

/// Субтитры текущего файла: встроенные (tx3g, WebVTT в MP4) и внешние (SRT, ASS, VTT).
/// Встроенные читаются из файла заранее и рисуются тем же слоем, что внешние: один вид, размер, подложка и сдвиг
/// для всех. Системный рендер AVPlayer выключен.
@MainActor
final class SubtitleController: ObservableObject {
    struct Embedded: Identifiable, Equatable {
        let id: Int32
        let title: String
        let language: String?
        let codec: String
        let track: SubtitleTrack
    }

    struct External: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let language: String?
        var track: SubtitleTrack
        var encoding: TextEncoding
        /// Найден рядом с видео (а не добавлен руками).
        let nearby: Bool

        var title: String { url.lastPathComponent }
    }

    enum Selection: Equatable {
        case off
        case embedded(Int32)
        case external(UUID)
    }

    @Published private(set) var embedded: [Embedded] = []
    @Published private(set) var external: [External] = []
    @Published private(set) var selection: Selection = .off
    /// Сдвиг (Z / X): плюс — позже.
    @Published private(set) var delay: Double = 0
    @Published var lastError: String?

    private weak var model: PlayerModel?

    init(model: PlayerModel) { self.model = model }

    var activeTrack: SubtitleTrack? {
        switch selection {
        case .off: return nil
        case .embedded(let id): return embedded.first { $0.id == id }?.track
        case .external(let id): return external.first { $0.id == id }?.track
        }
    }

    var selectedExternal: External? {
        guard case .external(let id) = selection else { return nil }
        return external.first { $0.id == id }
    }

    /// Реплики на экране.
    func cues(at time: Double) -> [SubtitleCue] { activeTrack?.cues(at: time - delay) ?? [] }

    var delayTitle: String {
        let tenths = (delay * 10).rounded() / 10
        if tenths == 0 { return "Сдвиг субтитров 0 с" }
        let text = String(format: "%+.1f", tenths).replacingOccurrences(of: ".", with: ",").replacingOccurrences(of: "-", with: "−")
        return "Сдвиг субтитров \(text) с"
    }

    func reset() {
        pending.values.forEach { $0.cancel() }
        pending = [:]
        embedded = []
        external = []
        selection = .off
        delay = 0
        lastError = nil
    }

    // MARK: - Загрузка

    /// Встроенные дорожки и файлы рядом; выбор по умолчанию — язык, выбранный в прошлый раз, или язык системы.
    func load(asset: AVURLAsset, url: URL) async {
        let tracks = (try? await asset.loadTracks(withMediaType: .subtitle)) ?? []
        var found: [Embedded] = []
        for track in tracks {
            guard let embedded = await Self.read(track, asset: asset) else { continue }
            found.append(embedded)
        }
        var nearby: [External] = []
        if PlayerPrefs.subtitlesNearby {
            let folder = url.deletingLastPathComponent()
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for candidate in SubtitleFinder.candidates(for: url, names: names).prefix(8) {
                guard !Task.isCancelled else { return }
                guard let loaded = try? await Self.parseFile(candidate.url) else { continue }
                nearby.append(External(url: candidate.url, language: candidate.language, track: loaded.track,
                                       encoding: loaded.encoding, nearby: true))
            }
        }
        guard model?.currentURL == url else { return }
        embedded = found
        external = nearby + external.filter { !$0.nearby }
        if selection == .off || activeTrack == nil { selection = defaultSelection() }
    }

    /// Выключены, если в прошлый раз выключили; иначе — дорожка или файл на запомненном языке или языке системы;
    /// файл `имя.srt` без языка рядом с видео — тоже.
    func defaultSelection(preferred: [String] = Locale.preferredLanguages) -> Selection {
        let remembered = PlayerPrefs.subtitleLanguage
        if remembered == "off" { return .off }
        let languages = ([remembered].compactMap { $0 } + preferred.map { SubtitleFinder.languageCode($0) })
        for language in languages {
            if let match = embedded.first(where: { $0.language.map(SubtitleFinder.languageCode) == language }) { return .embedded(match.id) }
            if let match = external.first(where: { $0.language.map(SubtitleFinder.languageCode) == language }) { return .external(match.id) }
        }
        if let plain = external.first(where: { $0.nearby && $0.language == nil }) { return .external(plain.id) }
        return .off
    }

    /// Разбор файла вне главного потока. Отмена задачи (смена файла, закрытие окна) прерывает разбор.
    nonisolated static func parseFile(_ url: URL, encoding: TextEncoding? = nil) async throws
        -> (track: SubtitleTrack, encoding: TextEncoding) {
        let loaded = try SubtitleParser.load(url, encoding: encoding)
        try Task.checkCancellation()
        return loaded
    }

    /// Текст дорожки tx3g / WebVTT целиком (дорожка субтитров — килобайты). Другие форматы не показываем.
    /// Читается вне главного потока; отмена задачи останавливает чтение.
    nonisolated static func read(_ track: AVAssetTrack, asset: AVAsset) async -> Embedded? {
        guard let format = try? await track.load(.formatDescriptions).first else { return nil }
        let subtype = format.mediaSubType.rawValue
        guard subtype == kCMTextFormatType_3GText || subtype == kCMSubtitleFormatType_WebVTT else { return nil }
        let tag = try? await track.load(.extendedLanguageTag)
        let code = try? await track.load(.languageCode)
        let language = (tag ?? nil) ?? (code ?? nil)
        let id = track.trackID
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        var cues: [SubtitleCue] = []
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let duration = CMSampleBufferGetDuration(sample).seconds
            guard start.isFinite, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            // Пустой образец (промежуток между репликами) — читать нечего.
            guard length > 0 else { continue }
            var data = Data(count: length)
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
            }
            let text = subtype == kCMTextFormatType_3GText ? tx3gText(data) : webVTTText(data)
            guard !text.isEmpty else { continue }
            var cue = SubtitleParser.markup(text)
            cue.start = start
            cue.end = duration.isFinite && duration > 0 ? start + duration : start + 3
            cues.append(cue)
        }
        let codec = subtype == kCMTextFormatType_3GText ? "mov_text" : "WebVTT"
        let track = SubtitleTrack(format: subtype == kCMTextFormatType_3GText ? .srt : .vtt, cues: cues)
        return Embedded(id: id, title: languageName(language) ?? "Дорожка \(id)", language: language, codec: codec, track: track)
    }

    /// tx3g: 2 байта длины (big-endian), затем текст UTF-8 или UTF-16 с BOM; стилевые атомы после текста не нужны.
    nonisolated static func tx3gText(_ data: Data) -> String {
        guard data.count >= 2 else { return "" }
        let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
        guard length > 0, data.count >= 2 + length else { return "" }
        let body = data[(data.startIndex + 2)..<(data.startIndex + 2 + length)]
        if body.starts(with: [0xFE, 0xFF]) { return String(data: body.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        return String(decoding: body, as: UTF8.self)
    }

    /// WebVTT в MP4 (ISO 14496-30): `vttc` → `payl` с текстом; пустые образцы — `vtte`.
    nonisolated static func webVTTText(_ data: Data) -> String {
        NeroChapters.boxes(in: data).filter { $0.type == "vttc" }.flatMap { NeroChapters.boxes(in: Data($0.payload)) }
            .filter { $0.type == "payl" }.map { String(decoding: $0.payload, as: UTF8.self) }.joined(separator: "\n")
    }

    /// Язык своим названием, как в списках дорожек плееров: «ru» → «Русский», «en» → «English».
    nonisolated static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        let short = SubtitleFinder.languageCode(code)
        guard let name = Locale(identifier: short).localizedString(forLanguageCode: short) else { return code }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: - Выбор

    func select(_ selection: Selection) {
        self.selection = selection
        lastError = nil
        let language: String?
        switch selection {
        case .off: language = "off"
        case .embedded(let id): language = embedded.first { $0.id == id }?.language.map(SubtitleFinder.languageCode)
        case .external(let id): language = external.first { $0.id == id }?.language.map(SubtitleFinder.languageCode)
        }
        if let language { UserDefaults.standard.set(language, forKey: Pref.playerSubtitleLanguage) }
    }

    /// «Добавить файл…» или перетаскивание `.srt` на окно — к текущему видео, сразу включается.
    /// Файл разбирается вне главного потока; сменили видео или закрыли окно — результат не нужен.
    @discardableResult
    func addExternal(_ url: URL) -> Task<Void, Never> {
        if let existing = external.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            select(.external(existing.id))
            return Task {}
        }
        let video = model?.currentURL
        return run { [weak self] in
            let result: Result<(track: SubtitleTrack, encoding: TextEncoding), Error>
            do { result = .success(try await Self.parseFile(url)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, self.model?.currentURL == video else { return }
            switch result {
            case .success(let loaded):
                let base = video?.deletingPathExtension().lastPathComponent.lowercased() ?? ""
                let stem = url.deletingPathExtension().lastPathComponent
                let language = stem.lowercased().hasPrefix(base + ".") && !base.isEmpty ? String(stem.dropFirst(base.count + 1)) : nil
                let item = External(url: url, language: language, track: loaded.track, encoding: loaded.encoding, nearby: false)
                self.external.append(item)
                self.select(.external(item.id))
            case .failure(let error):
                self.lastError = "«\(url.lastPathComponent)»: \(error.localizedDescription)"
            }
        }
    }

    /// Ручной выбор кодировки внешнего файла: те же байты перечитываются (вне главного потока).
    @discardableResult
    func reencode(_ encoding: TextEncoding) -> Task<Void, Never> {
        guard let current = selectedExternal else { return Task {} }
        return run { [weak self] in
            let result: Result<(track: SubtitleTrack, encoding: TextEncoding), Error>
            do { result = .success(try await Self.parseFile(current.url, encoding: encoding)) } catch { result = .failure(error) }
            guard let self, !Task.isCancelled, let index = self.external.firstIndex(where: { $0.id == current.id }) else { return }
            switch result {
            case .success(let loaded):
                self.external[index].track = loaded.track
                self.external[index].encoding = loaded.encoding
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Разборы, начатые по просьбе пользователя: отменяются при смене файла и закрытии окна, по завершении убираются.
    private var pending: [UUID: Task<Void, Never>] = [:]

    private func run(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            await body()
            self?.pending[id] = nil
        }
        pending[id] = task
        return task
    }

    func shiftDelay(_ step: Double) {
        delay = ((delay + step) * 10).rounded() / 10
    }

    func resetDelay() { delay = 0 }
}

import AVFoundation
import Foundation

/// «Пропустить интро / титры» и «Следующая серия» по главам файла (MVP, § 8.2–8.3).
/// Решает `SkipPlanner` на каждом тике времени; без файла и без отрезков ничего не делает.
@MainActor
final class SkipController: ObservableObject {
    /// Главы файла — зазоры на шкале и подписи при наведении.
    @Published private(set) var chapters: [ChapterClassifier.Chapter] = []
    @Published private(set) var segments: [SkipSegment] = []
    @Published private(set) var decision: SkipPlanner.Decision = .none
    /// Тост после авто-пропуска (v14c): отрезок и куда вернуться.
    @Published var skippedToast: SkipSegment?

    private var state = SkipPlanner.State()
    private var folder: String?
    private weak var model: PlayerModel?
    private var toastWork: DispatchWorkItem?

    init(model: PlayerModel) { self.model = model }

    /// Текущий отрезок, внутри которого играет видео.
    var currentSegment: SkipSegment? {
        guard let index = state.inside, index < segments.count else { return nil }
        return segments[index]
    }

    func reset() {
        chapters = []
        segments = []
        decision = .none
        state = SkipPlanner.State()
        folder = nil
        dismissToast()
    }

    /// Главы QuickTime (`chap`) или Nero (`chpl`) → отрезки.
    func load(asset: AVURLAsset, url: URL, duration: Double) async {
        let chapters = await Self.readChapters(asset: asset, url: url, duration: duration)
        guard model?.currentURL == url else { return }
        self.chapters = chapters
        folder = url.deletingLastPathComponent().standardizedFileURL.path
        segments = SkipSources.resolve(ChapterClassifier.segments(from: chapters, fileDuration: duration))
    }

    static func readChapters(asset: AVURLAsset, url: URL, duration: Double) async -> [ChapterClassifier.Chapter] {
        var groups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages + ["und"])) ?? []
        if groups.isEmpty, let locale = (try? await asset.load(.availableChapterLocales))?.first {
            groups = (try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])) ?? []
        }
        var chapters: [ChapterClassifier.Chapter] = []
        for group in groups {
            let item = AVMetadataItem.metadataItems(from: group.items, filteredByIdentifier: .commonIdentifierTitle).first
            let title = (try? await item?.load(.stringValue)) ?? ""
            let start = group.timeRange.start.seconds, length = group.timeRange.duration.seconds
            guard start.isFinite else { continue }
            chapters.append(.init(title: title, start: start, end: length.isFinite ? start + length : duration))
        }
        if chapters.isEmpty {
            let nero = await Task.detached(priority: .utility) { NeroChapters.read(url) }.value
            chapters = nero.enumerated().map { index, chapter in
                .init(title: chapter.title, start: chapter.start, end: index + 1 < nero.count ? nero[index + 1].start : duration)
            }
        }
        return chapters.filter { $0.end > $0.start && $0.start < duration }
    }

    // MARK: - Тик и события

    var context: SkipPlanner.Context {
        SkipPlanner.Context(duration: model?.duration ?? 0, hasNext: model?.playlist.hasNext ?? false,
                            autoSkip: PlayerPrefs.skipAutomatically, autoNext: PlayerPrefs.nextEpisode,
                            hidden: folder.map { PlayerPrefs.skipHiddenFolders.contains($0) } ?? false)
    }

    func tick(_ time: Double) {
        guard !segments.isEmpty else { return }
        let decision = SkipPlanner.decide(time: time, segments: segments, context: context, state: &state)
        switch decision {
        case .skipNow(let index):
            perform(index, automatic: true)
        case .playNext:
            self.decision = .none
            model?.next()
        default:
            if decision != self.decision { self.decision = decision }
        }
    }

    /// Перемотка (пользователем или пропуском): авто-пропуска после неё нет, отсчёт отменяется.
    func noteSeek() {
        state.seeked = true
        cancelCountdown()
    }

    /// Пауза отменяет отсчёт «Следующей серии».
    func notePause() { _ = cancelCountdown() }

    /// Esc или «Смотреть титры»: отсчёт стоп, остаётся кнопка «Следующая серия». `true` — было что отменять.
    @discardableResult
    func cancelCountdown() -> Bool {
        guard case .countdown(let index, _) = decision else { return false }
        state.countdownCancelled = true
        let segment = segments[index]
        decision = .button(segment: index, title: segment.title(nextEpisode: true), fresh: true)
        return true
    }

    // MARK: - Действия

    /// S / ↩ / кнопка: работают весь отрезок, даже когда кнопки не видно. Вне отрезка — ничего.
    func skipCurrent() {
        guard let model, model.phase == .ready, let index = SkipPlanner.segmentIndex(at: model.currentTime, in: segments),
              !context.hidden else { return }
        perform(index, automatic: false)
    }

    private func perform(_ index: Int, automatic: Bool) {
        guard let model, index < segments.count else { return }
        let segment = segments[index]
        decision = .none
        guard let target = SkipPlanner.target(for: segment, duration: model.duration, hasNext: model.playlist.hasNext) else {
            model.next()
            return
        }
        // Чуть раньше конца можно, позже — никогда: не съесть начало серии.
        model.seek(to: target, toleranceBefore: 0.5)
        if automatic { showToast(segment) }
    }

    /// «Вернуть ⌘Z»: на начало отрезка, повторного авто-пропуска в этом открытии нет.
    func undo() {
        guard let segment = skippedToast, let index = segments.firstIndex(of: segment) else { return }
        state.undone.insert(index)
        dismissToast()
        model?.seek(to: segment.range.lowerBound, exact: true)
    }

    /// «Дальше ↩» на карточке следующей серии.
    func playNext() {
        decision = .none
        model?.next()
    }

    /// «Не показывать в этой папке».
    func hideInFolder() {
        guard let folder else { return }
        PlayerPrefs.hideSkip(inFolder: folder)
        decision = .none
    }

    private func showToast(_ segment: SkipSegment) {
        skippedToast = segment
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.skippedToast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func dismissToast() {
        toastWork?.cancel()
        skippedToast = nil
    }
}

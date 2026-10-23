import AVFoundation
import XCTest
@testable import MacUtils
@testable import MUAudio
@testable import MUVideoPlayer

/// Этап 4 плеера: «Пропустить интро / титры» по главам и «Следующая серия» (§ 8.2–8.3, 8.8).
final class ChapterClassifierTests: XCTestCase {
    private let hour: Double = 2700   // серия 45 мин

    func testNormalization() {
        XCTAssertEqual(ChapterClassifier.words("Ed's Story"), ["eds", "story"], "апостроф удаляется")
        XCTAssertEqual(ChapterClassifier.words("OP1"), ["op"], "цифры — пробел")
        XCTAssertEqual(ChapterClassifier.words("Ещё: ЗАСТАВКА!"), ["еще", "заставка"], "ё → е, регистр")
        XCTAssertEqual(ChapterClassifier.words("Opening-Theme"), ["opening", "theme"])
        XCTAssertEqual(ChapterClassifier.tokens("Op. 27 No. 2"), ["op", "27", "no", "2"], "номера сохраняются")
        XCTAssertEqual(ChapterClassifier.tokens("OP1"), ["op", "1"])
    }

    func testDictionaryByTitle() {
        let table: [(String, ChapterClassifier.Kind?)] = [
            ("Intro", .intro), ("OP", .intro), ("OP2", .intro), ("Opening Credits", .intro), ("Opening Theme", .intro), ("OP 1", .intro), ("Opening", .intro),
            ("Заставка", .intro), ("Вступление", .intro), ("Опенинг", .intro), ("Начальные титры", .intro), ("オープニング", .intro),
            ("Recap", .recap), ("Previously on Harbor", .recap), ("Ранее в сериале", .recap), ("В предыдущих сериях", .recap),
            ("Пересказ", .recap),
            ("Ending", .credits), ("ED", .credits), ("End Credits", .credits), ("Outro", .credits), ("Титры", .credits),
            ("Финальные титры", .credits), ("Эндинг", .credits), ("エンディング", .credits),
            ("Preview", .preview), ("Next Episode", .preview), ("Анонс", .preview), ("Следующая серия", .preview), ("予告", .preview),
            // Ловушки.
            ("Ed's Story", nil), ("The Ending", nil), ("Prologue", nil), ("Пролог", nil), ("Концовка", nil),
            ("Opening Theme Full Version", nil), ("Chapter 1", nil), ("", nil), ("Introduction to physics", nil),
            // Тестер 2, дефект 2: op / ed / intro — только всё название или с номером.
            ("Intro to Swift", nil), ("Op. 27 No. 2", nil), ("Ed Sheeran", nil), ("Opening theme song", nil),
            ("Ending 2", .credits), ("ED 3", .credits), ("Intro.", .intro), ("— Intro —", .intro), ("Credits roll", nil),
        ]
        for (title, kind) in table {
            XCTAssertEqual(ChapterClassifier.kind(title: title), kind, title)
        }
    }

    func testPlaceAndLengthGuards() {
        XCTAssertEqual(ChapterClassifier.kind(title: "Intro", start: 65, length: 90, fileDuration: hour), .intro)
        XCTAssertNil(ChapterClassifier.kind(title: "Opening Night", start: 600, length: 2400, fileDuration: 7200), "40 мин — не заставка")
        XCTAssertNil(ChapterClassifier.kind(title: "Intro", start: 1000, length: 60, fileDuration: hour), "позже первой четверти")
        XCTAssertNil(ChapterClassifier.kind(title: "Intro", start: 700, length: 60, fileDuration: 7200), "позже 10 мин")
        XCTAssertNil(ChapterClassifier.kind(title: "Intro", start: 0, length: 301, fileDuration: hour), "длиннее 5 мин")
        XCTAssertNil(ChapterClassifier.kind(title: "The Ending", start: 1300, length: 300, fileDuration: hour), "в середине фильма")
        XCTAssertNil(ChapterClassifier.kind(title: "Ending", start: 1300, length: 300, fileDuration: hour), "титры не в последних 20 %")
        XCTAssertEqual(ChapterClassifier.kind(title: "Ending", start: 2580, length: 120, fileDuration: hour), .credits)
        XCTAssertNil(ChapterClassifier.kind(title: "Credits", start: 2000, length: 700, fileDuration: 2700), "длиннее 10 мин")
    }

    func testSegmentsMergeNeighboursAndPreviewTail() {
        let chapters: [ChapterClassifier.Chapter] = [
            .init(title: "Recap", start: 0, end: 40), .init(title: "Intro", start: 40, end: 70), .init(title: "Opening", start: 70, end: 100),
            .init(title: "Episode", start: 100, end: 2500), .init(title: "Ending", start: 2500, end: 2640), .init(title: "Preview", start: 2640, end: 2700),
        ]
        let segments = ChapterClassifier.segments(from: chapters, fileDuration: hour)
        XCTAssertEqual(segments.map(\.kind), [.recap, .intro, .credits])
        XCTAssertEqual(segments[1].range, 40...100, "Intro + Opening — один отрезок")
        XCTAssertEqual(segments[2].range, 2500...2700, "анонс после титров — их хвост")
        XCTAssertEqual(segments[1].label, "Intro")
        let lonePreview = ChapterClassifier.segments(from: [.init(title: "Preview", start: 2600, end: 2700)], fileDuration: hour)
        XCTAssertTrue(lonePreview.isEmpty, "анонс без титров перед ним не трогаем")
    }

    func testTrapsFileGivesNothing() {
        let traps: [ChapterClassifier.Chapter] = [
            .init(title: "Ed's Story", start: 0, end: 120), .init(title: "Prologue", start: 120, end: 300),
            .init(title: "Opening Night", start: 300, end: 2700), .init(title: "The Ending", start: 2700, end: 3600),
            .init(title: "Пролог", start: 3600, end: 3700), .init(title: "Концовка", start: 3700, end: 3800),
        ]
        XCTAssertTrue(ChapterClassifier.segments(from: traps, fileDuration: 3800).isEmpty)
    }

    func testSourcePriorityAndNone() {
        let chapter = SkipSegment(kind: .intro, range: 60...150, source: .chapter)
        let manual = SkipSegment(kind: .intro, range: 62...148, source: .manualFile)
        let folder = SkipSegment(kind: .intro, range: 61...149, source: .manualFolder)
        let audio = SkipSegment(kind: .credits, range: 2500...2700, source: .audio)
        XCTAssertEqual(SkipSources.resolve([chapter, folder, manual, audio]), [manual, audio], "ручная метка файла важнее")
        XCTAssertEqual(SkipSources.resolve([chapter, folder]), [folder], "метка папки важнее глав")
        XCTAssertEqual(SkipSources.resolve([chapter, audio], suppressed: [.intro]), [audio], "метка «нет» гасит остальные")
    }
}

final class SkipPlannerTests: XCTestCase {
    private let intro = SkipSegment(kind: .intro, range: 65...155, source: .chapter, label: "Opening")
    private let credits = SkipSegment(kind: .credits, range: 2580...2700, source: .chapter, label: "Ending")
    private var segments: [SkipSegment] { [intro, credits] }

    private func context(autoSkip: Bool = false, autoNext: Bool = true, hasNext: Bool = true, hidden: Bool = false) -> SkipPlanner.Context {
        .init(duration: 2700, hasNext: hasNext, autoSkip: autoSkip, autoNext: autoNext, hidden: hidden)
    }

    /// Воспроизведение идёт само от `from` до `to` тиками по 0,1 с; последнее решение.
    private func play(_ state: inout SkipPlanner.State, from: Double, to: Double, _ context: SkipPlanner.Context) -> [SkipPlanner.Decision] {
        var decisions: [SkipPlanner.Decision] = []
        var time = from
        while time <= to + 0.0001 {
            decisions.append(SkipPlanner.decide(time: time, segments: segments, context: context, state: &state))
            time += 0.1
        }
        return decisions
    }

    func testReachingSegmentShowsButtonForTenSeconds() {
        var state = SkipPlanner.State()
        let decisions = play(&state, from: 60, to: 66, context())
        XCTAssertEqual(decisions.last, .button(segment: 0, title: "Пропустить интро", fresh: true))
        _ = play(&state, from: 66.1, to: 76, context())
        XCTAssertEqual(SkipPlanner.decide(time: 76, segments: segments, context: context(), state: &state),
                       .button(segment: 0, title: "Пропустить интро", fresh: false), "через 10 с кнопка уходит (S и ↩ работают)")
        XCTAssertEqual(SkipPlanner.decide(time: 160, segments: segments, context: context(), state: &state), .none, "вне отрезка — ничего")
    }

    func testSeekIntoSegmentGivesButtonWithoutAutoSkip() {
        var state = SkipPlanner.State()
        _ = SkipPlanner.decide(time: 10, segments: segments, context: context(autoSkip: true), state: &state)
        state.seeked = true
        let decision = SkipPlanner.decide(time: 100, segments: segments, context: context(autoSkip: true), state: &state)
        XCTAssertEqual(decision, .button(segment: 0, title: "Пропустить интро", fresh: true), "перемотали внутрь — только кнопка")
    }

    func testAutoSkipOncePerOpening() {
        var state = SkipPlanner.State()
        let decisions = play(&state, from: 64.5, to: 65.2, context(autoSkip: true))
        XCTAssertEqual(decisions.filter { $0 == .skipNow(segment: 0) }.count, 1)
        // Вернулись в начало отрезка (перемоткой) и снова дошли сами — второго пропуска нет.
        state.seeked = true
        _ = SkipPlanner.decide(time: 30, segments: segments, context: context(autoSkip: true), state: &state)
        let again = play(&state, from: 64.5, to: 65.5, context(autoSkip: true))
        XCTAssertFalse(again.contains(.skipNow(segment: 0)), "один раз за открытие")
    }

    func testUndoPreventsSecondSkip() {
        var state = SkipPlanner.State()
        state.undone.insert(0)
        let decisions = play(&state, from: 64.5, to: 66, context(autoSkip: true))
        XCTAssertFalse(decisions.contains(.skipNow(segment: 0)))
        XCTAssertEqual(decisions.last, .button(segment: 0, title: "Пропустить интро", fresh: true))
    }

    func testCreditsAtEndWithNextCountDown() {
        var state = SkipPlanner.State()
        var decisions = play(&state, from: 2579, to: 2582, context())
        guard case .countdown(1, let remaining) = decisions.last else { return XCTFail("отсчёт: \(String(describing: decisions.last))") }
        XCTAssertEqual(remaining, 3, accuracy: 0.11)
        decisions = play(&state, from: 2582.1, to: 2586, context())
        XCTAssertTrue(decisions.contains(.playNext), "через 5 с — следующий файл")
    }

    func testCreditsWithoutNextOrInTheMiddle() {
        var state = SkipPlanner.State()
        XCTAssertEqual(play(&state, from: 2579, to: 2581, context(hasNext: false)).last,
                       .button(segment: 1, title: "Пропустить титры", fresh: true), "последняя серия — без отсчёта")
        let middle = SkipSegment(kind: .credits, range: 2200...2400, source: .chapter)
        var other = SkipPlanner.State()
        var last: SkipPlanner.Decision = .none
        for time in stride(from: 2199.0, through: 2201, by: 0.1) {
            last = SkipPlanner.decide(time: time, segments: [middle], context: context(), state: &other)
        }
        XCTAssertEqual(last, .button(segment: 0, title: "Пропустить титры", fresh: true), "титры не в конце — за ними может быть сцена")
    }

    func testAutoNextOffGivesNextEpisodeButton() {
        var state = SkipPlanner.State()
        XCTAssertEqual(play(&state, from: 2579, to: 2581, context(autoNext: false)).last,
                       .button(segment: 1, title: "Следующая серия", fresh: true))
    }

    func testPauseOrSeekCancelsCountdownButKeepsButton() {
        var state = SkipPlanner.State()
        _ = play(&state, from: 2579, to: 2581, context())
        state.countdownCancelled = true   // Esc, «Смотреть титры», пауза, перемотка
        XCTAssertEqual(SkipPlanner.decide(time: 2581.1, segments: segments, context: context(), state: &state),
                       .button(segment: 1, title: "Следующая серия", fresh: true))
        // Перемотка внутрь титров — отсчёта нет.
        var seeked = SkipPlanner.State()
        _ = SkipPlanner.decide(time: 100, segments: segments, context: context(), state: &seeked)
        seeked.seeked = true
        XCTAssertEqual(SkipPlanner.decide(time: 2600, segments: segments, context: context(), state: &seeked),
                       .button(segment: 1, title: "Следующая серия", fresh: true))
    }

    func testHiddenFolderShowsNothing() {
        var state = SkipPlanner.State()
        XCTAssertTrue(play(&state, from: 64, to: 70, context(autoSkip: true, hidden: true)).allSatisfy { $0 == .none })
    }

    func testTargets() {
        XCTAssertEqual(SkipPlanner.target(for: intro, duration: 2700, hasNext: true), 155)
        XCTAssertNil(SkipPlanner.target(for: credits, duration: 2700, hasNext: true), "конец файла — следующий файл")
        XCTAssertEqual(SkipPlanner.target(for: credits, duration: 2700, hasNext: false), 2700)
        XCTAssertEqual(intro.title(nextEpisode: false), "Пропустить интро")
        XCTAssertEqual(SkipSegment(kind: .recap, range: 0...30, source: .chapter).title(nextEpisode: false), "Пропустить пересказ")
        XCTAssertEqual(intro.sourceTitle, "интро · глава «Opening»")
    }
}

/// Главы из настоящих файлов: QuickTime (`chap`) и Nero (`chpl`, свой разбор).
final class ChapterReadingTests: XCTestCase {
    private var folder: URL?

    override func setUpWithError() throws { folder = try DemoVideo.makeFolder() }
    override func tearDown() { DemoVideo.cleanup(folder) }

    func testQuickTimeChapters() async throws {
        var options = DemoVideo.Options()
        options.duration = 10
        options.width = 160
        options.height = 90
        options.chapters = [.init(title: "Intro", start: 0), .init(title: "Story", start: 2), .init(title: "Ending", start: 8.5)]
        let url = try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: "qt.m4v")
        let chapters = await SkipController.readChapters(asset: AVURLAsset(url: url), url: url, duration: 10)
        XCTAssertEqual(chapters.map(\.title), ["Intro", "Story", "Ending"])
        XCTAssertEqual(chapters[2].start, 8.5, accuracy: 0.05)
        XCTAssertEqual(chapters[2].end, 10, accuracy: 0.05)
        let segments = ChapterClassifier.segments(from: chapters, fileDuration: 10)
        XCTAssertEqual(segments.map(\.kind), [.intro, .credits])
    }

    func testNeroChaptersParsedFromAtom() async throws {
        var options = DemoVideo.Options()
        options.duration = 10
        options.width = 160
        options.height = 90
        options.neroChapters = [.init(title: "Заставка", start: 0), .init(title: "Серия", start: 1.5), .init(title: "Титры", start: 8.2)]
        let url = try await DemoVideo.make(options, in: try XCTUnwrap(folder), name: "chpl.mp4")
        let raw = NeroChapters.read(url)
        XCTAssertEqual(raw.map(\.title), ["Заставка", "Серия", "Титры"])
        XCTAssertEqual(raw[2].start, 8.2, accuracy: 0.0001)
        let chapters = await SkipController.readChapters(asset: AVURLAsset(url: url), url: url, duration: 10)
        XCTAssertEqual(chapters.map(\.title), ["Заставка", "Серия", "Титры"], "AVFoundation chpl не читает — свой разбор")
        XCTAssertEqual(chapters[0].end, 1.5, accuracy: 0.0001)
    }

    func testBrokenAtomsDoNotCrash() {
        XCTAssertTrue(NeroChapters.parse(chpl: Data()).isEmpty)
        XCTAssertTrue(NeroChapters.parse(chpl: Data([1, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0])).isEmpty, "обещано 5 глав, данных нет")
        XCTAssertTrue(NeroChapters.boxes(in: Data([0, 0, 0, 3, 0x6D, 0x6F, 0x6F, 0x76])).isEmpty, "размер меньше заголовка")
        XCTAssertTrue(NeroChapters.boxes(in: Data([0, 0, 1, 0, 0x6D, 0x6F, 0x6F, 0x76])).isEmpty, "размер больше данных")
        var random = PlayerTestRandom(3)
        for _ in 0..<300 {
            let bytes = Data((0..<Int(random.next() % 200)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
            _ = NeroChapters.chapters(inMoov: bytes)
            _ = NeroChapters.parse(chpl: bytes)
        }
    }
}

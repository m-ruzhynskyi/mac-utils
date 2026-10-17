import AppKit
import Combine
import SwiftUI

/// Откуда начинается захват, куда уходит коллаж и как сообщается результат — подменяется в тестах сессии.
@MainActor
struct StepsEnvironment {
    var startCapture: () -> Bool = { ScreenshotService.shared.start(.edit) }
    var save: (CGImage, @escaping @MainActor (Result<URL, Error>) -> Void) -> Void = { ScreenshotService.shared.saveCollage($0, done: $1) }
    var copy: (CGImage, @escaping @MainActor (Bool) -> Void) -> Void = { ScreenshotService.shared.copyCollage($0, done: $1) }
    /// Выдача без вопросов (выход из приложения): туда же, куда обычные снимки.
    var deliverQuietly: (CGImage) -> Void = { ScreenshotService.shared.deliver($0) }
    var toast: (String, String, Color) -> Void = { Toast.show($0, symbol: $1, tint: $2) }
    /// Идёт запись экрана или длинный снимок: панель и предпросмотр ждут, пока они закончатся.
    var captureBusy: () -> Bool = { ScreenRecorder.current != nil || ScrollCapture.current != nil }
    /// Тесты сессии окон не открывают.
    var showsWindows = true
}

/// «Коллаж шагов»: несколько снимков подряд складываются в одну картинку с номерами 1, 2, 3.
///
/// Снизу экрана — панель шагов с миниатюрами: шаг можно удалить, переснять, перетащить на другое место.
/// «Ещё шаг» (или ⌘⇧X) открывает захват с уже выделенной областью прошлого шага — Enter снимает её снова.
/// «Готово» открывает предпросмотр коллажа: раскладка, рамка, номера, подписи; там же «Сохранить» и «Скопировать».
/// Панель и предпросмотр в снимок не попадают: на время захвата прячутся и исключаются из него.
@MainActor
final class StepsSession: ObservableObject {
    private(set) static var current: StepsSession?
    static var environment = StepsEnvironment()

    @Published private(set) var model = StepsModel()
    /// Панель спрашивает «Удалить все шаги?» (отмена при двух шагах и больше).
    @Published private(set) var confirmingCancel = false
    /// Когда шаги последний раз менялись (забытая сессия не должна вечно считаться «занятостью»).
    private(set) var lastActivity = Date()

    private var hudPanel: NSPanel?
    private var preview: StepsPreviewWindowController?
    private var resize: AnyCancellable?
    /// Пока идёт запись экрана или длинный снимок, панель и предпросмотр не показываются; таймер ждёт конца.
    private var resumeTimer: Timer?

    private var env: StepsEnvironment { Self.environment }

    // MARK: - Шаги

    /// Добавляет снятый шаг (или заменяет переснимаемый); первая же картинка начинает сессию.
    /// `rect` — выделенная область в глобальных точках: её предложит следующий «Ещё шаг».
    static func add(_ image: CGImage, unit: CGFloat, rect: CGRect?) {
        let session = current ?? StepsSession()
        current = session
        let wasRetake = session.model.retakeNumber
        let memoryBefore = session.model.memoryBytes
        guard let number = session.model.add(image, unit: unit, rect: rect) else {
            session.env.toast("В коллаже уже \(StepsModel.maxSteps) шагов — больше не поместится",
                              "exclamationmark.triangle.fill", .orange)
            return
        }
        session.touch()
        Log.capture.info("Коллаж: шаг \(number)\(wasRetake != nil ? " переснят" : "")")
        // Шаги держатся в памяти полноразмерными: на больших экранах это быстро гигабайт.
        let memory = session.model.memoryBytes
        if memoryBefore < StepsModel.memoryWarningBytes, memory >= StepsModel.memoryWarningBytes {
            let size = ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory)
            session.env.toast("Шаги коллажа занимают \(size) памяти — лучше сохранить коллаж и начать новый",
                              "memorychip", .orange)
        }
    }

    /// Номер следующего шага и что сделает Enter — для подсказки в режиме снимка; nil — коллажа нет.
    static var captureHint: String? {
        guard let session = current else { return nil }
        if let number = session.model.retakeNumber { return "Пересъёмка шага \(number) · Enter — заменить" }
        return "Шаг \(session.model.count + 1) коллажа · Enter — добавить"
    }

    /// Область для следующего снимка (глобальные точки): прошлого шага или переснимаемого.
    static var proposedRect: CGRect? { current?.model.proposedRect }

    /// Последний шаг тоже можно удалить: панель остаётся — «Вернуть удалённый» или «Ещё шаг».
    func remove(_ id: UUID) {
        model.remove(id)
        touch()
    }

    func undoRemove() {
        if model.undoRemove() { touch() }
    }

    func move(_ id: UUID, to index: Int) {
        model.move(id, to: index)
        touch()
    }

    func setCaption(_ text: String, for id: UUID) {
        model.setCaption(text, for: id)
        touch()
    }

    func retake(_ id: UUID) {
        model.beginRetake(id)
        nextStep()
    }

    private func touch() {
        lastActivity = Date()
    }

    // MARK: - Захват

    /// Перед снимком: панель и предпросмотр прячутся. Возвращает номера их окон — их исключает и сам захват
    /// (окно, ещё не успевшее исчезнуть с экрана, не попадёт в кадр).
    static func prepareForCapture() -> [CGWindowID] {
        guard let session = current else { return [] }
        var ids: [CGWindowID] = []
        for window in [session.hudPanel, session.preview?.window] {
            guard let window, window.windowNumber > 0 else { continue }
            ids.append(CGWindowID(window.windowNumber))
            window.orderOut(nil)
        }
        return ids
    }

    /// Захват закрыт (снят шаг, Esc, ошибка): пересъёмка без снимка отменяется, панель или предпросмотр
    /// возвращаются. `resume == false` — захват уступил место записи экрана или длинному снимку: вернутся,
    /// когда те закончатся. Возвращает true, если показан предпросмотр (ему и остаётся фокус).
    @discardableResult
    static func captureClosed(resume: Bool = true) -> Bool {
        guard let session = current else { return false }
        session.model.cancelRetake()
        guard resume else {
            session.resumeWhenCaptureEnds()
            return false
        }
        return session.reappear()
    }

    /// Панель или предпросмотр — что было открыто. true — предпросмотр.
    @discardableResult
    private func reappear() -> Bool {
        if let preview {
            // Снимок по ⌘⇧X прямо из предпросмотра: окно возвращается с новым шагом.
            if env.showsWindows { preview.show() }
            return true
        }
        showHUD()
        return false
    }

    private func resumeWhenCaptureEnds() {
        resumeTimer?.invalidate()
        let since = Date()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                // Запись и длинный снимок стартуют с задержкой: первую секунду просто ждём.
                guard Date().timeIntervalSince(since) >= 1, !self.env.captureBusy() else { return }
                timer.invalidate()
                self.resumeTimer = nil
                self.reappear()
            }
        }
    }

    func nextStep() {
        confirmingCancel = false
        guard env.startCapture() else {
            // Захват не начался (идёт запись, нет разрешения): пересъёмка не висит до следующего снимка.
            model.cancelRetake()
            showHUD()
            return
        }
    }

    // MARK: - Панель

    private func showHUD() {
        guard env.showsWindows else { return }
        if hudPanel == nil { makeHUD() }
        placeHUD()
        hudPanel?.orderFrontRegardless()
    }

    private func makeHUD() {
        let host = FirstMouseHostingView(rootView: StepsHUD(session: self))
        host.sizingOptions = [.intrinsicContentSize]
        let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Своё окно в снимок экрана не попадает и при обычном захвате системой.
        panel.sharingType = .none
        panel.contentView = host
        hudPanel = panel
        // Панель меняет размер вместе с числом шагов: держим её по центру внизу экрана.
        resize = objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.placeHUD() }
        }
    }

    private func placeHUD() {
        guard let panel = hudPanel, let host = panel.contentView else { return }
        let size = host.fittingSize
        let screen = panel.screen ?? NSScreen.withMouse ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: visible.minY + 24)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    // MARK: - Готово и отмена

    /// «Готово»: предпросмотр коллажа (панель на это время прячется).
    func showPreview() {
        guard !model.isEmpty else { return }
        confirmingCancel = false
        hudPanel?.orderOut(nil)
        guard env.showsWindows else { return }
        let controller = preview ?? StepsPreviewWindowController(session: self)
        preview = controller
        controller.show()
    }

    /// «Назад к шагам» или закрытие окна предпросмотра: шаги остаются.
    func closePreview(showHUD: Bool = true) {
        guard let controller = preview else { return }
        preview = nil
        controller.dismiss()
        if showHUD { self.showHUD() }
    }

    /// Сохранить или скопировать собранный коллаж. Шаги закрываются только когда картинка точно на месте:
    /// если сохранить не вышло, она кладётся в буфер обмена, а шаги, подписи и предпросмотр остаются.
    /// `done(true)` — коллаж выдан и сессия закрыта.
    func deliver(_ image: CGImage, action: StepsPreviewModel.Delivery, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let env = self.env
        let count = model.count
        switch action {
        case .save:
            env.save(image) { [weak self] result in
                switch result {
                case .success(let url):
                    Log.capture.info("Коллаж сохранён: \(count) шагов, \(image.width)×\(image.height)")
                    self?.end()
                    env.toast("Коллаж сохранён: \(url.lastPathComponent)", "square.and.arrow.down.fill", .green)
                    done(true)
                case .failure(let error):
                    Log.capture.error("Коллаж не сохранён: \(error.localizedDescription, privacy: .public)")
                    // Запасной путь: картинка — в буфер обмена, чтобы её можно было вставить куда угодно.
                    env.copy(image) { copied in
                        env.toast(copied
                            ? "Не удалось сохранить коллаж (\(error.localizedDescription)). Он скопирован в буфер обмена, шаги на месте"
                            : "Не удалось сохранить коллаж: \(error.localizedDescription). Шаги на месте — попробуйте ещё раз",
                            "exclamationmark.triangle.fill", .orange)
                        done(false)
                    }
                }
            }
        case .copy:
            env.copy(image) { [weak self] copied in
                if copied {
                    Log.capture.info("Коллаж скопирован: \(count) шагов, \(image.width)×\(image.height)")
                    self?.end()
                    env.toast("Коллаж скопирован", "doc.on.clipboard.fill", .accentColor)
                } else {
                    env.toast("Не удалось скопировать коллаж. Шаги на месте — попробуйте ещё раз",
                              "exclamationmark.triangle.fill", .orange)
                }
                done(copied)
            }
        }
    }

    /// Собрать и выдать без вопросов, с сохранёнными настройками (выход из приложения, выключение Mac).
    /// Если на полный размер не хватило памяти — собирается поменьше; не вышло и так — тост, а не тишина.
    func finish() {
        let steps = model.steps
        end()
        guard !steps.isEmpty else { return }
        let images = steps.map { ($0.image, $0.unit) }
        var options = StepsPreviewModel.savedOptions(captions: steps.map(\.caption))
        var collage = ShotComposer.compose(steps: images, options: options)
        if collage == nil {
            options.maxSide = 8000
            options.maxPixels = 24_000_000
            collage = ShotComposer.compose(steps: images, options: options)
        }
        guard let collage else {
            Log.capture.error("Коллаж из \(steps.count) шагов не собрался при выходе")
            env.toast("Не удалось собрать коллаж из \(steps.count) \(plural(steps.count, "шага", "шагов", "шагов")): не хватило памяти",
                      "exclamationmark.triangle.fill", .orange)
            return
        }
        Log.capture.info("Коллаж: \(steps.count) шагов, \(collage.width)×\(collage.height)")
        env.deliverQuietly(collage)
    }

    /// «Отмена»: при двух шагах и больше — сначала вопрос в самой панели (окна-вопросы мешали бы работе).
    func cancel() {
        if model.count >= 2 && !confirmingCancel {
            confirmingCancel = true
            return
        }
        discard()
    }

    func keepSteps() {
        confirmingCancel = false
    }

    func discard() {
        end()
        env.toast("Коллаж отменён", "xmark.circle.fill", .secondary)
    }

    private func end() {
        resize = nil
        resumeTimer?.invalidate()
        resumeTimer = nil
        hudPanel?.orderOut(nil)
        hudPanel = nil
        preview?.dismiss()
        preview = nil
        if Self.current === self { Self.current = nil }
    }
}

private struct StepsHUD: View {
    @ObservedObject var session: StepsSession

    var body: some View {
        StepsPanelContent(
            items: session.model.steps.map { StepsPanelItem(id: $0.id, thumbnail: $0.thumbnail) },
            confirmingCancel: session.confirmingCancel,
            canUndo: session.model.canUndo,
            isFull: session.model.isFull,
            actions: StepsPanelActions(
                cancel: { session.cancel() },
                keep: { session.keepSteps() },
                discard: { session.discard() },
                next: { session.nextStep() },
                finish: { session.showPreview() },
                remove: { session.remove($0) },
                retake: { session.retake($0) },
                move: { session.move($0, to: $1) },
                undo: { session.undoRemove() }))
    }
}

// MARK: - Панель шагов (представление)

struct StepsPanelItem: Identifiable {
    let id: UUID
    let thumbnail: CGImage
}

struct StepsPanelActions {
    var cancel: () -> Void = {}
    var keep: () -> Void = {}
    var discard: () -> Void = {}
    var next: () -> Void = {}
    var finish: () -> Void = {}
    var remove: (UUID) -> Void = { _ in }
    var retake: (UUID) -> Void = { _ in }
    var move: (UUID, Int) -> Void = { _, _ in }
    var undo: () -> Void = {}
}

/// Панель коллажа шагов: заголовок, счётчик, «Отмена / Ещё шаг / Готово» и полоса миниатюр.
/// Значения готовые, без модели (её же снимают UI-тесты на демо-данных).
struct StepsPanelContent: View {
    let items: [StepsPanelItem]
    var confirmingCancel = false
    var canUndo = false
    var isFull = false
    var actions = StepsPanelActions()

    static let thumbSize = CGSize(width: 112, height: 72)
    static let thumbSpacing: CGFloat = DS.Space.s
    /// Шире полоса прокручивается.
    static let stripMaxWidth: CGFloat = 640

    @State private var dragging: UUID?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            if !items.isEmpty || !isFull { strip }
        }
        .floating(.panel)
        .padding(4)
        .fixedSize()
    }

    private var countText: String {
        "\(items.count) \(plural(items.count, "шаг", "шага", "шагов"))"
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.dsText)
                .frame(width: DS.Size.rowTile, height: DS.Size.rowTile)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            if confirmingCancel {
                Text("Удалить все шаги (\(items.count))?")
                    .font(DS.Font.manrope(13, .heavy, relativeTo: .callout)).foregroundStyle(.dsText)
                Spacer(minLength: DS.Space.l)
                Button("Оставить", action: actions.keep).buttonStyle(.graphite(.secondary, size: .compact))
                Button("Удалить", action: actions.discard).buttonStyle(.graphite(.danger, size: .compact))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Коллаж шагов").font(DS.Font.manrope(13, .heavy, relativeTo: .callout)).foregroundStyle(.dsText)
                    HStack(spacing: 6) {
                        Text(countText).font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute)
                        if canUndo {
                            Button("Вернуть удалённый", action: actions.undo)
                                .buttonStyle(.plain)
                                .font(DS.Font.caption)
                                .foregroundStyle(.dsAccText)
                        }
                    }
                }
                Spacer(minLength: DS.Space.l)
                Button("Отмена", action: actions.cancel).buttonStyle(.graphite(.ghost, size: .compact))
                Button("Ещё шаг", action: actions.next).buttonStyle(.graphite(.secondary, size: .compact))
                    .disabled(isFull)
                    .help("⌘⇧X — та же область уже выделена, Enter снимает её. Потяните мышью, чтобы выбрать другую.")
                Button("Готово", action: actions.finish).buttonStyle(.graphite(.primary, size: .compact))
                    .disabled(items.isEmpty)
                    .help("Предпросмотр коллажа: раскладка, подписи, сохранение")
            }
        }
    }

    private var strip: some View {
        let pitch = Self.thumbSize.width + Self.thumbSpacing
        let count = items.count + (isFull ? 0 : 1)
        let width = min(Self.stripMaxWidth, CGFloat(count) * pitch - Self.thumbSpacing)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.thumbSpacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    StepThumb(item: item, number: index + 1,
                              retake: { actions.retake(item.id) }, remove: { actions.remove(item.id) },
                              moveLeft: index > 0 ? { actions.move(item.id, index - 1) } : nil,
                              moveRight: index < items.count - 1 ? { actions.move(item.id, index + 1) } : nil)
                        .offset(x: dragging == item.id ? dragOffset : 0)
                        .zIndex(dragging == item.id ? 1 : 0)
                        .gesture(DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                dragging = item.id
                                dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                let target = StepsModel.reorderIndex(from: index, translation: value.translation.width,
                                                                     pitch: pitch, count: items.count)
                                dragging = nil
                                dragOffset = 0
                                if target != index { actions.move(item.id, target) }
                            })
                }
                if !isFull {
                    Button(action: actions.next) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.dsMute)
                            .frame(width: Self.thumbSize.width, height: Self.thumbSize.height)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.dsLine, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .help("Ещё шаг")
                    .accessibilityLabel("Ещё шаг")
                }
            }
            .padding(.vertical, 2)
        }
        .frame(width: max(width, Self.thumbSize.width), height: Self.thumbSize.height + 4)
    }
}

/// Миниатюра шага: номер, при наведении — «Переснять» и «Удалить»; меню по правому щелчку — то же и перенос.
private struct StepThumb: View {
    let item: StepsPanelItem
    let number: Int
    let retake: () -> Void
    let remove: () -> Void
    let moveLeft: (() -> Void)?
    let moveRight: (() -> Void)?

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack(alignment: .topLeading) {
            Image(decorative: item.thumbnail, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: StepsPanelContent.thumbSize.width, height: StepsPanelContent.thumbSize.height)
                .background(Color.dsField)
                .clipShape(shape)
                .overlay(shape.strokeBorder(hovered ? Color.dsAccLine : Color.dsLine, lineWidth: hovered ? 2 : 1))
            Text("\(number)")
                .font(DS.Font.mono(11, relativeTo: .caption2))
                .foregroundStyle(.dsAccInk)
                .frame(minWidth: 20, minHeight: 20)
                .background(Color.dsAcc, in: Circle())
                .padding(5)
            if hovered {
                HStack(spacing: 4) {
                    thumbButton("arrow.counterclockwise", title: "Переснять", action: retake)
                    thumbButton("xmark", title: "Удалить", action: remove)
                }
                .padding(5)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
        .frame(width: StepsPanelContent.thumbSize.width, height: StepsPanelContent.thumbSize.height)
        .contentShape(shape)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Переснять", action: retake)
            if let moveLeft { Button("Переместить влево", action: moveLeft) }
            if let moveRight { Button("Переместить вправо", action: moveRight) }
            Divider()
            Button("Удалить", action: remove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Шаг \(number)")
    }

    private func thumbButton(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.dsText)
                .frame(width: 20, height: 20)
                .background(Color.dsPanel.opacity(0.92), in: Circle())
                .overlay(Circle().strokeBorder(Color.dsLine, lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Раскладка

enum StepsLayout: String, CaseIterable, Identifiable {
    case auto, vertical, horizontal, grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто (ближе к квадрату)"
        case .vertical: return "Столбиком"
        case .horizontal: return "В ряд"
        case .grid: return "Сеткой (квадратом)"
        }
    }

    /// Короткое название для переключателя в предпросмотре.
    var shortTitle: String {
        switch self {
        case .auto: return "Авто"
        case .vertical: return "Столбик"
        case .horizontal: return "Ряд"
        case .grid: return "Сетка"
        }
    }
}

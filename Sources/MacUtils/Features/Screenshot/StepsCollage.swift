import AppKit
import Combine
import SwiftUI

/// «Коллаж шагов»: несколько снимков подряд складываются в одну картинку с номерами 1, 2, 3.
///
/// Снизу экрана — панель шагов с миниатюрами: шаг можно удалить, переснять, перетащить на другое место.
/// «Ещё шаг» (или ⌘⇧X) открывает захват с уже выделенной областью прошлого шага — Enter снимает её снова.
/// «Готово» открывает предпросмотр коллажа: раскладка, рамка, номера, подписи; там же «Сохранить» и «Скопировать».
/// Панель и предпросмотр в снимок не попадают: на время захвата прячутся и исключаются из него.
@MainActor
final class StepsSession: ObservableObject {
    private(set) static var current: StepsSession?

    @Published private(set) var model = StepsModel()
    /// Панель спрашивает «Удалить все шаги?» (отмена при двух шагах и больше).
    @Published private(set) var confirmingCancel = false
    /// Когда шаги последний раз менялись (забытая сессия не должна вечно считаться «занятостью»).
    private(set) var lastActivity = Date()

    private var hudPanel: NSPanel?
    private var preview: StepsPreviewWindowController?
    private var resize: AnyCancellable?

    // MARK: - Шаги

    /// Добавляет снятый шаг (или заменяет переснимаемый); первая же картинка начинает сессию.
    /// `rect` — выделенная область в глобальных точках: её предложит следующий «Ещё шаг».
    static func add(_ image: CGImage, unit: CGFloat, rect: CGRect?) {
        let session = current ?? StepsSession()
        current = session
        let wasRetake = session.model.retakeNumber
        guard let number = session.model.add(image, unit: unit, rect: rect) else {
            Toast.show("В коллаже уже \(StepsModel.maxSteps) шагов — больше не поместится",
                       symbol: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        session.touch()
        Log.capture.info("Коллаж: шаг \(number)\(wasRetake != nil ? " переснят" : "")")
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

    /// Захват закрыт (снят шаг, Esc, ошибка): пересъёмка без снимка отменяется, панель возвращается.
    static func captureClosed() {
        guard let session = current else { return }
        session.model.cancelRetake()
        if let preview = session.preview {
            // Снимок по ⌘⇧X прямо из предпросмотра: окно возвращается с новым шагом.
            preview.show()
        } else {
            session.showHUD()
        }
    }

    func nextStep() {
        confirmingCancel = false
        // Из предпросмотра «Ещё шаг» (⌘⇧X) — сначала обратно к шагам.
        let fromPreview = preview != nil
        closePreview(showHUD: false)
        guard ScreenshotService.shared.start(.edit) else {
            // Захват не начался: пересъёмка не висит до следующего снимка, панель — на месте.
            model.cancelRetake()
            if fromPreview { showPreview() } else { showHUD() }
            return
        }
    }

    // MARK: - Панель

    private func showHUD() {
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

    /// Сохранить или скопировать готовый коллаж из предпросмотра.
    func deliver(_ image: CGImage, action: StepsPreviewModel.Delivery) {
        Log.capture.info("Коллаж: \(self.model.count) шагов, \(image.width)×\(image.height)")
        end()
        switch action {
        case .save: ScreenshotService.shared.save(image)
        case .copy: ScreenshotService.shared.copy(image)
        }
    }

    /// Собрать и выдать без вопросов, с сохранёнными настройками (выход из приложения, выключение Mac).
    func finish() {
        let steps = model.steps
        end()
        guard !steps.isEmpty, let collage = ShotComposer.compose(steps: steps.map { ($0.image, $0.unit) },
                                                                 options: StepsPreviewModel.savedOptions(captions: steps.map(\.caption)))
        else { return }
        Log.capture.info("Коллаж: \(steps.count) шагов, \(collage.width)×\(collage.height)")
        ScreenshotService.shared.deliver(collage)
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
        Toast.show("Коллаж отменён", symbol: "xmark.circle.fill", tint: .secondary)
    }

    private func end() {
        resize = nil
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
            canUndo: session.model.lastRemoved != nil,
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

import AppKit
import SwiftUI

/// Предпросмотр коллажа шагов: раскладка, оформление, подписи и порядок — до сохранения.
/// Настройки оформления запоминаются (те же, что в разделе «Снимки»), подписи — только для этого коллажа.
@MainActor
final class StepsPreviewModel: ObservableObject {
    enum Delivery { case save, copy }

    @Published var layout: StepsLayout { didSet { changed(Pref.screenshotStepsLayout, layout.rawValue) } }
    @Published var equalSize: Bool { didSet { changed(Pref.screenshotStepsEqualSize, equalSize) } }
    @Published var windowFrame: Bool { didSet { changed(Pref.screenshotStepsFrame, windowFrame) } }
    @Published var titles: Bool { didSet { changed(Pref.screenshotStepsTitles, titles) } }
    @Published var badges: Bool { didSet { changed(Pref.screenshotStepsBadges, badges) } }
    @Published var arrows: Bool { didSet { changed(Pref.screenshotStepsArrows, arrows) } }

    @Published private(set) var steps: [StepShot] = []
    /// Уменьшенная копия коллажа для окна (полный размер собирается только при сохранении).
    @Published private(set) var image: NSImage?
    /// Размер итоговой картинки и уменьшена ли она под предел.
    @Published private(set) var outputSize: CGSize = .zero
    @Published private(set) var downscaled = false
    /// Коллаж собирается и сохраняется (или копируется): кнопки заняты, на «Сохранить» — индикатор.
    @Published private(set) var delivering: Delivery?

    /// Сторона уменьшенной копии для окна: быстро собирается и чётко выглядит на Retina.
    static let previewSide: CGFloat = 2400

    private let defaults: UserDefaults
    private let source: () -> [StepShot]
    private let onCaption: (String, UUID) -> Void
    private let onMove: (UUID, Int) -> Void
    let back: () -> Void
    private let onDeliver: @MainActor (CGImage, Delivery, @escaping @MainActor (Bool) -> Void) -> Void
    private var renderTask: Task<Void, Never>?
    /// Номер последней заказанной сборки: результат устаревшей (переключатель уже сдвинули) отбрасывается.
    private var renderGeneration = 0

    init(defaults: UserDefaults = .standard, steps: @escaping () -> [StepShot],
         setCaption: @escaping (String, UUID) -> Void = { _, _ in }, move: @escaping (UUID, Int) -> Void = { _, _ in },
         back: @escaping () -> Void = {},
         deliver: @escaping @MainActor (CGImage, Delivery, @escaping @MainActor (Bool) -> Void) -> Void = { _, _, done in done(true) }) {
        self.defaults = defaults
        source = steps
        onCaption = setCaption
        onMove = move
        self.back = back
        onDeliver = deliver
        layout = StepsLayout(rawValue: defaults.string(forKey: Pref.screenshotStepsLayout) ?? "") ?? .auto
        equalSize = defaults.bool(forKey: Pref.screenshotStepsEqualSize)
        windowFrame = defaults.bool(forKey: Pref.screenshotStepsFrame)
        titles = defaults.bool(forKey: Pref.screenshotStepsTitles)
        badges = defaults.bool(forKey: Pref.screenshotStepsBadges)
        arrows = defaults.bool(forKey: Pref.screenshotStepsArrows)
        reload()
    }

    /// Оформление по сохранённым настройкам (выдача без предпросмотра — при выходе из приложения).
    static func savedOptions(captions: [String], defaults: UserDefaults = .standard) -> ShotComposer.Options {
        var options = ShotComposer.Options()
        options.layout = StepsLayout(rawValue: defaults.string(forKey: Pref.screenshotStepsLayout) ?? "") ?? .auto
        options.equalSize = defaults.bool(forKey: Pref.screenshotStepsEqualSize)
        options.windowFrame = defaults.bool(forKey: Pref.screenshotStepsFrame)
        options.titles = defaults.bool(forKey: Pref.screenshotStepsTitles)
        options.badges = defaults.bool(forKey: Pref.screenshotStepsBadges)
        options.arrows = defaults.bool(forKey: Pref.screenshotStepsArrows)
        options.captions = captions
        options.background = ShotBackground(rawValue: defaults.string(forKey: Pref.screenshotBackground) ?? "") ?? .sky
        options.dark = ShotComposer.systemIsDark
        return options
    }

    var options: ShotComposer.Options {
        var options = Self.savedOptions(captions: steps.map(\.caption), defaults: defaults)
        options.layout = layout
        options.equalSize = equalSize
        options.windowFrame = windowFrame
        options.titles = titles
        options.badges = badges
        options.arrows = arrows
        return options
    }

    func reload() {
        steps = source()
        scheduleRender(immediately: true)
    }

    func caption(for id: UUID) -> String {
        steps.first { $0.id == id }?.caption ?? ""
    }

    func setCaption(_ text: String, for id: UUID) {
        onCaption(text, id)
        steps = source()
        scheduleRender(immediately: false)
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        onMove(id, index + offset)
        reload()
    }

    /// Полноразмерный коллаж (с пределом размера итога), собирается вне главного потока.
    func export() async -> CGImage? {
        await Self.compose(steps, options: options)
    }

    /// Сборка в фоне: окно не замирает и на двадцати больших шагах.
    nonisolated private static func compose(_ steps: [StepShot], options: ShotComposer.Options) async -> CGImage? {
        let input = UncheckedSendable(steps.map { ($0.image, $0.unit) })
        let output = await Task.detached(priority: .userInitiated) {
            UncheckedSendable(ShotComposer.compose(steps: input.value, options: options))
        }.value
        return output.value
    }

    func deliver(_ action: Delivery) {
        guard delivering == nil, !steps.isEmpty else { return }
        delivering = action
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let image = await self.export() else {
                self.delivering = nil
                Toast.show("Не удалось собрать коллаж: не хватило памяти. Шаги на месте",
                           symbol: "exclamationmark.triangle.fill", tint: .orange)
                return
            }
            // Сессия закроет окно сама, если всё получилось; иначе окно и шаги остаются.
            self.onDeliver(image, action) { [weak self] _ in self?.delivering = nil }
        }
    }

    private func changed(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
        scheduleRender(immediately: true)
    }

    /// Пересборка уменьшенной копии: переключатели и порядок — сразу, набор подписи — после короткой паузы,
    /// чтобы не собирать коллаж на каждую букву.
    func scheduleRender(immediately: Bool) {
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 150_000_000) }
            guard !Task.isCancelled else { return }
            await self?.render()
        }
    }

    private func render() async {
        renderGeneration += 1
        let generation = renderGeneration
        guard !steps.isEmpty else {
            image = nil
            outputSize = .zero
            return
        }
        let full = options
        let sizes = steps.map { CGSize(width: $0.image.width, height: $0.image.height) }
        let plan = ShotComposer.plan(sizes: sizes, units: steps.map(\.unit), options: full)
        outputSize = plan.outputSize
        downscaled = plan.scale < 0.999
        var quick = full
        quick.maxSide = min(full.maxSide, Self.previewSide)
        quick.maxPixels = min(full.maxPixels, Self.previewSide * Self.previewSide)
        let cg = await Self.compose(steps, options: quick)
        // Пока собиралось, могли заказать новую сборку: тогда эта уже не нужна.
        guard generation == renderGeneration, !Task.isCancelled, let cg else { return }
        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

// MARK: - Окно

@MainActor
final class StepsPreviewWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var session: StepsSession?
    private let model: StepsPreviewModel

    init(session: StepsSession) {
        self.session = session
        model = StepsPreviewModel(
            steps: { [weak session] in session?.model.steps ?? [] },
            setCaption: { [weak session] text, id in session?.setCaption(text, for: id) },
            move: { [weak session] id, index in session?.move(id, to: index) },
            back: { [weak session] in session?.closePreview() },
            deliver: { [weak session] image, action, done in
                guard let session else { return done(false) }
                session.deliver(image, action: action, done: done)
            })
        super.init()
    }

    func show() {
        model.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        ScreenOutput.activateApp()
        window.makeKeyAndOrderFrontOnScreen()
    }

    func dismiss() {
        window?.delegate = nil
        window?.orderOut(nil)
        window = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: 1040, height: 680)),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Коллаж шагов"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 520)
        // Окно коллажа — часть инструмента снимка: в снимки экрана не попадает.
        window.sharingType = .none
        window.contentView = NSHostingView(rootView: StepsPreviewView(model: model))
        window.delegate = self
        window.center()
        return window
    }

    /// Красная кнопка и ⌘W — «Назад к шагам»: шаги не теряются.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        session?.closePreview()
        return false
    }
}

// MARK: - Представление

struct StepsPreviewView: View {
    @ObservedObject var model: StepsPreviewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                preview
                Rectangle().fill(Color.dsLine).frame(width: 1)
                sidebar
            }
            Rectangle().fill(Color.dsLine).frame(height: 1)
            footer
        }
        .background(Color.dsBg)
    }

    private var preview: some View {
        ZStack {
            Color.dsBg
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    .padding(DS.Space.xxl)
                    .accessibilityLabel("Предпросмотр коллажа")
            }
        }
        .padding(.top, DS.Size.titlebar - DS.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Коллаж шагов").font(DS.Font.headline).foregroundStyle(.dsText)
                    .padding(.top, DS.Space.l)

                GroupLabel("Раскладка")
                Segmented(selection: $model.layout, options: StepsLayout.allCases.map { ($0, $0.shortTitle) })

                GroupLabel("Оформление")
                VStack(spacing: DS.Space.s) {
                    Toggle("Одинаковый размер", isOn: $model.equalSize)
                    Toggle("Рамка окна macOS", isOn: $model.windowFrame)
                    Toggle("«Шаг N» в заголовке окна", isOn: $model.titles).disabled(!model.windowFrame)
                    Toggle("Номера", isOn: $model.badges)
                    Toggle("Стрелки между шагами", isOn: $model.arrows)
                }
                .toggleStyle(.graphiteLabeled)

                GroupLabel("Шаги и подписи")
                ForEach(Array(model.steps.enumerated()), id: \.element.id) { index, step in
                    StepCaptionRow(number: index + 1, step: step,
                                   caption: Binding(get: { model.caption(for: step.id) },
                                                    set: { model.setCaption($0, for: step.id) }),
                                   moveUp: index > 0 ? { model.move(step.id, by: -1) } : nil,
                                   moveDown: index < model.steps.count - 1 ? { model.move(step.id, by: 1) } : nil)
                }
                Text("Подпись необязательна: короткая строка под шагом. Порядок — стрелками или перетаскиванием на панели шагов.")
                    .font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Space.xl)
            .padding(.bottom, DS.Space.xl)
        }
        .frame(width: 380)
        .background(Color.dsPanel)
    }

    private var sizeText: String {
        guard model.outputSize.width > 0 else { return "" }
        let size = "\(Int(model.outputSize.width)) × \(Int(model.outputSize.height)) px"
        return model.downscaled ? "\(size) · уменьшено до предела" : size
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s) {
            Text(sizeText).font(DS.Font.mono(12, relativeTo: .caption)).foregroundStyle(.dsMute)
                .help(model.downscaled ? "Коллаж больше предела по размеру и уменьшен целиком, чтобы файл открывался везде." : "")
            Spacer()
            Button("Назад к шагам", action: model.back)
                .buttonStyle(.graphite(.ghost))
                .keyboardShortcut(.cancelAction)
            Button { model.deliver(.copy) } label: {
                busyLabel("Скопировать", busy: model.delivering == .copy)
            }
            .buttonStyle(.graphite(.secondary))
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("В буфер обмена (⇧⌘C)")
            Button { model.deliver(.save) } label: {
                busyLabel("Сохранить", busy: model.delivering == .save)
            }
            .buttonStyle(.graphite(.primary))
            .keyboardShortcut("s", modifiers: .command)
            .help("В папку снимков (⌘S)")
        }
        .disabled(model.steps.isEmpty || model.delivering != nil)
        .padding(.horizontal, DS.Space.xl)
        .padding(.vertical, DS.Space.m)
        .background(Color.dsPanel)
    }
}

/// Подпись кнопки; пока идёт сборка и запись — с индикатором.
private func busyLabel(_ title: String, busy: Bool) -> some View {
    HStack(spacing: DS.Space.s) {
        if busy { ProgressView().controlSize(.small).accessibilityLabel("Собираю коллаж") }
        Text(title)
    }
}

private struct StepCaptionRow: View {
    let number: Int
    let step: StepShot
    @Binding var caption: String
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?

    var body: some View {
        HStack(spacing: DS.Space.s) {
            ZStack(alignment: .topLeading) {
                Image(decorative: step.thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 38)
                    .background(Color.dsField)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text("\(number)")
                    .font(DS.Font.mono(10, relativeTo: .caption2))
                    .foregroundStyle(.dsAccInk)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.dsAcc, in: Circle())
                    .padding(2)
            }
            TextField("Подпись шага \(number)", text: $caption)
                .textFieldStyle(.graphite)
                .accessibilityLabel("Подпись шага \(number)")
            VStack(spacing: 2) {
                arrow("chevron.up", title: "Раньше", action: moveUp)
                arrow("chevron.down", title: "Позже", action: moveDown)
            }
        }
    }

    private func arrow(_ symbol: String, title: String, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.dsMute)
                .frame(width: 22, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(action == nil)
        .opacity(action == nil ? 0.35 : 1)
        .help(title)
        .accessibilityLabel("Шаг \(number): \(title.lowercased())")
    }
}

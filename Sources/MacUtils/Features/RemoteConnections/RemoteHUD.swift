import AppKit
import MURemoteConnections
import SwiftUI
import MUCore
import MUDesign

/// Кнопка в HUD подключения.
enum RemoteHUDAction: Hashable {
    case cancel, close, openAccessibility, download, diagnostics, openFile, retry
    case choose(RemoteProgram)

    func title(_ program: RemoteProgram) -> String {
        switch self {
        case .cancel: return RL("Отмена")
        case .close: return RL("Закрыть")
        case .openAccessibility: return RL("Открыть настройки")
        case .download: return RL("Скачать %@", program.title)
        case .diagnostics: return RL("Диагностика")
        case .openFile: return RL("Открыть файл")
        case .retry: return RL("Повторить")
        case .choose(let p): return p.title
        }
    }
}

/// Текст и вид HUD для фазы подключения (m06/m07). Без пароля: только название и ID записи.
struct RemoteHUDContent: Equatable {
    var tone: DS.Tone
    var title: String
    var detail: String?
    var spinner = false
    var progress: Double?
    var actions: [RemoteHUDAction] = []
    /// Роли окна программы для «Диагностики» (поле пароля не найдено).
    var structure: [String] = []

    /// Явный инициализатор: из-за `private var finalOverride` поэлементный — `private`, а сообщения собирает и Center
    /// (RDP, копирование). Старые компиляторы (CI, macos-15) иначе не собирают.
    init(tone: DS.Tone, title: String, detail: String? = nil, spinner: Bool = false, progress: Double? = nil,
         actions: [RemoteHUDAction] = [], structure: [String] = []) {
        self.tone = tone
        self.title = title
        self.detail = detail
        self.spinner = spinner
        self.progress = progress
        self.actions = actions
        self.structure = structure
    }

    /// Висит, пока идёт подключение; итог гаснет сам (успех — 2,5 с, ошибка — 12 с).
    var isFinal: Bool { !spinner && tone != .info }
    var lifetime: TimeInterval { tone == .success ? 2.5 : 12 }

    static func make(_ phase: ConnectionPhase, program: RemoteProgram, record: ConnectionRecord) -> RemoteHUDContent {
        let p = program.title
        let who = "\(record.name) · \(record.displayID)"
        let isAnyDesk = program == .anyDesk
        switch phase {
        case .opening:
            return RemoteHUDContent(tone: .info, title: RL("Открываю %@…", p), detail: who, spinner: true)
        case let .waiting(elapsed, timeout):
            return RemoteHUDContent(tone: .info, title: isAnyDesk ? RL("Жду окно пароля… %@ с", elapsed) : RL("Жду окно аутентификации… %@ с", elapsed),
                                    detail: RL("Таймаут %@ с · «Отмена» оставит окно %@ как есть", timeout, p), spinner: true,
                                    progress: Double(elapsed) / Double(max(timeout, 1)), actions: [.cancel])
        case .intermediate(.sessionChoice):
            return RemoteHUDContent(tone: .info, title: RL("Выбираю сеанс в %@…", p), detail: RL("Пароль введу после"),
                                    spinner: true, actions: [.cancel])
        case .intermediate(.remoteSide):
            return RemoteHUDContent(tone: .info, title: RL("Жду ответа удалённого компьютера…"),
                                    detail: RL("Пароль введу, когда %@ его попросит", p), spinner: true, actions: [.cancel])
        case .intermediate(.unknown):
            return RemoteHUDContent(tone: .info, title: RL("%@ показал своё окно", p),
                                    detail: RL("Ответьте в окне %@ — пароль введу после", p), spinner: true, actions: [.cancel])
        case .typingID:
            return RemoteHUDContent(tone: .info, title: RL("Ввожу ID в %@…", p), detail: who, spinner: true, actions: [.cancel])
        case .entered:
            return RemoteHUDContent(tone: .success, title: RL("Пароль введён"), detail: RL("Подтверждаю вход…"), spinner: false)
                .with(final: false)
        case .finished(let outcome):
            return make(outcome, program: program, record: record, who: who)
        }
    }

    private static func make(_ outcome: ConnectionOutcome, program: RemoteProgram, record: ConnectionRecord,
                             who: String) -> RemoteHUDContent {
        let p = program.title
        let isAnyDesk = program == .anyDesk
        switch outcome {
        case .connected:
            return RemoteHUDContent(tone: .success, title: RL("Подключено"), detail: who)
        case .submitted:
            return RemoteHUDContent(tone: .neutral, title: RL("Пароль введён · сеанс не подтверждён"),
                                    detail: RL("Проверьте окно %@: открылся ли сеанс.", p), actions: [.close])
        case .sessionClosed:
            return RemoteHUDContent(tone: .warning, title: RL("%@ закрыл сеанс", p),
                                    detail: RL("Пароль введён, но сеанс не открылся. Причина — в окне %@.", p), actions: [.retry, .close])
        case .connectedWithoutPassword:
            return RemoteHUDContent(tone: .success, title: RL("Подключено без пароля"),
                                    detail: isAnyDesk ? RL("Сеанс открыт — AnyDesk уже помнит этот компьютер")
                                                      : RL("Сеанс открыт — TeamViewer пустил без пароля"))
        case .unconfirmed(copyID: true):
            return RemoteHUDContent(tone: .neutral, title: RL("Не удалось подключиться — ID скопирован"),
                                    detail: RL("Вставьте ID в %@ (⌘V) и нажмите «Connect».", p), actions: [.retry, .close])
        case .unconfirmed(copyID: false):
            return RemoteHUDContent(tone: .neutral, title: RL("Не удалось подтвердить подключение"),
                                    detail: RL("%@ не показал ни окно пароля, ни открытый сеанс. Проверьте окно %@.", p, p),
                                    actions: [.retry, .close])
        case .openedWithoutPassword(.userChoice):
            return RemoteHUDContent(tone: .success, title: RL("%@ открыт", p), detail: RL("%@. Пароль введите в окне %@.", who, p))
        case .openedWithoutPassword(.notInFile):
            return RemoteHUDContent(tone: .success, title: RL("%@ открыт", p),
                                    detail: RL("В файле нет пароля для «%@» — введите его в окне %@.", record.name, p))
        case .cancelled:
            return RemoteHUDContent(tone: .neutral, title: RL("Отменено"), detail: nil)
        case .failed(let failure):
            return make(failure, program: program, record: record)
        }
    }

    private static func make(_ failure: ConnectionFailure, program: RemoteProgram, record: ConnectionRecord) -> RemoteHUDContent {
        let p = program.title
        switch failure {
        case .noAccessibility:
            return RemoteHUDContent(tone: .warning, title: RL("%@ открыт, пароль не введён", p),
                                    detail: RL("Нет доступа «Универсальный доступ». Введите пароль вручную."),
                                    actions: [.openAccessibility, .close])
        case .notInstalled:
            return RemoteHUDContent(tone: .danger, title: RL("%@ не найден", p), detail: RL("Нет /Applications/%@.app.", p),
                                    actions: [.download, .close])
        case .launchFailed:
            return RemoteHUDContent(tone: .danger, title: RL("%@ не запустился", p), detail: RL("Ссылка подключения не открылась."),
                                    actions: [.retry, .close])
        case .aliasNotSupported:
            return RemoteHUDContent(tone: .warning, title: RL("%@ не открывает алиасы", p),
                                    detail: RL("Укажите в файле числовой ID для «%@».", record.name), actions: [.openFile, .close])
        case .programNotSpecified:
            return RemoteHUDContent(tone: .warning, title: RL("Программа не указана"),
                                    detail: RL("В строке нет колонки «Программа», а ID подходит и AnyDesk, и TeamViewer. Выберите программу."),
                                    actions: RemoteProgram.allCases.map { .choose($0) })
        case .fieldNotFound(let structure):
            return RemoteHUDContent(tone: .warning, title: RL("Введите пароль вручную"),
                                    detail: RL("Поле пароля не найдено (интерфейс %@ мог измениться). Пароль не скопирован.", p),
                                    actions: [.diagnostics, .close], structure: structure)
        case .wrongPassword:
            return RemoteHUDContent(tone: .danger, title: RL("Проверьте пароль в файле"),
                                    detail: RL("%@ отклонил пароль для «%@».", p, record.name), actions: [.openFile, .close])
        case .focusLost:
            return RemoteHUDContent(tone: .warning, title: RL("Ввод прерван"), detail: RL("Фокус ушёл из %@, пароль не отправлен.", p),
                                    actions: [.retry, .close])
        case .untrustedProgram:
            return RemoteHUDContent(tone: .danger, title: RL("Подпись %@ не подтверждена", p),
                                    detail: RL("Пароль не введён: запущенная программа подписана не разработчиком %@.", p),
                                    actions: [.download, .close])
        case .entryGone:
            return RemoteHUDContent(tone: .warning, title: RL("Записи больше нет в файле"),
                                    detail: RL("Файл изменился — запись не найдена. Список обновлён."), actions: [.close])
        case .fileUnavailable(let code):
            return RemoteHUDContent(tone: .danger, title: RL("Файл подключений не прочитан"),
                                    detail: code == .locked ? RL("Файл занят другой программой — попробуйте ещё раз.")
                                                            : RL("Проверьте, что файл на месте, и повторите."),
                                    actions: [.retry, .close])
        }
    }

    private var finalOverride: Bool?
    private func with(final: Bool) -> RemoteHUDContent {
        var copy = self
        copy.finalOverride = final
        return copy
    }

    /// «Пароль введён» в ходе подключения — не итог, не гаснет.
    var fadesOut: Bool { finalOverride ?? isFinal }
}

/// Карточка HUD (m06/m07): 400 pt, рамка тона, значок или индикатор, кнопки.
struct RemoteHUDCard: View {
    let content: RemoteHUDContent
    let program: RemoteProgram
    var showStructure = false
    var onAction: (RemoteHUDAction) -> Void = { _ in }

    var body: some View {
        let c = content
        let shape = RoundedRectangle(cornerRadius: DS.Radius.floating, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if c.spinner {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: c.tone.symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(c.tone.ink)
                    }
                }
                .frame(width: 32, height: 32)
                .background(c.spinner ? Color.dsField : c.tone.fill, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(DS.Font.manrope(15, .bold, relativeTo: .body)).foregroundStyle(.dsText)
                        .monospacedDigit()
                    if let detail = c.detail {
                        Text(detail).font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
            }
            if let progress = c.progress { ProgressBar(value: progress) }
            if showStructure, !c.structure.isEmpty {
                ScrollView {
                    Text(c.structure.joined(separator: "\n"))
                        .font(DS.Font.mono(11, relativeTo: .caption2)).foregroundStyle(.dsMute)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(160, CGFloat(c.structure.count) * 15 + 4))
                .padding(8)
                .background(Color.dsField, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .padding(.leading, 44)
                .accessibilityLabel(RL("Структура окна %@: только роли элементов", program.title))
            }
            if !c.actions.isEmpty {
                HStack(spacing: DS.Space.s) {
                    ForEach(Array(c.actions.enumerated()), id: \.offset) { index, action in
                        Button(action.title(program)) { onAction(action) }
                            .buttonStyle(.graphite(index == 0 && c.tone != .info ? .primary : .secondary, size: .compact))
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .background(Color.dsPanel, in: shape)
        .overlay(shape.strokeBorder(c.tone.line, lineWidth: 1.5))
        .padding(4)
    }
}

@MainActor
private final class RemoteHUDModel: ObservableObject {
    @Published var content: RemoteHUDContent
    @Published var program: RemoteProgram
    @Published var showStructure = false

    init(content: RemoteHUDContent, program: RemoteProgram) {
        self.content = content
        self.program = program
    }
}

private struct RemoteHUDView: View {
    @ObservedObject var model: RemoteHUDModel
    let onAction: (RemoteHUDAction) -> Void

    var body: some View {
        RemoteHUDCard(content: model.content, program: model.program, showStructure: model.showStructure, onAction: onAction)
    }
}

/// Плавающая карточка у верха экрана. Не забирает фокус: иначе пароль ушёл бы не туда.
@MainActor
final class RemoteHUDController {
    static let shared = RemoteHUDController()

    var onAction: ((RemoteHUDAction) -> Void)?
    private var panel: NSPanel?
    private var model: RemoteHUDModel?
    private var generation = 0

    private(set) var current: RemoteHUDContent?

    func show(_ phase: ConnectionPhase, program: RemoteProgram, record: ConnectionRecord) {
        if case .finished(.cancelled) = phase { return dismiss() }
        show(RemoteHUDContent.make(phase, program: program, record: record), program: program, waiting: phase.isWaiting)
    }

    /// Готовое сообщение (RDP, копирование) — тот же HUD.
    func show(_ content: RemoteHUDContent, program: RemoteProgram = .anyDesk, waiting: Bool = false) {
        let announce = current?.title != content.title && !(current?.spinner == true && content.spinner && waiting)
        current = content
        generation += 1
        let token = generation
        if let model {
            model.content = content
            model.program = program
            model.showStructure = false
        } else {
            present(content, program: program)
        }
        DispatchQueue.main.async { [weak self] in self?.fit() }
        if announce {
            let text = [content.title, content.detail].compactMap { $0 }.joined(separator: ". ")
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        if content.fadesOut {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(content.lifetime * 1_000_000_000))
                guard let self, token == self.generation else { return }
                self.dismiss()
            }
        }
    }

    func toggleStructure() {
        model?.showStructure.toggle()
        generation += 1 // раскрытая диагностика не гаснет сама
        DispatchQueue.main.async { [weak self] in self?.fit() }
    }

    func dismiss() {
        generation += 1
        current = nil
        guard let panel else { return }
        self.panel = nil
        model = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
    }

    private func present(_ content: RemoteHUDContent, program: RemoteProgram) {
        let model = RemoteHUDModel(content: content, program: program)
        self.model = model
        let host = FirstMouseHostingView(rootView: RemoteHUDView(model: model) { [weak self] action in self?.onAction?(action) })
        let size = host.fittingSize
        let panel = RemoteHUDPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host
        if let frame = (NSScreen.withMouse ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 40))
        }
        panel.orderFrontRegardlessOnScreen()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        }
        self.panel = panel
    }

    /// Высота меняется вместе с текстом; верхний край остаётся на месте.
    private func fit() {
        guard let panel, let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let old = panel.frame
        panel.setFrame(NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height, width: size.width, height: size.height),
                       display: true)
    }
}

private final class RemoteHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension ConnectionPhase {
    var isWaiting: Bool { if case .waiting = self { return true } else { return false } }
}

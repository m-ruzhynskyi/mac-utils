import SwiftUI
import MUCore
import MUDesign

/// Первый запуск (`.audit/concept/Onboarding*.dc.html`): слева — знак, приветствие и прогресс, справа — шаг.
/// Три шага: приветствие → разрешения → готово. «Назад» и «Продолжить» ничего не меняют в настройках,
/// кроме `Pref.onboardingDone` на последнем шаге. Показывается в окне настроек (`SettingsRootView`), своего окна нет.
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var step = OnboardingContent.Step.welcome
    @ObservedObject private var permissions = PermissionsModel.shared

    var body: some View {
        OnboardingContent(
            step: step,
            accessibility: permissions.accessibility ? .granted : .needed,
            screenRecording: permissions.screenRecording ? .granted : .needed,
            microphone: permissions.microphone == .granted ? .granted : permissions.microphone == .denied ? .denied : .needed,
            openAccessibility: {
                Permissions.requestAccessibility()
                Permissions.open(.accessibility)
            },
            openScreenRecording: {
                Permissions.requestScreenRecording()
                Permissions.open(.screenRecording)
            },
            back: { move(-1) },
            next: { if step == .done { onFinish() } else { move(1) } }
        )
        .onAppear { permissions.refresh() }
    }

    private func move(_ delta: Int) {
        guard let next = OnboardingContent.Step(rawValue: step.rawValue + delta) else { return }
        step = next
    }
}

/// Вид первого запуска на готовых значениях (без моделей разрешений) — для снимков интерфейса.
struct OnboardingContent: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, done

        var label: String {
            switch self {
            case .welcome: return "ВОЗМОЖНОСТИ"
            case .permissions: return "РАЗРЕШЕНИЯ"
            case .done: return "СОЧЕТАНИЯ"
            }
        }
    }

    var step: Step
    var accessibility: PermissionState
    var screenRecording: PermissionState
    var microphone: PermissionState
    var openAccessibility: () -> Void = {}
    var openScreenRecording: () -> Void = {}
    var back: () -> Void = {}
    var next: () -> Void = {}

    private let features: [SettingsSection] = [.screenshot, .windows, .switcher, .shelf, .qr, .annotate, .meetings, .volume,
                                               .layout, .cheatSheet, .downloads, .cleanup]

    var body: some View {
        HStack(spacing: 0) {
            welcomeColumn
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                .background(Color.dsSide)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.dsLine).frame(width: 1).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 14) {
                Text(step.label)
                    .font(DS.Font.manrope(12, .bold, relativeTo: .caption))
                    .tracking(DS.Font.tracking(0.1, size: 12))
                    .foregroundStyle(.dsAccText)
                    .accessibilityAddTraits(.isHeader)
                stepContent
                Spacer(minLength: DS.Space.m)
                navigation
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.dsBg)
    }

    // MARK: Левая колонка

    private var welcomeColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            let tile = RoundedRectangle(cornerRadius: 20, style: .continuous)
            AppMark(size: 38, color: .dsAccLine)
                .frame(width: 72, height: 72)
                .background(Color.dsPanel, in: tile)
                .overlay(tile.strokeBorder(Color.dsLine, lineWidth: 1))
            Text("Добро пожаловать в Mac Utils")
                .font(DS.Font.welcomeTitle)
                .tracking(DS.Font.tracking(-0.03, size: 30))
                .foregroundStyle(.dsText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Три разрешения, и всё работает. Ничего не уходит в сеть: OCR и подсказки считаются на вашем Mac.")
                .font(DS.Font.body)
                .lineSpacing(4)
                .foregroundStyle(.dsMute)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? Color.dsAccLine : Color.dsOff).frame(width: 28, height: 5)
                }
            }
            .accessibilityHidden(true)
            Text("Шаг \(step.rawValue + 1) из \(Step.allCases.count)")
                .font(DS.Font.rowSub)
                .foregroundStyle(.dsMute)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: Шаги

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(features) { section in ToolTile(systemImage: section.symbol, title: section.title) }
            }
        case .permissions:
            VStack(spacing: 14) {
                PermissionCard(title: PermissionKind.accessibility.title,
                               purpose: "Для ⌘X/⌘V в Finder, прокрутки и переключателя",
                               state: accessibility, action: openAccessibility)
                PermissionCard(title: PermissionKind.screenRecording.title,
                               purpose: "Для скриншотов, записи и трансляции",
                               state: screenRecording, action: openScreenRecording)
                PermissionCard(title: PermissionKind.microphone.title,
                               purpose: "Нужен записям встреч и записи экрана с микрофоном",
                               state: microphone, optional: true)
            }
        case .done:
            ListCard {
                KeyRow(HotKeyAction.screenshot.title, action: .screenshot)
                KeyRow(HotKeyAction.tools.title, action: .tools)
                KeyRow(HotKeyAction.settings.title, action: .settings)
            }
        }
    }

    private var navigation: some View {
        HStack {
            if step != .welcome {
                Button("Назад", action: back).buttonStyle(.graphite(.ghost))
            }
            Spacer()
            Button(step == .done ? "Открыть настройки" : "Продолжить", action: next)
                .buttonStyle(.graphite(step == .done ? .primary : .secondary, size: .large))
                .keyboardShortcut(.defaultAction)
        }
    }
}

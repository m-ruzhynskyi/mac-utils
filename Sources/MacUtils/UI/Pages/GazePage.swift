import AppKit
import SwiftUI
import MUCore
import MUDesign
import MUGaze

// MARK: - Взгляд в камеру

/// Утверждённый макет: `.audit/hide-ai-design/index.html`, раздел «Взгляд в камеру».
/// Включается только вручную; включение не сохраняется между запусками. Камера открыта, пока включено.
struct GazePage: View {
    @ObservedObject private var service = GazeService.shared
    @AppStorage(Pref.gazeTarget) private var target = "camera"
    @AppStorage(Pref.gazePointYaw) private var pointYaw = 0.0
    @AppStorage(Pref.gazePointPitch) private var pointPitch = 0.0
    @AppStorage(Pref.gazeFreedom) private var freedom = "normal"
    @AppStorage(Pref.gazeCalibrated) private var calibrated = false
    @AppStorage(Pref.gazeScreenLift) private var screenLift = 0.15

    private var isOn: Binding<Bool> {
        Binding(get: { service.isOn }, set: { service.setOn($0) })
    }

    var body: some View {
        SettingsPage(.gaze,
                     subtitle: "В звонке глаза смотрят туда, куда вы выбрали, даже когда вы смотрите на экран. Лицо и глаза — ваши, с камеры; меняется только положение зрачков.",
                     isOn: isOn, toggleLabel: "Взгляд в камеру") {
            statusCard

            GroupLabel("Куда смотреть")
            ListCard {
                GazeTargetField(target: $target, yaw: $pointYaw, pitch: $pointPitch, freedom: GazeFreedom(rawValue: freedom) ?? .normal)
                    .padding(.vertical, 6)
                Row("Куда смотреть", subtitle: "Перетащите точку туда, куда должны смотреть глаза. Круг — насколько они могут естественно двигаться") {
                    Segmented(selection: $target, options: [("camera", "В камеру"), ("below", "Чуть ниже"), ("point", "Своя точка")])
                }
                Row("Свобода движения", subtitle: "Мелкие движения глаз, как у живого человека. Моргания не меняются") {
                    Segmented(selection: $freedom, options: [("low", "Мало"), ("normal", "Обычно"), ("high", "Много")])
                }
                Row("Когда голова сильно повёрнута", subtitle: "Поправка плавно выключается, чтобы глаза не выглядели странно") { EmptyView() }
            }

            GroupLabel("Калибровка")
            ListCard { calibrationRow }

            GroupLabel("Как подключить в Zoom, Discord, Meet")
            ListCard {
                Row("1. Один раз: OBS Studio",
                    subtitle: "Бесплатная программа. В ней добавьте источник «Syphon Client» → «\(GazeService.syphonName)», затем «Start Virtual Camera» («Запустить виртуальную камеру»)") { EmptyView() }
                Row("2. В звонке выберите камеру «OBS Virtual Camera»",
                    subtitle: "Zoom, Discord, Google Meet, Teams, Telegram — везде, где можно выбрать камеру") { EmptyView() }
            }
            Footnote("Свою камеру Mac Utils сделать не может: macOS разрешает это только программам с платной подписью разработчика. Поэтому камера идёт через OBS.")
        }
    }

    // MARK: Состояние

    @ViewBuilder private var statusCard: some View {
        switch service.status {
        case .cameraDenied:
            Banner(.warning, title: "Нет доступа к камере.", message: "Разрешите Mac Utils камеру в Системных настройках и включите снова.") {
                Button("Открыть настройки") { Permissions.open(.camera) }
                    .buttonStyle(.graphite(.primary, size: .compact))
            }
        case .noCamera:
            Banner(.warning, title: "Камера не найдена.", message: "Подключите камеру и включите снова. Виртуальные камеры (в том числе OBS) не используются.") { EmptyView() }
        case let .failed(message):
            Banner(.danger, title: message) { EmptyView() }
        case .off:
            ListCard { FeatureStatusRow(tone: .neutral, label: "Выключено", detail: "Камера не используется") }
        case .starting:
            ListCard { FeatureStatusRow(tone: .info, label: "Запуск…") }
        case .running:
            ListCard {
                if service.obsFPS > 0 {
                    FeatureStatusRow(tone: .success, label: "Работает",
                                     detail: String(format: "OBS получает картинку · %.0f к/с", service.obsFPS))
                } else {
                    FeatureStatusRow(tone: .info, label: "Камера работает",
                                     detail: String(format: "%.0f к/с. OBS пока не подключён — шаги ниже", service.stats.fps))
                }
                if !service.preciseEyes {
                    FeatureStatusRow(tone: .warning, label: "Упрощённый режим", detail: "Модель глаз не загрузилась — поправка грубее")
                }
            }
        }
    }

    // MARK: Калибровка

    @ViewBuilder private var calibrationRow: some View {
        switch service.calibration {
        case let .collecting(step, progress):
            Row(step == .camera ? "Смотрите прямо в камеру" : "Смотрите в середину экрана",
                subtitle: "Не двигайте голову. \(Int(progress * 100))%") {
                Button("Отмена") { service.cancelCalibration() }.buttonStyle(.graphite(.secondary, size: .compact))
            }
        case let .failed(message):
            Row("Калибровка не удалась", subtitle: message) { calibrateButton }
        default:
            Row("В камеру и на середину экрана", subtitle: calibrationSubtitle) { calibrateButton }
        }
    }

    private var calibrationSubtitle: String {
        if calibrated {
            let angle = GazeCalibrationRecorder.Result(biasX: 0, screenLift: screenLift).screenAngleDegrees()
            return String(format: "Готово: экран ниже камеры примерно на %.0f°", angle)
        }
        return "Две секунды смотрите в камеру, затем две — в середину экрана. Без калибровки экран считается чуть ниже камеры"
    }

    private var calibrateButton: some View {
        Button(calibrated ? "Повторить" : "Откалибровать") { service.startCalibration() }
            .buttonStyle(.graphite(.secondary, size: .compact))
            .disabled(service.status != .running)
            .help(service.status == .running ? "" : "Сначала включите «Взгляд в камеру»")
    }
}

/// Поле «куда смотреть»: камера сверху, точка взгляда и круг свободы. Перетаскивание — «Своя точка».
/// По горизонтали ±15°, по вертикали от +5° (выше камеры) до −20° (низ экрана ноутбука).
private struct GazeTargetField: View {
    @Binding var target: String
    @Binding var yaw: Double
    @Binding var pitch: Double
    let freedom: GazeFreedom

    static let yawRange = 15.0, pitchTop = 5.0, pitchBottom = -20.0

    private var current: (yaw: Double, pitch: Double) {
        switch target {
        case "below": return (0, GazeTarget.slightlyBelowPitch)
        case "point": return (yaw, pitch)
        default: return (0, 0)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let p = point(current, in: size)
            let r = freedom.parameters.keepRadius / 0.18 * 22 + 8
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.dsPanel)
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.dsLine)
                VStack(spacing: 2) {
                    Image(systemName: "web.camera").foregroundStyle(.dsMute)
                    Text("камера").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                }
                .position(x: size.width / 2, y: point((0, 0), in: size).y - 2)
                Circle().strokeBorder(Color.dsAccLine, lineWidth: 1.5).frame(width: r * 2, height: r * 2).position(p)
                Circle().fill(Color.dsAcc).frame(width: 14, height: 14).position(p)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let v = angles(g.location, in: size)
                target = "point"; yaw = v.yaw; pitch = v.pitch
            })
            .accessibilityElement()
            .accessibilityLabel("Куда смотреть")
            .accessibilityValue(String(format: "%.0f° по горизонтали, %.0f° по вертикали", current.yaw, current.pitch))
            .accessibilityAdjustableAction { dir in
                target = "point"
                pitch = min(max(pitch + (dir == .increment ? 1 : -1), Self.pitchBottom), Self.pitchTop)
            }
        }
        .frame(height: 150)
    }

    private func point(_ a: (yaw: Double, pitch: Double), in size: CGSize) -> CGPoint {
        let x = size.width / 2 + a.yaw / Self.yawRange * (size.width / 2 - 24)
        let t = (Self.pitchTop - a.pitch) / (Self.pitchTop - Self.pitchBottom)
        return CGPoint(x: x, y: 18 + t * (size.height - 36))
    }

    private func angles(_ p: CGPoint, in size: CGSize) -> (yaw: Double, pitch: Double) {
        let yaw = (p.x - size.width / 2) / (size.width / 2 - 24) * Self.yawRange
        let t = (p.y - 18) / (size.height - 36)
        let pitch = Self.pitchTop - t * (Self.pitchTop - Self.pitchBottom)
        return (min(max(yaw, -Self.yawRange), Self.yawRange).rounded(), min(max(pitch, Self.pitchBottom), Self.pitchTop).rounded())
    }
}

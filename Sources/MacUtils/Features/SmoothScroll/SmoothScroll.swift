import AppKit
import CoreGraphics

/// Плавная прокрутка для обычной мыши: каждый «щелчок» колеса поглощается
/// и проигрывается заново потоком пиксельных событий с замедлением в конце.
/// Трекпад и Magic Mouse (события с фазами) не затрагиваются; непрерывные
/// события без фаз от драйверов мышей (Logi Options+) тоже сглаживаются.
@MainActor
final class SmoothScroll: NSObject, ObservableObject {
    static let shared = SmoothScroll()

    @Published private(set) var isRunning = false

    /// Метка наших собственных событий, чтобы tap их пропускал.
    private static let marker: Int64 = 0x4D55_5343

    private var tap: EventTap?
    private var timer: Timer?

    private var remainingY = 0.0
    private var remainingX = 0.0
    private var carryY = 0.0
    private var carryX = 0.0
    private var lastTick: TimeInterval = 0
    private var lastFrame: TimeInterval = 0
    private var streak = 0
    private var flags: CGEventFlags = []

    private override init() {
        super.init()
    }

    func sync() {
        let wanted = UserDefaults.standard.bool(forKey: Pref.smoothScroll) && Permissions.accessibility
        if wanted {
            if tap == nil {
                tap = EventTap(types: [.scrollWheel]) { [weak self] type, event in
                    self?.handle(type: type, event: event) ?? true
                }
            }
            isRunning = tap?.start() ?? false
            if !isRunning { Log.scroll.error("Не удалось создать event tap для прокрутки") }
        } else {
            tap?.stop()
            tap = nil
            stopGlide()
            isRunning = false
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .scrollWheel else { return true }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return true }
        // Трекпад, Magic Mouse и инерция всегда идут с фазами — они уже плавные.
        if event.getIntegerValueField(.scrollWheelEventScrollPhase) != 0
            || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { return true }
        // Непрерывные события без фаз шлют драйверы мышей (Logi Options+ и т. п.).
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        let defaults = UserDefaults.standard
        let speed = min(max(defaults.double(forKey: Pref.smoothSpeed), 0.3), 4)

        // Сдвиг в пикселях для этого события.
        let pixelsY: Double
        let pixelsX: Double
        if continuous {
            pixelsY = Self.pointDelta(event, .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1) * speed
            pixelsX = Self.pointDelta(event, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2) * speed
        } else {
            let dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            let dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
            // Быстрое вращение колеса ускоряет прокрутку.
            let now = ProcessInfo.processInfo.systemUptime
            streak = (now - lastTick) < 0.12 ? min(streak + 1, 15) : 0
            lastTick = now
            let step = 50.0 * speed * (1 + Double(streak) * 0.12)
            pixelsY = dy * step
            pixelsX = dx * step
        }
        guard pixelsY != 0 || pixelsX != 0 else { return true }

        // Смена направления сразу гасит остаток.
        if pixelsY != 0, remainingY * pixelsY < 0 { remainingY = 0; carryY = 0 }
        if pixelsX != 0, remainingX * pixelsX < 0 { remainingX = 0; carryX = 0 }
        remainingY += pixelsY
        remainingX += pixelsX
        flags = event.flags

        startGlide()
        return false
    }

    /// Сдвиг непрерывного события в пикселях (дробные доли — из fixed-point поля).
    private static func pointDelta(_ event: CGEvent, _ point: CGEventField, _ fixed: CGEventField) -> Double {
        let pixels = event.getIntegerValueField(point)
        return pixels != 0 ? Double(pixels) : event.getDoubleValueField(fixed)
    }

    private func startGlide() {
        guard timer == nil else { return }
        lastFrame = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 120.0, target: self, selector: #selector(frame),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopGlide() {
        timer?.invalidate()
        timer = nil
        remainingX = 0
        remainingY = 0
        carryX = 0
        carryY = 0
    }

    @objc private func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(max(now - lastFrame, 1.0 / 240.0), 1.0 / 30.0)
        lastFrame = now

        let duration = min(max(UserDefaults.standard.double(forKey: Pref.smoothDuration), 0.08), 1.5)
        // Экспоненциальное замедление: ~98% пути проходится за `duration`.
        let k = 1 - exp(-dt / (duration / 4))

        let moveY = abs(remainingY) < 1 ? remainingY : remainingY * k
        let moveX = abs(remainingX) < 1 ? remainingX : remainingX * k
        remainingY -= moveY
        remainingX -= moveX

        let totalY = moveY + carryY
        let totalX = moveX + carryX
        let pixelsY = totalY.rounded(.towardZero)
        let pixelsX = totalX.rounded(.towardZero)
        carryY = totalY - pixelsY
        carryX = totalX - pixelsX

        if pixelsY != 0 || pixelsX != 0 {
            post(dy: Int32(pixelsY), dx: Int32(pixelsX))
        }

        if remainingY == 0 && remainingX == 0 {
            stopGlide()
        }
    }

    private func post(dy: Int32, dx: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                  wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        if let location = CGEvent(source: nil)?.location {
            event.location = location
        }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cgSessionEventTap)
    }
}

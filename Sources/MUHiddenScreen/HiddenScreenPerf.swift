import AppKit
import CoreMedia
import Darwin
import MUCore

/// Замер скорости зеркала (HSCR-47, раздел perf самопроверки): кадры потока и показанные кадры в секунду,
/// возраст кадра (время кадра ScreenCaptureKit → показ в зеркале), цена сторожа курсора, загрузка процессора.
public struct PerfSample: Sendable {
    public var seconds: Double
    public var streamFrames: Int
    public var shownFrames: Int
    /// Возраст кадра при показе, мс.
    public var frameAges: [Double]
    /// Сколько длился обработчик сторожа курсора, мкс.
    public var guardDurations: [Double]
    /// Процессор за замер, % одного ядра: имя → проценты.
    public var cpu: [(String, Double)]
    public var framePixels: CGSize?
    public var displayPoints: CGSize?

    public init(seconds: Double, streamFrames: Int, shownFrames: Int, frameAges: [Double], guardDurations: [Double],
                cpu: [(String, Double)], framePixels: CGSize?, displayPoints: CGSize?) {
        self.seconds = seconds
        self.streamFrames = streamFrames
        self.shownFrames = shownFrames
        self.frameAges = frameAges
        self.guardDurations = guardDurations
        self.cpu = cpu
        self.framePixels = framePixels
        self.displayPoints = displayPoints
    }

    /// Перцентиль (0…1) по ближайшему рангу; пусто — nil.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func format(_ value: Double?, _ unit: String) -> String {
        value.map { "\(Int($0.rounded())) \(unit)" } ?? "—"
    }

    /// «perf как есть: поток 58 к/с, показано 58 к/с, возраст кадра p50 12 мс p95 30 мс, сторож 120 выз/с p50 4 мкс p95 15 мкс,
    /// CPU Mac Utils 12%, помощник 0%, Claude 40%; кадр 1800×1400 px, дисплей 1440×900 pt».
    public func line(phase: String) -> String {
        let per = max(seconds, 0.001)
        let stream = Double(streamFrames) / per
        let shown = Double(shownFrames) / per
        let calls = Double(guardDurations.count) / per
        let frame = framePixels.map { "\(Int($0.width))×\(Int($0.height)) px" } ?? "—"
        let display = displayPoints.map { "\(Int($0.width))×\(Int($0.height)) pt" } ?? "—"
        let cpuText = cpu.map { "\($0.0) \(Int($0.1.rounded()))%" }.joined(separator: ", ")
        return "perf \(phase): поток \(Int(stream.rounded())) к/с, показано \(Int(shown.rounded())) к/с, "
            + "возраст кадра p50 \(Self.format(Self.percentile(frameAges, 0.5), "мс")) p95 \(Self.format(Self.percentile(frameAges, 0.95), "мс")), "
            + "сторож \(Int(calls.rounded())) выз/с p50 \(Self.format(Self.percentile(guardDurations, 0.5), "мкс")) p95 \(Self.format(Self.percentile(guardDurations, 0.95), "мкс")), "
            + "CPU \(cpuText.isEmpty ? "—" : cpuText); кадр \(frame), дисплей \(display)"
    }
}

/// Сбор замера. Счётчики пишутся только пока замер идёт (`active`): в обычной работе — одна проверка флага.
@MainActor
final class PerfMeter {
    private(set) var active = false
    private var started: TimeInterval = 0
    private var streamFrames = 0
    private var shownFrames = 0
    private var ages: [Double] = []
    private var guards: [Double] = []
    private var pendingFrame = false
    private var link: CADisplayLink?
    private var cpuStart: [pid_t: Double] = [:]
    private var watched: [(String, [pid_t])] = []

    /// `processes` — имя и процессы (программа и её дочерние), чей процессор считать.
    func start(view: NSView, processes: [(String, [pid_t])]) {
        active = true
        started = ProcessInfo.processInfo.systemUptime
        streamFrames = 0
        shownFrames = 0
        ages.removeAll()
        guards.removeAll()
        watched = processes
        cpuStart = [:]
        for pid in processes.flatMap(\.1) { cpuStart[pid] = Self.cpuSeconds(pid) }
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop(framePixels: CGSize?, displayPoints: CGSize?) -> PerfSample {
        active = false
        link?.invalidate()
        link = nil
        let seconds = ProcessInfo.processInfo.systemUptime - started
        let cpu = watched.map { name, pids -> (String, Double) in
            let used = pids.reduce(0.0) { $0 + max((Self.cpuSeconds($1) ?? 0) - (cpuStart[$1] ?? 0), 0) }
            return (name, used / max(seconds, 0.001) * 100)
        }
        return PerfSample(seconds: seconds, streamFrames: streamFrames, shownFrames: shownFrames, frameAges: ages,
                          guardDurations: guards, cpu: cpu, framePixels: framePixels, displayPoints: displayPoints)
    }

    /// Кадр потока дошёл до главного потока и поставлен в слой; `pts` — время кадра (часы хоста, с).
    func frame(pts: Double) {
        guard active else { return }
        streamFrames += 1
        pendingFrame = true
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        if pts > 0, now >= pts { ages.append((now - pts) * 1000) }
    }

    /// Кадров потока с начала замера (сколько сдвинула прокрутка).
    var streamFramesSoFar: Int { streamFrames }

    func guardCall(_ microseconds: Double) {
        guard active else { return }
        guards.append(microseconds)
    }

    /// Обновление экрана: новый кадр с прошлого обновления — «показан».
    @objc private func tick() {
        guard pendingFrame else { return }
        pendingFrame = false
        shownFrames += 1
    }

    /// Процессорное время процесса, с (`proc_pid_rusage`; у arm64 — в тиках `mach_absolute_time`).
    nonisolated static func cpuSeconds(_ pid: pid_t) -> Double? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks = Double(info.ri_user_time + info.ri_system_time)
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Процесс и его дочерние (у Electron отрисовка — в дочернем «Helper (Renderer)»).
    nonisolated static func family(_ pid: pid_t) -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 64)
        let count = children.withUnsafeMutableBufferPointer { buffer in
            proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        // Ответ — число процессов (в части версий — байты): не больше размера буфера.
        let n = Int(count) > children.count ? Int(count) / MemoryLayout<pid_t>.size : max(Int(count), 0)
        return [pid] + children.prefix(n).filter { $0 > 0 && $0 != pid }
    }
}

import Charts
import SwiftUI

/// «Монитор системы»: процессор, память, диск, сеть, батарея — раз в секунду,
/// пока вкладка открыта.
@MainActor
final class SystemMonitorModel: ObservableObject {
    static let shared = SystemMonitorModel()
    static let historyLength = 60

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memory: SystemStats.Memory?
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var disk: SystemStats.Disk?
    @Published private(set) var download: Double = 0
    @Published private(set) var upload: Double = 0
    @Published private(set) var downloadHistory: [Double] = []
    @Published private(set) var uploadHistory: [Double] = []
    @Published private(set) var battery: SystemStats.Battery?
    @Published private(set) var thermal = ProcessInfo.processInfo.thermalState

    let cores = ProcessInfo.processInfo.activeProcessorCount

    private var timer: Timer?
    private var lastTicks: [SystemStats.CPUTicks] = []
    private var lastNetwork: (received: UInt64, sent: UInt64) = (0, 0)
    private var lastSample = Date()
    private var users = 0

    /// Вкладки включают выборку, пока они на экране.
    func start() {
        users += 1
        guard timer == nil else { return }
        lastTicks = SystemStats.cpuTicks()
        lastNetwork = SystemStats.networkBytes()
        lastSample = Date()
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { SystemMonitorModel.shared.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        users = max(users - 1, 0)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let now = Date()
        let seconds = now.timeIntervalSince(lastSample)
        lastSample = now

        let ticks = SystemStats.cpuTicks()
        if !lastTicks.isEmpty { cpu = SystemStats.cpuUsage(previous: lastTicks, current: ticks) }
        lastTicks = ticks
        Self.push(cpu, to: &cpuHistory)

        memory = SystemStats.memory()
        Self.push(memory?.fraction ?? 0, to: &memoryHistory)
        disk = SystemStats.disk()

        let network = SystemStats.networkBytes()
        download = SystemStats.rate(previous: lastNetwork.received, current: network.received, seconds: seconds)
        upload = SystemStats.rate(previous: lastNetwork.sent, current: network.sent, seconds: seconds)
        lastNetwork = network
        Self.push(download, to: &downloadHistory)
        Self.push(upload, to: &uploadHistory)

        battery = SystemStats.battery()
        thermal = ProcessInfo.processInfo.thermalState
    }

    private static func push(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}

struct SystemMonitorView: View {
    @ObservedObject var model: SystemMonitorModel

    private let columns = [GridItem(.adaptive(minimum: 280), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                MonitorCard(title: "Процессор", symbol: "cpu", tint: .blue,
                            value: percent(model.cpu),
                            detail: "\(model.cores) \(plural(model.cores, "ядро", "ядра", "ядер"))",
                            history: model.cpuHistory, maximum: 1)
                MonitorCard(title: "Память", symbol: "memorychip", tint: .green,
                            value: model.memory.map { percent($0.fraction) } ?? "—",
                            detail: model.memory.map { "\(bytes($0.used)) из \(bytes($0.total)) · сжато \(bytes($0.compressed))" } ?? "",
                            history: model.memoryHistory, maximum: 1)
                MonitorCard(title: "Сеть", symbol: "network", tint: .purple,
                            value: "↓ \(speed(model.download))",
                            detail: "↑ \(speed(model.upload))",
                            history: model.downloadHistory, maximum: nil,
                            secondHistory: model.uploadHistory)
                diskCard
                statusCard
            }
            .padding(16)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var diskCard: some View {
        CardShell(title: "Диск", symbol: "internaldrive", tint: .orange) {
            if let disk = model.disk {
                Text(percent(disk.fraction)).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                ProgressView(value: disk.fraction).tint(disk.fraction > 0.9 ? .red : .orange)
                Text("Свободно \(bytes(UInt64(disk.available))) из \(bytes(UInt64(disk.total)))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—")
            }
        }
    }

    private var statusCard: some View {
        CardShell(title: "Система", symbol: "gauge.with.dots.needle.33percent", tint: .teal) {
            if let battery = model.battery {
                Label("Батарея \(battery.percent) %\(battery.charging ? " · заряжается" : battery.onAC ? " · от сети" : "")",
                      systemImage: battery.charging ? "battery.100.bolt" : "battery.75")
            }
            Label("Нагрев: \(thermalText)", systemImage: "thermometer.medium")
            Label("Работает \(uptime)", systemImage: "clock")
        }
    }

    private var thermalText: String {
        switch model.thermal {
        case .nominal: return "норма"
        case .fair: return "повышенный"
        case .serious: return "высокий"
        case .critical: return "критический"
        @unknown default: return "—"
        }
    }

    private var uptime: String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        return days > 0 ? "\(days) д \(hours) ч" : "\(hours) ч \(minutes) мин"
    }
}

private struct CardShell<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            content
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MonitorCard: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let detail: String
    let history: [Double]
    /// nil — шкала по максимуму истории (для сети).
    let maximum: Double?
    var secondHistory: [Double]? = nil

    var body: some View {
        CardShell(title: title, symbol: symbol, tint: tint) {
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Chart {
                ForEach(Array(history.enumerated()), id: \.offset) { index, point in
                    AreaMark(x: .value("t", index), y: .value("v", point))
                        .foregroundStyle(tint.opacity(0.25))
                    LineMark(x: .value("t", index), y: .value("v", point))
                        .foregroundStyle(tint)
                }
                if let secondHistory {
                    ForEach(Array(secondHistory.enumerated()), id: \.offset) { index, point in
                        LineMark(x: .value("t", index), y: .value("up", point), series: .value("s", "up"))
                            .foregroundStyle(Color.pink)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...(SystemMonitorModel.historyLength - 1))
            .chartYScale(domain: 0...yMax)
            .frame(height: 54)
        }
    }

    private var yMax: Double {
        if let maximum { return maximum }
        return max((history + (secondHistory ?? [])).max() ?? 1, 1024)
    }
}

// MARK: - Форматирование

func percent(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded())) %"
}

func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
}

func speed(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/с"
}

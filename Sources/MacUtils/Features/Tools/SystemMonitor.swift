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

    /// Для снимков интерфейса: демонстрационные значения, выборка не запускается.
    private(set) var isDemo = false

    static func demo() -> SystemMonitorModel {
        let model = SystemMonitorModel()
        model.isDemo = true
        model.cpu = 0.32
        model.memory = SystemStats.Memory(total: 16 << 30, used: 11 << 30, wired: 2 << 30, compressed: 1 << 30, app: 6 << 30)
        model.disk = SystemStats.Disk(total: 500_000_000_000, available: 210_000_000_000)
        model.download = 2_400_000
        model.upload = 380_000
        model.battery = SystemStats.Battery(percent: 78, charging: false, onAC: true)
        let wave = (0..<historyLength).map { 0.25 + 0.15 * sin(Double($0) / 6) }
        model.cpuHistory = wave
        model.memoryHistory = wave.map { $0 + 0.4 }
        model.downloadHistory = wave.map { $0 * 4_000_000 }
        model.uploadHistory = wave.map { $0 * 600_000 }
        return model
    }

    private var timer: Timer?
    private var lastTicks: [SystemStats.CPUTicks] = []
    private var lastNetwork: (received: UInt64, sent: UInt64) = (0, 0)
    private var lastSample = Date()
    private var users = 0

    /// Вкладки включают выборку, пока они на экране (`onScreen`: и закрытие окна тоже выключает).
    func start() {
        guard !isDemo else { return }
        users += 1
        guard timer == nil else { return }
        lastTicks = SystemStats.cpuTicks()
        lastNetwork = SystemStats.networkBytes()
        lastSample = Date()
        sample()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { SystemMonitorModel.shared.sample() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard !isDemo else { return }
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
    var compact = false

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: compact ? 160 : 280), spacing: compact ? 10 : 14)] }

    var body: some View {
        ToolsPageFrame(.monitor, compact: compact) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: compact ? 10 : 14) {
                    MonitorCard(title: "Процессор", symbol: "cpu", tint: .dsAccLine,
                                value: percent(model.cpu),
                                detail: "\(model.cores) \(plural(model.cores, "ядро", "ядра", "ядер"))",
                                history: model.cpuHistory, maximum: 1)
                    MonitorCard(title: "Память", symbol: "memorychip", tint: .dsBlue,
                                value: model.memory.map { percent($0.fraction) } ?? "—",
                                detail: model.memory.map { "\(bytes($0.used)) из \(bytes($0.total)) · сжато \(bytes($0.compressed))" } ?? "",
                                history: model.memoryHistory, maximum: 1)
                    MonitorCard(title: "Сеть", symbol: "network", tint: .dsBlue,
                                value: "↓ \(speed(model.download))",
                                detail: "↑ \(speed(model.upload))",
                                history: model.downloadHistory, maximum: nil,
                                secondHistory: model.uploadHistory)
                    diskCard
                    statusCard
                }
                .padding(compact ? 10 : 0)
            }
        }
        .environment(\.compactCards, compact)
        .onScreen { $0 ? model.start() : model.stop() }
    }

    private var diskCard: some View {
        CardShell(title: "Диск", symbol: "internaldrive") {
            if let disk = model.disk {
                Text(percent(disk.fraction)).font(CardShell<EmptyView>.valueFont(compact)).foregroundStyle(.dsText).monospacedDigit()
                ProgressBar(value: disk.fraction)
                Text("Свободно \(bytes(UInt64(disk.available))) из \(bytes(UInt64(disk.total)))")
                    .font(DS.Font.rowSub).foregroundStyle(.dsMute)
            } else {
                Text("—").font(DS.Font.rowTitle).foregroundStyle(.dsMute)
            }
        }
    }

    private var statusCard: some View {
        CardShell(title: "Система", symbol: "gauge.with.dots.needle.33percent") {
            if let battery = model.battery {
                line("Батарея \(battery.percent) %\(battery.charging ? " · заряжается" : battery.onAC ? " · от сети" : "")",
                     symbol: battery.charging ? "battery.100.bolt" : "battery.75")
            }
            line("Нагрев: \(thermalText)", symbol: "thermometer.medium")
            line("Работает \(uptime)", symbol: "clock")
        }
    }

    private func line(_ text: String, symbol: String) -> some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.dsMute).frame(width: 20)
                .accessibilityHidden(true)
            Text(text).font(DS.Font.bodyStrong).foregroundStyle(.dsText)
        }
        .accessibilityElement(children: .combine)
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

private struct CompactCardsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var compactCards: Bool {
        get { self[CompactCardsKey.self] }
        set { self[CompactCardsKey.self] = newValue }
    }
}

/// Карточка монитора: в окне — `panel` с обводкой, в панели из строки меню — `field`.
private struct CardShell<Content: View>: View {
    @Environment(\.compactCards) private var compact
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    static func valueFont(_ compact: Bool) -> Font { DS.Font.manrope(compact ? 20 : 28, .heavy, relativeTo: .title) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: symbol).font(.system(size: compact ? 12 : 14, weight: .medium)).foregroundStyle(.dsMute)
                    .accessibilityHidden(true)
                Text(title.uppercased()).font(DS.Font.groupLabel).tracking(DS.Font.tracking(0.12, size: 11)).foregroundStyle(.dsMute)
            }
            content
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 96 : 150, alignment: .topLeading)
        .padding(compact ? 12 : 16)
        .background(compact ? Color.dsField : Color.dsPanel, in: shape)
        .overlay { if !compact { shape.strokeBorder(Color.dsLine, lineWidth: 1) } }
        .accessibilityElement(children: .combine)
    }
}

private struct MonitorCard: View {
    @Environment(\.compactCards) private var compact
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
        CardShell(title: title, symbol: symbol) {
            Text(value).font(CardShell<EmptyView>.valueFont(compact)).foregroundStyle(.dsText).monospacedDigit()
            Text(detail).font(DS.Font.rowSub).foregroundStyle(.dsMute).lineLimit(1)
            Chart {
                ForEach(Array(history.enumerated()), id: \.offset) { index, point in
                    AreaMark(x: .value("t", index), y: .value("v", point))
                        .foregroundStyle(tint.opacity(0.18))
                    LineMark(x: .value("t", index), y: .value("v", point))
                        .foregroundStyle(tint)
                }
                if let secondHistory {
                    ForEach(Array(secondHistory.enumerated()), id: \.offset) { index, point in
                        LineMark(x: .value("t", index), y: .value("up", point), series: .value("s", "up"))
                            .foregroundStyle(Color.dsRec)
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...(SystemMonitorModel.historyLength - 1))
            .chartYScale(domain: 0...yMax)
            .frame(height: compact ? 28 : 54)
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
    // Без allowsNonnumericFormatting = false форматтер пишет «Zero KB» вместо «0 КБ».
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: Int64(max(0, bytesPerSecond))) + "/с"
}

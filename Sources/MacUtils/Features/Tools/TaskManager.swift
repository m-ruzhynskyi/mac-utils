import AppKit
import Darwin
import SwiftUI

/// Процесс в «Диспетчере задач».
struct ProcessRow: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    let isApp: Bool
    let user: String
    /// Загрузка процессора, % одного ядра (как в Мониторе активности).
    var cpu: Double
    /// Занимаемая память (phys_footprint), байты.
    var memory: UInt64

    var id: pid_t { pid }
}

/// Расчёт загрузки по процессорному времени (без системных вызовов — для тестов).
enum ProcessMath {
    /// Процент одного ядра за интервал: Δ процессорного времени / Δ реального времени.
    static func cpuPercent(previousNanos: UInt64, currentNanos: UInt64, elapsedNanos: UInt64) -> Double {
        guard elapsedNanos > 0, currentNanos >= previousNanos else { return 0 }
        return Double(currentNanos - previousNanos) / Double(elapsedNanos) * 100
    }

    enum Sort: String, CaseIterable, Identifiable {
        case cpu, memory, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cpu: return "Процессор"
            case .memory: return "Память"
            case .name: return "Имя"
            }
        }
    }

    static func sorted(_ rows: [ProcessRow], by sort: Sort) -> [ProcessRow] {
        rows.sorted {
            switch sort {
            case .cpu: return $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.pid < $1.pid
            case .memory: return $0.memory != $1.memory ? $0.memory > $1.memory : $0.pid < $1.pid
            case .name: return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }
}

@MainActor
final class TaskManagerModel: ObservableObject {
    static let shared = TaskManagerModel()

    @Published private(set) var rows: [ProcessRow] = []
    @Published var sort: ProcessMath.Sort = .cpu
    @Published var appsOnly = true
    @Published var search = ""
    @Published var selection: pid_t?
    @Published private(set) var lastError: String?

    private var timer: Timer?
    private var lastTimes: [pid_t: UInt64] = [:]
    private var lastSample: UInt64 = 0
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    var visible: [ProcessRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let filtered = rows.filter { (!appsOnly || $0.isApp)
            && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query) }
        return ProcessMath.sorted(filtered, by: sort)
    }

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { TaskManagerModel.shared.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sample() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let elapsed = lastSample > 0 ? now - lastSample : 0
        lastSample = now

        let apps = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) },
                              uniquingKeysWith: { first, _ in first })
        var times: [pid_t: UInt64] = [:]
        var result: [ProcessRow] = []
        for pid in Self.allPIDs() where pid > 0 {
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
                }
            }
            let app = apps[pid]
            let name = app?.localizedName ?? ProcessInfo.processName(pid) ?? "pid \(pid)"
            var cpu = 0.0
            var memory: UInt64 = 0
            if ok {
                let nanos = (usage.ri_user_time + usage.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
                times[pid] = nanos
                if let previous = lastTimes[pid], elapsed > 0 {
                    cpu = ProcessMath.cpuPercent(previousNanos: previous, currentNanos: nanos, elapsedNanos: elapsed)
                }
                memory = usage.ri_phys_footprint
            }
            result.append(ProcessRow(pid: pid, name: name,
                                     isApp: app.map { $0.activationPolicy == .regular } ?? false,
                                     user: Self.userName(of: pid), cpu: cpu, memory: memory))
        }
        lastTimes = times
        rows = result
    }

    // MARK: - Завершение

    func quit(_ pid: pid_t, force: Bool) {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else {
            lastError = "Этот процесс завершать нельзя"
            return
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else if kill(pid, force ? SIGKILL : SIGTERM) != 0 {
            lastError = errno == EPERM
                ? "Нет прав: процесс принадлежит системе или другому пользователю"
                : "Не удалось завершить процесс (\(String(cString: strerror(errno))))"
            return
        }
        lastError = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            MainActor.assumeIsolated { TaskManagerModel.shared.sample() }
        }
    }

    // MARK: - Системные вызовы

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(filled, 0))))
    }

    private static var userNames: [uid_t: String] = [:]

    private static func userName(of pid: pid_t) -> String {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return "" }
        let uid = info.pbsi_uid
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        userNames[uid] = name
        return name
    }
}

struct TaskManagerView: View {
    @ObservedObject var model: TaskManagerModel
    var compact = false
    @State private var confirmForce: ProcessRow?
    @State private var explaining: ProcessRow?
    @ObservedObject private var ai = ProcessExplainer.shared
    @AppStorage(Pref.ai) private var aiEnabled = true
    @AppStorage(Pref.aiTasks) private var aiTasks = true
    private var aiOn: Bool { aiEnabled && aiTasks }

    private func explain(_ row: ProcessRow) {
        ai.explain(row)
        explaining = row
    }

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("Поиск", text: $model.search).textFieldStyle(.roundedBorder)
                        Toggle("Приложения", isOn: $model.appsOnly).toggleStyle(.checkbox)
                    }
                    Picker("Сортировка", selection: $model.sort) {
                        ForEach(ProcessMath.Sort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(8)
            } else {
                HStack(spacing: 10) {
                    TextField("Поиск по имени или PID", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Picker("Сортировка", selection: $model.sort) {
                        ForEach(ProcessMath.Sort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .labelsHidden()
                    Toggle("Только приложения", isOn: $model.appsOnly)
                    Spacer(minLength: 0)
                }
                .padding(10)
            }

            List(selection: $model.selection) {
                ForEach(model.visible) { row in
                    ProcessLine(row: row, compact: compact, category: aiOn ? ai.categories[row.name] : nil).tag(row.pid)
                        .contextMenu {
                            if aiOn {
                                Button("Что это за процесс?") { explain(row) }
                                Divider()
                            }
                            Button("Завершить") { model.quit(row.pid, force: false) }
                            Button("Завершить принудительно") { confirmForce = row }
                        }
                }
            }

            HStack(spacing: 10) {
                if let error = model.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer()
                if aiOn {
                    if ai.categorizing { ProgressView().controlSize(.small) }
                    Button {
                        if let pid = model.selection, let row = model.rows.first(where: { $0.pid == pid }) {
                            explain(row)
                        } else {
                            ai.categorize(model.visible)
                        }
                    } label: { Image(systemName: "sparkles") }
                    .help("ИИ: выбран процесс — объяснить, что это и можно ли закрыть; не выбран — разложить список по категориям")
                    .popover(item: $explaining, arrowEdge: .top) { row in
                        ProcessExplanation(row: row, ai: ai)
                    }
                }
                Text(compact ? "\(model.visible.count)" : "Процессов: \(model.visible.count)").foregroundStyle(.secondary).monospacedDigit()
                    .help("Процессов в списке")
                Button(compact ? "Стоп" : "Завершить") { if let pid = model.selection { model.quit(pid, force: false) } }
                    .help("Завершить выбранный процесс")
                    .disabled(model.selection == nil)
                Button(compact ? "Убить" : "Принудительно") {
                    if let pid = model.selection { confirmForce = model.rows.first { $0.pid == pid } }
                }
                .disabled(model.selection == nil)
            }
            .padding(10)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .alert(item: $confirmForce) { row in
            Alert(title: Text("Завершить «\(row.name)» принудительно?"),
                  message: Text("Несохранённые данные будут потеряны."),
                  primaryButton: .destructive(Text("Завершить")) { model.quit(row.pid, force: true) },
                  secondaryButton: .cancel(Text("Отмена")))
        }
    }
}

private struct ProcessExplanation: View {
    let row: ProcessRow
    @ObservedObject var ai: ProcessExplainer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(row.name).font(.headline).lineLimit(1)
            }
            if let info = ai.infos[row.name] {
                Text(info.category).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(info.what).fixedSize(horizontal: false, vertical: true)
                Label(info.safe == "да" ? "Можно завершить" : info.safe == "нет" ? "Лучше не завершать" : "Осторожно",
                      systemImage: info.safe == "да" ? "checkmark.circle.fill" : info.safe == "нет" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(info.safe == "да" ? .green : info.safe == "нет" ? .red : .orange)
                Text(info.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Ответ локальной модели — может ошибаться.").font(.caption2).foregroundStyle(.tertiary)
            } else if let error = ai.error, !ai.busy.contains(row.name) {
                Text(error).foregroundStyle(.orange)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Спрашиваю модель…").foregroundStyle(.secondary) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct ProcessLine: View {
    let row: ProcessRow
    var compact = false
    var category: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSRunningApplication(processIdentifier: row.pid)?.icon
                  ?? NSWorkspace.shared.icon(for: .unixExecutable))
                .resizable().frame(width: compact ? 16 : 20, height: compact ? 16 : 20)
            if compact {
                Text(row.name).lineLimit(1).truncationMode(.tail)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name).lineLimit(1).truncationMode(.tail)
                    Text("PID \(row.pid) · \(row.user)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let category {
                Text(category).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            Text(String(format: "%.1f %%", row.cpu))
                .monospacedDigit()
                .foregroundStyle(row.cpu > 80 ? .red : .primary)
                .frame(width: compact ? 54 : 70, alignment: .trailing)
            Text(bytes(row.memory))
                .monospacedDigit()
                .frame(width: compact ? 68 : 90, alignment: .trailing)
        }
    }
}

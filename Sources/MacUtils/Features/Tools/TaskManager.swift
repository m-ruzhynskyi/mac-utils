import AppKit
import Darwin
import SwiftUI
import MUCore
import MUDesign
import MUAudio
import MUTextEditor

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
    /// Кем был PID, когда строка попала в список: PID может смениться до нажатия «Завершить».
    var identity = ProcessIdentity(bundleID: nil, startTime: nil)
    /// Нагрузку удалось прочитать. У процессов root и других пользователей macOS без прав администратора её не отдаёт.
    var statsKnown = true

    var id: pid_t { pid }
}

/// Отпечаток процесса: по нему перед завершением проверяем, что PID всё ещё та же программа.
struct ProcessIdentity: Equatable {
    var bundleID: String?
    /// Время запуска процесса (секунды с 1970), если ОС его сообщила.
    var startTime: TimeInterval?

    /// Тот же процесс: bundle id совпадает, а времена запуска (если известны обоим) различаются не больше чем на секунду.
    /// `actual == nil` — процесса больше нет.
    static func isSame(expected: ProcessIdentity, actual: ProcessIdentity?) -> Bool {
        guard let actual else { return false }
        if expected.bundleID != actual.bundleID { return false }
        if let a = expected.startTime, let b = actual.startTime { return abs(a - b) <= 1 }
        return true
    }
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
            // Процессы с неизвестной нагрузкой — в конце, а не вперемешку с настоящими нулями.
            case .cpu where $0.statsKnown != $1.statsKnown, .memory where $0.statsKnown != $1.statsKnown:
                return $0.statsKnown
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

    /// Для снимков интерфейса: демонстрационные строки, процессы системы не читаются.
    private(set) var isDemo = false

    static func demo() -> TaskManagerModel {
        let model = TaskManagerModel()
        model.isDemo = true
        let items: [(String, Double, UInt64)] = [("Safari", 12.4, 840 << 20), ("Xcode", 8.1, 2_100 << 20), ("Terminal", 1.2, 120 << 20),
                                                 ("Figma", 0.8, 560 << 20), ("Notes", 0.2, 90 << 20), ("Mail", 0.1, 210 << 20)]
        model.rows = items.enumerated().map { index, item in
            ProcessRow(pid: pid_t(1000 + index), name: item.0, isApp: true, user: "demo", cpu: item.1, memory: item.2)
        }
        model.selection = 1002
        return model
    }

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

    /// Сколько видов «Задач» на экране (`onScreen`): настройки, окно «Инструменты», панель. Выборка — только пока > 0:
    /// onDisappear при закрытии окна не приходит, и раньше перебор процессов шёл раз в 2 с и с закрытыми настройками.
    private(set) var viewers = ViewerCount()
    var isSampling: Bool { timer != nil }

    func viewerChanged(_ shown: Bool) {
        viewers.update(shown)
        viewers.any ? start() : stop()
    }

    private func start() {
        guard !isDemo, timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { TaskManagerModel.shared.sample() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Имя из таблицы процессов ядра (как у `ps`): доступно и для процессов root, когда proc_name отказывает.
    nonisolated static func kernelName(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return name.isEmpty ? nil : name
    }

    func sample() {
        guard !isDemo else { return }
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
            let name = app?.localizedName ?? ProcessInfo.processName(pid) ?? Self.kernelName(of: pid) ?? "pid \(pid)"
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
                                     user: Self.userName(of: pid), cpu: cpu, memory: memory,
                                     identity: Self.identity(of: pid, app: app) ?? ProcessIdentity(bundleID: nil, startTime: nil),
                                     statsKnown: ok))
        }
        lastTimes = times
        rows = result
    }

    // MARK: - Завершение

    func quit(_ row: ProcessRow, force: Bool) {
        let pid = row.pid
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else {
            lastError = "Этот процесс завершать нельзя"
            return
        }
        // Между списком и нажатием PID мог перейти к другой программе — её не трогаем.
        let app = NSRunningApplication(processIdentifier: pid)
        guard ProcessIdentity.isSame(expected: row.identity, actual: Self.identity(of: pid, app: app)) else {
            lastError = "«\(row.name)» уже закрыта или PID занят другой программой — список обновлён"
            sample()
            return
        }
        if let app {
            let accepted = force ? app.forceTerminate() : app.terminate()
            if !accepted {
                lastError = "«\(row.name)» не приняла запрос на завершение"
                return
            }
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

    /// Отпечаток через sysctl: время запуска отдаётся и для процессов root и других пользователей
    /// (`proc_pidinfo` для них не работает). nil — процесса нет.
    static func identity(of pid: pid_t, app: NSRunningApplication?) -> ProcessIdentity? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_starttime
        let start = TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
        return ProcessIdentity(bundleID: app?.bundleIdentifier, startTime: start)
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
        ToolsPageFrame(.tasks, compact: compact) {
            VStack(spacing: compact ? 0 : DS.Space.m) {
                toolbar
                processList
                if let error = model.lastError {
                    Banner(.warning, title: error)
                        .padding(.horizontal, compact ? DS.Space.s : 0)
                        .padding(.top, compact ? DS.Space.s : 0)
                }
                bottomBar
            }
        }
        .onScreen { model.viewerChanged($0) }
        .alert(item: $confirmForce) { row in
            Alert(title: Text("Завершить «\(row.name)» принудительно?"),
                  message: Text("Несохранённые данные будут потеряны."),
                  primaryButton: .destructive(Text("Завершить")) { model.quit(row, force: true) },
                  secondaryButton: .cancel(Text("Отмена")))
        }
    }

    private var sortOptions: [(value: ProcessMath.Sort, title: String)] {
        ProcessMath.Sort.allCases.map { (value: $0, title: $0.title) }
    }

    /// Верхняя панель: поиск на всю ширину; под ним — сортировка на всю оставшуюся ширину и фильтр «только программы».
    private var toolbar: some View {
        VStack(spacing: DS.Space.s) {
            ToolsSearchField(prompt: compact ? "Поиск" : "Поиск по имени или PID", text: $model.search)
            HStack(spacing: DS.Space.s) {
                ToolsSegmented(selection: $model.sort, options: sortOptions)
                Chip(compact ? "Программы" : "Только программы", selected: model.appsOnly) { model.appsOnly.toggle() }
                    .fixedSize()
                    .help("Показывать только программы, без фоновых процессов")
            }
        }
        .padding(.horizontal, compact ? DS.Space.s : 0)
        .padding(.top, compact ? DS.Space.s : 0)
        .padding(.bottom, compact ? DS.Space.s : 0)
    }

    private var processList: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(model.visible) { row in
                    let selected = model.selection == row.pid
                    ProcessLine(row: row, compact: compact, category: aiOn ? ai.categories[row.name] : nil)
                        .padding(.horizontal, 10)
                        .background(selected ? Color.dsField : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { model.selection = row.pid }
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .contextMenu {
                            if aiOn {
                                Button("Что это за процесс?") { explain(row) }
                                Divider()
                            }
                            Button("Завершить") { model.quit(row, force: false) }
                            Button("Завершить принудительно") { confirmForce = row }
                        }
                }
            }
            .padding(DS.Space.xs)
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let rows = model.visible
            guard !rows.isEmpty else { return }
            let current = rows.firstIndex { $0.pid == model.selection }
            switch direction {
            case .down: model.selection = rows[min((current ?? -1) + 1, rows.count - 1)].pid
            case .up: model.selection = rows[max((current ?? rows.count) - 1, 0)].pid
            default: break
            }
        }
        .background(compact ? Color.clear : Color.dsPanel, in: shape)
        .overlay { if !compact { shape.strokeBorder(Color.dsLine, lineWidth: 1) } }
        .clipShape(shape)
        .padding(.horizontal, compact ? DS.Space.s : 0)
    }

    private var bottomBar: some View {
        ToolsBar(compact: compact) {
            if aiOn {
                if ai.categorizing { ProgressView().controlSize(.small) }
                IconButton("ИИ: выбран процесс — объяснить, что это и можно ли закрыть; не выбран — разложить список по категориям",
                           systemImage: "sparkles", compact: true) {
                    if let pid = model.selection, let row = model.rows.first(where: { $0.pid == pid }) {
                        explain(row)
                    } else {
                        ai.categorize(model.visible)
                    }
                }
                .popover(item: $explaining, arrowEdge: .top) { row in
                    ProcessExplanation(row: row, ai: ai)
                }
            }
            Text("\(model.visible.count) \(plural(model.visible.count, "процесс", "процесса", "процессов"))")
                .font(DS.Font.manrope(13, .semibold, relativeTo: .callout)).foregroundStyle(.dsMute)
                .lineLimit(1).fixedSize()
                .help("Процессов в списке")
            Spacer(minLength: DS.Space.s)
            Button(compact ? "Стоп" : "Завершить") {
                if let pid = model.selection, let row = model.rows.first(where: { $0.pid == pid }) { model.quit(row, force: false) }
            }
            .buttonStyle(.graphite(.secondary, size: .compact))
            .help("Завершить выбранный процесс")
            .disabled(model.selection == nil)
            Button(compact ? "Убить" : "Принудительно") {
                if let pid = model.selection { confirmForce = model.rows.first { $0.pid == pid } }
            }
            .buttonStyle(.graphite(.danger, size: .compact))
            .disabled(model.selection == nil)
        }
    }
}

private struct ProcessExplanation: View {
    let row: ProcessRow
    @ObservedObject var ai: ProcessExplainer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.dsAccText)
                Text(row.name).font(DS.Font.rowTitle).foregroundStyle(.dsText).lineLimit(1)
            }
            if let info = ai.infos[row.name] {
                let tone: DS.Tone = info.safe == "да" ? .success : info.safe == "нет" ? .danger : .warning
                Text(info.category).font(DS.Font.caption).foregroundStyle(.dsMute)
                Text(info.what).font(DS.Font.body).foregroundStyle(.dsText).fixedSize(horizontal: false, vertical: true)
                Pill(tone, info.safe == "да" ? "Можно завершить" : info.safe == "нет" ? "Лучше не завершать" : "Осторожно")
                Text(info.why).font(DS.Font.rowSub).foregroundStyle(.dsMute).fixedSize(horizontal: false, vertical: true)
                Text("Ответ локальной модели — может ошибаться.").font(DS.Font.rowSub).foregroundStyle(.dsMute)
            } else if let error = ai.error, !ai.busy.contains(row.name) {
                Text(error).font(DS.Font.body).foregroundStyle(Color.dsRec)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Спрашиваю модель…").font(DS.Font.body).foregroundStyle(.dsMute) }
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
                .resizable().frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
            if compact {
                Text(row.name).font(DS.Font.bodyStrong).foregroundStyle(.dsText).lineLimit(1).truncationMode(.tail)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.name).font(DS.Font.bodyStrong).foregroundStyle(.dsText).lineLimit(1).truncationMode(.tail)
                    Text("PID \(row.pid) · \(row.user)").font(DS.Font.rowSub).foregroundStyle(.dsMute)
                }
            }
            Spacer(minLength: 8)
            if let category {
                Text(category).font(DS.Font.rowSub).foregroundStyle(.dsMute).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.dsField, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.dsLine, lineWidth: 1))
            }
            Text(row.statsKnown ? String(format: "%.1f %%", row.cpu) : "—")
                .font(DS.Font.mono(13, relativeTo: .callout))
                .foregroundStyle(row.cpu > 80 ? Color.dsRec : (row.statsKnown ? .dsText : .dsMute))
                .frame(width: compact ? 58 : 72, alignment: .trailing)
                .help(row.statsKnown ? "" : "Системный процесс: macOS не сообщает его нагрузку без прав администратора")
            Text(row.statsKnown ? bytes(row.memory) : "—")
                .font(DS.Font.mono(13, relativeTo: .callout))
                .foregroundStyle(.dsMute)
                .frame(width: compact ? 70 : 92, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

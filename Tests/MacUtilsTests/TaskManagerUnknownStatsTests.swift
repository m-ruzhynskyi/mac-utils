import XCTest
@testable import MacUtils
@testable import MUAudio

/// Процессы root и других пользователей: имя из таблицы ядра, нагрузка неизвестна — в конце списка, без фальшивых нулей.
final class TaskManagerUnknownStatsTests: XCTestCase {
    private func row(_ pid: pid_t, _ name: String, cpu: Double, memory: UInt64, known: Bool = true) -> ProcessRow {
        ProcessRow(pid: pid, name: name, isApp: false, user: "u", cpu: cpu, memory: memory, statsKnown: known)
    }

    func testUnknownStatsGoLastForCPUAndMemory() {
        let rows = [row(1, "launchd", cpu: 0, memory: 0, known: false), row(2, "Safari", cpu: 3, memory: 100),
                    row(3, "idle", cpu: 0, memory: 10)]
        XCTAssertEqual(ProcessMath.sorted(rows, by: .cpu).map(\.pid), [2, 3, 1])
        XCTAssertEqual(ProcessMath.sorted(rows, by: .memory).map(\.pid), [2, 3, 1])
        XCTAssertEqual(ProcessMath.sorted(rows, by: .name).map(\.name), ["idle", "launchd", "Safari"])
    }

    func testKernelNameReadsLaunchd() {
        XCTAssertEqual(TaskManagerModel.kernelName(of: 1), "launchd", "имя процесса root доступно без прав администратора")
        XCTAssertNil(TaskManagerModel.kernelName(of: -1))
    }
}

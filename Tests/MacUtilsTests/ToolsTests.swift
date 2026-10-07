import XCTest
@testable import MacUtils

final class SystemStatsTests: XCTestCase {
    func testCPUUsageAcrossCores() {
        let before = [SystemStats.CPUTicks(user: 100, system: 50, idle: 850, nice: 0),
                      SystemStats.CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        let after = [SystemStats.CPUTicks(user: 150, system: 100, idle: 850, nice: 0),   // +100 busy, +0 idle
                     SystemStats.CPUTicks(user: 0, system: 0, idle: 1100, nice: 0)]      // +100 idle
        XCTAssertEqual(SystemStats.cpuUsage(previous: before, current: after), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SystemStats.cpuUsage(previous: after, current: after), 0)
    }

    func testMemoryLikeActivityMonitor() {
        let memory = SystemStats.memory(pageSize: 16_384, internalPages: 100_000, purgeablePages: 10_000,
                                        wiredPages: 50_000, compressedPages: 20_000, total: 16 << 30)
        XCTAssertEqual(memory.app, 90_000 * 16_384)
        XCTAssertEqual(memory.used, (90_000 + 50_000 + 20_000) * 16_384)
        XCTAssertEqual(memory.fraction, Double(memory.used) / Double(16 << 30), accuracy: 0.0001)
        // Не больше всей памяти.
        let capped = SystemStats.memory(pageSize: 16_384, internalPages: 2_000_000, purgeablePages: 0,
                                        wiredPages: 0, compressedPages: 0, total: 1 << 30)
        XCTAssertEqual(capped.used, 1 << 30)
    }

    func testNetworkRate() {
        XCTAssertEqual(SystemStats.rate(previous: 1000, current: 3000, seconds: 2), 1000)
        XCTAssertEqual(SystemStats.rate(previous: 3000, current: 1000, seconds: 1), 0, "переполнение счётчика")
        XCTAssertEqual(SystemStats.rate(previous: 0, current: 10, seconds: 0), 0)
    }

    func testLiveReadingsAreSane() {
        XCTAssertFalse(SystemStats.cpuTicks().isEmpty)
        let memory = try? XCTUnwrap(SystemStats.memory())
        XCTAssertGreaterThan(memory?.used ?? 0, 0)
        XCTAssertGreaterThan(SystemStats.disk()?.total ?? 0, 0)
    }
}

final class ProcessMathTests: XCTestCase {
    func testCPUPercent() {
        XCTAssertEqual(ProcessMath.cpuPercent(previousNanos: 0, currentNanos: 1_000_000_000, elapsedNanos: 2_000_000_000), 50)
        XCTAssertEqual(ProcessMath.cpuPercent(previousNanos: 0, currentNanos: 4_000_000_000, elapsedNanos: 2_000_000_000), 200,
                       "несколько ядер — больше 100 %")
        XCTAssertEqual(ProcessMath.cpuPercent(previousNanos: 5, currentNanos: 1, elapsedNanos: 10), 0)
    }

    func testSorting() {
        let rows = [ProcessRow(pid: 3, name: "beta", isApp: true, user: "u", cpu: 5, memory: 100),
                    ProcessRow(pid: 1, name: "Alpha", isApp: true, user: "u", cpu: 50, memory: 10),
                    ProcessRow(pid: 2, name: "gamma", isApp: false, user: "u", cpu: 5, memory: 1000)]
        XCTAssertEqual(ProcessMath.sorted(rows, by: .cpu).map(\.pid), [1, 2, 3])
        XCTAssertEqual(ProcessMath.sorted(rows, by: .memory).map(\.pid), [2, 3, 1])
        XCTAssertEqual(ProcessMath.sorted(rows, by: .name).map(\.name), ["Alpha", "beta", "gamma"])
    }
}

final class CleanupCategoryTests: XCTestCase {
    func testDownloadsOnlyOlderThan30Days() throws {
        let downloads = try XCTUnwrap(CleanupCategory.all().first { $0.kind == .downloads })
        let now = Date()
        XCTAssertTrue(downloads.includes(name: "old.zip", modified: now.addingTimeInterval(-31 * 86_400), now: now))
        XCTAssertFalse(downloads.includes(name: "new.zip", modified: now.addingTimeInterval(-5 * 86_400), now: now))
        XCTAssertFalse(downloads.includes(name: ".DS_Store", modified: .distantPast, now: now))
        XCTAssertFalse(downloads.checkedByDefault)
    }

    func testCachesIncludeEverythingVisible() throws {
        let caches = try XCTUnwrap(CleanupCategory.all().first { $0.kind == .caches })
        XCTAssertTrue(caches.includes(name: "com.example.app", modified: nil))
        XCTAssertFalse(caches.includes(name: ".hidden", modified: nil))
        XCTAssertTrue(caches.checkedByDefault)
        XCTAssertFalse(caches.permanent)
    }

    func testOnlyTrashIsPermanent() {
        let permanent = CleanupCategory.all().filter(\.permanent).map(\.kind)
        XCTAssertEqual(permanent, [.trash])
    }
}

@MainActor
final class TaskManagerSamplingTests: XCTestCase {
    func testSamplesOwnProcessWithMemoryAndCPU() throws {
        let model = TaskManagerModel.shared
        model.sample()
        // Немного нагрузим процессор между замерами.
        var x = 0.0
        let end = Date().addingTimeInterval(0.3)
        while Date() < end { x += sin(x + 1) }
        model.sample()
        let own = try XCTUnwrap(model.rows.first { $0.pid == ProcessInfo.processInfo.processIdentifier })
        XCTAssertGreaterThan(own.memory, 1_000_000)
        XCTAssertGreaterThan(own.cpu, 10, "процесс крутился ~0.3 с")
        XCTAssertGreaterThan(model.rows.count, 50)
        XCTAssertFalse(own.user.isEmpty)
        _ = x
    }
}

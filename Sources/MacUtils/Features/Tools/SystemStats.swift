import Darwin
import Foundation
import IOKit.ps

/// Снимки системных счётчиков и расчёты по ним (без UI — для тестов).
enum SystemStats {
    // MARK: - Процессор

    /// Такты одного ядра: пользователь, система, простой, nice.
    struct CPUTicks: Equatable {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        var busy: UInt64 { user + system + nice }
        var total: UInt64 { busy + idle }
    }

    /// Загрузка (0…1) между двумя снимками; ядра суммируются.
    static func cpuUsage(previous: [CPUTicks], current: [CPUTicks]) -> Double {
        var busy: UInt64 = 0, total: UInt64 = 0
        for (a, b) in zip(previous, current) {
            busy += b.busy &- a.busy
            total += b.total &- a.total
        }
        guard total > 0 else { return 0 }
        return min(max(Double(busy) / Double(total), 0), 1)
    }

    static func cpuTicks() -> [CPUTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { cpu in
            let base = cpu * states
            return CPUTicks(user: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                            system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                            idle: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                            nice: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
    }

    // MARK: - Память

    struct Memory: Equatable {
        var total: UInt64
        var used: UInt64
        var wired: UInt64
        var compressed: UInt64
        var app: UInt64

        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    /// «Используется» как в Мониторе активности: память приложений + связанная + сжатая.
    static func memory(pageSize: UInt64, internalPages: UInt64, purgeablePages: UInt64,
                       wiredPages: UInt64, compressedPages: UInt64, total: UInt64) -> Memory {
        let app = (internalPages &- min(purgeablePages, internalPages)) * pageSize
        let wired = wiredPages * pageSize
        let compressed = compressedPages * pageSize
        return Memory(total: total, used: min(app + wired + compressed, total), wired: wired,
                      compressed: compressed, app: app)
    }

    static func memory() -> Memory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return memory(pageSize: UInt64(vm_kernel_page_size), internalPages: UInt64(stats.internal_page_count),
                      purgeablePages: UInt64(stats.purgeable_count), wiredPages: UInt64(stats.wire_count),
                      compressedPages: UInt64(stats.compressor_page_count),
                      total: ProcessInfo.processInfo.physicalMemory)
    }

    // MARK: - Диск

    struct Disk: Equatable {
        var total: Int64
        var available: Int64
        var used: Int64 { max(total - available, 0) }
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    static func disk() -> Disk? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity else { return nil }
        return Disk(total: Int64(total), available: values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    // MARK: - Сеть

    /// Байты (принято, отправлено) по всем интерфейсам, кроме loopback.
    static func networkBytes() -> (received: UInt64, sent: UInt64) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return (0, 0) }
        defer { freeifaddrs(pointer) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let interface = entry.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               (interface.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
               let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                received += UInt64(data.pointee.ifi_ibytes)
                sent += UInt64(data.pointee.ifi_obytes)
            }
            cursor = interface.ifa_next
        }
        return (received, sent)
    }

    /// Скорость в байтах/с; счётчики 32-битные и могут переполняться.
    static func rate(previous: UInt64, current: UInt64, seconds: Double) -> Double {
        guard seconds > 0, current >= previous else { return 0 }
        return Double(current - previous) / seconds
    }

    // MARK: - Батарея

    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
        var onAC: Bool
    }

    static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Battery(percent: current * 100 / max,
                           charging: (description[kIOPSIsChargingKey] as? Bool) ?? false,
                           onAC: (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }
}

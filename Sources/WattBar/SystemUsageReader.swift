import Foundation
import Darwin

struct CPUTicks {
    let user: UInt64
    let system: UInt64
    let nice: UInt64
    let idle: UInt64
}

/// A fresh baseline is needed after a failed query or a counter reset/rollover.
struct CPUUsageAccumulator {
    private var previous: CPUTicks?

    mutating func sample(_ ticks: CPUTicks?) -> Double? {
        defer { previous = ticks }
        guard let ticks, let previous,
              ticks.user >= previous.user, ticks.system >= previous.system,
              ticks.nice >= previous.nice, ticks.idle >= previous.idle else { return nil }
        let busy = Double(ticks.user - previous.user) + Double(ticks.system - previous.system)
            + Double(ticks.nice - previous.nice)
        let total = busy + Double(ticks.idle - previous.idle)
        return total > 0 ? min(100, max(0, busy / total * 100)) : nil
    }
}

final class CPUUsageReader {
    private var accumulator = CPUUsageAccumulator()

    func read() -> Double? { accumulator.sample(Self.ticks()) }

    private static func ticks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUTicks(user: UInt64(info.cpu_ticks.0), system: UInt64(info.cpu_ticks.1),
                        nice: UInt64(info.cpu_ticks.3), idle: UInt64(info.cpu_ticks.2))
    }
}

enum MemoryPressureLevel: String, CaseIterable {
    case normal, warning, critical, unknown

    init(systemValue: Int?) {
        switch systemValue {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }

    var title: String { rawValue.capitalized }
}

struct MemoryPressureReading {
    let percentage: Double
    let level: MemoryPressureLevel

    /// The kernel's available percentage matches memory_pressure's system-wide
    /// free percentage. Its complement is a pressure indicator, not memory used.
    /// Severity comes from the independent VM pressure level, never this percent.
    static func from(availablePercentage: Int?, systemLevel: Int?) -> MemoryPressureReading? {
        guard let availablePercentage, (0...100).contains(availablePercentage) else { return nil }
        return MemoryPressureReading(percentage: Double(100 - availablePercentage),
                                     level: MemoryPressureLevel(systemValue: systemLevel))
    }
}

final class MemoryPressureReader {
    func read() -> MemoryPressureReading? {
        MemoryPressureReading.from(availablePercentage: Self.integer("kern.memorystatus_level"),
                                   systemLevel: Self.integer("kern.memorystatus_vm_pressure_level"))
    }

    private static func integer(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0,
              size == MemoryLayout<Int32>.size else { return nil }
        return Int(value)
    }
}

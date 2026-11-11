import Foundation

/// What the small graph at the left of the menu bar readout shows.
enum GraphMetric: String, CaseIterable {
    case systemDraw, cpuUsage, memoryPressure, cpuTemperature, gpuDraw, networkDownload, batteryFlow, off

    var title: String {
        switch self {
        case .systemDraw: return "System Draw"
        case .cpuUsage: return "CPU Usage"
        case .memoryPressure: return "Memory Pressure"
        case .cpuTemperature: return "CPU Temperature"
        case .gpuDraw: return "GPU Draw"
        case .networkDownload: return "Network Download"
        case .batteryFlow: return "Battery Charge/Drain"
        case .off: return "Off"
        }
    }

    /// Smallest full-scale value, so a fresh install does not draw tall bars
    /// at idle. Nil for the temperature line, which scales to its own range.
    var scaleFloor: Double? {
        switch self {
        case .systemDraw, .batteryFlow: return 30
        case .gpuDraw: return 10
        case .networkDownload: return 1_000_000
        case .cpuTemperature, .cpuUsage, .memoryPressure, .off: return nil
        }
    }

    /// Battery Charge/Drain needs a battery; elsewhere the graph shows System Draw.
    func resolved(hasBattery: Bool) -> GraphMetric {
        self == .batteryFlow && !hasBattery ? .systemDraw : self
    }
}

/// How the menu bar graph draws its history.
enum GraphStyle: String, CaseIterable {
    case line, bars

    var title: String { self == .line ? "Line" : "Bars" }
}

func hasSystemBattery(_ reading: PowerReading?) -> Bool {
    guard let reading else { return false }
    return reading.batteryFlowWatts != nil && reading.powerState != PowerReading.desktopState
}

/// Values that turn orange in the menu bar, and the graph with them.
enum StatusWarning {
    static let cpuTemperatureCelsius = 85.0
    static let batteryDrainWatts = 40.0
    static let cpuUsagePercent = 90.0

    static func cpuUsageIsHigh(_ percentage: Double?) -> Bool {
        guard let percentage, percentage.isFinite else { return false }
        return percentage >= cpuUsagePercent
    }

    // Compared after rounding, so the colour agrees with the whole number shown.
    static func cpuIsHot(_ celsius: Double?) -> Bool {
        guard let celsius else { return false }
        return celsius.rounded() >= cpuTemperatureCelsius
    }

    static func batteryDrainIsHigh(_ flow: PowerFlow) -> Bool {
        guard case .discharge(let watts) = flow else { return false }
        return watts.rounded() >= batteryDrainWatts
    }
}

/// Recent readings for the menu bar graph, averaged into wall-clock buckets so
/// the bars cover the same time at every refresh interval. Held in memory
/// only; the per-metric peaks that set the scale are persisted by the caller.
struct GraphHistory {
    static let bucketCount = 11
    static let bucketDuration: TimeInterval = 30
    /// Both styles cover the same window: 11 bars of 30 s.
    static var window: TimeInterval { Double(bucketCount) * bucketDuration }
    /// Kept a little longer than the window, as finer line buckets may start earlier.
    static var retention: TimeInterval { window + bucketDuration }

    /// Line points every 15 s, or every 30 s at slower refreshes, so each
    /// bucket gets at least one reading and the line only breaks at real gaps.
    static func lineBucketDuration(refreshInterval: TimeInterval) -> TimeInterval {
        refreshInterval <= 10 ? 15 : 30
    }

    struct Sample {
        let date: Date
        let value: Double
    }

    private(set) var samples: [GraphMetric: [Sample]] = [:]
    /// Largest magnitude seen for each bar metric.
    private(set) var peaks: [GraphMetric: Double]
    private var lastDate: Date?

    init(peaks: [GraphMetric: Double] = [:]) {
        self.peaks = peaks
    }

    static func bucket(_ date: Date, duration: TimeInterval = bucketDuration) -> Int {
        Int((date.timeIntervalSince1970 / duration).rounded(.down))
    }

    mutating func add(_ values: [GraphMetric: Double?], at date: Date) {
        // A clock set backwards would leave samples "in the future"; start over.
        if let lastDate, date < lastDate { samples.removeAll() }
        lastDate = date
        for (metric, value) in values {
            guard metric != .off, let value, value.isFinite else { continue }
            samples[metric, default: []].append(Sample(date: date, value: value))
            if metric.scaleFloor != nil, abs(value) > peaks[metric] ?? 0 {
                peaks[metric] = abs(value)
            }
        }
        let cutoff = date.addingTimeInterval(-Self.retention)
        for metric in Array(samples.keys) {
            samples[metric]?.removeAll { $0.date < cutoff }
        }
    }

    /// Bucket averages, oldest first and newest (the current bucket) last;
    /// nil where nothing was recorded.
    func bars(_ metric: GraphMetric, now: Date) -> [Double?] {
        buckets(metric, now: now, duration: Self.bucketDuration)
    }

    /// Averages over the window in buckets of the given length, oldest first.
    func buckets(_ metric: GraphMetric, now: Date, duration: TimeInterval) -> [Double?] {
        let count = max(1, Int((Self.window / duration).rounded()))
        var sums = [Double](repeating: 0, count: count)
        var counts = [Int](repeating: 0, count: count)
        let newest = Self.bucket(now, duration: duration)
        for sample in samples[metric] ?? [] {
            let age = newest - Self.bucket(sample.date, duration: duration)
            guard (0..<count).contains(age) else { continue }
            sums[count - 1 - age] += sample.value
            counts[count - 1 - age] += 1
        }
        return zip(sums, counts).map { $1 == 0 ? nil : $0 / Double($1) }
    }

    /// Full-height value for bars: the highest reading seen, never below the floor.
    func scale(_ metric: GraphMetric) -> Double {
        if metric == .cpuUsage || metric == .memoryPressure { return 100 }
        return max(metric.scaleFloor ?? 1, peaks[metric] ?? 0)
    }
}

import Foundation

/// Recent CPU temperature readings for the menu's history chart. Held in
/// memory only. Wall-clock times are used so time asleep shows as a gap
/// rather than making older readings look recent.
struct TemperatureHistory {
    struct Sample {
        let date: Date
        let celsius: Double
    }

    let window: TimeInterval
    private(set) var samples: [Sample] = []

    init(window: TimeInterval = 3_600) {
        self.window = window
    }

    mutating func add(_ celsius: Double?, at date: Date) {
        // A clock set backwards would leave samples "in the future"; start over.
        if let last = samples.last, date < last.date { samples.removeAll() }
        if let celsius, celsius.isFinite {
            samples.append(Sample(date: date, celsius: celsius))
        }
        let cutoff = date.addingTimeInterval(-window)
        let firstKept = samples.firstIndex { $0.date >= cutoff } ?? samples.endIndex
        samples.removeFirst(firstKept)
    }

    var latest: Double? { samples.last?.celsius }
    var minimum: Double? { samples.map(\.celsius).min() }
    var maximum: Double? { samples.map(\.celsius).max() }
    var average: Double? {
        samples.isEmpty ? nil : samples.reduce(0) { $0 + $1.celsius } / Double(samples.count)
    }
}

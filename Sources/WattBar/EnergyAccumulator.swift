import Foundation

struct EnergyAccumulator {
    private(set) var wattHours: Double
    private(set) var activeSeconds: TimeInterval
    private var previousSample: (watts: Double, date: Date)?

    init(wattHours: Double, activeSeconds: TimeInterval) {
        self.wattHours = max(0, wattHours.isFinite ? wattHours : 0)
        self.activeSeconds = max(0, activeSeconds.isFinite ? activeSeconds : 0)
    }

    mutating func addSample(
        watts: Double?,
        at date: Date,
        maximumInterval: TimeInterval
    ) {
        guard let watts, watts.isFinite, watts >= 0 else {
            previousSample = nil
            return
        }

        defer {
            previousSample = (watts, date)
        }

        guard let previousSample else { return }
        let elapsedSeconds = date.timeIntervalSince(previousSample.date)
        guard elapsedSeconds > 0, elapsedSeconds <= maximumInterval else { return }

        let averageWatts = (previousSample.watts + watts) / 2
        wattHours += averageWatts * elapsedSeconds / 3_600
        activeSeconds += elapsedSeconds
    }

    mutating func pause() {
        previousSample = nil
    }

    mutating func reset() {
        wattHours = 0
        activeSeconds = 0
        previousSample = nil
    }
}


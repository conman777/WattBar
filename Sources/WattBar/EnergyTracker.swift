import Foundation

final class EnergyTracker {
    private let defaults: UserDefaults
    private var lastPersistence: Date?
    private(set) var accumulator: EnergyAccumulator

    init(defaults: UserDefaults) {
        self.defaults = defaults
        accumulator = EnergyAccumulator(
            wattHours: defaults.double(forKey: DefaultsKey.accumulatedEnergyWh),
            activeSeconds: defaults.double(forKey: DefaultsKey.accumulatedTrackingSeconds)
        )
    }

    func add(_ reading: PowerReading, enabled: Bool, refreshInterval: TimeInterval) {
        guard enabled else {
            accumulator.pause()
            return
        }
        accumulator.addSample(watts: reading.systemWatts, at: reading.updatedAt,
            maximumInterval: max(5, refreshInterval * 2.5))
        if lastPersistence.map({ reading.updatedAt.timeIntervalSince($0) >= 30 }) ?? true {
            persist(at: reading.updatedAt)
        }
    }

    func pause() { accumulator.pause() }
    func reset() { accumulator.reset() }

    func persist(at date: Date = Date()) {
        defaults.set(accumulator.wattHours, forKey: DefaultsKey.accumulatedEnergyWh)
        defaults.set(accumulator.activeSeconds, forKey: DefaultsKey.accumulatedTrackingSeconds)
        lastPersistence = date
    }
}

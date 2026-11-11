import Foundation

enum DefaultsKey {
    static let refreshInterval = "refreshInterval"
    static let showActiveApps = "showActiveApps"
    static let showMenuBarLabel = "showMenuBarLabel"
    static let compactMenuBar = "compactMenuBar"
    static let showChargingRate = "showChargingRate"
    static let showNetworkSpeeds = "showNetworkSpeeds"
    static let trackEnergyUsage = "trackEnergyUsage"
    static let accumulatedEnergyWh = "accumulatedEnergyWh"
    static let accumulatedTrackingSeconds = "accumulatedTrackingSeconds"
    static let southAfricaTariff = "southAfricaTariffRandPerKWh"
    static let unitedKingdomTariff = "unitedKingdomTariffPoundsPerKWh"
    static let menuBarGraph = "menuBarGraph"
    static let menuBarGraphPeaks = "menuBarGraphPeaks"
    static let menuBarGraphStyle = "menuBarGraphStyle"
}

enum DefaultTariff {
    // Electricity prices vary by provider, region, payment method, and time.
    // These are editable example unit rates, not universal or guaranteed prices.
    static let southAfricaRandPerKWh = 3.50
    static let unitedKingdomPoundsPerKWh = 0.2611
}

final class AppSettings {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var refreshInterval: TimeInterval {
        get {
            let storedValue = defaults.double(forKey: DefaultsKey.refreshInterval)
            return storedValue > 0 ? storedValue : 5
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.refreshInterval)
        }
    }

    var showActiveApps: Bool {
        get {
            defaults.object(forKey: DefaultsKey.showActiveApps) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.showActiveApps)
        }
    }

    var showMenuBarLabel: Bool {
        get {
            defaults.bool(forKey: DefaultsKey.showMenuBarLabel)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.showMenuBarLabel)
        }
    }

    var compactMenuBar: Bool {
        get {
            defaults.bool(forKey: DefaultsKey.compactMenuBar)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.compactMenuBar)
        }
    }

    var showChargingRate: Bool {
        get {
            defaults.bool(forKey: DefaultsKey.showChargingRate)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.showChargingRate)
        }
    }

    var showNetworkSpeeds: Bool {
        get {
            defaults.bool(forKey: DefaultsKey.showNetworkSpeeds)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.showNetworkSpeeds)
        }
    }

    var trackEnergyUsage: Bool {
        get {
            defaults.bool(forKey: DefaultsKey.trackEnergyUsage)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.trackEnergyUsage)
        }
    }

    var southAfricaTariff: Double {
        get {
            guard defaults.object(forKey: DefaultsKey.southAfricaTariff) != nil else {
                return DefaultTariff.southAfricaRandPerKWh
            }
            let value = defaults.double(forKey: DefaultsKey.southAfricaTariff)
            return value.isFinite && value > 0 ? value : DefaultTariff.southAfricaRandPerKWh
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.southAfricaTariff)
        }
    }

    var unitedKingdomTariff: Double {
        get {
            guard defaults.object(forKey: DefaultsKey.unitedKingdomTariff) != nil else {
                return DefaultTariff.unitedKingdomPoundsPerKWh
            }
            let value = defaults.double(forKey: DefaultsKey.unitedKingdomTariff)
            return value.isFinite && value > 0 ? value : DefaultTariff.unitedKingdomPoundsPerKWh
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.unitedKingdomTariff)
        }
    }

    /// The stored choice; use resolved(hasBattery:) for what is actually drawn.
    var graphMetric: GraphMetric {
        get {
            (defaults.object(forKey: DefaultsKey.menuBarGraph) as? String).flatMap(GraphMetric.init) ?? .systemDraw
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKey.menuBarGraph)
        }
    }

    var graphStyle: GraphStyle {
        get {
            (defaults.object(forKey: DefaultsKey.menuBarGraphStyle) as? String).flatMap(GraphStyle.init) ?? .line
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKey.menuBarGraphStyle)
        }
    }

    /// Highest value seen per graph metric, kept across launches for the bar scale.
    var graphPeaks: [GraphMetric: Double] {
        get {
            guard let stored = defaults.object(forKey: DefaultsKey.menuBarGraphPeaks) as? [String: Any] else { return [:] }
            var peaks: [GraphMetric: Double] = [:]
            for (key, value) in stored {
                if let metric = GraphMetric(rawValue: key), let peak = doubleValue(value), peak.isFinite, peak > 0 {
                    peaks[metric] = peak
                }
            }
            return peaks
        }
        set {
            let stored = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value) })
            defaults.set(stored, forKey: DefaultsKey.menuBarGraphPeaks)
        }
    }
}

import Foundation
import IOKit

struct ExternalPowerSample {
    let watts: Double
    let ageSeconds: TimeInterval
}

final class ExternalPowerReader {
    let inputURL: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("WattBar", isDirectory: true)
            .appendingPathComponent("external-power-watts.txt")
    }()

    func read(maximumAge: TimeInterval, now: Date) -> ExternalPowerSample? {
        let path = inputURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return nil
        }

        let age = max(0, now.timeIntervalSince(modifiedAt))
        guard age <= maximumAge,
              let contents = try? String(contentsOf: inputURL, encoding: .utf8),
              let watts = Double(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              watts.isFinite,
              watts >= 0,
              watts <= 100_000 else {
            return nil
        }

        return ExternalPowerSample(watts: watts, ageSeconds: age)
    }
}

final class SystemPowerReader {
    private let externalPowerReader = ExternalPowerReader()

    func read(maximumExternalAge: TimeInterval) -> PowerReading {
        let updatedAt = Date()
        let externalSample = externalPowerReader.read(
            maximumAge: maximumExternalAge,
            now: updatedAt
        )

        guard let properties = batteryProperties() else {
            if let externalSample {
                return PowerReading(
                    systemWatts: externalSample.watts,
                    adapterInputWatts: nil,

                    powerState: PowerReading.desktopState,
                    batteryFlowWatts: nil,
                    source: "External whole-device meter",
                    details: String(
                        format: "Fresh local meter sample (%.1f s old)",
                        externalSample.ageSeconds
                    ),
                    updatedAt: updatedAt
                )
            }

            return PowerReading(
                systemWatts: nil,
                adapterInputWatts: nil,

                powerState: PowerReading.desktopState,
                batteryFlowWatts: nil,
                source: "Whole-device telemetry not exposed by macOS",
                details: "External meter input inactive (see README)",
                updatedAt: updatedAt
            )
        }

        let telemetry = properties["PowerTelemetryData"] as? [String: Any]
        let pluggedIn = boolValue(properties["ExternalConnected"])
            ?? boolValue(properties["AppleRawExternalConnected"])
            ?? false
        let telemetryBatteryWatts = telemetry.flatMap { dictionary in
            doubleValue(dictionary["BatteryPower"]).map { $0 / 1_000 }
        }
        let nativeSystemWatts = telemetry.flatMap { dictionary in
            doubleValue(dictionary["SystemLoad"]).flatMap { $0 > 0 ? $0 / 1_000 : nil }
        } ?? (!pluggedIn ? telemetryBatteryWatts.map(abs) : nil)
        let systemWatts = externalSample?.watts ?? nativeSystemWatts
        let adapterInputWatts = telemetry.flatMap { dictionary in
            doubleValue(dictionary["SystemPowerIn"]).flatMap { $0 > 0 ? $0 / 1_000 : nil }
        }

        let voltage = doubleValue(properties["AppleRawBatteryVoltage"]) ?? doubleValue(properties["Voltage"])
        let amperage = doubleValue(properties["InstantAmperage"]) ?? doubleValue(properties["Amperage"])
        let batteryFlowWatts = telemetryBatteryWatts ?? voltage.flatMap { volts in
            amperage.map { amps in (volts * amps) / 1_000_000 }
        }

        let percent = batteryPercent(from: properties)
        let charging = boolValue(properties["IsCharging"]) ?? false
        let full = boolValue(properties["FullyCharged"]) ?? false
        let adapterWatts = adapterWatts(from: properties)

        let powerState: String
        if pluggedIn && full {
            powerState = "Plugged in, full"
        } else if pluggedIn && charging {
            powerState = "Plugged in, charging"
        } else if pluggedIn {
            powerState = "Plugged in"
        } else {
            powerState = "On battery"
        }

        var detailParts: [String] = []
        if let percent {
            detailParts.append("Battery \(percent)%")
        }
        if let adapterWatts {
            detailParts.append("Adapter \(formatWholeWatts(adapterWatts))")
        }
        if let voltage {
            detailParts.append(String(format: "Battery %.2f V", voltage / 1_000))
        }
        if let externalSample {
            detailParts.append(
                String(format: "External meter %.1f s old", externalSample.ageSeconds)
            )
        }

        let source: String
        if externalSample != nil {
            source = "External whole-device meter"
        } else if telemetry?["SystemLoad"] != nil {
            source = "macOS system load telemetry"
        } else if !pluggedIn, telemetryBatteryWatts != nil {
            source = "Battery discharge rate (whole-device estimate)"
        } else {
            source = "Whole-device telemetry unavailable"
        }

        return PowerReading(
            systemWatts: systemWatts,
            adapterInputWatts: adapterInputWatts,

            powerState: powerState,
            batteryFlowWatts: batteryFlowWatts,
            source: source,
            details: detailParts.isEmpty ? "No battery details available" : detailParts.joined(separator: " | "),
            updatedAt: updatedAt
        )
    }

    private func batteryProperties() -> [String: Any]? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanagedProperties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanagedProperties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }

        return properties
    }

    private func adapterWatts(from properties: [String: Any]) -> Double? {
        if let details = properties["AdapterDetails"] as? [String: Any],
           let watts = doubleValue(details["Watts"]) {
            return watts
        }

        if let details = properties["AppleRawAdapterDetails"] as? [[String: Any]],
           let first = details.first,
           let watts = doubleValue(first["Watts"]) {
            return watts
        }

        return nil
    }

    private func batteryPercent(from properties: [String: Any]) -> Int? {
        if let currentCapacity = doubleValue(properties["CurrentCapacity"]), currentCapacity >= 0, currentCapacity <= 100 {
            return Int(currentCapacity.rounded())
        }

        guard let current = doubleValue(properties["AppleRawCurrentCapacity"]),
              let maximum = doubleValue(properties["AppleRawMaxCapacity"]),
              maximum > 0 else {
            return nil
        }

        return Int(((current / maximum) * 100).rounded())
    }
}


import Foundation

enum PowerFlow: Equatable {
    case adapter(Double)
    case discharge(Double)
    case idle

    init(adapterInputWatts: Double?, batteryFlowWatts: Double?) {
        if let watts = adapterInputWatts, watts > 0.05 {
            self = .adapter(watts)
        } else if let watts = batteryFlowWatts, watts < -0.05 {
            self = .discharge(abs(watts))
        } else {
            self = .idle
        }
    }

    var label: String {
        if case .discharge = self { return "BAT" }
        return "IN"
    }

    var compactValue: String {
        switch self {
        case .adapter(let watts): return String(format: "%.0fW", watts)
        case .discharge(let watts): return String(format: "−%.0fW", watts)
        case .idle: return "Idle"
        }
    }

    var description: String {
        switch self {
        case .adapter(let watts): return String(format: "⚡︎ %.1f W", watts)
        case .discharge(let watts): return String(format: "−%.1f W", watts)
        case .idle: return "Power idle"
        }
    }
}

extension PowerFlow {
    /// One piece of the menu's flow line, e.g. "Battery" "+19 W".
    struct Part: Equatable {
        enum Tone { case neutral, charging, draining }
        let label: String
        let value: String
        let tone: Tone
    }

    /// Where the power comes from, what the Mac draws, and what the battery
    /// does: "Adapter 61 W → Mac 42 W · Battery +19 W". A battery flow that
    /// rounds to zero is left out; desktops show only the Mac.
    static func summary(adapterInputWatts: Double?, batteryFlowWatts: Double?, systemWatts: Double?) -> [Part] {
        func watts(_ value: Double) -> String { String(format: "%.0f W", value) }
        let mac = Part(label: "Mac", value: systemWatts.map(watts) ?? "--", tone: .neutral)
        switch PowerFlow(adapterInputWatts: adapterInputWatts, batteryFlowWatts: batteryFlowWatts) {
        case .adapter(let input):
            var parts = [Part(label: "Adapter", value: watts(input), tone: .neutral), mac]
            if let battery = batteryFlowWatts, abs(battery) >= 0.5 {
                parts.append(Part(label: "Battery", value: (battery > 0 ? "+" : "−") + watts(abs(battery)),
                                  tone: battery > 0 ? .charging : .draining))
            }
            return parts
        case .discharge(let drain):
            return [Part(label: "Battery", value: watts(drain), tone: .draining), mac]
        case .idle:
            return [mac]
        }
    }

    static func summary(for reading: PowerReading) -> [Part] {
        summary(adapterInputWatts: reading.adapterInputWatts, batteryFlowWatts: reading.batteryFlowWatts,
                systemWatts: reading.systemWatts)
    }

    /// The source flows into the Mac ("→"); the battery note follows ("·").
    static func separator(before index: Int) -> String { index == 1 ? " → " : " · " }

    static func summaryText(_ parts: [Part]) -> String {
        parts.enumerated().map { index, part in
            (index > 0 ? separator(before: index) : "") + "\(part.label) \(part.value)"
        }.joined()
    }
}

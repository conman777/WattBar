import Foundation

func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
        return number.doubleValue
    case let int as Int:
        return Double(int)
    case let double as Double:
        return double
    case let string as String:
        return Double(string)
    default:
        return nil
    }
}

func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
        return bool
    case let number as NSNumber:
        return number.boolValue
    case let string as String:
        return (string as NSString).boolValue
    default:
        return nil
    }
}

func positiveDecimal(from text: String) -> Double? {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
    return value
}

func formatWatts(_ watts: Double?) -> String {
    guard let watts else { return "unavailable" }
    return String(format: "%.1f W", watts)
}

func formatWholeWatts(_ watts: Double) -> String {
    String(format: "%.0f W", watts)
}

func formatEnergySummary(_ wattHours: Double) -> String {
    let kilowattHours = wattHours / 1_000
    if wattHours < 1 {
        return String(format: "%.3f Wh · %.5f kWh", wattHours, kilowattHours)
    }
    if wattHours < 1_000 {
        return String(format: "%.2f Wh · %.4f kWh", wattHours, kilowattHours)
    }
    return String(format: "%.3f kWh", kilowattHours)
}

func formatTrackingDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded(.down)))
    let days = totalSeconds / 86_400
    let hours = (totalSeconds % 86_400) / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let remainingSeconds = totalSeconds % 60

    if days > 0 {
        return "\(days)d \(hours)h \(minutes)m"
    }
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    if minutes > 0 {
        return "\(minutes)m \(remainingSeconds)s"
    }
    return "\(remainingSeconds)s"
}

func formatSystemUptime(_ seconds: TimeInterval) -> String {
    formatTrackingDuration(seconds)
}

/// Costs share one precision so the two currencies read alike; amounts under
/// one cent/penny show as "< R 0.01" rather than switching to four decimals.
func formatCost(_ amount: Double, symbol: String) -> String {
    if amount > 0 && amount < 0.005 { return "< \(symbol)0.01" }
    return symbol + String(format: "%.2f", max(0, amount))
}

func formatRand(_ rand: Double) -> String {
    formatCost(rand, symbol: "R ")
}

func formatPounds(_ pounds: Double) -> String {
    formatCost(pounds, symbol: "£")
}

private let rateFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 4
    formatter.minimumIntegerDigits = 1
    return formatter
}()

/// Tariffs keep sub-penny precision only when the rate has it: 3.50, 0.2611.
func formatRate(_ rate: Double) -> String {
    rateFormatter.string(from: NSNumber(value: rate)) ?? String(format: "%.4f", rate)
}

func formatBatteryFlow(_ watts: Double?) -> String {
    guard let watts else { return "unavailable" }

    if abs(watts) < 0.05 {
        return "0.0 W (not charging/discharging)"
    }

    if watts > 0 {
        return String(format: "%.1f W into battery", watts)
    }

    return String(format: "%.1f W from battery", abs(watts))
}

func formatMenuBarPowerFlow(adapterInputWatts: Double?, batteryFlowWatts: Double?) -> String {
    PowerFlow(adapterInputWatts: adapterInputWatts, batteryFlowWatts: batteryFlowWatts).description
}

func formatNetworkSpeed(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
        return "measuring…"
    }

    if bytesPerSecond >= 1_000_000_000 {
        return String(format: "%.1f GB/s", bytesPerSecond / 1_000_000_000)
    }
    if bytesPerSecond >= 1_000_000 {
        return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
    if bytesPerSecond >= 1_000 {
        return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
    }
    return String(format: "%.0f B/s", bytesPerSecond)
}

func formatStackedNetworkSpeed(_ bytesPerSecond: Double?) -> String {
    guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
        return "--"
    }

    // At most three digits, so values fit the width the menu bar reserves.
    func scaled(_ value: Double, _ unit: String) -> String {
        String(format: value < 9.95 ? "%.1f" : "%.0f", value) + unit
    }
    if bytesPerSecond >= 999_500_000 {
        return scaled(bytesPerSecond / 1_000_000_000, "G")
    }
    if bytesPerSecond >= 999_500 {
        return scaled(bytesPerSecond / 1_000_000, "M")
    }
    if bytesPerSecond >= 999.5 {
        return String(format: "%.0fK", bytesPerSecond / 1_000)
    }
    return String(format: "%.0fB", bytesPerSecond)
}

func formatAccessibleNetworkSpeed(_ reading: NetworkSpeedReading?) -> String {
    guard let reading else { return "Network speed measuring" }
    return "Download \(formatNetworkSpeed(reading.downloadBytesPerSecond)), upload \(formatNetworkSpeed(reading.uploadBytesPerSecond))"
}

private let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    formatter.allowsNonnumericFormatting = false
    return formatter
}()

func formatByteCount(_ bytes: UInt64?) -> String {
    guard let bytes else { return "measuring…" }
    return byteCountFormatter.string(fromByteCount: Int64(clamping: bytes))
}

func formatGPUWatts(_ watts: Double?) -> String {
    guard let watts else { return "unavailable" }
    return String(format: "%.1f W (estimated)", watts)
}

func formatCPUTemperature(_ celsius: Double?, unavailable: String = "unavailable") -> String {
    guard let celsius else { return unavailable }
    return String(format: "%.0f °C", celsius)
}

func formatFanSpeed(_ rpm: Double?) -> String {
    guard let rpm else { return "unavailable" }
    return rpm < 1 ? "off" : String(format: "%.0f rpm", rpm)
}

func formatStackedFanSpeed(_ rpm: Double?) -> String {
    guard let rpm else { return "--" }
    return rpm < 1 ? "off" : String(format: "%.0f", rpm)
}


/// Fits the menu's energy row: "12.0 Wh" below 1 kWh, then "1.24 kWh".
func formatShortEnergy(_ wattHours: Double) -> String {
    wattHours < 999.95
        ? String(format: "%.1f Wh", max(0, wattHours))
        : String(format: "%.2f kWh", wattHours / 1_000)
}

/// App memory for the busiest-apps rows: "540 MB", then "2.1 GB".
func formatAppMemory(_ megabytes: Int) -> String {
    megabytes < 1_000 ? "\(max(0, megabytes)) MB" : String(format: "%.1f GB", Double(megabytes) / 1_024)
}

func formatPercentage(_ value: Double?) -> String {
    value.map { String(format: "%.0f %%", $0) } ?? "--"
}

func formatMemoryPressure(_ reading: MemoryPressureReading?) -> String {
    guard let reading else { return "--" }
    return "\(formatPercentage(reading.percentage)) (\(reading.level.title))"
}

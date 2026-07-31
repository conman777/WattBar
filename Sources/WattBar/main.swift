import Cocoa
import Darwin
import IOKit
import ServiceManagement

@_silgen_name("wattbar_gpu_watts")
private func wattbar_gpu_watts() -> Double

private enum DefaultsKey {
    static let refreshInterval = "refreshInterval"
    static let showActiveApps = "showActiveApps"
    static let showMenuBarLabel = "showMenuBarLabel"
    static let showChargingRate = "showChargingRate"
    static let trackEnergyUsage = "trackEnergyUsage"
    static let accumulatedEnergyWh = "accumulatedEnergyWh"
    static let accumulatedTrackingSeconds = "accumulatedTrackingSeconds"
    static let southAfricaTariff = "southAfricaTariffRandPerKWh"
    static let unitedKingdomTariff = "unitedKingdomTariffPoundsPerKWh"
}

private enum DefaultTariff {
    // Electricity prices vary by provider, region, payment method, and time.
    // These are editable example unit rates, not universal or guaranteed prices.
    static let southAfricaRandPerKWh = 3.50
    static let unitedKingdomPoundsPerKWh = 0.2611
}

private struct PowerReading {
    let systemWatts: Double?
    let adapterInputWatts: Double?
    let batteryPercent: Int?
    let powerState: String
    let batteryFlowWatts: Double?
    let source: String
    let details: String
    let updatedAt: Date
}

private struct ActiveApp {
    let name: String
    let cpu: Double
    let memoryMB: Int
}

private struct EnergyAccumulator {
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

private final class InstanceLock {
    private let fd: Int32

    init?(name: String) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("WattBar", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let lockPath = directory.appendingPathComponent("\(name).lock").path
        fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return nil }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

private struct ExternalPowerSample {
    let watts: Double
    let ageSeconds: TimeInterval
}

private final class ExternalPowerReader {
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

private final class SystemPowerReader {
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
                    batteryPercent: nil,
                    powerState: "Desktop / no system battery",
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
                batteryPercent: nil,
                powerState: "Desktop / no system battery",
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
            batteryPercent: percent,
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

private final class ActiveAppReader {
    func topApps(limit: Int = 5) -> [ActiveApp] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,pcpu=,rss=,comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var totals: [String: (cpu: Double, memoryKB: Int)] = [:]
        let currentPID = ProcessInfo.processInfo.processIdentifier

        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4,
                  let pid = pid_t(parts[0]),
                  pid != currentPID,
                  let cpu = Double(parts[1]),
                  let memoryKB = Int(parts[2]),
                  cpu >= 0.1 else {
                continue
            }

            let command = String(parts[3])
            let appName = displayName(for: pid, command: command)
            let existing = totals[appName] ?? (0, 0)
            totals[appName] = (existing.cpu + cpu, existing.memoryKB + memoryKB)
        }

        return totals
            .map { ActiveApp(name: $0.key, cpu: $0.value.cpu, memoryMB: max(1, $0.value.memoryKB / 1_024)) }
            .sorted { lhs, rhs in
                if lhs.cpu == rhs.cpu {
                    return lhs.memoryMB > rhs.memoryMB
                }
                return lhs.cpu > rhs.cpu
            }
            .prefix(limit)
            .map { $0 }
    }

    private func displayName(for pid: pid_t, command: String) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName,
           !name.isEmpty {
            return name
        }

        let lastPathComponent = URL(fileURLWithPath: command).lastPathComponent
        return lastPathComponent.isEmpty ? command : lastPathComponent
    }
}

private final class GPUReader {
    func read() -> Double? {
        let watts = wattbar_gpu_watts()
        return watts >= 0 ? watts : nil
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let reader = SystemPowerReader()
    private let gpuReader = GPUReader()
    private let activeAppReader = ActiveAppReader()
    private let activeAppRefreshInterval: TimeInterval = 15
    private let energyPersistenceInterval: TimeInterval = 30
    private let statusFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.systemFontSize,
        weight: .regular
    )
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var statusItem: NSStatusItem?
    private var timer: Timer?
    private var instanceLock: InstanceLock?
    private var latestReading: PowerReading?
    private var latestGPUWatts: Double?
    private var latestActiveApps: [ActiveApp] = []
    private var energyAccumulator = EnergyAccumulator(wattHours: 0, activeSeconds: 0)
    private var lastActiveAppRefresh: Date?
    private var lastEnergyPersistence: Date?
    private var lastStatusSignature: String?
    private var menuIsOpen = false
    private var menuHasBeenBuilt = false
    private var energyUsageLoaded = false
    private lazy var statusAttributes: [NSAttributedString.Key: Any] = [.font: statusFont]
    private lazy var cpuStatusIcon = statusIconAttachment(.cpu, font: statusFont)
    private lazy var gpuStatusIcon = statusIconAttachment(.gpu, font: statusFont)

    private var refreshInterval: TimeInterval {
        get {
            let storedValue = UserDefaults.standard.double(forKey: DefaultsKey.refreshInterval)
            return storedValue > 0 ? storedValue : 5
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.refreshInterval)
        }
    }

    private var showActiveApps: Bool {
        get {
            UserDefaults.standard.object(forKey: DefaultsKey.showActiveApps) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showActiveApps)
        }
    }

    private var showMenuBarLabel: Bool {
        get {
            UserDefaults.standard.bool(forKey: DefaultsKey.showMenuBarLabel)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showMenuBarLabel)
        }
    }

    private var showChargingRate: Bool {
        get {
            UserDefaults.standard.bool(forKey: DefaultsKey.showChargingRate)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showChargingRate)
        }
    }

    private var trackEnergyUsage: Bool {
        get {
            UserDefaults.standard.bool(forKey: DefaultsKey.trackEnergyUsage)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.trackEnergyUsage)
        }
    }

    private var southAfricaTariff: Double {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: DefaultsKey.southAfricaTariff) != nil else {
                return DefaultTariff.southAfricaRandPerKWh
            }
            let value = defaults.double(forKey: DefaultsKey.southAfricaTariff)
            return value.isFinite && value > 0 ? value : DefaultTariff.southAfricaRandPerKWh
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.southAfricaTariff)
        }
    }

    private var unitedKingdomTariff: Double {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: DefaultsKey.unitedKingdomTariff) != nil else {
                return DefaultTariff.unitedKingdomPoundsPerKWh
            }
            let value = defaults.double(forKey: DefaultsKey.unitedKingdomTariff)
            return value.isFinite && value > 0 ? value : DefaultTariff.unitedKingdomPoundsPerKWh
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.unitedKingdomTariff)
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "local.codex.wattbar"
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let duplicate = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { $0.processIdentifier != currentPID && !$0.isTerminated }

        guard !duplicate, let lock = InstanceLock(name: bundleIdentifier) else {
            NSApp.terminate(nil)
            return
        }

        instanceLock = lock
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        energyAccumulator = EnergyAccumulator(
            wattHours: UserDefaults.standard.double(forKey: DefaultsKey.accumulatedEnergyWh),
            activeSeconds: UserDefaults.standard.double(forKey: DefaultsKey.accumulatedTrackingSeconds)
        )
        energyUsageLoaded = true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.toolTip = "WattBar"

        refresh()
        scheduleTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistEnergyUsage(force: true)
    }

    @objc private func refresh() {
        let reading = reader.read(
            maximumExternalAge: max(15, refreshInterval * 2.5)
        )
        updateEnergyUsage(with: reading)
        latestReading = reading
        latestGPUWatts = gpuReader.read()
        if menuIsOpen {
            refreshActiveAppsIfNeeded(minimumAge: activeAppRefreshInterval)
        }
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func setRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        refreshInterval = interval
        scheduleTimer()
        rebuildMenu()
    }

    @objc private func toggleActiveApps() {
        showActiveApps.toggle()
        if showActiveApps {
            lastActiveAppRefresh = nil
        } else {
            latestActiveApps = []
        }
        refresh()
    }

    @objc private func toggleMenuBarLabel() {
        showMenuBarLabel.toggle()
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func toggleChargingRate() {
        showChargingRate.toggle()
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func toggleEnergyUsage() {
        trackEnergyUsage.toggle()
        if !trackEnergyUsage {
            energyAccumulator.pause()
            persistEnergyUsage(force: true)
        }
        refresh()
    }

    @objc private func editTariffs() {
        let alert = NSAlert()
        alert.messageText = "Electricity Tariffs"
        alert.informativeText = """
        Enter the unit rates from your electricity bills. Cost totals exclude standing charges.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let randField = NSTextField(string: String(format: "%.4f", southAfricaTariff))
        let poundsField = NSTextField(string: String(format: "%.4f", unitedKingdomTariff))
        randField.placeholderString = "Rand per kWh"
        poundsField.placeholderString = "Pounds per kWh"

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "South Africa (R/kWh):"), randField],
            [NSTextField(labelWithString: "UK (£/kWh):"), poundsField]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 130
        grid.frame = NSRect(x: 0, y: 0, width: 330, height: 52)
        alert.accessoryView = grid

        while alert.runModal() == .alertFirstButtonReturn {
            guard let randRate = positiveDecimal(from: randField.stringValue),
                  let poundsRate = positiveDecimal(from: poundsField.stringValue) else {
                showAlert(
                    title: "Invalid Tariff",
                    message: "Enter a number greater than zero for both per-kWh rates."
                )
                continue
            }

            southAfricaTariff = randRate
            unitedKingdomTariff = poundsRate
            rebuildMenu()
            return
        }
    }

    @objc private func resetEnergyUsage() {
        let alert = NSAlert()
        alert.messageText = "Reset tracked usage?"
        alert.informativeText = "This resets tracking time, accumulated watt-hours, and both cost totals to zero."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        energyAccumulator.reset()
        persistEnergyUsage(force: true)
        refresh()
    }

    @objc private func toggleOpenAtLogin() {
        guard #available(macOS 13.0, *) else {
            showAlert(title: "Open at Login Unavailable", message: "This setting requires macOS 13 or newer.")
            return
        }

        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "Open at Login Unavailable", message: error.localizedDescription)
        }

        rebuildMenu()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = min(0.5, refreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refreshActiveAppsIfNeeded(minimumAge: TimeInterval) {
        guard showActiveApps else {
            latestActiveApps = []
            return
        }

        let now = Date()
        if let lastActiveAppRefresh,
           now.timeIntervalSince(lastActiveAppRefresh) < minimumAge {
            return
        }

        latestActiveApps = activeAppReader.topApps()
        lastActiveAppRefresh = now
    }

    private func updateEnergyUsage(with reading: PowerReading) {
        guard trackEnergyUsage else {
            energyAccumulator.pause()
            return
        }

        // Do not infer energy across app downtime, sleep, or a missing sensor
        // interval. A delayed timer can span at most 2.5 normal refresh periods.
        let maximumInterval = max(5, refreshInterval * 2.5)
        energyAccumulator.addSample(
            watts: reading.systemWatts,
            at: reading.updatedAt,
            maximumInterval: maximumInterval
        )
        persistEnergyUsage(at: reading.updatedAt)
    }

    private func persistEnergyUsage(force: Bool = false, at date: Date = Date()) {
        guard energyUsageLoaded else { return }
        if !force,
           let lastEnergyPersistence,
           date.timeIntervalSince(lastEnergyPersistence) < energyPersistenceInterval {
            return
        }

        UserDefaults.standard.set(
            energyAccumulator.wattHours,
            forKey: DefaultsKey.accumulatedEnergyWh
        )
        UserDefaults.standard.set(
            energyAccumulator.activeSeconds,
            forKey: DefaultsKey.accumulatedTrackingSeconds
        )
        lastEnergyPersistence = date
    }

    private func updateStatusTitle() {
        guard let reading = latestReading else {
            statusItem?.button?.title = "WattBar"
            return
        }

        let wattsValue = reading.systemWatts.map { String(format: "%.1f W", $0) } ?? "-- W"
        let gpuValue = latestGPUWatts.map { String(format: "%.1f W", $0) } ?? "-- W"
        let uptimeValue = formatSystemUptime(ProcessInfo.processInfo.systemUptime)
        let powerFlowText = showChargingRate
            ? formatMenuBarPowerFlow(
                adapterInputWatts: reading.adapterInputWatts,
                batteryFlowWatts: reading.batteryFlowWatts
            )
            : nil
        let gpuTooltip = latestGPUWatts.map { String(format: "%.1f W", $0) } ?? "unavailable"
        let batteryTooltip = formatBatteryFlow(reading.batteryFlowWatts)
        let signature = [
            showMenuBarLabel ? "label" : "no-label",
            wattsValue,
            gpuValue,
            uptimeValue,
            powerFlowText ?? "no-flow",
            batteryTooltip
        ].joined(separator: "|")
        guard signature != lastStatusSignature else { return }
        lastStatusSignature = signature

        let font = statusFont
        let attributes = statusAttributes
        let attributedTitle = NSMutableAttributedString()

        if showMenuBarLabel {
            attributedTitle.append(NSAttributedString(string: "WattBar ", attributes: attributes))
        }
        attributedTitle.append(cpuStatusIcon)
        attributedTitle.append(NSAttributedString(string: " \(wattsValue)", attributes: attributes))

        if let powerFlowText {
            attributedTitle.append(NSAttributedString(string: " | ", attributes: attributes))
            var powerFlowAttributes = attributes
            if reading.adapterInputWatts == nil,
               let batteryFlowWatts = reading.batteryFlowWatts,
               batteryFlowWatts < -0.05 {
                powerFlowAttributes[.foregroundColor] = NSColor.systemRed
            }
            attributedTitle.append(NSAttributedString(string: powerFlowText, attributes: powerFlowAttributes))
        }

        attributedTitle.append(NSAttributedString(string: " | ", attributes: attributes))
        attributedTitle.append(gpuStatusIcon)
        attributedTitle.append(NSAttributedString(string: " \(gpuValue)", attributes: attributes))

        let accessibleParts = [
            "System \(wattsValue)",
            powerFlowText,
            "GPU \(gpuValue)",
            "Computer uptime \(uptimeValue)"
        ].compactMap { $0 }
        let accessibleTitle = accessibleParts.joined(separator: " | ")
        let width = ceil(attributedTitle.size().width) + 18

        statusItem?.length = max(46, width)
        statusItem?.button?.font = font
        statusItem?.button?.image = nil
        statusItem?.button?.title = accessibleTitle
        statusItem?.button?.attributedTitle = attributedTitle
        statusItem?.button?.setAccessibilityLabel("WattBar \(accessibleTitle)")
        statusItem?.button?.toolTip = "System draw: \(wattsValue) | Battery: \(batteryTooltip) | GPU: \(gpuTooltip) | Computer uptime: \(uptimeValue)"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshActiveAppsIfNeeded(minimumAge: 5)
        rebuildMenu(force: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu(force: Bool = false) {
        let menu: NSMenu
        if let existingMenu = statusItem?.menu {
            menu = existingMenu
        } else {
            menu = NSMenu(title: "WattBar")
            menu.delegate = self
            statusItem?.menu = menu
        }

        guard force || menuIsOpen || !menuHasBeenBuilt else { return }
        menu.removeAllItems()

        if let reading = latestReading {
            addInfo("System draw: \(formatWatts(reading.systemWatts))", to: menu)
            addInfo("Adapter input: \(formatWatts(reading.adapterInputWatts))", to: menu)
            addInfo("GPU draw: \(formatGPUWatts(latestGPUWatts))", to: menu)
            addInfo("Power: \(reading.powerState)", to: menu)
            addInfo("Battery flow: \(formatBatteryFlow(reading.batteryFlowWatts))", to: menu)
            addInfo("Whole-device source: \(reading.source)", to: menu)
            addInfo("Details: \(reading.details)", to: menu)
            addInfo("Updated: \(formatter.string(from: reading.updatedAt))", to: menu)
        } else {
            addInfo("WattBar is measuring...", to: menu)
        }

        addInfo(
            "Computer uptime: \(formatSystemUptime(ProcessInfo.processInfo.systemUptime))",
            to: menu
        )

        menu.addItem(.separator())
        addEnergySection(to: menu)

        menu.addItem(.separator())
        addInfo("Top active apps (CPU, not exact watts)", to: menu)

        if showActiveApps {
            if latestActiveApps.isEmpty {
                addInfo("No busy apps right now", to: menu)
            } else {
                for (index, app) in latestActiveApps.enumerated() {
                    addInfo("\(index + 1). \(app.name) - \(String(format: "%.1f", app.cpu))% CPU, \(app.memoryMB) MB RAM", to: menu)
                }
            }
        } else {
            addInfo("Hidden", to: menu)
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let intervalItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu(title: "Refresh Interval")
        for interval in [2.0, 5.0, 10.0, 30.0] {
            let item = NSMenuItem(title: "\(Int(interval)) seconds", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = abs(refreshInterval - interval) < 0.1 ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)

        let activeAppsItem = NSMenuItem(title: "Show Active Apps", action: #selector(toggleActiveApps), keyEquivalent: "")
        activeAppsItem.target = self
        activeAppsItem.state = showActiveApps ? .on : .off
        menu.addItem(activeAppsItem)

        let menuLabelItem = NSMenuItem(title: "Show WattBar Label", action: #selector(toggleMenuBarLabel), keyEquivalent: "")
        menuLabelItem.target = self
        menuLabelItem.state = showMenuBarLabel ? .on : .off
        menu.addItem(menuLabelItem)

        let chargingRateItem = NSMenuItem(
            title: "Show Charging Rate in Menu Bar",
            action: #selector(toggleChargingRate),
            keyEquivalent: ""
        )
        chargingRateItem.target = self
        chargingRateItem.state = showChargingRate ? .on : .off
        menu.addItem(chargingRateItem)

        let openAtLoginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        openAtLoginItem.target = self
        if #available(macOS 13.0, *) {
            openAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } else {
            openAtLoginItem.isEnabled = false
        }
        menu.addItem(openAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit WattBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menuHasBeenBuilt = true
    }

    private func addInfo(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addEnergySection(to menu: NSMenu) {
        let energyUsageItem = NSMenuItem(
            title: "Track Energy Usage & Cost",
            action: #selector(toggleEnergyUsage),
            keyEquivalent: ""
        )
        energyUsageItem.target = self
        energyUsageItem.state = trackEnergyUsage ? .on : .off
        menu.addItem(energyUsageItem)

        if trackEnergyUsage {
            let summaryItem = NSMenuItem()
            summaryItem.view = energySummaryView()
            menu.addItem(summaryItem)
        }

        let tariffItem = NSMenuItem(
            title: "Electricity Tariffs…",
            action: #selector(editTariffs),
            keyEquivalent: ""
        )
        tariffItem.target = self
        tariffItem.indentationLevel = 1
        menu.addItem(tariffItem)

        let resetEnergyItem = NSMenuItem(
            title: "Reset Tracking Totals…",
            action: #selector(resetEnergyUsage),
            keyEquivalent: ""
        )
        resetEnergyItem.target = self
        resetEnergyItem.indentationLevel = 1
        resetEnergyItem.isEnabled =
            energyAccumulator.wattHours > 0 || energyAccumulator.activeSeconds > 0
        menu.addItem(resetEnergyItem)
    }

    private func energySummaryView() -> NSView {
        let width: CGFloat = 344
        let height: CGFloat = 160
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let title = NSTextField(labelWithString: "Energy & cost — tracking")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        let liveValue = energyValueLabel(formatWatts(latestReading?.systemWatts))
        let energyValue = energyValueLabel(formatEnergySummary(energyAccumulator.wattHours))
        let durationValue = energyValueLabel(formatTrackingDuration(energyAccumulator.activeSeconds))
        let kilowattHours = energyAccumulator.wattHours / 1_000
        let randValue = energyValueLabel(formatRand(kilowattHours * southAfricaTariff))
        let poundsValue = energyValueLabel(formatPounds(kilowattHours * unitedKingdomTariff))

        let grid = NSGridView(views: [
            [energyNameLabel("Live power"), liveValue],
            [energyNameLabel("Tracking time"), durationValue],
            [energyNameLabel("Energy used"), energyValue],
            [energyNameLabel("South Africa cost"), randValue],
            [energyNameLabel("United Kingdom cost"), poundsValue]
        ])
        grid.rowSpacing = 4
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing

        let tariffNote = NSTextField(
            labelWithString: String(
                format: "Rates: R %.4f/kWh and £%.4f/kWh",
                southAfricaTariff,
                unitedKingdomTariff
            )
        )
        tariffNote.font = NSFont.systemFont(ofSize: 10)
        tariffNote.textColor = .secondaryLabelColor

        let standingChargeNote = NSTextField(labelWithString: "Standing charges excluded")
        standingChargeNote.font = NSFont.systemFont(ofSize: 10)
        standingChargeNote.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, grid, tariffNote, standingChargeNote])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.setCustomSpacing(7, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        container.setAccessibilityElement(true)
        container.setAccessibilityLabel(
            """
            Energy tracking. Live power \(liveValue.stringValue). \
            Tracking time \(durationValue.stringValue). \
            Energy used \(energyValue.stringValue). \
            South Africa cost \(randValue.stringValue). \
            United Kingdom cost \(poundsValue.stringValue).
            """
        )
        return container
    }

    private func energyNameLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func energyValueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .right
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private func doubleValue(_ value: Any?) -> Double? {
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

private func boolValue(_ value: Any?) -> Bool? {
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

private func positiveDecimal(from text: String) -> Double? {
    let normalized = text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".")
    guard let value = Double(normalized), value.isFinite, value > 0 else { return nil }
    return value
}

private func formatWatts(_ watts: Double?) -> String {
    guard let watts else { return "unavailable" }
    return String(format: "%.1f W", watts)
}

private func formatWholeWatts(_ watts: Double) -> String {
    String(format: "%.0f W", watts)
}

private func formatEnergySummary(_ wattHours: Double) -> String {
    let kilowattHours = wattHours / 1_000
    if wattHours < 1 {
        return String(format: "%.3f Wh · %.5f kWh", wattHours, kilowattHours)
    }
    if wattHours < 1_000 {
        return String(format: "%.2f Wh · %.4f kWh", wattHours, kilowattHours)
    }
    return String(format: "%.3f kWh", kilowattHours)
}

private func formatTrackingDuration(_ seconds: TimeInterval) -> String {
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

private func formatSystemUptime(_ seconds: TimeInterval) -> String {
    formatTrackingDuration(seconds)
}

private func formatRand(_ rand: Double) -> String {
    rand < 0.01 ? String(format: "R %.4f", rand) : String(format: "R %.2f", rand)
}

private func formatPounds(_ pounds: Double) -> String {
    pounds < 0.01 ? String(format: "£%.4f", pounds) : String(format: "£%.2f", pounds)
}

private func formatBatteryFlow(_ watts: Double?) -> String {
    guard let watts else { return "unavailable" }

    if abs(watts) < 0.05 {
        return "0.0 W (not charging/discharging)"
    }

    if watts > 0 {
        return String(format: "%.1f W into battery", watts)
    }

    return String(format: "%.1f W from battery", abs(watts))
}

private func formatMenuBarPowerFlow(adapterInputWatts: Double?, batteryFlowWatts: Double?) -> String {
    if let adapterInputWatts, adapterInputWatts > 0.05 {
        return String(format: "⚡︎ %.1f W", adapterInputWatts)
    }

    if let batteryFlowWatts, batteryFlowWatts < -0.05 {
        return String(format: "−%.1f W", abs(batteryFlowWatts))
    }

    return "Power idle"
}

private enum StatusPowerIcon {
    case cpu
    case gpu
}

private func statusIconAttachment(_ icon: StatusPowerIcon, font: NSFont) -> NSAttributedString {
    let size = icon == .cpu ? NSSize(width: 15, height: 15) : NSSize(width: 18, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor.labelColor.setStroke()
        switch icon {
        case .cpu:
            drawCPUStatusIcon(in: rect)
        case .gpu:
            drawGPUStatusIcon(in: rect)
        }
        return true
    }
    image.isTemplate = true

    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NSRect(
        x: 0,
        y: floor(font.descender) + 1,
        width: size.width,
        height: size.height
    )
    return NSAttributedString(attachment: attachment)
}

private func drawCPUStatusIcon(in rect: NSRect) {
    let path = NSBezierPath()
    path.lineWidth = 1.15
    path.appendRoundedRect(NSRect(x: 3.5, y: 3.5, width: 8, height: 8), xRadius: 1.2, yRadius: 1.2)
    path.appendRoundedRect(NSRect(x: 5.5, y: 5.5, width: 4, height: 4), xRadius: 0.6, yRadius: 0.6)
    for point in [5.5, 7.5, 9.5] {
        path.move(to: NSPoint(x: point, y: 1.5))
        path.line(to: NSPoint(x: point, y: 3.5))
        path.move(to: NSPoint(x: point, y: 11.5))
        path.line(to: NSPoint(x: point, y: 13.5))
        path.move(to: NSPoint(x: 1.5, y: point))
        path.line(to: NSPoint(x: 3.5, y: point))
        path.move(to: NSPoint(x: 11.5, y: point))
        path.line(to: NSPoint(x: 13.5, y: point))
    }
    path.stroke()
}

private func drawGPUStatusIcon(in rect: NSRect) {
    let path = NSBezierPath()
    path.lineWidth = 1.1
    path.appendRoundedRect(NSRect(x: 1, y: 2, width: 14, height: 10), xRadius: 1.4, yRadius: 1.4)
    path.appendOval(in: NSRect(x: 3, y: 4, width: 6, height: 6))
    path.appendOval(in: NSRect(x: 5.3, y: 6.3, width: 1.4, height: 1.4))
    for y in [5.2, 7, 8.8] {
        path.move(to: NSPoint(x: 10.5, y: y))
        path.line(to: NSPoint(x: 13.5, y: y))
    }
    path.move(to: NSPoint(x: 15, y: 4))
    path.line(to: NSPoint(x: 17, y: 4))
    path.move(to: NSPoint(x: 15, y: 10))
    path.line(to: NSPoint(x: 17, y: 10))
    path.move(to: NSPoint(x: 4, y: 2))
    path.line(to: NSPoint(x: 4, y: 0.8))
    path.line(to: NSPoint(x: 10, y: 0.8))
    path.stroke()
}

private func formatGPUWatts(_ watts: Double?) -> String {
    guard let watts else { return "unavailable" }
    return String(format: "%.1f W (estimated)", watts)
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()

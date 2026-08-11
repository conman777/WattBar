import Cocoa
import Darwin
import IOKit
import ServiceManagement

@_silgen_name("wattbar_gpu_watts")
private func wattbar_gpu_watts() -> Double

@_silgen_name("wattbar_cpu_temperature_celsius")
private func wattbar_cpu_temperature_celsius() -> Double

private enum DefaultsKey {
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

private struct NetworkSpeedReading {
    let downloadBytesPerSecond: Double
    let uploadBytesPerSecond: Double
    let totalDownloadedBytes: UInt64
    let totalUploadedBytes: UInt64
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

private final class CPUTemperatureReader {
    func read() -> Double? {
        let celsius = wattbar_cpu_temperature_celsius()
        return celsius >= 0 ? celsius : nil
    }
}

private final class StatusItemHoverHandler: NSObject {
    private let onEnter: () -> Void
    private let onExit: () -> Void

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
    }

    @objc func mouseEntered(with event: NSEvent) {
        onEnter()
    }

    @objc func mouseExited(with event: NSEvent) {
        onExit()
    }
}

private final class NetworkSpeedReader {
    private var previousSample: (receivedBytes: UInt64, sentBytes: UInt64, date: Date)?
    private var totalDownloadedBytes: UInt64 = 0
    private var totalUploadedBytes: UInt64 = 0

    func read(at date: Date = Date()) -> NetworkSpeedReading? {
        guard let counters = interfaceByteCounters() else {
            previousSample = nil
            return nil
        }

        guard let previousSample else {
            self.previousSample = (counters.receivedBytes, counters.sentBytes, date)
            return NetworkSpeedReading(
                downloadBytesPerSecond: 0,
                uploadBytesPerSecond: 0,
                totalDownloadedBytes: 0,
                totalUploadedBytes: 0
            )
        }
        let elapsed = date.timeIntervalSince(previousSample.date)
        self.previousSample = (counters.receivedBytes, counters.sentBytes, date)
        guard elapsed > 0 else {
            return nil
        }

        let downloadedBytes = counters.receivedBytes >= previousSample.receivedBytes
            ? counters.receivedBytes - previousSample.receivedBytes
            : 0
        let uploadedBytes = counters.sentBytes >= previousSample.sentBytes
            ? counters.sentBytes - previousSample.sentBytes
            : 0
        totalDownloadedBytes &+= downloadedBytes
        totalUploadedBytes &+= uploadedBytes

        return NetworkSpeedReading(
            downloadBytesPerSecond: Double(downloadedBytes) / elapsed,
            uploadBytesPerSecond: Double(uploadedBytes) / elapsed,
            totalDownloadedBytes: totalDownloadedBytes,
            totalUploadedBytes: totalUploadedBytes
        )
    }

    private func interfaceByteCounters() -> (receivedBytes: UInt64, sentBytes: UInt64)? {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return nil }
        defer { freeifaddrs(firstAddress) }

        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var foundInterface = false
        var address: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = address {
            let interface = current.pointee
            if let socketAddress = interface.ifa_addr,
               socketAddress.pointee.sa_family == UInt8(AF_LINK),
               interface.ifa_flags & UInt32(IFF_UP) != 0,
               interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
               let rawData = interface.ifa_data {
                let data = rawData.assumingMemoryBound(to: if_data.self).pointee
                receivedBytes &+= UInt64(data.ifi_ibytes)
                sentBytes &+= UInt64(data.ifi_obytes)
                foundInterface = true
            }
            address = interface.ifa_next
        }

        return foundInterface ? (receivedBytes, sentBytes) : nil
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let reader = SystemPowerReader()
    private let gpuReader = GPUReader()
    private let cpuTemperatureReader = CPUTemperatureReader()
    private let networkSpeedReader = NetworkSpeedReader()
    private let activeAppReader = ActiveAppReader()
    private let activeAppRefreshInterval: TimeInterval = 15
    private let energyPersistenceInterval: TimeInterval = 30
    private let statusFont = NSFont.monospacedDigitSystemFont(
        ofSize: 10,
        weight: .regular
    )
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var hoverTrackingHandler: StatusItemHoverHandler?
    private var hoverPopover: NSPopover?
    private var localRightClickMonitor: Any?
    private var globalRightClickMonitor: Any?
    private var lastRightClickTime: TimeInterval = 0
    private var statusMenuPresentationPending = false
    private var timer: Timer?
    private var instanceLock: InstanceLock?
    private var latestReading: PowerReading?
    private var latestGPUWatts: Double?
    private var latestCPUTemperature: Double?
    private var latestNetworkSpeed: NetworkSpeedReading?
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
    private lazy var compactStatusImage: NSImage? = {
        guard let image = NSImage(
            systemSymbolName: "bolt.horizontal.circle",
            accessibilityDescription: "WattBar"
        ) else { return nil }

        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let configuredImage = image.withSymbolConfiguration(configuration) ?? image
        configuredImage.isTemplate = true
        return configuredImage
    }()

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

    private var compactMenuBar: Bool {
        get {
            UserDefaults.standard.bool(forKey: DefaultsKey.compactMenuBar)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.compactMenuBar)
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

    private var showNetworkSpeeds: Bool {
        get {
            UserDefaults.standard.bool(forKey: DefaultsKey.showNetworkSpeeds)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.showNetworkSpeeds)
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
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(handleStatusItemClick)
        statusItem?.button?.sendAction(on: [.leftMouseUp])
        installHoverTracking()
        installRightClickHandling()

        refresh()
        scheduleTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let localRightClickMonitor {
            NSEvent.removeMonitor(localRightClickMonitor)
        }
        if let globalRightClickMonitor {
            NSEvent.removeMonitor(globalRightClickMonitor)
        }
        persistEnergyUsage(force: true)
    }

    @objc private func refresh() {
        let reading = reader.read(
            maximumExternalAge: max(15, refreshInterval * 2.5)
        )
        updateEnergyUsage(with: reading)
        latestReading = reading
        latestGPUWatts = gpuReader.read()
        latestCPUTemperature = cpuTemperatureReader.read()
        latestNetworkSpeed = networkSpeedReader.read(at: reading.updatedAt)
        if menuIsOpen {
            refreshActiveAppsIfNeeded(minimumAge: activeAppRefreshInterval)
        }
        rebuildMenu()
        updateStatusTitle()
        updateHoverPopover()
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

    @objc private func handleStatusItemClick() {
        hideHoverPopover()
        compactMenuBar.toggle()
        rebuildMenu(force: true)
        updateStatusTitle()
    }

    @objc private func toggleCompactMenuBar() {
        compactMenuBar.toggle()
        rebuildMenu()
        updateStatusTitle()
    }

    private func installHoverTracking() {
        guard let button = statusItem?.button else { return }

        let handler = StatusItemHoverHandler(
            onEnter: { [weak self] in self?.showHoverPopover() },
            onExit: { [weak self] in self?.hideHoverPopover() }
        )
        let trackingArea = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: handler,
            userInfo: nil
        )
        button.addTrackingArea(trackingArea)
        hoverTrackingHandler = handler
    }

    private func installRightClickHandling() {
        localRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
            guard let self else { return event }
            return self.handleRightClickIfNeeded() ? nil : event
        }
        globalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .rightMouseUp) { [weak self] _ in
            _ = self?.handleRightClickIfNeeded()
        }
    }

    @discardableResult
    private func handleRightClickIfNeeded() -> Bool {
        guard let button = statusItem?.button,
              let window = button.window else { return false }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = window.convertToScreen(buttonFrameInWindow)
        guard buttonFrameOnScreen.contains(NSEvent.mouseLocation) else { return false }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRightClickTime > 0.2 else { return true }
        lastRightClickTime = now

        presentStatusMenu()
        return true
    }

    private func presentStatusMenu() {
        guard !statusMenuPresentationPending else { return }
        statusMenuPresentationPending = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusMenuPresentationPending = false
            self.showStatusMenu()
        }
    }

    private func showStatusMenu() {
        if statusMenu == nil {
            rebuildMenu(force: true)
        }
        guard let menu = statusMenu, let button = statusItem?.button else { return }
        hideHoverPopover()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.midX, y: button.bounds.minY),
            in: button
        )
    }

    private func showHoverPopover() {
        guard compactMenuBar, let button = statusItem?.button else { return }

        let popover = hoverPopover ?? NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hoverDetailViewController()
        hoverPopover = popover

        if !popover.isShown {
            popover.show(
                relativeTo: button.bounds,
                of: button,
                preferredEdge: .maxY
            )
        }
    }

    private func hideHoverPopover() {
        hoverPopover?.performClose(nil)
    }

    private func updateHoverPopover() {
        guard hoverPopover?.isShown == true else { return }
        hoverPopover?.contentViewController = hoverDetailViewController()
    }

    private func hoverDetailViewController() -> NSViewController {
        let text = NSTextField(wrappingLabelWithString: hoverDetailsText())
        text.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textColor = .labelColor
        text.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 190))
        container.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14)
        ])

        let controller = NSViewController()
        controller.view = container
        controller.preferredContentSize = NSSize(width: 330, height: 190)
        return controller
    }

    private func hoverDetailsText() -> String {
        guard let reading = latestReading else { return "WattBar is measuring…" }

        return """
        System draw: \(formatWatts(reading.systemWatts))
        CPU temperature: \(formatCPUTemperature(latestCPUTemperature))
        Adapter input: \(formatWatts(reading.adapterInputWatts))
        GPU draw: \(formatGPUWatts(latestGPUWatts))
        Power: \(reading.powerState)
        Battery flow: \(formatBatteryFlow(reading.batteryFlowWatts))
        Download: \(formatNetworkSpeed(latestNetworkSpeed?.downloadBytesPerSecond))
        Upload: \(formatNetworkSpeed(latestNetworkSpeed?.uploadBytesPerSecond))
        Total downloaded: \(formatByteCount(latestNetworkSpeed?.totalDownloadedBytes))
        Total uploaded: \(formatByteCount(latestNetworkSpeed?.totalUploadedBytes))
        """
    }

    @objc private func toggleChargingRate() {
        showChargingRate.toggle()
        rebuildMenu()
        updateStatusTitle()
    }

    @objc private func toggleNetworkSpeeds() {
        showNetworkSpeeds.toggle()
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
            applyStatusPresentation(
                length: compactMenuBar ? 28 : NSStatusItem.variableLength,
                image: compactMenuBar ? compactStatusImage : nil,
                title: compactMenuBar ? "" : "WattBar",
                attributedTitle: NSAttributedString(string: ""),
                accessibilityLabel: "WattBar",
                toolTip: "WattBar is measuring..."
            )
            return
        }

        let wattsValue = reading.systemWatts.map { String(format: "%.1f W", $0) } ?? "-- W"
        let gpuValue = latestGPUWatts.map { String(format: "%.1f W", $0) } ?? "-- W"
        let uptimeValue = formatSystemUptime(ProcessInfo.processInfo.systemUptime)
        let cpuTemperatureValue = formatCPUTemperature(latestCPUTemperature, unavailable: "-- °C")
        let compactWattsValue = reading.systemWatts.map { String(format: "%.0fW", $0) } ?? "--W"
        let compactGPUValue = latestGPUWatts.map { String(format: "%.0fW", $0) } ?? "--W"
        let compactCPUTemperatureValue = latestCPUTemperature.map { String(format: "%.0f°", $0) } ?? "--°"
        let powerFlowText = showChargingRate
            ? formatCompactMenuBarPowerFlow(
                adapterInputWatts: reading.adapterInputWatts,
                batteryFlowWatts: reading.batteryFlowWatts
            )
            : nil
        let gpuTooltip = latestGPUWatts.map { String(format: "%.1f W", $0) } ?? "unavailable"
        let batteryTooltip = formatBatteryFlow(reading.batteryFlowWatts)
        let compactNetworkValue = showNetworkSpeeds
            ? formatCompactNetworkSpeed(latestNetworkSpeed)
            : nil
        let signature = [
            showMenuBarLabel ? "label" : "no-label",
            compactMenuBar ? "compact" : "expanded",
            compactWattsValue,
            compactCPUTemperatureValue,
            compactGPUValue,
            uptimeValue,
            powerFlowText ?? "no-flow",
            compactNetworkValue ?? "no-network",
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
        attributedTitle.append(
            NSAttributedString(
                string: " \(compactWattsValue) \(compactCPUTemperatureValue)",
                attributes: attributes
            )
        )

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
        attributedTitle.append(NSAttributedString(string: " \(compactGPUValue)", attributes: attributes))

        if let compactNetworkValue {
            attributedTitle.append(NSAttributedString(string: " | \(compactNetworkValue)", attributes: attributes))
        }

        let accessibleParts = [
            "System \(wattsValue)",
            "CPU temperature \(cpuTemperatureValue)",
            (showChargingRate || compactMenuBar) ? formatMenuBarPowerFlow(
                adapterInputWatts: reading.adapterInputWatts,
                batteryFlowWatts: reading.batteryFlowWatts
            ) : nil,
            (showNetworkSpeeds || compactMenuBar) ? formatAccessibleNetworkSpeed(latestNetworkSpeed) : nil,
            "GPU \(gpuValue)",
            "Computer uptime \(uptimeValue)"
        ].compactMap { $0 }
        let accessibleTitle = accessibleParts.joined(separator: " | ")
        let width = ceil(attributedTitle.size().width) + 12

        statusItem?.button?.font = font
        let networkTooltip = (showNetworkSpeeds || compactMenuBar)
            ? " | \(formatAccessibleNetworkSpeed(latestNetworkSpeed)) | Total downloaded \(formatByteCount(latestNetworkSpeed?.totalDownloadedBytes)) | Total uploaded \(formatByteCount(latestNetworkSpeed?.totalUploadedBytes))"
            : ""
        let chargingTooltip = (showChargingRate || compactMenuBar)
            ? " | \(formatMenuBarPowerFlow(adapterInputWatts: reading.adapterInputWatts, batteryFlowWatts: reading.batteryFlowWatts))"
            : ""
        applyStatusPresentation(
            length: compactMenuBar ? 28 : max(40, width),
            image: compactMenuBar ? compactStatusImage : nil,
            title: compactMenuBar ? "" : accessibleTitle,
            attributedTitle: compactMenuBar
                ? NSAttributedString(string: "")
                : attributedTitle,
            accessibilityLabel: "WattBar \(accessibleTitle)",
            toolTip: "System draw: \(wattsValue) | CPU temperature: \(cpuTemperatureValue) | Battery: \(batteryTooltip) | GPU: \(gpuTooltip) | Computer uptime: \(uptimeValue)\(chargingTooltip)\(networkTooltip)"
        )
    }

    private func applyStatusPresentation(
        length: CGFloat,
        image: NSImage?,
        title: String,
        attributedTitle: NSAttributedString,
        accessibilityLabel: String,
        toolTip: String
    ) {
        guard let statusItem, let button = statusItem.button else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            // Replace the contents before resizing the status item so AppKit
            // never renders the compact icon over the expanded text.
            button.image = image
            button.imagePosition = image == nil ? .noImage : .imageOnly
            button.imageScaling = .scaleNone
            button.title = title
            button.attributedTitle = attributedTitle
            button.setAccessibilityLabel(accessibilityLabel)
            button.toolTip = toolTip
            statusItem.length = length
            button.needsLayout = true
            button.layoutSubtreeIfNeeded()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        hideHoverPopover()
        menuIsOpen = true
        refreshActiveAppsIfNeeded(minimumAge: 5)
        rebuildMenu(force: true)
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    private func rebuildMenu(force: Bool = false) {
        let menu: NSMenu
        if let existingMenu = statusMenu {
            menu = existingMenu
        } else {
            menu = NSMenu(title: "WattBar")
            menu.delegate = self
            statusMenu = menu
        }

        guard force || menuIsOpen || !menuHasBeenBuilt else { return }
        menu.removeAllItems()

        let compactMenuItem = NSMenuItem(
            title: compactMenuBar ? "Show Full Display" : "Minimize WattBar",
            action: #selector(toggleCompactMenuBar),
            keyEquivalent: ""
        )
        compactMenuItem.target = self
        compactMenuItem.state = compactMenuBar ? .on : .off
        menu.addItem(compactMenuItem)
        menu.addItem(.separator())

        addSectionHeader("Live readings", to: menu)
        if let reading = latestReading {
            addInfo("System draw   \(formatWatts(reading.systemWatts))", to: menu)
            addInfo("CPU temperature   \(formatCPUTemperature(latestCPUTemperature))", to: menu)
            addInfo("Adapter input   \(formatWatts(reading.adapterInputWatts))", to: menu)
            addInfo("GPU draw   \(formatGPUWatts(latestGPUWatts))", to: menu)
            addInfo("Power   \(reading.powerState)", to: menu)
            addInfo("Battery flow   \(formatBatteryFlow(reading.batteryFlowWatts))", to: menu)

            let detailsItem = NSMenuItem(title: "Reading details", action: nil, keyEquivalent: "")
            let detailsMenu = NSMenu(title: "Reading details")
            addInfo("Whole-device source   \(reading.source)", to: detailsMenu)
            addInfo("Details   \(reading.details)", to: detailsMenu)
            addInfo("Updated   \(formatter.string(from: reading.updatedAt))", to: detailsMenu)
            detailsItem.submenu = detailsMenu
            menu.addItem(detailsItem)
        } else {
            addInfo("WattBar is measuring…", to: menu)
        }

        addInfo(
            "Computer uptime: \(formatSystemUptime(ProcessInfo.processInfo.systemUptime))",
            to: menu
        )

        menu.addItem(.separator())

        let energyItem = NSMenuItem(title: "Energy & Cost", action: nil, keyEquivalent: "")
        let energyMenu = NSMenu(title: "Energy & Cost")
        addEnergySection(to: energyMenu)
        energyItem.submenu = energyMenu
        menu.addItem(energyItem)

        let networkItem = NSMenuItem(title: "Network Speeds & Totals", action: nil, keyEquivalent: "")
        networkItem.submenu = networkUsageMenu()
        menu.addItem(networkItem)

        let activeAppsItem = NSMenuItem(title: "Active Apps", action: nil, keyEquivalent: "")
        activeAppsItem.submenu = activeAppsMenu()
        menu.addItem(activeAppsItem)

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu()
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit WattBar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menuHasBeenBuilt = true
    }

    private func addSectionHeader(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        menu.addItem(item)
    }

    private func networkUsageMenu() -> NSMenu {
        let menu = NSMenu(title: "Network Speeds & Totals")

        let networkSpeedsItem = NSMenuItem(
            title: "Show Speeds in Menu Bar",
            action: #selector(toggleNetworkSpeeds),
            keyEquivalent: ""
        )
        networkSpeedsItem.target = self
        networkSpeedsItem.state = showNetworkSpeeds ? .on : .off
        menu.addItem(networkSpeedsItem)
        menu.addItem(.separator())
        addInfo("Current download   \(formatNetworkSpeed(latestNetworkSpeed?.downloadBytesPerSecond))", to: menu)
        addInfo("Current upload   \(formatNetworkSpeed(latestNetworkSpeed?.uploadBytesPerSecond))", to: menu)
        addInfo("Total downloaded   \(formatByteCount(latestNetworkSpeed?.totalDownloadedBytes))", to: menu)
        addInfo("Total uploaded   \(formatByteCount(latestNetworkSpeed?.totalUploadedBytes))", to: menu)
        return menu
    }

    private func activeAppsMenu() -> NSMenu {
        let menu = NSMenu(title: "Active Apps")

        let activeAppsToggle = NSMenuItem(
            title: showActiveApps ? "Hide Active Apps" : "Show Active Apps",
            action: #selector(toggleActiveApps),
            keyEquivalent: ""
        )
        activeAppsToggle.target = self
        activeAppsToggle.state = showActiveApps ? .on : .off
        menu.addItem(activeAppsToggle)
        menu.addItem(.separator())

        if showActiveApps {
            if latestActiveApps.isEmpty {
                addInfo("No busy apps right now", to: menu)
            } else {
                for (index, app) in latestActiveApps.enumerated() {
                    addInfo(
                        "\(index + 1). \(app.name)   \(String(format: "%.1f", app.cpu))% CPU · \(app.memoryMB) MB RAM",
                        to: menu
                    )
                }
            }
        } else {
            addInfo("Active-app readings are hidden", to: menu)
        }
        return menu
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu(title: "Settings")

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let intervalItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        let intervalMenu = NSMenu(title: "Refresh Interval")
        for interval in [2.0, 5.0, 10.0, 30.0] {
            let item = NSMenuItem(title: "Every \(Int(interval)) seconds", action: #selector(setRefreshInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = abs(refreshInterval - interval) < 0.1 ? .on : .off
            intervalMenu.addItem(item)
        }
        intervalItem.submenu = intervalMenu
        menu.addItem(intervalItem)
        menu.addItem(.separator())

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
        return menu
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

private func formatCompactMenuBarPowerFlow(adapterInputWatts: Double?, batteryFlowWatts: Double?) -> String {
    if let adapterInputWatts, adapterInputWatts > 0.05 {
        return String(format: "⚡︎%.0fW", adapterInputWatts)
    }

    if let batteryFlowWatts, batteryFlowWatts < -0.05 {
        return String(format: "−%.0fW", abs(batteryFlowWatts))
    }

    return "Idle"
}

private func formatNetworkSpeed(_ bytesPerSecond: Double?) -> String {
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

private func formatCompactNetworkSpeed(_ reading: NetworkSpeedReading?) -> String {
    guard let reading else { return "↓-- ↑--" }
    return "↓\(formatNetworkSpeed(reading.downloadBytesPerSecond)) ↑\(formatNetworkSpeed(reading.uploadBytesPerSecond))"
}

private func formatAccessibleNetworkSpeed(_ reading: NetworkSpeedReading?) -> String {
    guard let reading else { return "Network speed measuring" }
    return "Download \(formatNetworkSpeed(reading.downloadBytesPerSecond)), upload \(formatNetworkSpeed(reading.uploadBytesPerSecond))"
}

private func formatByteCount(_ bytes: UInt64?) -> String {
    guard let bytes else { return "measuring…" }
    return ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)
}

private enum StatusPowerIcon {
    case cpu
    case gpu
}

private func statusIconAttachment(_ icon: StatusPowerIcon, font: NSFont) -> NSAttributedString {
    let baseSize = icon == .cpu ? NSSize(width: 15, height: 15) : NSSize(width: 18, height: 14)
    let scale = font.pointSize / NSFont.systemFontSize
    let displaySize = NSSize(
        width: round(baseSize.width * scale),
        height: round(baseSize.height * scale)
    )
    let image = NSImage(size: baseSize, flipped: false) { rect in
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
        width: displaySize.width,
        height: displaySize.height
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

private func formatCPUTemperature(_ celsius: Double?, unavailable: String = "unavailable") -> String {
    guard let celsius else { return unavailable }
    return String(format: "%.0f °C", celsius)
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.run()

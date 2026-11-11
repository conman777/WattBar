import Cocoa
import Darwin
import IOKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WattBarActions {
    private let reader = SystemPowerReader()
    private let gpuReader = GPUReader()
    private let cpuTemperatureReader = CPUTemperatureReader()
    private let fanSpeedReader = FanSpeedReader()
    private let networkSpeedReader = NetworkSpeedReader()
    private let cpuUsageReader = CPUUsageReader()
    private let memoryPressureReader = MemoryPressureReader()
    private let activeAppLoader = ActiveAppLoader()
    private let settings = AppSettings()
    private lazy var energyTracker = EnergyTracker(defaults: settings.defaults)
    private var displayController: StatusDisplayController?

    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var timer: Timer?
    private var instanceLock: InstanceLock?
    private var latestReading: PowerReading?
    private var latestGPUWatts: Double?
    private var latestCPUTemperature: Double?
    private var latestFanRPM: Double?
    private var temperatureHistory = TemperatureHistory()
    private lazy var graphHistory = GraphHistory(peaks: settings.graphPeaks)
    private var latestNetworkSpeed: NetworkSpeedReading?
    private var latestCPUUsage: Double?
    private var latestMemoryPressure: MemoryPressureReading?
    private var menuIsOpen = false
    private var livePanel: LiveMenuPanel?

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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let statusItem {
            displayController = StatusDisplayController(statusItem: statusItem, settings: settings)
        }
        // Every click opens the panel, filled in menuNeedsUpdate.
        let menu = NSMenu(title: "WattBar")
        if let statusItem { configureStatusMenu(item: statusItem, menu: menu) }

        activeAppLoader.onUpdate = { [weak self] in
            guard let self, self.menuIsOpen, self.settings.showActiveApps,
                  let menu = self.statusMenu else { return }
            StatusMenuBuilder.updateActiveApps(in: menu, apps: self.activeAppLoader.apps)
        }
        activeAppLoader.setEnabled(settings.showActiveApps)
        refresh()
        scheduleTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if instanceLock != nil { energyTracker.persist() }
    }

    @objc func refresh() {
        let reading = reader.read(
            maximumExternalAge: max(15, settings.refreshInterval * 2.5)
        )
        energyTracker.add(reading, enabled: settings.trackEnergyUsage, refreshInterval: settings.refreshInterval)
        latestReading = reading
        latestGPUWatts = gpuReader.read()
        latestCPUTemperature = cpuTemperatureReader.read()
        temperatureHistory.add(latestCPUTemperature, at: reading.updatedAt)
        latestFanRPM = fanSpeedReader.read()
        latestNetworkSpeed = networkSpeedReader.read()
        latestCPUUsage = cpuUsageReader.read()
        latestMemoryPressure = memoryPressureReader.read()
        // Every metric is recorded, so switching the graph shows history at once.
        let peaks = graphHistory.peaks
        graphHistory.add([
            .systemDraw: reading.systemWatts,
            .cpuTemperature: latestCPUTemperature,
            .cpuUsage: latestCPUUsage,
            .memoryPressure: latestMemoryPressure?.percentage,
            .gpuDraw: latestGPUWatts,
            .networkDownload: latestNetworkSpeed?.downloadBytesPerSecond,
            .batteryFlow: reading.batteryFlowWatts
        ], at: reading.updatedAt)
        if graphHistory.peaks != peaks { settings.graphPeaks = graphHistory.peaks }

        updateStatusTitle()
        if menuIsOpen { livePanel?.update(menuSnapshot()) }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    @objc func setRefreshInterval(_ sender: NSMenuItem) {
        guard let interval = sender.representedObject as? TimeInterval else { return }
        settings.refreshInterval = interval
        scheduleTimer()
    }

    @objc func toggleActiveApps() {
        settings.showActiveApps.toggle()
        activeAppLoader.setEnabled(settings.showActiveApps)
        refresh()
    }

    @objc func toggleMenuBarLabel() {
        settings.showMenuBarLabel.toggle()
        updateStatusTitle()
    }

    func configureStatusMenu(item: NSStatusItem, menu: NSMenu) {
        statusItem = item; statusMenu = menu
        menu.delegate = self
        item.button?.target = self
        item.button?.action = #selector(handleStatusItemClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func handleStatusItemClick() {
        openStatusMenu()
    }

    /// Attach only for the click so AppKit positions and highlights it natively.
    private func openStatusMenu() {
        guard !menuIsOpen, let menu = statusMenu, let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    @objc func toggleCompactMenuBar() {
        settings.compactMenuBar.toggle()
        updateStatusTitle()
    }

    @objc func toggleChargingRate() {
        settings.showChargingRate.toggle()
        updateStatusTitle()
    }

    @objc func setGraphMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let metric = GraphMetric(rawValue: raw) else { return }
        settings.graphMetric = metric
        livePanel?.syncSelection()
        updateStatusTitle()
    }

    @objc func setGraphStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = GraphStyle(rawValue: raw) else { return }
        settings.graphStyle = style
        updateStatusTitle()
    }

    @objc func toggleNetworkSpeeds() {
        settings.showNetworkSpeeds.toggle()
        updateStatusTitle()
    }

    @objc func toggleEnergyUsage() {
        settings.trackEnergyUsage.toggle()
        if !settings.trackEnergyUsage {
            energyTracker.pause()
            energyTracker.persist()
        }
        refresh()
    }

    @objc func editTariffs() {
        let alert = NSAlert()
        alert.messageText = "Electricity Tariffs"
        alert.informativeText = """
        Enter the unit rates from your electricity bills. Cost totals exclude standing charges.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let randField = NSTextField(string: formatRate(settings.southAfricaTariff))
        let poundsField = NSTextField(string: formatRate(settings.unitedKingdomTariff))
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

            settings.southAfricaTariff = randRate
            settings.unitedKingdomTariff = poundsRate

            return
        }
    }

    @objc func resetEnergyUsage() {
        let alert = NSAlert()
        alert.messageText = "Reset tracked usage?"
        alert.informativeText = "This resets tracking time, accumulated watt-hours, and both cost totals to zero."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        energyTracker.reset()
        energyTracker.persist()
        refresh()
    }

    @objc func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showAlert(title: "Open at Login Unavailable", message: error.localizedDescription)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = min(0.5, settings.refreshInterval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateStatusTitle() {
        // Readings redraw while tracking; the controller defers width changes.
        displayController?.update(reading: latestReading, gpuWatts: latestGPUWatts,
            cpuTemperature: latestCPUTemperature, fanRPM: latestFanRPM, network: latestNetworkSpeed,
            uptime: ProcessInfo.processInfo.systemUptime, graph: graphHistory,
            cpuUsage: latestCPUUsage, memoryPressure: latestMemoryPressure)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        guard !menuIsOpen else { return }
        activeAppLoader.refreshIfNeeded()
        livePanel = StatusMenuBuilder(settings: settings, snapshot: menuSnapshot(), actions: self).populate(menu)
    }

    private func menuSnapshot() -> MenuSnapshot {
        MenuSnapshot(reading: latestReading, gpuWatts: latestGPUWatts,
            cpuTemperature: latestCPUTemperature, fanRPM: latestFanRPM, network: latestNetworkSpeed,
            activeApps: activeAppLoader.apps, energy: energyTracker.accumulator,
            uptime: ProcessInfo.processInfo.systemUptime, temperatureHistory: temperatureHistory,
            cpuUsage: latestCPUUsage, memoryPressure: latestMemoryPressure)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menuIsOpen = true
        livePanel?.startTracking()
        displayController?.isMenuTracking = true
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        statusItem?.menu = nil
        menuIsOpen = false
        livePanel = nil
        displayController?.isMenuTracking = false
        updateStatusTitle()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}


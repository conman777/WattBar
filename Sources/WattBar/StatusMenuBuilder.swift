import Cocoa
import ServiceManagement

@objc protocol WattBarActions: AnyObject {
    func toggleCompactMenuBar()
    func toggleNetworkSpeeds()
    func toggleActiveApps()
    func refresh()
    func setRefreshInterval(_ sender: NSMenuItem)
    func toggleMenuBarLabel()
    func toggleChargingRate()
    func setGraphMetric(_ sender: NSMenuItem)
    func setGraphStyle(_ sender: NSMenuItem)
    func toggleOpenAtLogin()
    func toggleEnergyUsage()
    func editTariffs()
    func resetEnergyUsage()
    func quit()
}

struct MenuSnapshot {
    let reading: PowerReading?
    let gpuWatts: Double?
    let cpuTemperature: Double?
    let fanRPM: Double?
    let network: NetworkSpeedReading?
    let activeApps: [ActiveApp]?
    let energy: EnergyAccumulator
    let uptime: TimeInterval
    var temperatureHistory = TemperatureHistory()
    var cpuUsage: Double? = nil
    var memoryPressure: MemoryPressureReading? = nil
}

final class StatusMenuBuilder {
    static let activeAppRowCount = 5

    let settings: AppSettings
    let snapshot: MenuSnapshot
    weak var actions: (any WattBarActions)?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(settings: AppSettings, snapshot: MenuSnapshot, actions: any WattBarActions) {
        self.settings = settings
        self.snapshot = snapshot
        self.actions = actions
    }

    @discardableResult
    func populate(_ menu: NSMenu) -> LiveMenuPanel {
        menu.removeAllItems()

        // Informational rows are view-backed items of one width; their titles
        // keep each section identifiable to tests and assistive technology.
        let updated = snapshot.reading.map { formatter.string(from: $0.updatedAt) }
        let dashboard = DashboardView(snapshot: snapshot, updated: updated, now: Date())
        addPanel(dashboard,
                 title: updated.map { "Readings · \($0)" } ?? "Readings", to: menu)

        menu.addItem(.separator())
        let network = networkRow()
        addPanel(network, title: "Network", to: menu)
        var energy: SummaryRowView?

        if settings.trackEnergyUsage {
            menu.addItem(.separator())
            energy = energyRow()
            addPanel(energy!, title: "Energy & Cost", to: menu)
        }

        if settings.showActiveApps {
            menu.addItem(.separator())
            addPanel(AppHeaderView(), title: "Busiest Apps", to: menu)
            // Reserve the rows so an asynchronous result changes only their
            // contents and visibility, without rebuilding a menu AppKit is tracking.
            for index in 0..<Self.activeAppRowCount {
                let row = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                row.isEnabled = false
                row.identifier = NSUserInterfaceItemIdentifier("active-app-\(index)")
                row.view = AppRowView()
                Self.configureActiveAppRow(row, apps: snapshot.activeApps, index: index)
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())

        let detailsMenu = NSMenu(title: "Reading Details")
        var details: [(String, String)] = []
        if let reading = snapshot.reading {
            details += [("Whole-device source", reading.source), ("Details", reading.details),
                        ("Power state", reading.powerState)]
        }
        details.append(("CPU usage", formatPercentage(snapshot.cpuUsage)))
        details.append(("Memory pressure", formatMemoryPressure(snapshot.memoryPressure)))
        details.append(("Computer uptime", formatSystemUptime(snapshot.uptime)))
        if let updated { details.append(("Updated", updated)) }
        Self.addRows(details, to: detailsMenu)
        addSubmenu("Reading Details", detailsMenu, to: menu)
        addSubmenu("Menu Bar Display", menuBarDisplayMenu(), to: menu)
        addSubmenu("Settings", settingsMenu(), to: menu)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit WattBar", action: #selector(WattBarActions.quit), keyEquivalent: "q")
        quitItem.target = actions
        menu.addItem(quitItem)
        return LiveMenuPanel(menu: menu, dashboard: dashboard, network: network, energy: energy,
                             settings: settings, actions: actions, snapshot: snapshot)
    }

    private func addPanel(_ view: NSView, title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.view = view
        menu.addItem(item)
    }

    private func networkRow() -> SummaryRowView {
        guard let network = snapshot.network else {
            return SummaryRowView(title: "Network", value: "Measuring…", detailTitle: "Since launch", detailValue: "--")
        }
        return SummaryRowView(
            title: "Network",
            value: "↓ \(formatNetworkSpeed(network.downloadBytesPerSecond))  ↑ \(formatNetworkSpeed(network.uploadBytesPerSecond))",
            detailTitle: "Since launch",
            detailValue: "↓ \(formatByteCount(network.totalDownloadedBytes))  ↑ \(formatByteCount(network.totalUploadedBytes))"
        )
    }

    private func energyRow() -> SummaryRowView {
        let wattHours = snapshot.energy.wattHours
        let kilowattHours = wattHours / 1_000
        let value = [formatShortEnergy(wattHours), formatRand(kilowattHours * settings.southAfricaTariff),
                     formatPounds(kilowattHours * settings.unitedKingdomTariff)].joined(separator: " · ")
        return SummaryRowView(title: "Energy", value: value, detailTitle: "Tracked for",
                              detailValue: formatTrackingDuration(snapshot.energy.activeSeconds))
    }

    @discardableResult
    private func addSubmenu(_ title: String, _ submenu: NSMenu, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
        return item
    }

    /// Toggles keep a fixed title and show their state with a checkmark only.
    private func addToggle(_ title: String, _ action: Selector, isOn: Bool, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = actions
        item.state = isOn ? .on : .off
        menu.addItem(item)
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

    private static var rowFont: NSFont { NSFont.menuFont(ofSize: 0) }
    private static var valueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: rowFont.pointSize, weight: .regular)
    }

    static func labelWidth(for rows: [(String, String)]) -> CGFloat {
        rows.map { ($0.0 as NSString).size(withAttributes: [.font: rowFont]).width }.max() ?? 0
    }

    /// Read-only label/value rows. A shared tab stop lines the values up in a
    /// column; the menu font is proportional, so space padding cannot. Pass a
    /// labelWidth to align these rows with rows added elsewhere in the menu.
    static func addRows(_ rows: [(String, String)], labelWidth: CGFloat? = nil, to menu: NSMenu) {
        let labelWidth = labelWidth ?? Self.labelWidth(for: rows)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: ceil(labelWidth) + 20)]
        for (label, value) in rows {
            let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            let text = NSMutableAttributedString(string: label + "\t", attributes: [
                .font: rowFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph
            ])
            text.append(NSAttributedString(string: value, attributes: [
                .font: valueFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
            ]))
            item.attributedTitle = text
            menu.addItem(item)
        }
    }

    static func updateActiveApps(in menu: NSMenu, apps: [ActiveApp]?) {
        for index in 0..<activeAppRowCount {
            let identifier = "active-app-\(index)"
            if let row = menu.items.first(where: { $0.identifier?.rawValue == identifier }) {
                configureActiveAppRow(row, apps: apps, index: index)
            }
        }
    }

    private static func configureActiveAppRow(_ row: NSMenuItem, apps: [ActiveApp]?, index: Int) {
        let view = row.view as? AppRowView
        guard let apps, index < apps.count else {
            // The first row carries the loading/empty message; unused rows hide.
            row.isHidden = index > 0
            row.title = apps == nil ? "Loading active apps…" : "No busy apps right now"
            view?.show(message: row.title)
            return
        }
        let app = apps[index]
        row.isHidden = false
        row.title = "\(app.name), \(String(format: "%.0f%%", app.cpu)) CPU, \(formatAppMemory(app.memoryMB))"
        view?.show(app, description: row.title)
    }

    private func menuBarDisplayMenu() -> NSMenu {
        let menu = NSMenu(title: "Menu Bar Display")
        addToggle("Show Icon Only", #selector(WattBarActions.toggleCompactMenuBar),
                  isOn: settings.compactMenuBar, to: menu)
        menu.addItem(.separator())
        addSectionHeader("Full display shows", to: menu)
        addToggle("WattBar Label", #selector(WattBarActions.toggleMenuBarLabel),
                  isOn: settings.showMenuBarLabel, to: menu)
        addToggle("Adapter / Battery Power", #selector(WattBarActions.toggleChargingRate),
                  isOn: settings.showChargingRate, to: menu)
        addToggle("Network Speeds", #selector(WattBarActions.toggleNetworkSpeeds),
                  isOn: settings.showNetworkSpeeds, to: menu)
        addSubmenu("Graph", graphMenu(), to: menu)
        return menu
    }

    /// One choice at a time, shown with a checkmark. Battery Charge/Drain is
    /// offered only on Macs with a battery.
    private func graphMenu() -> NSMenu {
        let menu = NSMenu(title: "Graph")
        let hasBattery = hasSystemBattery(snapshot.reading)
        let selected = settings.graphMetric.resolved(hasBattery: hasBattery)
        for metric in GraphMetric.allCases where metric != .batteryFlow || hasBattery {
            if metric == .off { menu.addItem(.separator()) }
            let item = NSMenuItem(title: metric.title, action: #selector(WattBarActions.setGraphMetric(_:)), keyEquivalent: "")
            item.target = actions
            item.representedObject = metric.rawValue
            item.state = metric == selected ? .on : .off
            menu.addItem(item)
        }
        // The style only matters while there is a graph to draw.
        guard selected != .off else { return menu }
        menu.addItem(.separator())
        addSectionHeader("Style", to: menu)
        for style in GraphStyle.allCases {
            let item = NSMenuItem(title: style.title, action: #selector(WattBarActions.setGraphStyle(_:)), keyEquivalent: "")
            item.target = actions
            item.representedObject = style.rawValue
            item.state = style == settings.graphStyle ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu(title: "Settings")

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(WattBarActions.refresh), keyEquivalent: "r")
        refreshItem.target = actions
        menu.addItem(refreshItem)

        let intervalMenu = NSMenu(title: "Refresh Interval")
        for interval in [2.0, 5.0, 10.0, 30.0] {
            let item = NSMenuItem(title: "Every \(Int(interval)) seconds", action: #selector(WattBarActions.setRefreshInterval(_:)), keyEquivalent: "")
            item.target = actions
            item.representedObject = interval
            item.state = abs(settings.refreshInterval - interval) < 0.1 ? .on : .off
            intervalMenu.addItem(item)
        }
        addSubmenu("Refresh Interval", intervalMenu, to: menu)
        menu.addItem(.separator())

        addToggle("Show Busiest Apps", #selector(WattBarActions.toggleActiveApps),
                  isOn: settings.showActiveApps, to: menu)
        addToggle("Track Energy Usage & Cost", #selector(WattBarActions.toggleEnergyUsage),
                  isOn: settings.trackEnergyUsage, to: menu)
        let tariffItem = NSMenuItem(
            title: "Electricity Tariffs…",
            action: #selector(WattBarActions.editTariffs),
            keyEquivalent: ""
        )
        tariffItem.target = actions
        menu.addItem(tariffItem)
        let resetEnergyItem = NSMenuItem(
            title: "Reset Energy Totals…",
            action: #selector(WattBarActions.resetEnergyUsage),
            keyEquivalent: ""
        )
        resetEnergyItem.target = actions
        resetEnergyItem.isEnabled =
            snapshot.energy.wattHours > 0 || snapshot.energy.activeSeconds > 0
        menu.addItem(resetEnergyItem)
        menu.addItem(.separator())

        addToggle("Open at Login", #selector(WattBarActions.toggleOpenAtLogin),
                  isOn: SMAppService.mainApp.status == .enabled, to: menu)
        return menu
    }

}

/// Owns only the views created on open; refreshes never mutate menu structure.
final class LiveMenuPanel {
    private weak var menu: NSMenu?
    let dashboard: DashboardView
    let network: SummaryRowView
    private let energy: SummaryRowView?
    private let settings: AppSettings
    private weak var actions: (any WattBarActions)?
    private var hasBattery: Bool
    private var hoverTimer: Timer?
    private let formatter: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; return formatter
    }()

    init(
        menu: NSMenu, dashboard: DashboardView, network: SummaryRowView, energy: SummaryRowView?,
        settings: AppSettings, actions: (any WattBarActions)?, snapshot: MenuSnapshot
    ) {
        self.menu = menu; self.dashboard = dashboard; self.network = network; self.energy = energy
        self.settings = settings; self.actions = actions; hasBattery = hasSystemBattery(snapshot.reading)
        dashboard.onSelectMetric = { [weak self] in self?.choose($0) }
        network.onPress = { [weak self] in self?.choose(.networkDownload) }
        network.actionLabel = "Graph Network download in the menu bar"
        syncSelection()
    }

    deinit { hoverTimer?.invalidate() }

    func startTracking() {
        hoverTimer?.invalidate()
        // Menu tracking does not reliably deliver tracking-area enter/exit events.
        // One common-mode timer supplies hover without intercepting menu events.
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            for view in [
                self.dashboard.heroBlock, self.dashboard.flowBlock, self.dashboard.cpu,
                self.dashboard.memory, self.dashboard.gpu, self.network,
            ] {
                guard let window = view.window else { view.updateHover(false); continue }
                let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                view.updateHover(view.onPress != nil && window.isVisible && view.bounds.contains(point))
            }
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func choose(_ metric: GraphMetric) {
        guard metric != .batteryFlow || hasBattery else { return }
        settings.graphMetric = metric
        let sender = NSMenuItem(); sender.representedObject = metric.rawValue
        actions?.setGraphMetric(sender)
        syncSelection()
    }

    func syncSelection() {
        let metric = settings.graphMetric.resolved(hasBattery: hasBattery)
        dashboard.select(metric); network.graphSelected = metric == .networkDownload
        func sync(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == #selector(WattBarActions.setGraphMetric(_:)),
                    let raw = item.representedObject as? String
                {
                    item.state = raw == metric.rawValue ? .on : .off
                }
                if let submenu = item.submenu { sync(submenu) }
            }
        }
        if let menu { sync(menu) }
    }

    func update(_ snapshot: MenuSnapshot, now: Date = Date()) {
        hasBattery = hasSystemBattery(snapshot.reading)
        let updated = snapshot.reading.map { formatter.string(from: $0.updatedAt) }
        dashboard.update(snapshot: snapshot, updated: updated, now: now)
        if let speed = snapshot.network {
            network.update(
                title: "Network",
                value:
                    "↓ \(formatNetworkSpeed(speed.downloadBytesPerSecond))  ↑ \(formatNetworkSpeed(speed.uploadBytesPerSecond))",
                detailTitle: "Since launch",
                detailValue:
                    "↓ \(formatByteCount(speed.totalDownloadedBytes))  ↑ \(formatByteCount(speed.totalUploadedBytes))")
        } else {
            network.update(title: "Network", value: "Measuring…", detailTitle: "Since launch", detailValue: "--")
        }
        let kWh = snapshot.energy.wattHours / 1_000
        energy?.update(
            title: "Energy",
            value: [
                formatShortEnergy(snapshot.energy.wattHours), formatRand(kWh * settings.southAfricaTariff),
                formatPounds(kWh * settings.unitedKingdomTariff),
            ].joined(separator: " · "), detailTitle: "Tracked for",
            detailValue: formatTrackingDuration(snapshot.energy.activeSeconds))
        if let menu {
            StatusMenuBuilder.updateActiveApps(in: menu, apps: snapshot.activeApps)
            menu.items.first?.title = updated.map { "Readings · \($0)" } ?? "Readings"
        }
        syncSelection()
    }
}

import Cocoa
import Darwin

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
    checks += 1
}
// Suite-backed defaults leave stub plists in ~/Library/Preferences that cfprefsd writes after
// removePersistentDomain, so tests keep settings in memory instead.
final class InMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: nil)! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    override func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
}
func counters(_ received: UInt64, _ sent: UInt64 = 0) -> InterfaceCounters {
    InterfaceCounters(receivedBytes: received, sentBytes: sent)
}
func networkTests() {
    var tracker = NetworkAccumulator()
    _ = tracker.sample([1: counters(4_294_967_000)], at: 0)
    let rollover = tracker.sample([1: counters(4_294_968_000)], at: 2)!
    expect(rollover.totalDownloadedBytes == 1000, "Traffic crossing 4 GiB must be retained")
    expect(rollover.downloadBytesPerSecond == 500, "64-bit delta must determine speed")

    tracker = NetworkAccumulator()
    _ = tracker.sample([1: counters(1000), 2: counters(1_000_000_000)], at: 0)
    _ = tracker.sample([1: counters(1500)], at: 2)
    let reconnect = tracker.sample([1: counters(2000), 2: counters(1_000_000_000)], at: 4)!
    expect(reconnect.totalDownloadedBytes == 1000, "Reconnected interface must not add its lifetime traffic")
    expect(reconnect.downloadBytesPerSecond == 250, "Unaffected interface must continue counting")
    let resumed = tracker.sample([1: counters(2500), 2: counters(1_000_000_500)], at: 6)!
    expect(resumed.totalDownloadedBytes == 2000, "Both interfaces must count new traffic after reconnect")

    expect(tracker.sample(nil, at: 8) == nil, "Unavailable sampling must report unavailable")
    let recovered = tracker.sample([1: counters(5000)], at: 10)!
    expect(recovered.totalDownloadedBytes == 2000, "Recovery must preserve session totals without guessing missing traffic")
    let reset = tracker.sample([1: counters(100)], at: 12)!
    expect(reset.downloadBytesPerSecond == 0, "Reset counters must not produce a spike")
    let postReset = tracker.sample([1: counters(200, 100)], at: 14)!
    expect(postReset.totalDownloadedBytes == 2100 && postReset.totalUploadedBytes == 100, "Counting must resume after reset")
    let offline = tracker.sample([:], at: 16)!
    expect(offline.totalDownloadedBytes == 2100 && offline.downloadBytesPerSecond == 0, "No active interface must preserve totals")

    func message(index: UInt16, flags: Int32, received: UInt64, sent: UInt64, linkType: Int32 = IFT_ETHER) -> Data {
        var header = if_msghdr2()
        header.ifm_msglen = UInt16(MemoryLayout<if_msghdr2>.size)
        header.ifm_type = UInt8(RTM_IFINFO2)
        header.ifm_index = index
        header.ifm_flags = flags
        header.ifm_data.ifi_type = UInt8(linkType)
        header.ifm_data.ifi_ibytes = received
        header.ifm_data.ifi_obytes = sent
        return withUnsafeBytes(of: &header) { Data($0) }
    }
    var messages = message(index: 3, flags: IFF_UP, received: 8_000_000_000, sent: 9_000_000_000)
    messages.append(message(index: 4, flags: IFF_UP | IFF_LOOPBACK, received: 99, sent: 99))
    messages.append(message(index: 5, flags: 0, received: 88, sent: 88))
    messages.append(message(index: 6, flags: IFF_UP | IFF_POINTOPOINT, received: 77, sent: 77, linkType: 1))
    messages.append(message(index: 7, flags: IFF_UP, received: 66, sent: 66, linkType: IFT_BRIDGE))
    messages.append(message(index: 8, flags: IFF_UP, received: 55, sent: 55, linkType: IFT_CELLULAR))
    let decoded = NetworkSpeedReader.decodeInterfaceCounters(messages)!
    expect(decoded.count == 2 && decoded[3]?.receivedBytes == 8_000_000_000 && decoded[3]?.sentBytes == 9_000_000_000, "Decode real 64-bit fields and filter down/loopback interfaces")
    expect(decoded[6] == nil && decoded[7] == nil, "Tunnels and bridges must not double-count physical traffic")
    expect(decoded[8]?.receivedBytes == 55, "Cellular links must be counted")
    expect(NetworkSpeedReader.decodeInterfaceCounters(Data([0, 0, 0, 0])) == nil, "Reject malformed zero-length messages")
    expect(NetworkSpeedReader.decodeInterfaceCounters(Data(messages.dropLast())) == nil, "Reject truncated messages")
}

func systemUsageTests() {
    let baseline = CPUTicks(user: 100, system: 100, nice: 10, idle: 790)
    var cpu = CPUUsageAccumulator()
    expect(cpu.sample(baseline) == nil, "CPU needs a first delta")
    expect(cpu.sample(CPUTicks(user: 120, system: 110, nice: 20, idle: 850)) == 40,
           "CPU counts user, system and nice over total ticks across all cores")
    expect(cpu.sample(CPUTicks(user: 120, system: 110, nice: 20, idle: 850)) == nil, "Zero total ticks are unavailable")
    expect(cpu.sample(CPUTicks(user: 120, system: 110, nice: 20, idle: 950)) == 0, "Idle CPU is zero percent")
    expect(cpu.sample(CPUTicks(user: 220, system: 110, nice: 20, idle: 950)) == 100, "Fully busy CPU is 100 percent")
    expect(cpu.sample(nil) == nil && cpu.sample(baseline) == nil, "A failed CPU query resets the baseline")
    for reset in [CPUTicks(user: 99, system: 100, nice: 10, idle: 790),
                  CPUTicks(user: 100, system: 99, nice: 10, idle: 790),
                  CPUTicks(user: 100, system: 100, nice: 9, idle: 790),
                  CPUTicks(user: 100, system: 100, nice: 10, idle: 789)] {
        cpu = CPUUsageAccumulator()
        _ = cpu.sample(baseline)
        expect(cpu.sample(reset) == nil, "A backwards CPU counter cannot produce a spike")
        expect(cpu.sample(CPUTicks(user: reset.user + 1, system: reset.system + 1, nice: reset.nice + 1, idle: reset.idle + 1)) == 75,
               "CPU sampling resumes from reset counters")
    }
    for (raw, level) in [(1, MemoryPressureLevel.normal), (2, .warning), (4, .critical), (0, .unknown), (3, .unknown), (8, .unknown), (-1, .unknown)] {
        let reading = MemoryPressureReading.from(availablePercentage: 56, systemLevel: raw)!
        expect(reading.percentage == 44 && reading.level == level, "Memory pressure complements available percent and maps system level \(raw)")
    }
    expect(MemoryPressureReading.from(availablePercentage: 100, systemLevel: 4)?.percentage == 0
           && MemoryPressureReading.from(availablePercentage: 0, systemLevel: 1)?.percentage == 100,
           "Memory percent includes both endpoints without guessing severity")
    expect(MemoryPressureReading.from(availablePercentage: nil, systemLevel: 1) == nil
           && MemoryPressureReading.from(availablePercentage: -1, systemLevel: 1) == nil
           && MemoryPressureReading.from(availablePercentage: 101, systemLevel: 1) == nil, "Missing or invalid available percent is unavailable")
    expect(MemoryPressureReading.from(availablePercentage: 56, systemLevel: nil)?.level == .unknown,
           "Missing pressure level must not be presented as normal")
    expect(formatPercentage(nil) == "--" && formatPercentage(38) == "38 %"
           && formatMemoryPressure(MemoryPressureReading(percentage: 44, level: .normal)) == "44 % (Normal)", "Usage formatting")
}

func loaderTests() {
    let gate = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    let loader = ActiveAppLoader {
        precondition(!Thread.isMainThread, "Process enumeration must run off the UI thread")
        entered.signal()
        gate.wait()
        return [ActiveApp(name: "Background result", cpu: 12, memoryMB: 345)]
    }
    loader.setEnabled(true)
    expect(loader.isLoading && loader.apps == nil, "Loading must return immediately without waiting for process enumeration")
    expect(entered.wait(timeout: .now() + 2) == .success, "Worker must start")
    loader.refreshIfNeeded()
    expect(entered.wait(timeout: .now() + 0.01) == .timedOut, "Concurrent menu openings must not duplicate work")
    loader.setEnabled(false)
    gate.signal()
    let deadline = Date().addingTimeInterval(2)
    while loader.isLoading && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(loader.apps == nil && !loader.isLoading, "Disabled requests must discard in-flight results")
    loader.setEnabled(true)
    gate.signal()
    let secondDeadline = Date().addingTimeInterval(2)
    while loader.isLoading && Date() < secondDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    expect(loader.apps?.first?.name == "Background result", "Re-enabling must load a fresh result")
    loader.refreshIfNeeded()
    expect(!loader.isLoading, "Fresh results must be cached")
}

func appTests() {
    let result = ActiveAppReader.parse("""
    101 20.0 102400 /Applications/Example App.app/Contents/MacOS/Example App
    102 0.0 921600 /Applications/Example App.app/Contents/MacOS/Example App
    103 0.0 500000 Idle
    104 90.0 1000 Self
    105 NaN 100 Bad
    106 1.0 -20 BadMemory
    """, excludingPID: 104) { _, command in command }
    expect(result.count == 1, "Exclude idle apps, self, and malformed values after grouping")
    expect(result[0].memoryMB == 1000 && result[0].cpu == 20, "Include RAM of idle app processes")
    expect(result[0].name.contains("Example App"), "Preserve spaces in process names")
    expect(ActiveAppReader.parse("1 1 10 A", limit: 0, excludingPID: 2) { _, name in name }.isEmpty, "Zero result limit must be safe")
}

let testDate = Date(timeIntervalSince1970: 1000)
func reading(_ watts: Double?, at seconds: TimeInterval = 0) -> PowerReading {
    PowerReading(systemWatts: watts, adapterInputWatts: 65, powerState: "Plugged in, charging",
        batteryFlowWatts: 20, source: "Test telemetry", details: "Battery 50%",
        updatedAt: testDate.addingTimeInterval(seconds))
}
func energyTests() {
    let defaults = InMemoryDefaults()
    defaults.set(12.0, forKey: DefaultsKey.accumulatedEnergyWh)
    defaults.set(60.0, forKey: DefaultsKey.accumulatedTrackingSeconds)
    let tracker = EnergyTracker(defaults: defaults)
    expect(tracker.accumulator.wattHours == 12 && tracker.accumulator.activeSeconds == 60, "Load existing saved energy and time")
    tracker.add(reading(60), enabled: true, refreshInterval: 5)
    tracker.add(reading(60, at: 6), enabled: true, refreshInterval: 5)
    expect(abs(tracker.accumulator.wattHours - 12.1) < 0.000001, "Integrate energy between valid samples")
    tracker.add(reading(nil, at: 8), enabled: true, refreshInterval: 5)
    tracker.add(reading(60, at: 10), enabled: true, refreshInterval: 5)
    expect(tracker.accumulator.activeSeconds == 66, "Do not integrate missing telemetry")
    tracker.add(reading(60, at: 100), enabled: true, refreshInterval: 5)
    expect(tracker.accumulator.activeSeconds == 66, "Do not integrate long sleep gaps")
    tracker.pause()
    tracker.persist()
    let reopened = EnergyTracker(defaults: defaults)
    expect(abs(reopened.accumulator.wattHours - 12.1) < 0.000001, "Persist values across launches")
    reopened.add(reading(60, at: 110), enabled: false, refreshInterval: 5)
    reopened.add(reading(60, at: 112), enabled: true, refreshInterval: 5)
    expect(reopened.accumulator.activeSeconds == 66, "Paused time must not count")
    reopened.reset()
    reopened.persist()
    expect(defaults.double(forKey: DefaultsKey.accumulatedEnergyWh) == 0 && defaults.double(forKey: DefaultsKey.accumulatedTrackingSeconds) == 0, "Reset both totals")
}
func formattingTests() {
    expect(formatStackedNetworkSpeed(500) == "500B" && formatStackedNetworkSpeed(1_500) == "2K", "Small speeds stay within three digits")
    expect(formatStackedNetworkSpeed(1_234_000) == "1.2M" && formatStackedNetworkSpeed(123_400_000) == "123M", "Megabyte speeds drop the decimal above 10")
    expect(formatStackedNetworkSpeed(999_600) == "1.0M" && formatStackedNetworkSpeed(2_500_000_000) == "2.5G", "Unit boundaries round up cleanly")
    expect(formatRand(0.042) == "R 0.04" && formatPounds(0.0031) == "< £0.01" && formatPounds(0) == "£0.00", "Costs share one precision")
    expect(formatRate(3.5) == "3.50" && formatRate(0.2611) == "0.2611", "Rates keep only meaningful decimals")
    expect(formatFanSpeed(2499.6) == "2500 rpm" && formatFanSpeed(0) == "off" && formatFanSpeed(nil) == "unavailable", "Fan speed reads as whole rpm, or off when stopped")
    expect(formatStackedFanSpeed(6550) == "6550" && formatStackedFanSpeed(0) == "off" && formatStackedFanSpeed(nil) == "--", "Menu-bar fan speed fits four characters")
}
func historyTests() {
    var history = TemperatureHistory(window: 100)
    history.add(50, at: testDate)
    history.add(nil, at: testDate.addingTimeInterval(10))
    history.add(70, at: testDate.addingTimeInterval(20))
    expect(history.samples.count == 2 && history.minimum == 50 && history.maximum == 70 && history.average == 60,
           "Unavailable readings are skipped, not recorded as zero")
    history.add(60, at: testDate.addingTimeInterval(110))
    expect(history.samples.map(\.celsius) == [70, 60], "Readings older than the window are dropped")
    history.add(40, at: testDate.addingTimeInterval(50))
    expect(history.samples.map(\.celsius) == [40], "A clock moved backwards restarts the history")
    let flat = TemperatureChartView.scale(minimum: 49, maximum: 49)
    expect(flat.low == 45 && flat.high == 55, "Flat readings still get a 10° axis")
    let wide = TemperatureChartView.scale(minimum: 41, maximum: 88)
    expect(wide.low == 35 && wide.high == 90, "Axis rounds to 5° steps around the readings")
}
func flowTests() {
    let adapter = PowerFlow(adapterInputWatts: 65, batteryFlowWatts: -10)
    expect(adapter == .adapter(65) && adapter.label == "IN" && adapter.compactValue == "65W", "Adapter flow uses typed data")
    let battery = PowerFlow(adapterInputWatts: nil, batteryFlowWatts: -10)
    expect(battery == .discharge(10) && battery.label == "BAT" && battery.compactValue == "−10W", "Battery discharge has independent display semantics")
    expect(PowerFlow(adapterInputWatts: nil, batteryFlowWatts: 0) == .idle, "Idle flow must be explicit")
}

func flowSummaryTests() {
    let charging = PowerFlow.summary(adapterInputWatts: 61, batteryFlowWatts: 19, systemWatts: 42)
    expect(PowerFlow.summaryText(charging) == "Adapter 61 W → Mac 42 W · Battery +19 W" && charging.last?.tone == .charging,
           "Adapter flow names the source, the Mac and a charging battery")
    let topUp = PowerFlow.summary(adapterInputWatts: 30, batteryFlowWatts: -12.4, systemWatts: 42)
    expect(PowerFlow.summaryText(topUp) == "Adapter 30 W → Mac 42 W · Battery −12 W" && topUp.last?.tone == .draining,
           "A battery topping up the adapter reads as draining")
    expect(PowerFlow.summaryText(PowerFlow.summary(adapterInputWatts: 61, batteryFlowWatts: 0.3, systemWatts: 60)) == "Adapter 61 W → Mac 60 W",
           "A battery flow that rounds to zero is left out")
    let battery = PowerFlow.summary(adapterInputWatts: nil, batteryFlowWatts: -42, systemWatts: 42)
    expect(PowerFlow.summaryText(battery) == "Battery 42 W → Mac 42 W" && battery.first?.tone == .draining,
           "On battery the battery is the source")
    expect(PowerFlow.summaryText(PowerFlow.summary(adapterInputWatts: nil, batteryFlowWatts: nil, systemWatts: 42)) == "Mac 42 W",
           "Desktops show only the Mac")
    expect(PowerFlow.summaryText(PowerFlow.summary(adapterInputWatts: nil, batteryFlowWatts: nil, systemWatts: nil)) == "Mac --",
           "Missing system draw is shown as unknown")
}
func graphTests() {
    let start = Date(timeIntervalSince1970: 30_000) // the start of a 30 s bucket
    var graph = GraphHistory()
    for (offset, watts) in [(0.0, 10.0), (10, 20), (20, 30), (30, 50)] {
        graph.add([.systemDraw: watts, .gpuDraw: nil], at: start.addingTimeInterval(offset))
    }
    var bars = graph.bars(.systemDraw, now: start.addingTimeInterval(40))
    expect(bars.count == GraphHistory.bucketCount && bars.last == 50 && bars[bars.count - 2] == 20,
           "Each bar averages its wall-clock bucket, newest on the right")
    expect(bars.dropLast(2).allSatisfy { $0 == nil } && graph.bars(.gpuDraw, now: start).allSatisfy { $0 == nil },
           "Empty buckets and unavailable readings draw nothing")
    bars = graph.bars(.systemDraw, now: start.addingTimeInterval(30 * 10 + 5))
    expect(bars.first == 20 && bars.compactMap { $0 }.count == 2, "Bars cover the last 11 buckets")
    graph.add([.systemDraw: 5], at: start.addingTimeInterval(30 * 13))
    expect(graph.samples[.systemDraw]?.count == 2, "Samples older than the graph are dropped")
    graph.add([.systemDraw: 7], at: start)
    expect(graph.samples[.systemDraw]?.map(\.value) == [7], "A clock moved backwards restarts the graph")
    for interval in [2.0, 5, 10, 30] {
        var timed = GraphHistory()
        for step in 0..<Int(300 / interval) { timed.add([.systemDraw: 20], at: start.addingTimeInterval(Double(step) * interval)) }
        let filled = timed.bars(.systemDraw, now: start.addingTimeInterval(299)).compactMap { $0 }
        expect(filled.count == 10 && filled.allSatisfy { $0 == 20 }, "Five minutes fill the same bars at a \(Int(interval)) s refresh")
        let duration = GraphHistory.lineBucketDuration(refreshInterval: interval)
        let points = timed.buckets(.systemDraw, now: start.addingTimeInterval(299), duration: duration)
        let used = points.enumerated().filter { $0.element != nil }.map(\.offset)
        expect(Double(points.count) * duration == GraphHistory.window && used.count == used.last! - used.first! + 1 && used.last == points.count - 1,
               "The line is unbroken over the same window at a \(Int(interval)) s refresh")
    }
    expect(GraphHistory.lineBucketDuration(refreshInterval: 2) == 15 && GraphHistory.lineBucketDuration(refreshInterval: 30) == 30,
           "Line points every 15 s, or 30 s at the slowest refresh")
    var gappy = GraphHistory()
    gappy.add([.systemDraw: 10], at: start)
    gappy.add([.systemDraw: 30], at: start.addingTimeInterval(60))
    gappy.add([.systemDraw: 20], at: start.addingTimeInterval(80))
    expect(gappy.buckets(.systemDraw, now: start.addingTimeInterval(85), duration: 15).suffix(6).map { $0 } == [10, nil, nil, nil, 30, 20],
           "Line buckets are wall-clock based and leave gaps empty")
    var scaled = GraphHistory()
    expect(scaled.scale(.systemDraw) == 30 && scaled.scale(.gpuDraw) == 10 && scaled.scale(.networkDownload) == 1_000_000,
           "A fresh install starts from a floor, not from idle readings")
    scaled.add([.systemDraw: 12, .batteryFlow: -45, .cpuTemperature: 99, .gpuDraw: .nan], at: start)
    expect(scaled.scale(.systemDraw) == 30 && scaled.scale(.batteryFlow) == 45 && scaled.peaks[.cpuTemperature] == nil && scaled.peaks[.gpuDraw] == nil,
           "Peaks track magnitude for bar metrics only and ignore invalid readings")
    scaled.add([.systemDraw: 88], at: start.addingTimeInterval(5))
    scaled.add([.systemDraw: 40], at: start.addingTimeInterval(10))
    expect(scaled.scale(.systemDraw) == 88, "Full height is the highest value seen")
    expect(GraphHistory(peaks: scaled.peaks).scale(.systemDraw) == 88, "Peaks carry over to a new history")
    for metric in [GraphMetric.cpuUsage, .memoryPressure] {
        expect(scaled.scale(metric) == 100, "Percentage graphs start with a fixed 100 percent scale")
        scaled.add([metric: 38], at: start.addingTimeInterval(15))
        expect(scaled.scale(metric) == 100 && scaled.peaks[metric] == nil, "Percentage graphs never remember peaks")
        expect(GraphHistory(peaks: [metric: 900]).scale(metric) == 100, "Stored peaks cannot change percentage scales")
        expect(scaled.bars(metric, now: start.addingTimeInterval(15)).last == 38, "Inactive metrics already have history when selected")
    }
}
func graphSettingTests() {
    let defaults = InMemoryDefaults()
    let settings = AppSettings(defaults: defaults)
    expect(settings.graphMetric == .systemDraw, "The graph shows system draw by default")
    for metric in GraphMetric.allCases {
        settings.graphMetric = metric
        expect(AppSettings(defaults: defaults).graphMetric == metric, "The graph choice \(metric) persists")
    }
    defaults.set("unknown", forKey: DefaultsKey.menuBarGraph)
    expect(settings.graphMetric == .systemDraw, "An unknown stored choice falls back to system draw")
    settings.graphPeaks = [.systemDraw: 64, .networkDownload: 2_500_000]
    expect(AppSettings(defaults: defaults).graphPeaks == [.systemDraw: 64, .networkDownload: 2_500_000], "Graph peaks persist across launches")
    defaults.set(["systemDraw": "bad", "gpuDraw": -1, "nonsense": 4], forKey: DefaultsKey.menuBarGraphPeaks)
    expect(settings.graphPeaks.isEmpty, "Invalid stored peaks are ignored")
    let desktop = PowerReading(systemWatts: 30, adapterInputWatts: nil, powerState: PowerReading.desktopState,
        batteryFlowWatts: nil, source: "Test", details: "", updatedAt: testDate)
    expect(!hasSystemBattery(desktop) && !hasSystemBattery(nil) && hasSystemBattery(reading(20)), "Detect Macs with a battery")
    expect(settings.graphStyle == .line, "The graph is a line by default")
    settings.graphStyle = .bars
    expect(AppSettings(defaults: defaults).graphStyle == .bars, "The graph style persists")
    defaults.set("dots", forKey: DefaultsKey.menuBarGraphStyle)
    expect(settings.graphStyle == .line, "An unknown stored style falls back to line")
    expect(GraphMetric.batteryFlow.resolved(hasBattery: false) == .systemDraw && GraphMetric.batteryFlow.resolved(hasBattery: true) == .batteryFlow
           && GraphMetric.off.resolved(hasBattery: false) == .off, "Battery Charge/Drain falls back to System Draw without a battery")
}
func warningTests() {
    expect(StatusWarning.cpuUsagePercent == 90 && !StatusWarning.cpuUsageIsHigh(89.99) && StatusWarning.cpuUsageIsHigh(90)
           && StatusWarning.cpuUsageIsHigh(100) && !StatusWarning.cpuUsageIsHigh(nil) && !StatusWarning.cpuUsageIsHigh(.nan),
           "CPU usage turns orange at 90 percent without rounding up")
    expect(StatusWarning.cpuTemperatureCelsius == 85 && StatusWarning.batteryDrainWatts == 40, "Warning thresholds")
    expect(!StatusWarning.cpuIsHot(84.4) && StatusWarning.cpuIsHot(84.6) && StatusWarning.cpuIsHot(85) && !StatusWarning.cpuIsHot(nil),
           "CPU warning agrees with the whole degrees shown")
    expect(StatusWarning.batteryDrainIsHigh(.discharge(40)) && !StatusWarning.batteryDrainIsHigh(.discharge(39.4))
           && !StatusWarning.batteryDrainIsHigh(.adapter(90)) && !StatusWarning.batteryDrainIsHigh(.idle),
           "Battery warning only for heavy discharge")
}
func shortFormatTests() {
    expect(formatShortEnergy(12) == "12.0 Wh" && formatShortEnergy(999.94) == "999.9 Wh" && formatShortEnergy(999.96) == "1.00 kWh"
           && formatShortEnergy(1_240) == "1.24 kWh", "Short energy switches to kWh at 1 kWh")
    expect(formatAppMemory(540) == "540 MB" && formatAppMemory(2_150) == "2.1 GB" && formatAppMemory(1_000) == "1.0 GB",
           "App memory reads as MB, then GB")
    expect(!formatByteCount(0).contains("Zero") && formatByteCount(612_000_000) == "612 MB", "Byte totals stay numeric")
}

final class TestActions: NSObject, WattBarActions {
    func toggleCompactMenuBar() {}; func toggleNetworkSpeeds() {}; func toggleActiveApps() {}
    func refresh() {}; func setRefreshInterval(_ sender: NSMenuItem) {}; func toggleMenuBarLabel() {}
    func toggleChargingRate() {}; func setGraphMetric(_ sender: NSMenuItem) {}; func setGraphStyle(_ sender: NSMenuItem) {}
    func toggleOpenAtLogin() {}
    func toggleEnergyUsage() {}; func editTariffs() {}; func resetEnergyUsage() {}; func quit() {}
}
final class LoadingMenuDelegate: NSObject, NSMenuDelegate {
    var onOpen: (() -> Void)?
    var isTracking = false
    func menuWillOpen(_ menu: NSMenu) { isTracking = true; onOpen?() }
    func menuDidClose(_ menu: NSMenu) { isTracking = false }
}
final class Backdrop: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}
func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

func interfaceTests() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    let defaults = InMemoryDefaults()
    let settings = AppSettings(defaults: defaults)
    let actions = TestActions()
    let menu = NSMenu(title: "WattBar")
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    defer { NSStatusBar.system.removeStatusItem(item) }
    let display = StatusDisplayController(statusItem: item, settings: settings)
    let network = NetworkSpeedReading(downloadBytesPerSecond: 500, uploadBytesPerSecond: 100,
        totalDownloadedBytes: 1000, totalUploadedBytes: 200)
    let sample = reading(20)
    var history = TemperatureHistory()
    var graph = GraphHistory()
    let end = Date()
    for step in 0..<720 where !(300..<380).contains(step) {
        let seconds = Double(step) * 5
        let date = end.addingTimeInterval(seconds - 3_600)
        let celsius = 48 + 14 * sin(seconds / 400) + (step % 7 == 0 ? 3 : 0)
        history.add(celsius, at: date)
        graph.add([.systemDraw: 18 + 14 * sin(seconds / 60), .cpuTemperature: celsius, .gpuDraw: 3 + 2 * sin(seconds / 90),
                   .cpuUsage: 50 + 30 * sin(seconds / 60), .memoryPressure: 44 + 10 * sin(seconds / 90),
                   .networkDownload: 400_000 + 300_000 * sin(seconds / 45), .batteryFlow: 25 * sin(seconds / 70)],
                  at: testDate.addingTimeInterval(seconds - 3_600)) // the status readings are dated testDate
    }
    let snapshot = MenuSnapshot(reading: sample, gpuWatts: 3, cpuTemperature: 55, fanRPM: 2500, network: network,
        activeApps: [ActiveApp(name: "Example App", cpu: 20, memoryMB: 1000)],
        energy: EnergyAccumulator(wattHours: 12, activeSeconds: 66), uptime: 90_000,
        cpuUsage: 38, memoryPressure: MemoryPressureReading(percentage: 44, level: .normal))
    func validateActions(_ menu: NSMenu) {
        for item in menu.items {
            if item.submenu == nil, let action = item.action { expect((item.target as? NSObject)?.responds(to: action) == true, "Menu action target must respond to \(action)") }
            if let submenu = item.submenu { validateActions(submenu) }
        }
    }
    // Renders a freshly made view in both appearances, on a window-coloured backdrop.
    func capture(_ name: String, _ make: () -> NSView) {
        guard let directory = ProcessInfo.processInfo.environment["WATTBAR_TEST_OUTPUT"] else { return }
        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let view = make()
            let backdrop = Backdrop(frame: view.bounds)
            backdrop.appearance = NSAppearance(named: appearance)
            backdrop.addSubview(view)
            backdrop.layoutSubtreeIfNeeded()
            guard let bitmap = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { fatalError("Cannot render \(name)") }
            backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
            let data = bitmap.representation(using: .png, properties: [:])!
            try! data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png"))
        }
    }
    func captureStatus(_ name: String) {
        let content = display.contentView.content
        let size = NSSize(width: item.length, height: NSStatusBar.system.thickness)
        capture(name) {
            let view = StatusContentView(frame: NSRect(origin: .zero, size: size))
            view.content = content
            return view
        }
    }
    settings.compactMenuBar = false
    display.update(reading: nil, gpuWatts: nil, cpuTemperature: nil, fanRPM: nil, network: nil, uptime: 0)
    expect(item.button?.attributedTitle.string == "WattBar" && display.displayedText == nil, "Full display must show a placeholder before the first reading")
    for compact in [false, true] {
        for networkVisible in [false, true] {
            for chargingVisible in [false, true] {
                settings.compactMenuBar = compact
                settings.showNetworkSpeeds = networkVisible
                settings.showChargingRate = chargingVisible
                settings.trackEnergyUsage = true
                StatusMenuBuilder(settings: settings, snapshot: snapshot, actions: actions).populate(menu)
                expect(menu.items.filter { $0.title == "Settings" }.count == 1 && menu.items.filter { $0.title == "Energy & Cost" }.count == 1, "Menu must rebuild without duplicate/missing sections")
                expect(menu.items.first?.title.hasPrefix("Readings · ") == true && menu.items.first?.view is DashboardView,
                       "The menu opens with the dashboard, identified as a timestamped snapshot")
                expect(["Network", "Energy & Cost", "Busiest Apps"].allSatisfy { title in menu.items.contains { $0.title == title && $0.submenu == nil && $0.view != nil } },
                       "Network, energy and busiest apps show directly in the menu, not in submenus")
                let panels = menu.items.compactMap(\.view)
                expect(panels.count == 9 && panels.allSatisfy { $0.frame.width == PanelMetrics.width && $0.frame.height > 0 },
                       "View-backed rows share one width")
                expect(panels.allSatisfy { $0.isAccessibilityElement() && !($0.accessibilityLabel() ?? "").isEmpty },
                       "Panels describe themselves to assistive technology")
                expect(!menu.items.contains { $0.title == "CPU Temperature History" } && descendants(menu.items[0].view!).contains { $0 is TemperatureHistoryView },
                       "The CPU temperature chart is inline, not in a submenu")
                let flowLabel = menu.items[0].view!.accessibilityLabel() ?? ""
                expect(flowLabel.contains("Adapter 65 W to Mac 20 W · Battery +20 W") && flowLabel.contains("Fan 2500 rpm"),
                       "Dashboard shows the power flow and the fan")
                let details = menu.items.first { $0.title == "Reading Details" }!.submenu!
                expect(details.items.contains { $0.attributedTitle?.string == "CPU usage\t38 %" }
                       && details.items.contains { $0.attributedTitle?.string == "Memory pressure\t44 % (Normal)" }, "Reading Details includes usage and pressure")
                let stops = Set(details.items.compactMap { ($0.attributedTitle?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.tabStops.first?.location })
                expect(details.items.count == 7 && stops.count == 1 && details.items.contains { $0.title.hasPrefix("Computer uptime") },
                       "Reading details, including uptime, line up on one tab stop")
                let displayMenu = menu.items.first { $0.title == "Menu Bar Display" }!.submenu!
                let toggles = Dictionary(uniqueKeysWithValues: displayMenu.items.filter { $0.action != nil && $0.submenu == nil }.map { ($0.title, $0.state) })
                expect(toggles == ["Show Icon Only": compact ? .on : .off, "WattBar Label": .off,
                                   "Adapter / Battery Power": chargingVisible ? .on : .off,
                                   "Network Speeds": networkVisible ? .on : .off],
                       "Menu-bar options live together with fixed titles; checkmarks alone show state")
                let graphMenu = displayMenu.items.first { $0.title == "Graph" }!.submenu!
                let metricItems = graphMenu.items.filter { $0.action == #selector(WattBarActions.setGraphMetric(_:)) }
                let styleItems = graphMenu.items.filter { $0.action == #selector(WattBarActions.setGraphStyle(_:)) }
                expect(metricItems.map(\.title) == GraphMetric.allCases.map(\.title) && metricItems.filter { $0.state == .on }.map(\.title) == ["System Draw"],
                       "Graph choices have fixed titles and one checkmark")
                expect(graphMenu.items.contains { $0.title == "Style" && !$0.isEnabled } && styleItems.map(\.title) == ["Line", "Bars"]
                       && styleItems.filter { $0.state == .on }.map(\.title) == ["Line"], "Graph style is a second group, Line by default")
                validateActions(menu)
                display.update(reading: sample, gpuWatts: 3, cpuTemperature: 55, fanRPM: 2500, network: network, uptime: 90_000, graph: graph)
                expect(item.length > 0 && item.length < 600, "Status item must have a bounded width")
                expect((item.button?.image != nil) == compact && (display.displayedText == nil) == compact,
                       "Compact mode must show an icon; full mode must show readings")
                if !compact {
                    let text = display.displayedText!
                    let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
                    expect(rows.count == 2 && rows[0].hasPrefix("SYS 20W") && rows[1].hasPrefix("CPU 55°"), "SYS over CPU leads the two-row readout")
                    expect(!text.contains("FAN") && !text.contains("│"), "No fan field and no divider characters in the menu bar")
                    expect(text.contains("IN 65W") == chargingVisible && text.contains("GPU 3W") && text.contains("↓ 500B") == networkVisible,
                           "Optional columns follow their settings")
                    let content = display.contentView.content
                    let layout = StatusContentView.layout(content)
                    expect(content.graph?.metric == .systemDraw && layout.graphX == 0, "The graph leads the full readout")
                    expect(zip(layout.columns, layout.columns.dropFirst()).allSatisfy { $0.x + $0.width + StatusContentView.columnGap <= $1.x + 0.01 }
                           && layout.columns.allSatisfy { $0.valueX >= $0.x && $0.valueX <= $0.x + $0.width },
                           "Columns are separated by spacing and keep their values inside them")
                    expect(item.length == ceil(layout.width) + 12 && !content.hasWarning && content.graph?.warning == false,
                           "Width comes from the layout; normal readings show no warning")
                    expect(content.columns[0].top.emphasis == .primary && content.columns[0].bottom?.emphasis == .primary
                           && content.columns.dropFirst().allSatisfy { $0.top.emphasis == .secondary }, "SYS and CPU are the primary column")
                    captureStatus("status-\(networkVisible ? "network" : "plain")-\(chargingVisible ? "charging" : "nocharging")")
                }
            }
        }
    }
    settings.compactMenuBar = false
    settings.showNetworkSpeeds = true
    settings.showChargingRate = true
    display.update(reading: reading(5), gpuWatts: 3, cpuTemperature: 55, fanRPM: 2500, network: network, uptime: 90_000, graph: graph)
    let steadyLength = item.length
    let busyNetwork = NetworkSpeedReading(downloadBytesPerSecond: 123_000_000, uploadBytesPerSecond: 45_600_000,
        totalDownloadedBytes: 1000, totalUploadedBytes: 200)
    display.update(reading: reading(150), gpuWatts: 42, cpuTemperature: 99, fanRPM: 6550, network: busyNetwork, uptime: 90_000, graph: graph)
    expect(item.length == steadyLength, "Status item width must not change as readings change")
    expect(display.contentView.content.graph?.style == .line && display.contentView.content.graph?.bars.count == 22,
           "Line style draws finer points at fast refreshes")
    settings.graphStyle = .bars
    display.update(reading: reading(150), gpuWatts: 42, cpuTemperature: 99, fanRPM: 6550, network: busyNetwork, uptime: 90_000, graph: graph)
    expect(item.length == steadyLength && display.contentView.content.graph?.bars.count == 11, "Line and bars take the same width")
    settings.graphStyle = .line
    let draining = PowerReading(systemWatts: 61, adapterInputWatts: nil, powerState: "On battery", batteryFlowWatts: -61,
        source: "Test telemetry", details: "Battery 50%", updatedAt: testDate)
    display.update(reading: draining, gpuWatts: 12, cpuTemperature: 91, fanRPM: 0, network: busyNetwork, uptime: 90_000, graph: graph)
    var content = display.contentView.content
    expect(item.length == steadyLength && content.text.contains("BAT −61W"), "Battery drain and a stopped fan do not resize the item")
    expect(content.columns[0].bottom?.warning == true && content.columns[1].top.warning && content.graph?.warning == true,
           "Hot CPU and heavy drain turn their values and the graph orange")
    expect((item.button!.accessibilityLabel() ?? "").contains("Fan off"), "The accessibility label keeps the fan reading")
    for style in GraphStyle.allCases {
        settings.graphStyle = style
        for metric in [GraphMetric.systemDraw, .cpuTemperature, .batteryFlow] {
            settings.graphMetric = metric
            display.update(reading: draining, gpuWatts: 12, cpuTemperature: 91, fanRPM: 0, network: busyNetwork, uptime: 90_000, graph: graph)
            expect(item.length == steadyLength && display.contentView.content.graph?.metric == metric && display.contentView.content.graph?.warning == true,
                   "Every graph keeps the width and takes the warning tint")
            captureStatus("status-\(style)-\(metric)-warning")
            display.update(reading: reading(20), gpuWatts: 3, cpuTemperature: 55, fanRPM: 2500, network: network, uptime: 90_000, graph: graph)
            expect(item.length == steadyLength && display.contentView.content.graph?.warning == false, "Normal readings leave the graph monochrome")
            captureStatus("status-\(style)-\(metric)")
        }
    }
    for style in GraphStyle.allCases {
        settings.graphStyle = style
        for metric in GraphMetric.allCases where metric != .off {
            settings.graphMetric = metric
            display.update(reading: draining, gpuWatts: 12, cpuTemperature: 91, fanRPM: nil, network: busyNetwork,
                           uptime: 90_000, graph: graph, cpuUsage: 100,
                           memoryPressure: MemoryPressureReading(percentage: 100, level: .critical))
            expect(item.length == steadyLength, "Every metric and style reserves the same width")
            display.update(reading: sample, gpuWatts: nil, cpuTemperature: nil, fanRPM: nil, network: nil, uptime: 0,
                           graph: graph, cpuUsage: nil, memoryPressure: nil)
            expect(item.length == steadyLength, "Missing readings never resize a graph choice")
        }
        settings.graphMetric = .cpuUsage
        for (usage, tint) in [(38.0, StatusContent.Graph.Tint.monochrome), (95, .orange)] {
            display.update(reading: draining, gpuWatts: 12, cpuTemperature: 91, fanRPM: 0, network: network,
                           uptime: 90_000, graph: graph, cpuUsage: usage,
                           memoryPressure: MemoryPressureReading(percentage: 95, level: .critical))
            let plotted = display.contentView.content.graph!
            expect(plotted.metric == .cpuUsage && plotted.scale == 100 && plotted.style == style && plotted.tint == tint,
                   "CPU graph uses fixed percent and only its own load warning")
            expect(MenuBarGraphDrawing.color(for: plotted) == (tint == .orange ? .systemOrange : NSColor.labelColor.withAlphaComponent(0.75)),
                   "CPU graph draws the expected semantic tint")
            captureStatus("status-\(style)-cpuUsage-\(usage >= 90 ? "high" : "normal")")
        }
        settings.graphMetric = .memoryPressure
        for level in MemoryPressureLevel.allCases {
            // A normal high percent and warning low percent prove that severity
            // comes from the system level rather than percentage thresholds.
            let pressure = MemoryPressureReading(percentage: level == .normal ? 95 : 44, level: level)
            display.update(reading: draining, gpuWatts: 12, cpuTemperature: 91, fanRPM: 0, network: network,
                           uptime: 90_000, graph: graph, cpuUsage: 100, memoryPressure: pressure)
            let plotted = display.contentView.content.graph!
            let tint: StatusContent.Graph.Tint = level == .warning ? .yellow : level == .critical ? .red : .monochrome
            let color: NSColor = level == .warning ? .systemYellow : level == .critical ? .systemRed : NSColor.labelColor.withAlphaComponent(0.75)
            expect(plotted.scale == 100 && plotted.style == style && plotted.tint == tint && MenuBarGraphDrawing.color(for: plotted) == color,
                   "Memory graph follows the system pressure level in either style")
            expect(item.length == steadyLength, "Usage and pressure warnings keep the item width")
            let label = item.button!.accessibilityLabel() ?? ""
            expect(label.contains("CPU usage 100 %") && label.contains("Memory pressure \(formatMemoryPressure(pressure))"),
                   "Status accessibility includes both readings and the system level")
            captureStatus("status-\(style)-memoryPressure-\(level.rawValue)")
        }
    }
    settings.graphMetric = .batteryFlow
    settings.graphStyle = .line
    let desktop = PowerReading(systemWatts: 30, adapterInputWatts: nil, powerState: PowerReading.desktopState,
        batteryFlowWatts: nil, source: "Test", details: "", updatedAt: testDate)
    display.update(reading: desktop, gpuWatts: 3, cpuTemperature: 55, fanRPM: nil, network: network, uptime: 90_000, graph: graph)
    expect(display.contentView.content.graph?.metric == .systemDraw, "Without a battery the graph falls back to system draw")
    let desktopSnapshot = MenuSnapshot(reading: desktop, gpuWatts: 3, cpuTemperature: 55, fanRPM: nil, network: nil,
        activeApps: nil, energy: EnergyAccumulator(wattHours: 0, activeSeconds: 0), uptime: 90_000)
    StatusMenuBuilder(settings: settings, snapshot: desktopSnapshot, actions: actions).populate(menu)
    let desktopGraph = menu.items.first { $0.title == "Menu Bar Display" }!.submenu!.items.first { $0.title == "Graph" }!.submenu!
    expect(!desktopGraph.items.contains { $0.title == "Battery Charge/Drain" } && desktopGraph.items.first { $0.state == .on }?.title == "System Draw",
           "Battery Charge/Drain is hidden without a battery")
    expect(!descendants(menu.items[0].view!).contains { ($0 as? TileView)?.accessibilityLabel()?.hasPrefix("Fan") == true }
           && descendants(menu.items[0].view!).filter { $0 is TileView }.count == 4, "Fanless Macs show four tiles without a fan")
    settings.graphMetric = .off
    display.update(reading: sample, gpuWatts: 3, cpuTemperature: 55, fanRPM: 2500, network: network, uptime: 90_000, graph: graph)
    expect(display.contentView.content.graph == nil && item.length < steadyLength,
           "Turning the graph off gives its width back")
    settings.graphMetric = .systemDraw
    settings.showMenuBarLabel = true
    display.update(reading: sample, gpuWatts: 3, cpuTemperature: 55, fanRPM: 2500, network: network, uptime: 90_000, graph: graph)
    content = display.contentView.content
    expect(content.columns[0].top.label == "WATT" && content.columns[0].bottom == nil && item.length > steadyLength, "The WattBar label adds its own column")
    captureStatus("status-label")
    settings.showMenuBarLabel = false

    settings.trackEnergyUsage = true
    StatusMenuBuilder(settings: settings, snapshot: snapshot, actions: actions).populate(menu)
    let appMenu = menu
    let originalRows = appMenu.items
    let appRows = appMenu.items.filter { $0.identifier?.rawValue.hasPrefix("active-app-") == true }
    expect(appRows.count == StatusMenuBuilder.activeAppRowCount && appRows.allSatisfy { $0.view is AppRowView }, "Reserve view-backed app rows")
    StatusMenuBuilder.updateActiveApps(in: menu, apps: nil)
    expect(appMenu.items.contains { $0.title == "Loading active apps…" && $0.view?.accessibilityLabel() == "Loading active apps…" }, "Show an honest loading state")
    expect(appRows.filter { !$0.isHidden }.count == 1, "Only the loading row is visible while loading")
    StatusMenuBuilder.updateActiveApps(in: menu, apps: [ActiveApp(name: "Loaded App", cpu: 5, memoryMB: 100)])
    expect(appMenu.items.contains { $0.title == "Loaded App, 5% CPU, 100 MB" && $0.view?.accessibilityLabel() == $0.title }, "Display asynchronous results")
    expect(appRows.filter { !$0.isHidden }.count == 1, "Unused rows hide instead of showing placeholders")
    StatusMenuBuilder.updateActiveApps(in: menu, apps: [])
    expect(appRows[0].title == "No busy apps right now" && appRows.filter { !$0.isHidden }.count == 1, "Say so when no app is busy")
    expect(zip(originalRows, appMenu.items).allSatisfy { $0 === $1 }, "Keep menu item identity stable while loading")
    if CommandLine.arguments.contains("--menu-tracking") {
        let ready = DispatchSemaphore(value: 0)
        let loader = ActiveAppLoader {
            _ = ready.wait(timeout: .now() + 2)
            return [ActiveApp(name: "Loaded during menu tracking", cpu: 1, memoryMB: 100)]
        }
        let delegate = LoadingMenuDelegate()
        delegate.onOpen = { ready.signal() }
        menu.delegate = delegate
        var updatedWhileTracking = false
        var finished = false
        loader.onUpdate = {
            StatusMenuBuilder.updateActiveApps(in: menu, apps: loader.apps)
            updatedWhileTracking = delegate.isTracking
            menu.cancelTracking()
        }
        let timeout = Timer(timeInterval: 2, repeats: false) { _ in menu.cancelTracking() }
        RunLoop.main.add(timeout, forMode: .common)
        loader.setEnabled(true)
        DispatchQueue.main.async {
            menu.popUp(positioning: nil, at: NSPoint(x: 100, y: 100), in: nil)
            finished = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        timeout.invalidate()
        expect(finished && updatedWhileTracking, "Async results must arrive while AppKit tracks a menu opened from the main queue")
        menu.delegate = nil
    }
    settings.compactMenuBar = false
    settings.showNetworkSpeeds = false
    let changedNetwork = NetworkSpeedReading(downloadBytesPerSecond: 900, uploadBytesPerSecond: 800,
        totalDownloadedBytes: 10_000, totalUploadedBytes: 20_000)
    display.update(reading: sample, gpuWatts: 3, cpuTemperature: 55, fanRPM: 2500, network: network, uptime: 90_000)
    expect(item.button!.toolTip == nil, "Details live only in the menu, not in a tooltip")
    let previousLabel = item.button!.accessibilityLabel()
    display.update(reading: sample, gpuWatts: 3, cpuTemperature: 55, fanRPM: 2500, network: changedNetwork, uptime: 90_000)
    expect(item.button!.accessibilityLabel() != previousLabel, "Accessibility label must update even for readings hidden from the bar")
    settings.compactMenuBar = true
    display.update(reading: sample, gpuWatts: 3, cpuTemperature: 55, fanRPM: 2500, network: changedNetwork, uptime: 90_000)
    expect(item.button!.toolTip == nil, "Icon-only mode has no tooltip either")

    let busyApps = [ActiveApp(name: "Xcode", cpu: 138, memoryMB: 2_150), ActiveApp(name: "Safari", cpu: 38, memoryMB: 540),
                    ActiveApp(name: "A very long application name that must truncate", cpu: 7.5, memoryMB: 96),
                    ActiveApp(name: "WindowServer", cpu: 3, memoryMB: 310)]
    let fullSnapshot = MenuSnapshot(reading: sample, gpuWatts: 6.1, cpuTemperature: 58, fanRPM: 1850,
        network: NetworkSpeedReading(downloadBytesPerSecond: 2_400_000, uploadBytesPerSecond: 310_000,
                                     totalDownloadedBytes: 4_200_000_000, totalUploadedBytes: 612_000_000),
        activeApps: busyApps, energy: EnergyAccumulator(wattHours: 1_240, activeSeconds: 22_320), uptime: 90_000,
        temperatureHistory: history)
    settings.showActiveApps = true
    StatusMenuBuilder(settings: settings, snapshot: fullSnapshot, actions: actions).populate(menu)
    expect(menu.items.contains { $0.title == "Energy & Cost" && $0.view?.accessibilityLabel() == "Energy: 1.24 kWh · R 4.34 · £0.32. Tracked for: 6h 12m" },
           "Energy row shows the short total, both costs and tracked time")
    expect(menu.items.contains { $0.title == "Network" && $0.view?.accessibilityLabel() == "Network: ↓ 2.4 MB/s  ↑ 310 KB/s. Since launch: ↓ \(formatByteCount(4_200_000_000))  ↑ 612 MB" },
           "Network row shows speeds and session totals")
    capture("menu-dashboard") { DashboardView(snapshot: fullSnapshot, updated: "10:42:07", now: end) }
    for level in [MemoryPressureLevel.normal, .warning, .critical] {
        for hasFan in [true, false] {
            var pressureSnapshot = fullSnapshot
            pressureSnapshot.cpuUsage = 38
            pressureSnapshot.memoryPressure = MemoryPressureReading(percentage: level == .normal ? 44 : level == .warning ? 72 : 92, level: level)
            if !hasFan {
                pressureSnapshot = MenuSnapshot(reading: sample, gpuWatts: 6.1, cpuTemperature: 58, fanRPM: nil,
                    network: network, activeApps: busyApps, energy: fullSnapshot.energy, uptime: 90_000,
                    temperatureHistory: history, cpuUsage: 38, memoryPressure: pressureSnapshot.memoryPressure)
            }
            let panel = DashboardView(snapshot: pressureSnapshot, updated: "10:42:07", now: end)
            panel.layoutSubtreeIfNeeded()
            let tiles = descendants(panel).compactMap { $0 as? TileView }
            expect(tiles.count == (hasFan ? 5 : 4), "Dashboard has five tiles with a fan, four without")
            let rows = descendants(panel).compactMap { $0 as? NSStackView }.filter { $0.arrangedSubviews.first is TileView }
            expect(rows.count == 2 && rows.map { $0.arrangedSubviews.count } == (hasFan ? [3, 2] : [2, 2]), "Sensor tiles form two balanced rows")
            for row in rows {
                let cells = row.arrangedSubviews
                expect(cells.allSatisfy { $0.frame.width > 80 && $0.frame.height > 35 && row.bounds.contains($0.frame) }
                       && zip(cells, cells.dropFirst()).allSatisfy { $0.frame.maxX + 7 <= $1.frame.minX }, "Tiles fit their row without overlap")
                let widths = cells.map { $0.frame.width }
                expect((widths.max()! - widths.min()!) <= 1, "Tile widths differ by at most one point for pixel rounding")
            }
            expect(tiles.contains { $0.accessibilityLabel() == "CPU load 38 %" }
                   && tiles.contains { $0.accessibilityLabel() == "CPU temp 58 °C" }, "CPU load and temperature are unambiguous")
            expect(tiles.first { $0.status != nil }?.status == level
                   && panel.accessibilityLabel()!.contains(formatMemoryPressure(pressureSnapshot.memoryPressure)), "Pressure dot and accessible status follow the snapshot")
            for tile in tiles {
                expect(tile.subviews.allSatisfy { tile.bounds.contains($0.frame) }, "Tile labels stay inside their backgrounds")
            }
            capture("menu-dashboard-memory-\(level.rawValue)\(hasFan ? "" : "-fanless")") {
                DashboardView(snapshot: pressureSnapshot, updated: "10:42:07", now: end)
            }
        }
    }
    capture("menu-dashboard-measuring") {
        DashboardView(snapshot: MenuSnapshot(reading: nil, gpuWatts: nil, cpuTemperature: nil, fanRPM: nil, network: nil,
            activeApps: nil, energy: EnergyAccumulator(wattHours: 0, activeSeconds: 0), uptime: 90_000), updated: nil, now: end)
    }
    capture("menu-dashboard-battery") {
        DashboardView(snapshot: MenuSnapshot(reading: draining, gpuWatts: 12, cpuTemperature: 91, fanRPM: nil, network: nil,
            activeApps: nil, energy: EnergyAccumulator(wattHours: 0, activeSeconds: 0), uptime: 90_000), updated: "10:42:07", now: end)
    }
    let sections = menu.items.filter { ["Network", "Energy & Cost", "Busiest Apps"].contains($0.title) || $0.identifier?.rawValue.hasPrefix("active-app-") == true }
    capture("menu-sections") {
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 0))
        var y: CGFloat = 0
        for section in sections.reversed() where !section.isHidden {
            let copy: NSView
            switch section.view {
            case let row as AppRowView:
                let fresh = AppRowView()
                let index = Int(section.identifier!.rawValue.split(separator: "-").last!)!
                if index < busyApps.count { fresh.show(busyApps[index], description: section.title) } else { continue }
                _ = row
                copy = fresh
            case is AppHeaderView: copy = AppHeaderView()
            default:
                copy = section.title == "Network"
                    ? SummaryRowView(title: "Network", value: "↓ 2.4 MB/s  ↑ 310 KB/s", detailTitle: "Since launch", detailValue: "↓ 4.2 GB  ↑ 612 MB")
                    : SummaryRowView(title: "Energy", value: "1.24 kWh · R 4.34 · £0.32", detailTitle: "Tracked for", detailValue: "6h 12m")
            }
            copy.frame.origin.y = y
            y += copy.frame.height + 6
            stack.addSubview(copy)
        }
        stack.frame.size.height = y
        return stack
    }
    capture("temperature-history-empty") { TemperatureHistoryView(history: TemperatureHistory(), now: end) }

    settings.showActiveApps = false
    settings.trackEnergyUsage = false
    StatusMenuBuilder(settings: settings, snapshot: snapshot, actions: actions).populate(menu)
    expect(!menu.items.contains { $0.title == "Energy & Cost" || $0.title == "Busiest Apps" || $0.identifier?.rawValue.hasPrefix("active-app-") == true },
           "Turning off energy tracking and busiest apps removes their sections")
    let settingsMenu = menu.items.first { $0.title == "Settings" }!.submenu!
    let settingsToggles = Dictionary(uniqueKeysWithValues: settingsMenu.items.filter { $0.action != nil }.map { ($0.title, $0.state) })
    expect(settingsToggles["Show Busiest Apps"] == .off && settingsToggles["Track Energy Usage & Cost"] == .off,
           "The section switches live in Settings and show their state")
}

networkTests()
systemUsageTests()
loaderTests()
appTests()
energyTests()
flowTests()
historyTests()
formattingTests()
flowSummaryTests()
graphTests()
graphSettingTests()
warningTests()
shortFormatTests()
if CommandLine.arguments.contains("--ui") { interfaceTests() }
if CommandLine.arguments.contains("--live-network") {
    let counters = NetworkSpeedReader.interfaceByteCounters()
    expect(counters != nil && !counters!.isEmpty, "Live macOS 64-bit network query must return interfaces")
    print("Live network: \(counters!.count) active interfaces, 64-bit counter data available")
}
if CommandLine.arguments.contains("--live-system") {
    let reader = CPUUsageReader()
    expect(reader.read() == nil, "Live CPU starts without a delta")
    Thread.sleep(forTimeInterval: 1)
    let cpu = reader.read()
    let memory = MemoryPressureReader().read()
    expect(cpu != nil && (0...100).contains(cpu!), "Live CPU returns an all-core percentage")
    expect(memory != nil && memory!.level != .unknown, "Live macOS memory pressure is readable without privileges")
    print(String(format: "Live CPU usage: %.2f %%", cpu!))
    print("Live memory pressure: \(formatMemoryPressure(memory)), available \(Int(100 - memory!.percentage)) %")
}
print("Passed \(checks) checks")

import Cocoa

/// Shared geometry for the view-backed rows of the status menu. Native menu
/// item titles sit in a text field framed 14 pt from the menu's edge; a label
/// field's alignment edge is 2 pt inside its frame, so a 16 pt inset puts
/// these labels exactly where the native titles are.
enum PanelMetrics {
    static let width: CGFloat = 320
    static let inset: CGFloat = 16
    static var contentWidth: CGFloat { width - inset * 2 }
    static var menuFontSize: CGFloat { NSFont.menuFont(ofSize: 0).pointSize }
    /// Quiet fill behind tiles and the chart. A dynamic colour, so it resolves
    /// for the current appearance whenever it is drawn.
    static let tint = NSColor(name: "WattBarPanelTint") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.05)
    }
}

func panelLabel(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.setAccessibilityElement(false)
    return field
}

/// A single-line label for attributed text. NSTextField(labelWithAttributedString:)
/// wraps, so its natural width follows its current frame and Auto Layout can
/// squeeze it to nothing; this one keeps the width of its text.
func attributedLabel(_ text: NSAttributedString) -> NSTextField {
    let field = NSTextField(labelWithAttributedString: text)
    field.maximumNumberOfLines = 1
    field.cell?.wraps = false
    field.cell?.truncatesLastVisibleLine = true
    field.lineBreakMode = .byTruncatingTail
    field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    field.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    field.setAccessibilityElement(false)
    return field
}

/// A big value with a smaller dimmed unit after it, e.g. "42 W".
func valueWithUnit(_ value: String, unit: String, size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
    let text = NSMutableAttributedString(string: value, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.labelColor
    ])
    guard !unit.isEmpty else { return text }
    text.append(NSAttributedString(string: " " + unit, attributes: [
        .font: NSFont.systemFont(ofSize: max(11, (size * 0.5).rounded()), weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor
    ]))
    return text
}

/// Makes a panel view the shared width and the height its content needs. The
/// width is only preferred, so a wider menu can still stretch the row.
private func sizeToFit(_ view: NSView, height: CGFloat? = nil) {
    view.frame = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: height ?? 0)
    if height == nil {
        let width = view.widthAnchor.constraint(equalToConstant: PanelMetrics.width)
        width.priority = .defaultHigh
        width.isActive = true
        view.frame.size.height = ceil(view.fittingSize.height)
        width.isActive = false
    }
    view.autoresizingMask = [.width]
}

/// A menu-item control consumes mouseDown and acts once on mouseUp. Returning
/// itself from hitTest prevents its noneditable labels swallowing the click.
class GraphActionView: NSView {
    var onPress: (() -> Void)? { didSet { setAccessibilityRole(onPress == nil ? .group : .button) } }
    var graphSelected = false {
        didSet {
            setAccessibilityValue(graphSelected ? 1 : 0); setAccessibilitySelected(graphSelected); needsDisplay = true
        }
    }
    private(set) var hovered = false
    private var pressed = false
    private var hoverArea: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return onPress == nil ? hit : self
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    func updateHover(_ inside: Bool) {
        guard hovered != inside else { return }
        hovered = inside; needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { updateHover(true) }
    override func mouseExited(with event: NSEvent) { updateHover(false) }
    override func mouseDown(with event: NSEvent) { pressed = onPress != nil }
    override func mouseUp(with event: NSEvent) {
        let activate = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if activate { onPress?() }
    }
    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return false }
        onPress(); return true
    }
    override func draw(_ dirtyRect: NSRect) {
        if onPress != nil && hovered {
            NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        if graphSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)
            path.lineWidth = 1.5; path.stroke()
        }
    }
}

/// Geometry and the set of sensors are chosen once, when the menu opens.
final class DashboardView: NSView {
    let heroBlock = GraphActionView()
    let flowBlock = GraphActionView()
    let cpu = TileView(title: "CPU")
    let memory = TileView(title: "Memory")
    let gpu = TileView(title: "GPU")
    private let fan: TileView?
    private let hero = attributedLabel(NSAttributedString())
    private let state = panelLabel("", size: 11, color: .secondaryLabelColor)
    private let stamp = panelLabel("", size: 11, color: .tertiaryLabelColor)
    private let flow = attributedLabel(NSAttributedString())
    private let chart: TemperatureHistoryView
    private let compactTiles: Bool
    var onSelectMetric: ((GraphMetric) -> Void)?
    private var selected: GraphMetric = .off
    private var cpuReadingLabel = ""

    init(snapshot: MenuSnapshot, updated: String?, now: Date) {
        compactTiles = snapshot.fanRPM == nil
        fan = snapshot.fanRPM == nil ? nil : TileView(title: "Fan")
        chart = TemperatureHistoryView(history: snapshot.temperatureHistory, now: now)
        let height: CGFloat = (snapshot.fanRPM == nil ? 154 : 212) + chart.frame.height + 6
        super.init(frame: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: height))
        autoresizingMask = [.width]
        func place(_ view: NSView, x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, in parent: NSView) {
            view.frame = NSRect(x: x, y: parent.bounds.height - top - height, width: width, height: height)
            parent.addSubview(view)
        }
        place(heroBlock, x: 10, top: 2, width: 120, height: 57, in: self)
        place(
            panelLabel("System draw", size: 11, color: .secondaryLabelColor), x: 6, top: 3, width: 108, height: 16,
            in: heroBlock)
        place(hero, x: 6, top: 16, width: 108, height: 38, in: heroBlock)
        place(state, x: 136, top: 10, width: 168, height: 16, in: self)
        place(stamp, x: 136, top: 29, width: 168, height: 16, in: self)
        state.alignment = .right; stamp.alignment = .right
        place(flowBlock, x: 10, top: 60, width: 300, height: 24, in: self)
        place(flow, x: 6, top: 3, width: 288, height: 18, in: flowBlock)
        let rows = fan.map { [[cpu, memory], [gpu, $0]] } ?? [[cpu, memory, gpu]]
        for (index, tiles) in rows.enumerated() {
            let row = NSStackView(views: tiles)
            row.orientation = .horizontal; row.distribution = .fillEqually; row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                row.topAnchor.constraint(equalTo: topAnchor, constant: 92 + CGFloat(index) * 58),
                row.widthAnchor.constraint(equalToConstant: 288), row.heightAnchor.constraint(equalToConstant: 50),
            ])
        }
        place(chart, x: 16, top: compactTiles ? 154 : 212, width: 288, height: chart.frame.height, in: self)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        heroBlock.onPress = { [weak self] in self?.onSelectMetric?(.systemDraw) }
        cpu.onPress = { [weak self] in
            guard let self else { return }
            self.onSelectMetric?(self.selected == .cpuUsage ? .cpuTemperature : .cpuUsage)
        }
        memory.onPress = { [weak self] in self?.onSelectMetric?(.memoryPressure) }
        gpu.onPress = { [weak self] in self?.onSelectMetric?(.gpuDraw) }
        update(snapshot: snapshot, updated: updated, now: now)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func select(_ metric: GraphMetric) {
        selected = metric
        heroBlock.graphSelected = metric == .systemDraw
        flowBlock.graphSelected = metric == .batteryFlow && flowBlock.onPress != nil
        cpu.graphSelected = metric == .cpuUsage || metric == .cpuTemperature
        memory.graphSelected = metric == .memoryPressure
        gpu.graphSelected = metric == .gpuDraw
        cpu.setAccessibilityLabel(
            (metric == .cpuUsage ? "Graph CPU temperature in the menu bar. " : "Graph CPU usage in the menu bar. ")
                + cpuReadingLabel)
    }

    func update(snapshot: MenuSnapshot, updated: String?, now: Date) {
        let reading = snapshot.reading
        hero.attributedStringValue = valueWithUnit(
            reading?.systemWatts.map { String(format: "%.0f", $0) } ?? "--",
            unit: reading?.systemWatts == nil ? "" : "W", size: 30, weight: .semibold)
        state.stringValue = reading?.powerState ?? "Measuring…"
        stamp.stringValue = updated.map { "updated \($0)" } ?? ""
        let parts = reading.map { PowerFlow.summary(for: $0) } ?? []
        flow.attributedStringValue = Self.flowText(parts)
        flowBlock.onPress = hasSystemBattery(reading) ? { [weak self] in self?.onSelectMetric?(.batteryFlow) } : nil
        heroBlock.setAccessibilityElement(true)
        heroBlock.setAccessibilityLabel("Graph System draw in the menu bar, \(formatWatts(reading?.systemWatts))")
        flowBlock.setAccessibilityElement(true)
        flowBlock.setAccessibilityLabel(
            (hasSystemBattery(reading) ? "Graph Battery charge or drain in the menu bar. " : "")
                + PowerFlow.summaryText(parts))
        let load = snapshot.cpuUsage.map { String(format: "%.0f%%", $0) } ?? "--"
        let temp = snapshot.cpuTemperature.map { String(format: "%.0f°C", $0) } ?? "--"
        let cpuText = NSMutableAttributedString(
            string: load + " · ",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: compactTiles ? 11 : 16, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
        cpuText.append(
            NSAttributedString(
                string: temp,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: compactTiles ? 11 : 16, weight: .semibold),
                    .foregroundColor: StatusWarning.cpuIsHot(snapshot.cpuTemperature)
                        ? NSColor.systemOrange : NSColor.labelColor,
                ]))
        cpuReadingLabel =
            "CPU load \(formatPercentage(snapshot.cpuUsage)), CPU temperature \(formatCPUTemperature(snapshot.cpuTemperature))"
        cpu.show(
            cpuText,
            label:
                "Graph CPU usage or temperature in the menu bar. CPU load \(formatPercentage(snapshot.cpuUsage)), CPU temperature \(formatCPUTemperature(snapshot.cpuTemperature))"
        )
        memory.status = snapshot.memoryPressure?.level
        memory.show(
            valueWithUnit(
                snapshot.memoryPressure.map { String(format: "%.0f", $0.percentage) } ?? "--",
                unit: snapshot.memoryPressure == nil ? "" : "%", size: 17, weight: .semibold),
            label: "Graph Memory pressure in the menu bar. \(formatMemoryPressure(snapshot.memoryPressure))")
        gpu.show(
            valueWithUnit(
                snapshot.gpuWatts.map { String(format: "%.1f", $0) } ?? "--", unit: snapshot.gpuWatts == nil ? "" : "W",
                size: 17, weight: .semibold),
            label: "Graph GPU draw in the menu bar. \(formatGPUWatts(snapshot.gpuWatts))")
        fan?.show(
            valueWithUnit(
                snapshot.fanRPM.map { $0 < 1 ? "off" : Int($0.rounded()).formatted() } ?? "--",
                unit: (snapshot.fanRPM ?? 0) < 1 ? "" : "rpm", size: 17, weight: .semibold),
            label: "Fan \(formatFanSpeed(snapshot.fanRPM))")
        chart.update(history: snapshot.temperatureHistory, now: now)
        select(selected)
        setAccessibilityLabel(
            [
                "System draw \(formatWatts(reading?.systemWatts))", state.stringValue, stamp.stringValue,
                PowerFlow.summaryText(parts).replacingOccurrences(of: "→", with: "to"), cpu.accessibilityLabel() ?? "",
                "Memory pressure \(formatMemoryPressure(snapshot.memoryPressure))",
                "GPU \(formatGPUWatts(snapshot.gpuWatts))",
                fan?.accessibilityLabel() ?? "",
                TemperatureHistoryView.accessibilityText(snapshot.temperatureHistory),
            ].joined(separator: ". "))
    }

    private static func flowText(_ parts: [PowerFlow.Part]) -> NSAttributedString {
        let dim: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let text = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: PowerFlow.separator(before: index), attributes: dim))
            }
            text.append(NSAttributedString(string: part.label + " ", attributes: dim))
            text.append(
                NSAttributedString(
                    string: part.value,
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: part.tone == .charging
                            ? NSColor.systemGreen : part.tone == .draining ? NSColor.systemOrange : NSColor.labelColor,
                    ]))
        }
        return text
    }
}

final class TileView: GraphActionView {
    var status: MemoryPressureLevel? { didSet { needsDisplay = true } }
    private let figure = attributedLabel(NSAttributedString())
    init(title: String) {
        super.init(frame: .zero)
        let name = panelLabel(title, size: 11, color: .secondaryLabelColor)
        for view in [name, figure] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        figure.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            figure.topAnchor.constraint(equalTo: name.bottomAnchor),
            figure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            figure.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            figure.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func show(_ text: NSAttributedString, label: String) {
        figure.attributedStringValue = text; setAccessibilityLabel(label)
    }
    override func draw(_ dirtyRect: NSRect) {
        PanelMetrics.tint.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        super.draw(dirtyRect)
        if let status {
            let color: NSColor =
                status == .normal
                ? .systemGreen
                : status == .warning ? .systemYellow : status == .critical ? .systemRed : .secondaryLabelColor
            color.setFill();
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 14, y: bounds.maxY - 16, width: 6, height: 6)).fill()
        }
    }
}

/// Fixed-height two-line summary, updated without replacing the menu item.
final class SummaryRowView: GraphActionView {
    var actionLabel: String? { didSet { updateAccessibilityLabel() } }
    private var summaryLabel = ""
    private func updateAccessibilityLabel() {
        setAccessibilityLabel([actionLabel, summaryLabel].compactMap { $0 }.joined(separator: ". "))
    }
    private var cells: [NSTextField] = []
    init(title: String, value: String, detailTitle: String, detailValue: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 39))
        autoresizingMask = [.width]
        cells = [
            panelLabel(title, size: PanelMetrics.menuFontSize), panelLabel(value, size: PanelMetrics.menuFontSize),
            panelLabel(detailTitle, size: 11, color: .secondaryLabelColor),
            panelLabel(detailValue, size: 11, color: .secondaryLabelColor),
        ]
        for cell in cells { addSubview(cell) }
        cells[1].alignment = .right; cells[3].alignment = .right
        setAccessibilityElement(true); setAccessibilityRole(.group)
        update(title: title, value: value, detailTitle: detailTitle, detailValue: detailValue)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(title: String, value: String, detailTitle: String, detailValue: String) {
        for (cell, text) in zip(cells, [title, value, detailTitle, detailValue]) { cell.stringValue = text }
        summaryLabel = "\(title): \(value). \(detailTitle): \(detailValue)"
        updateAccessibilityLabel()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        for row in 0..<2 {
            let left = cells[row * 2], right = cells[row * 2 + 1]
            let width = min(100, ceil((left.stringValue as NSString).size(withAttributes: [.font: left.font!]).width) + 4)
            left.frame = NSRect(x: 16, y: row == 0 ? 20 : 4, width: width, height: 16)
            right.frame = NSRect(x: 16 + width + 8, y: row == 0 ? 20 : 4, width: bounds.width - 40 - width, height: 16)
        }
    }
}

/// Heading for the busiest-apps list, with its column legend on the right.
final class AppHeaderView: NSView {
    init() {
        super.init(frame: .zero)
        let title = panelLabel("Busiest apps", size: 11, weight: .semibold, color: .secondaryLabelColor)
        let legend = panelLabel("CPU · memory", size: 11, color: .tertiaryLabelColor)
        for view in [title, legend] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1).isActive = true
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            legend.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset)
        ])
        sizeToFit(self, height: 20)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Busiest apps, by CPU and memory")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// One busiest-app row: name, a CPU bar, CPU share and memory. Also carries
/// the loading and empty messages, so the row can be reused as results arrive.
final class AppRowView: NSView {
    static let height: CGFloat = 22

    private let name = panelLabel("", size: PanelMetrics.menuFontSize)
    private let cpu = panelLabel("", size: 12)
    private let memory = panelLabel("", size: 12, color: .secondaryLabelColor)
    private let bar = BarView()

    init() {
        super.init(frame: .zero)
        cpu.alignment = .right
        memory.alignment = .right
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [name, bar, cpu, memory] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        let inset = PanelMetrics.inset
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            name.trailingAnchor.constraint(lessThanOrEqualTo: bar.leadingAnchor, constant: -10),
            memory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            memory.widthAnchor.constraint(equalToConstant: 56),
            cpu.trailingAnchor.constraint(equalTo: memory.leadingAnchor, constant: -2),
            cpu.widthAnchor.constraint(equalToConstant: 40),
            bar.trailingAnchor.constraint(equalTo: cpu.leadingAnchor, constant: -4),
            bar.widthAnchor.constraint(equalToConstant: 52),
            bar.heightAnchor.constraint(equalToConstant: 4)
        ])
        sizeToFit(self, height: Self.height)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ app: ActiveApp, description: String) {
        name.stringValue = app.name
        name.textColor = .labelColor
        cpu.stringValue = String(format: "%.0f%%", app.cpu)
        memory.stringValue = formatAppMemory(app.memoryMB)
        // One full core fills the bar; busier apps simply stay full.
        bar.fraction = CGFloat(max(0, min(1, app.cpu / 100)))
        for view in [bar, cpu, memory] as [NSView] { view.isHidden = false }
        setAccessibilityLabel(description)
    }

    func show(message: String) {
        name.stringValue = message
        name.textColor = .secondaryLabelColor
        for view in [bar, cpu, memory] as [NSView] { view.isHidden = true }
        setAccessibilityLabel(message)
    }
}

final class BarView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        var filled = bounds
        filled.size.width = max(bounds.height, bounds.width * fraction)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

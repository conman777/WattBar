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

/// Top of the menu: system draw, where the power is flowing, the key sensors
/// and the CPU temperature chart.
final class DashboardView: NSView {
    init(snapshot: MenuSnapshot, updated: String?, now: Date) {
        super.init(frame: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 0))
        let reading = snapshot.reading

        let caption = panelLabel("System draw", size: 11, color: .secondaryLabelColor)
        let watts = reading?.systemWatts.map { String(format: "%.0f", $0) } ?? "--"
        let hero = attributedLabel(
            valueWithUnit(watts, unit: reading?.systemWatts == nil ? "" : "W", size: 30, weight: .semibold))
        hero.setContentCompressionResistancePriority(.required, for: .horizontal)
        let state = panelLabel(reading?.powerState ?? "Measuring…", size: 11, color: .secondaryLabelColor)
        let stamp = panelLabel(updated.map { "updated \($0)" } ?? "", size: 11, color: .tertiaryLabelColor)
        state.alignment = .right
        stamp.alignment = .right
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let parts = reading.map { PowerFlow.summary(for: $0) } ?? []
        let flow = attributedLabel(Self.flowText(parts))

        let cpuLoad = TileView(title: "CPU load", value: snapshot.cpuUsage.map { String(format: "%.0f", $0) } ?? "--",
                               unit: snapshot.cpuUsage == nil ? "" : "%")
        let memory = TileView(title: "Memory", value: snapshot.memoryPressure.map { String(format: "%.0f", $0.percentage) } ?? "--",
                              unit: snapshot.memoryPressure == nil ? "" : "%", status: snapshot.memoryPressure?.level)
        let cpuTemp = TileView(title: "CPU temp", value: snapshot.cpuTemperature.map { String(format: "%.0f", $0) } ?? "--",
                               unit: snapshot.cpuTemperature == nil ? "" : "°C")
        let gpu = TileView(title: "GPU", value: snapshot.gpuWatts.map { String(format: "%.1f", $0) } ?? "--",
                           unit: snapshot.gpuWatts == nil ? "" : "W")
        let rows: [[TileView]]
        // Three over two with a fan; two equal pairs on fanless Macs.
        if let rpm = snapshot.fanRPM {
            let fan = rpm < 1 ? TileView(title: "Fan", value: "off", unit: "")
                : TileView(title: "Fan", value: Int(rpm.rounded()).formatted(), unit: "rpm")
            rows = [[cpuLoad, memory, gpu], [cpuTemp, fan]]
        } else {
            rows = [[cpuLoad, memory], [cpuTemp, gpu]]
        }
        let tileGrid = NSStackView()
        tileGrid.orientation = .vertical
        tileGrid.alignment = .leading
        tileGrid.spacing = 8
        for tiles in rows {
            let row = NSStackView(views: tiles)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 8
            tileGrid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: tileGrid.widthAnchor).isActive = true
        }

        let chart = TemperatureHistoryView(history: snapshot.temperatureHistory, now: now)

        for view in [caption, hero, state, stamp, flow, tileGrid, chart] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = PanelMetrics.inset
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            hero.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: -1),
            hero.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),

            // Power state and time sit on the right, the time on the hero's baseline.
            stamp.lastBaselineAnchor.constraint(equalTo: hero.lastBaselineAnchor),
            stamp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            state.bottomAnchor.constraint(equalTo: stamp.topAnchor, constant: -1),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            state.leadingAnchor.constraint(greaterThanOrEqualTo: hero.trailingAnchor, constant: 12),

            flow.topAnchor.constraint(equalTo: hero.bottomAnchor, constant: 2),
            flow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            flow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),

            tileGrid.topAnchor.constraint(equalTo: (parts.isEmpty ? hero : flow).bottomAnchor, constant: 10),
            tileGrid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            tileGrid.widthAnchor.constraint(equalToConstant: PanelMetrics.contentWidth),

            chart.topAnchor.constraint(equalTo: tileGrid.bottomAnchor, constant: 12),
            chart.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            chart.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        flow.isHidden = parts.isEmpty
        sizeToFit(self)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        var summary = ["System draw \(formatWatts(reading?.systemWatts))"]
        if let reading { summary.append(reading.powerState) }
        if let updated { summary.append("updated \(updated)") }
        if !parts.isEmpty { summary.append(PowerFlow.summaryText(parts).replacingOccurrences(of: "→", with: "to")) }
        summary.append("CPU load \(formatPercentage(snapshot.cpuUsage))")
        summary.append("Memory pressure \(formatMemoryPressure(snapshot.memoryPressure))")
        summary.append("CPU temperature \(formatCPUTemperature(snapshot.cpuTemperature))")
        summary.append("GPU \(formatGPUWatts(snapshot.gpuWatts))")
        if snapshot.fanRPM != nil { summary.append("Fan \(formatFanSpeed(snapshot.fanRPM))") }
        summary.append(TemperatureHistoryView.accessibilityText(snapshot.temperatureHistory))
        setAccessibilityLabel(summary.joined(separator: ". "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func flowText(_ parts: [PowerFlow.Part]) -> NSAttributedString {
        let dim: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: PowerFlow.separator(before: index), attributes: dim)) }
            let color: NSColor
            switch part.tone {
            case .neutral: color = .labelColor
            case .charging: color = .systemGreen
            case .draining: color = .systemOrange
            }
            text.append(NSAttributedString(string: part.label + " ", attributes: dim))
            text.append(NSAttributedString(string: part.value, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: color
            ]))
        }
        return text
    }
}

/// One sensor reading on a tinted rounded background.
final class TileView: NSView {
    let status: MemoryPressureLevel?

    init(title: String, value: String, unit: String, status: MemoryPressureLevel? = nil) {
        self.status = status
        super.init(frame: .zero)
        let name = panelLabel(title, size: 11, color: .secondaryLabelColor)
        let figure = attributedLabel(valueWithUnit(value, unit: unit, size: 17, weight: .semibold))
        for view in [name, figure] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        figure.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: status == nil ? -6 : -20),
            figure.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 0),
            figure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            figure.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            figure.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(("\(title) \(value) \(unit)" + (status.map { ", \($0.title) pressure" } ?? "")).trimmingCharacters(in: .whitespaces))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        PanelMetrics.tint.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        if let status {
            let color: NSColor
            switch status {
            case .normal: color = .systemGreen
            case .warning: color = .systemYellow
            case .critical: color = .systemRed
            case .unknown: color = .secondaryLabelColor
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 14, y: bounds.maxY - 16, width: 6, height: 6)).fill()
        }
    }
}

/// Two-line summary row: a section name with its headline value, then a
/// dimmed detail line underneath.
final class SummaryRowView: NSView {
    init(title: String, value: String, detailTitle: String, detailValue: String) {
        super.init(frame: .zero)
        let size = PanelMetrics.menuFontSize
        let cells = [
            panelLabel(title, size: size),
            panelLabel(value, size: size),
            panelLabel(detailTitle, size: 11, color: .secondaryLabelColor),
            panelLabel(detailValue, size: 11, color: .secondaryLabelColor)
        ]
        for cell in cells {
            cell.translatesAutoresizingMaskIntoConstraints = false
            addSubview(cell)
        }
        cells[1].alignment = .right
        cells[3].alignment = .right
        cells[1].setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cells[3].setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset = PanelMetrics.inset
        NSLayoutConstraint.activate([
            cells[0].topAnchor.constraint(equalTo: topAnchor, constant: 3),
            cells[0].leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            cells[1].firstBaselineAnchor.constraint(equalTo: cells[0].firstBaselineAnchor),
            cells[1].trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            cells[1].leadingAnchor.constraint(greaterThanOrEqualTo: cells[0].trailingAnchor, constant: 8),
            cells[2].topAnchor.constraint(equalTo: cells[0].bottomAnchor, constant: 1),
            cells[2].leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            cells[2].bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            cells[3].firstBaselineAnchor.constraint(equalTo: cells[2].firstBaselineAnchor),
            cells[3].trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            cells[3].leadingAnchor.constraint(greaterThanOrEqualTo: cells[2].trailingAnchor, constant: 8)
        ])
        sizeToFit(self)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title): \(value). \(detailTitle): \(detailValue)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
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

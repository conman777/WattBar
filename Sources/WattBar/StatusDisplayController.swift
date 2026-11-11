import Cocoa

final class StatusDisplayController {
    private let statusItem: NSStatusItem
    private let settings: AppSettings
    private let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    /// Draws the full readout (graph and columns) on top of the status button.
    let contentView = StatusContentView()
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

    init(statusItem: NSStatusItem, settings: AppSettings) {
        self.statusItem = statusItem
        self.settings = settings
        if let button = statusItem.button {
            contentView.frame = button.bounds
            contentView.autoresizingMask = [.width, .height]
            contentView.isHidden = true
            button.addSubview(contentView)
        }
    }

    /// The readout as text, row by row; nil while the full readout is hidden.
    var displayedText: String? { contentView.isHidden ? nil : contentView.content.text }

    func update(reading latestReading: PowerReading?, gpuWatts latestGPUWatts: Double?, cpuTemperature latestCPUTemperature: Double?, fanRPM latestFanRPM: Double?, network latestNetworkSpeed: NetworkSpeedReading?, uptime: TimeInterval, graph: GraphHistory = GraphHistory(), cpuUsage: Double? = nil, memoryPressure: MemoryPressureReading? = nil) {
        guard let reading = latestReading else {
            applyStatusPresentation(
                length: settings.compactMenuBar ? 28 : NSStatusItem.variableLength,
                image: settings.compactMenuBar ? compactStatusImage : nil,
                attributedTitle: NSAttributedString(
                    string: settings.compactMenuBar ? "" : "WattBar",
                    attributes: [.font: statusFont]
                ),
                content: nil,
                accessibilityLabel: "WattBar"
            )
            return
        }

        let accessibleTitle = [
            "System \(formatWatts(reading.systemWatts))",
            "CPU temperature \(formatCPUTemperature(latestCPUTemperature))",
            "CPU usage \(formatPercentage(cpuUsage))",
            "Memory pressure \(formatMemoryPressure(memoryPressure))",
            "Fan \(formatFanSpeed(latestFanRPM))",
            formatMenuBarPowerFlow(
                adapterInputWatts: reading.adapterInputWatts,
                batteryFlowWatts: reading.batteryFlowWatts
            ),
            formatAccessibleNetworkSpeed(latestNetworkSpeed),
            "GPU \(formatGPUWatts(latestGPUWatts))",
            "Computer uptime \(formatSystemUptime(uptime))"
        ].joined(separator: " | ")

        guard !settings.compactMenuBar else {
            applyStatusPresentation(length: 28, image: compactStatusImage, attributedTitle: NSAttributedString(),
                                    content: nil, accessibilityLabel: "WattBar \(accessibleTitle)")
            return
        }
        let content = statusContent(reading: reading, gpuWatts: latestGPUWatts,
                                    cpuTemperature: latestCPUTemperature, network: latestNetworkSpeed, graph: graph,
                                    cpuUsage: cpuUsage, memoryPressure: memoryPressure)
        applyStatusPresentation(
            length: max(40, ceil(StatusContentView.layout(content).width) + 12),
            image: nil,
            attributedTitle: NSAttributedString(),
            content: content,
            accessibilityLabel: "WattBar \(accessibleTitle)"
        )
    }

    private func statusContent(reading: PowerReading, gpuWatts: Double?, cpuTemperature: Double?,
                               network: NetworkSpeedReading?, graph: GraphHistory,
                               cpuUsage: Double?, memoryPressure: MemoryPressureReading?) -> StatusContent {
        typealias Field = StatusContent.Field
        let cpuHot = StatusWarning.cpuIsHot(cpuTemperature)
        var drainHigh = false
        let gpu = gpuWatts.map { String(format: "%.0fW", $0) } ?? "--W"

        // Each column reserves room for its widest usual reading (digits are
        // monospaced, so "888" covers any three-digit value). Without this the
        // status item resizes, and shifts its neighbours, as values change.
        var columns: [StatusContent.Column] = []
        if settings.showMenuBarLabel {
            columns.append(.init(top: Field("WATT", "", .primary), bottom: nil, reserve: []))
        }
        columns.append(.init(
            top: Field("SYS", reading.systemWatts.map { String(format: "%.0fW", $0) } ?? "--W", .primary),
            bottom: Field("CPU", cpuTemperature.map { String(format: "%.0f°", $0) } ?? "--°", .primary, warning: cpuHot),
            reserve: [Field("SYS", "888W", .primary), Field("CPU", "88°", .primary)]
        ))
        if settings.showChargingRate {
            let flow = PowerFlow(adapterInputWatts: reading.adapterInputWatts, batteryFlowWatts: reading.batteryFlowWatts)
            drainHigh = StatusWarning.batteryDrainIsHigh(flow)
            columns.append(.init(
                top: Field(flow.label, flow.compactValue, .secondary, warning: drainHigh),
                bottom: Field("GPU", gpu, .secondary),
                reserve: [Field("IN", "888W", .secondary), Field("BAT", "−88W", .secondary), Field("GPU", "88W", .secondary)]
            ))
        } else {
            // GPU keeps the top row, in line with SYS; the slot under it stays empty.
            columns.append(.init(top: Field("GPU", gpu, .secondary), bottom: nil,
                                 reserve: [Field("GPU", "88W", .secondary)]))
        }
        if settings.showNetworkSpeeds {
            columns.append(.init(
                top: Field("↓", formatStackedNetworkSpeed(network?.downloadBytesPerSecond), .secondary),
                bottom: Field("↑", formatStackedNetworkSpeed(network?.uploadBytesPerSecond), .secondary),
                reserve: [Field("↓", "888M", .secondary), Field("↑", "888M", .secondary)]
            ))
        }

        let metric = settings.graphMetric.resolved(hasBattery: hasSystemBattery(reading))
        let style = settings.graphStyle
        let tint: StatusContent.Graph.Tint
        switch metric {
        case .cpuUsage: tint = StatusWarning.cpuUsageIsHigh(cpuUsage) ? .orange : .monochrome
        case .memoryPressure:
            switch memoryPressure?.level {
            case .warning: tint = .yellow
            case .critical: tint = .red
            default: tint = .monochrome
            }
        default: tint = cpuHot || drainHigh ? .orange : .monochrome
        }
        let graphContent = metric == .off ? nil : StatusContent.Graph(
            metric: metric,
            style: style,
            bars: style == .bars
                ? graph.bars(metric, now: reading.updatedAt)
                : graph.buckets(metric, now: reading.updatedAt,
                                duration: GraphHistory.lineBucketDuration(refreshInterval: settings.refreshInterval)),
            scale: graph.scale(metric),
            tint: tint
        )
        return StatusContent(graph: graphContent, columns: columns)
    }

    private func applyStatusPresentation(
        length: CGFloat,
        image: NSImage?,
        attributedTitle: NSAttributedString,
        content: StatusContent?,
        accessibilityLabel: String
    ) {
        guard let button = statusItem.button else { return }

        button.setAccessibilityLabel(accessibilityLabel)
        // New readings only redraw the content view; the button itself changes
        // when the mode or the reserved width does.
        if let content { contentView.content = content }
        let presentationChanged = button.image !== image
            || !button.attributedTitle.isEqual(to: attributedTitle)
            || statusItem.length != length
            || contentView.isHidden != (content == nil)
        guard presentationChanged else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false

            // Replace the contents before resizing the status item so AppKit
            // never renders the compact icon over the expanded text.
            if button.image !== image { button.image = image }
            button.imagePosition = image == nil ? .noImage : .imageOnly
            button.imageScaling = .scaleNone
            button.alignment = .center
            if !button.attributedTitle.isEqual(to: attributedTitle) {
                button.attributedTitle = attributedTitle
            }
            contentView.isHidden = content == nil
            if statusItem.length != length { statusItem.length = length }
            button.needsLayout = true
            button.layoutSubtreeIfNeeded()
            contentView.frame = button.bounds
        }
    }
}

/// Everything the full menu bar readout draws, as plain values.
struct StatusContent: Equatable {
    struct Field: Equatable {
        enum Emphasis { case primary, secondary }
        let label: String
        let value: String
        let emphasis: Emphasis
        var warning = false

        init(_ label: String, _ value: String, _ emphasis: Emphasis, warning: Bool = false) {
            self.label = label
            self.value = value
            self.emphasis = emphasis
            self.warning = warning
        }
    }

    struct Column: Equatable {
        let top: Field
        let bottom: Field?
        /// Values the column keeps room for, so its width does not follow the readings.
        let reserve: [Field]
        var fields: [Field] { [top] + (bottom.map { [$0] } ?? []) }
    }

    struct Graph: Equatable {
        let metric: GraphMetric
        let style: GraphStyle
        /// Bucket averages, oldest first: one per bar, or one per line point.
        let bars: [Double?]
        let scale: Double
        enum Tint { case monochrome, orange, yellow, red }
        let tint: Tint
        var warning: Bool { tint != .monochrome }
    }

    var graph: Graph?
    var columns: [Column]

    var text: String {
        func row(_ fields: [Field?]) -> String {
            fields.compactMap { $0.map { [$0.label, $0.value].filter { !$0.isEmpty }.joined(separator: " ") } }
                .joined(separator: "  ")
        }
        return row(columns.map(\.top)) + "\n" + row(columns.map(\.bottom))
    }

    var hasWarning: Bool { columns.flatMap(\.fields).contains { $0.warning } }
}

/// Draws the graph and the two rows of readings. Drawing in draw(_:) with
/// semantic colours resolves them for the menu bar's current appearance at
/// every redraw, renders at the screen's scale, and keeps the warning colour,
/// which a template image would flatten.
final class StatusContentView: NSView {
    static let graphWidth: CGFloat = 32
    static let graphGap: CGFloat = 8
    static let columnGap: CGFloat = 10
    static let labelGap: CGFloat = 3
    /// Baseline-to-baseline distance of the two rows.
    static let lineSpacing: CGFloat = 10.5

    static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    static let primaryFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    static let secondaryFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    var content = StatusContent(graph: nil, columns: []) {
        didSet { if content != oldValue { needsDisplay = true } }
    }

    struct Placement {
        let x: CGFloat
        let valueX: CGFloat
        let width: CGFloat
    }

    struct Layout {
        let graphX: CGFloat?
        let columns: [Placement]
        let width: CGFloat
    }

    // Clicks go to the status button underneath; it also carries the readings
    // for assistive technology.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private static func font(_ emphasis: StatusContent.Field.Emphasis) -> NSFont {
        emphasis == .primary ? primaryFont : secondaryFont
    }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat {
        text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Positions from the left edge of the readout. Widths depend on labels
    /// and reserved values, so ordinary readings never change them.
    static func layout(_ content: StatusContent) -> Layout {
        // Off gives the graph's width back; every other choice takes the same slot.
        let graphX: CGFloat? = content.graph == nil ? nil : 0
        var x: CGFloat = graphX == nil ? 0 : graphWidth + graphGap
        var placements: [Placement] = []
        for (index, column) in content.columns.enumerated() {
            if index > 0 { x += columnGap }
            let fields = column.fields + column.reserve
            let labelWidth = fields.map { width($0.label, labelFont) }.max() ?? 0
            let valueWidth = fields.map { width($0.value, font($0.emphasis)) }.max() ?? 0
            let columnWidth = labelWidth + (valueWidth > 0 && labelWidth > 0 ? labelGap : 0) + valueWidth
            placements.append(Placement(x: x, valueX: x + labelWidth + (labelWidth > 0 ? labelGap : 0), width: columnWidth))
            x += columnWidth
        }
        return Layout(graphX: graphX, columns: placements, width: x)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = Self.layout(content)
        let origin = ((bounds.width - layout.width) / 2).rounded()
        let topBaseline = bounds.midY + 1.75
        let bottomBaseline = topBaseline - Self.lineSpacing

        if let graph = content.graph, let graphX = layout.graphX {
            let top = topBaseline + Self.primaryFont.capHeight
            MenuBarGraphDrawing.draw(graph, in: NSRect(x: origin + graphX, y: bottomBaseline,
                                                       width: Self.graphWidth, height: top - bottomBaseline))
        }

        for (column, placement) in zip(content.columns, layout.columns) {
            for (field, baseline) in [(column.top, topBaseline), (column.bottom, bottomBaseline)] {
                guard let field else { continue }
                draw(field.label, font: Self.labelFont, color: .secondaryLabelColor,
                     x: origin + placement.x, baseline: baseline)
                let color: NSColor
                if field.warning {
                    color = .systemOrange
                } else {
                    color = field.emphasis == .primary ? .labelColor : NSColor.labelColor.withAlphaComponent(0.8)
                }
                draw(field.value, font: Self.font(field.emphasis), color: color,
                     x: origin + placement.valueX, baseline: baseline)
            }
        }
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat) {
        guard !text.isEmpty else { return }
        // Without .usesLineFragmentOrigin the rect's origin is the baseline.
        (text as NSString).draw(with: NSRect(x: x, y: baseline, width: 200, height: 20), options: [],
                                attributes: [.font: font, .foregroundColor: color], context: nil)
    }
}

/// The small history graph. Line style: a line with a faint fill to the
/// baseline. Bars style: bars from zero, bars around a zero line for the
/// battery, or a line for temperature. Empty buckets draw nothing.
enum MenuBarGraphDrawing {
    static let barWidth: CGFloat = 2
    static let lineWidth: CGFloat = 1.2

    static func color(for graph: StatusContent.Graph) -> NSColor {
        switch graph.tint {
        case .monochrome: return NSColor.labelColor.withAlphaComponent(0.75)
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .red: return .systemRed
        }
    }

    static func draw(_ graph: StatusContent.Graph, in rect: NSRect) {
        let color = color(for: graph)
        let count = graph.bars.count
        guard count > 1 else { return }
        let step = (rect.width - barWidth) / CGFloat(count - 1)
        func barX(_ index: Int) -> CGFloat { rect.minX + CGFloat(index) * step }

        // A hairline marks the zero (or, for temperature, the bottom) of the graph.
        let baselineY = graph.metric == .batteryFlow ? (rect.midY * 2).rounded() / 2 : rect.minY
        NSColor.tertiaryLabelColor.setFill()
        NSRect(x: rect.minX, y: baselineY - 0.25, width: rect.width, height: 0.5).fill()

        if graph.style == .line {
            drawLine(graph, in: rect, baselineY: baselineY, color: color)
            return
        }

        switch graph.metric {
        case .cpuTemperature:
            let values = graph.bars.compactMap { $0 }
            guard let low = values.min(), let high = values.max() else { return }
            let scale = TemperatureChartView.scale(minimum: low, maximum: high)
            func point(_ index: Int, _ celsius: Double) -> NSPoint {
                let fraction = (celsius - scale.low) / (scale.high - scale.low)
                return NSPoint(x: barX(index) + barWidth / 2,
                               y: rect.minY + 1 + CGFloat(max(0, min(1, fraction))) * (rect.height - 2))
            }
            color.set()
            var line: NSBezierPath?
            for (index, value) in graph.bars.enumerated() {
                guard let value else {
                    line?.stroke()
                    line = nil
                    continue
                }
                let next = point(index, value)
                if let line {
                    line.line(to: next)
                } else {
                    let path = NSBezierPath()
                    path.lineWidth = 1.25
                    path.lineJoinStyle = .round
                    path.lineCapStyle = .round
                    path.move(to: next)
                    line = path
                    // An isolated reading still shows, as a dot.
                    let isolated = index + 1 >= count || graph.bars[index + 1] == nil
                    if isolated { NSBezierPath(ovalIn: NSRect(x: next.x - 1, y: next.y - 1, width: 2, height: 2)).fill() }
                }
            }
            line?.stroke()
        case .batteryFlow:
            color.setFill()
            let half = rect.height / 2
            for (index, value) in graph.bars.enumerated() {
                guard let value, abs(value) >= 0.05 else { continue }
                let height = max(1, CGFloat(min(1, abs(value) / graph.scale)) * half)
                let y = value > 0 ? baselineY : baselineY - height
                NSRect(x: barX(index), y: y, width: barWidth, height: height).fill()
            }
        case .systemDraw, .gpuDraw, .networkDownload, .cpuUsage, .memoryPressure, .off:
            color.setFill()
            for (index, value) in graph.bars.enumerated() {
                guard let value, value > 0 else { continue }
                let height = max(1, CGFloat(min(1, value / graph.scale)) * rect.height)
                NSRect(x: barX(index), y: rect.minY, width: barWidth, height: height).fill()
            }
        }
    }

    /// Same scaling as the bars: power and network from zero against the
    /// remembered peak, battery around zero, temperature over its recent range.
    private static func drawLine(_ graph: StatusContent.Graph, in rect: NSRect, baselineY: CGFloat, color: NSColor) {
        let inset = lineWidth / 2
        let count = graph.bars.count
        let step = (rect.width - lineWidth) / CGFloat(count - 1)
        let values = graph.bars.compactMap { $0 }
        guard let low = values.min(), let high = values.max() else { return }
        let temperatureScale = TemperatureChartView.scale(minimum: low, maximum: high)

        func point(_ index: Int, _ value: Double) -> NSPoint {
            let x = rect.minX + inset + CGFloat(index) * step
            switch graph.metric {
            case .cpuTemperature:
                let fraction = (value - temperatureScale.low) / (temperatureScale.high - temperatureScale.low)
                return NSPoint(x: x, y: rect.minY + inset + CGFloat(max(0, min(1, fraction))) * (rect.height - lineWidth))
            case .batteryFlow:
                let fraction = CGFloat(max(-1, min(1, value / graph.scale)))
                return NSPoint(x: x, y: baselineY + fraction * (rect.height / 2 - inset))
            case .systemDraw, .gpuDraw, .networkDownload, .cpuUsage, .memoryPressure, .off:
                let fraction = CGFloat(max(0, min(1, value / graph.scale)))
                return NSPoint(x: x, y: rect.minY + inset + fraction * (rect.height - lineWidth))
            }
        }

        // Runs of consecutive buckets; an empty bucket breaks the line.
        var runs: [[NSPoint]] = [[]]
        for (index, value) in graph.bars.enumerated() {
            if let value { runs[runs.count - 1].append(point(index, value)) } else if !runs[runs.count - 1].isEmpty { runs.append([]) }
        }
        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            if run.count == 1 {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: first.x - 1.2, y: first.y - 1.2, width: 2.4, height: 2.4)).fill()
                continue
            }
            let line = NSBezierPath()
            line.move(to: first)
            run.dropFirst().forEach { line.line(to: $0) }

            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: last.x, y: baselineY))
            area.line(to: NSPoint(x: first.x, y: baselineY))
            area.close()
            color.withAlphaComponent(graph.warning ? 0.25 : 0.18).setFill()
            area.fill()

            line.lineWidth = lineWidth
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            color.setStroke()
            line.stroke()
        }
    }
}

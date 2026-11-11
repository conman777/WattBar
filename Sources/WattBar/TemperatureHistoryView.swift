import Cocoa

/// CPU temperature over the history window, shown inline in the menu's
/// dashboard: a one-line header with the range figures, then the chart. Fills
/// the panel's content width; the dashboard supplies the side insets.
final class TemperatureHistoryView: NSView {
    static let chartHeight: CGFloat = 64

    private var summary: NSTextField!
    private var chart: TemperatureChartView!

    init(history: TemperatureHistory, now: Date) {
        super.init(frame: NSRect(x: 0, y: 0, width: PanelMetrics.contentWidth, height: 0))

        let minutes = Int(history.window / 60)
        let title = panelLabel("CPU temp · last \(minutes) min", size: 11, weight: .semibold,
                               color: .secondaryLabelColor)
        let figures = [("min", history.minimum), ("avg", history.average), ("max", history.maximum)]
        summary = attributedLabel(Self.summaryText(figures))
        chart = TemperatureChartView(history: history, now: now)

        for view in [title, summary!, chart!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: summary.leadingAnchor, constant: -8),
            summary.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor),
            chart.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            chart.leadingAnchor.constraint(equalTo: leadingAnchor),
            chart.trailingAnchor.constraint(equalTo: trailingAnchor),
            chart.heightAnchor.constraint(equalToConstant: Self.chartHeight),
            chart.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: PanelMetrics.contentWidth)
        ])
        frame.size.height = ceil(fittingSize.height)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.accessibilityText(history))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(history: TemperatureHistory, now: Date) {
        summary.attributedStringValue = Self.summaryText([("min", history.minimum), ("avg", history.average), ("max", history.maximum)])
        chart.update(history: history, now: now)
        setAccessibilityLabel(Self.accessibilityText(history))
    }

    static func accessibilityText(_ history: TemperatureHistory) -> String {
        let figures = [("now", history.latest), ("minimum", history.minimum),
                       ("average", history.average), ("maximum", history.maximum)]
        return "CPU temperature, last \(Int(history.window / 60)) minutes: "
            + figures.map { "\($0.0) \(formatCPUTemperature($0.1))" }.joined(separator: ", ")
    }

    private static func summaryText(_ figures: [(String, Double?)]) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, (name, value)) in figures.enumerated() {
            text.append(NSAttributedString(string: (index > 0 ? "  " : "") + name + " ", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor
            ]))
            text.append(NSAttributedString(string: value.map { String(format: "%.0f°", $0) } ?? "--", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]))
        }
        return text
    }
}

final class TemperatureChartView: NSView {
    /// Readings further apart than this (sleep, sensor dropouts) break the line.
    static let gapThreshold: TimeInterval = 90

    private var history: TemperatureHistory
    private var now: Date

    init(history: TemperatureHistory, now: Date) {
        self.history = history
        self.now = now
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(history: TemperatureHistory, now: Date) {
        self.history = history; self.now = now; needsDisplay = true
    }

    /// Rounded to 5° steps with at least 10° of range, so small wobbles do
    /// not look dramatic and the axis labels stay tidy.
    static func scale(minimum: Double, maximum: Double) -> (low: Double, high: Double) {
        var low = ((minimum - 2) / 5).rounded(.down) * 5
        var high = ((maximum + 2) / 5).rounded(.up) * 5
        if high - low < 10 {
            let middle = (low + high) / 2
            low = ((middle - 5) / 5).rounded(.down) * 5
            high = low + 10
            if high < maximum { high += 5 }
        }
        return (low, high)
    }

    override func draw(_ dirtyRect: NSRect) {
        let axisFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let axisAttributes: [NSAttributedString.Key: Any] = [
            .font: axisFont, .foregroundColor: NSColor.secondaryLabelColor
        ]
        let labelGutter: CGFloat = 28
        let timeRow: CGFloat = 14
        let plot = NSRect(x: labelGutter, y: timeRow,
                          width: bounds.width - labelGutter, height: bounds.height - timeRow - 4)

        // Same quiet tint as the dashboard tiles; resolved per appearance at draw time.
        PanelMetrics.tint.setFill()
        NSBezierPath(roundedRect: plot, xRadius: 6, yRadius: 6).fill()

        ("\(Int(history.window / 60)) min ago" as NSString)
            .draw(at: NSPoint(x: plot.minX, y: 0), withAttributes: axisAttributes)
        let nowLabel = "now" as NSString
        nowLabel.draw(at: NSPoint(x: plot.maxX - nowLabel.size(withAttributes: axisAttributes).width, y: 0),
                      withAttributes: axisAttributes)

        guard history.samples.count >= 2, let minimum = history.minimum, let maximum = history.maximum else {
            let message = "Collecting readings…" as NSString
            let size = message.size(withAttributes: axisAttributes)
            message.draw(at: NSPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2),
                         withAttributes: axisAttributes)
            return
        }

        let (low, high) = Self.scale(minimum: minimum, maximum: maximum)
        func y(_ celsius: Double) -> CGFloat {
            plot.minY + 4 + CGFloat((celsius - low) / (high - low)) * (plot.height - 8)
        }
        func x(_ date: Date) -> CGFloat {
            let elapsed = history.window - now.timeIntervalSince(date)
            return plot.minX + CGFloat(max(0, min(1, elapsed / history.window))) * plot.width
        }

        // Horizontal guides with their temperatures in the gutter.
        let guides = [low, (low + high) / 2, high]
        for value in guides {
            let guide = NSBezierPath()
            guide.move(to: NSPoint(x: plot.minX, y: y(value)))
            guide.line(to: NSPoint(x: plot.maxX, y: y(value)))
            guide.lineWidth = 0.5
            NSColor.separatorColor.setStroke()
            guide.stroke()
            let label = String(format: "%.0f°", value) as NSString
            let size = label.size(withAttributes: axisAttributes)
            label.draw(at: NSPoint(x: labelGutter - size.width - 4, y: y(value) - size.height / 2),
                       withAttributes: axisAttributes)
        }

        // Split into runs at gaps so sleep is not drawn as a straight line.
        var runs: [[TemperatureHistory.Sample]] = []
        for sample in history.samples {
            if let previous = runs.last?.last,
               sample.date.timeIntervalSince(previous.date) <= Self.gapThreshold {
                runs[runs.count - 1].append(sample)
            } else {
                runs.append([sample])
            }
        }

        let color = NSColor.systemOrange
        for run in runs {
            let points = run.map { NSPoint(x: x($0.date), y: y($0.celsius)) }
            guard let first = points.first, let last = points.last else { continue }
            if points.count == 1 {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)).fill()
                continue
            }
            let line = NSBezierPath()
            line.move(to: first)
            points.dropFirst().forEach { line.line(to: $0) }

            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: last.x, y: plot.minY))
            area.line(to: NSPoint(x: first.x, y: plot.minY))
            area.close()
            color.withAlphaComponent(0.15).setFill()
            area.fill()

            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            color.setStroke()
            line.stroke()
        }
    }
}

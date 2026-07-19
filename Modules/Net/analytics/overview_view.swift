//
//  overview_view.swift
//  Net
//

import Cocoa
import Kit

internal struct TrafficOverviewBillingPeriod {
    let interval: DateInterval
    private let calendar: Calendar
    private let cycleDay: Int

    init(containing date: Date, cycleDay: Int, calendar: Calendar = .current) {
        self.calendar = calendar
        let requestedDay = min(max(cycleDay, 1), 31)
        self.cycleDay = requestedDay
        let monthAnchor = calendar.date(from: calendar.dateComponents([.year, .month], from: date))
            ?? calendar.startOfDay(for: date)
        let thisCycle = Self.cycleDate(monthAnchor: monthAnchor, requestedDay: requestedDay, calendar: calendar)
        if date >= thisCycle {
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthAnchor)
                ?? monthAnchor.addingTimeInterval(31 * 86_400)
            self.interval = DateInterval(
                start: thisCycle,
                end: Self.cycleDate(monthAnchor: nextMonth, requestedDay: requestedDay, calendar: calendar)
            )
        } else {
            let previousMonth = calendar.date(byAdding: .month, value: -1, to: monthAnchor)
                ?? monthAnchor.addingTimeInterval(-31 * 86_400)
            self.interval = DateInterval(
                start: Self.cycleDate(monthAnchor: previousMonth, requestedDay: requestedDay, calendar: calendar),
                end: thisCycle
            )
        }
    }

    var totalDays: Int {
        max(1, self.calendar.dateComponents([.day], from: self.interval.start, to: self.interval.end).day ?? 1)
    }

    func elapsedDays(at date: Date) -> Int {
        let completed = self.calendar.dateComponents([.day], from: self.interval.start, to: min(date, self.interval.end)).day ?? 0
        return min(self.totalDays, max(1, completed + 1))
    }

    func query(networkID: String?, now: Date) -> TrafficAnalyticsQuery {
        TrafficAnalyticsQuery(
            range: .currentMonth,
            networkID: networkID,
            selectedInterval: DateInterval(start: self.interval.start, end: min(now, self.interval.end)),
            billingCycleDay: self.cycleDay,
            now: now
        )
    }

    private static func cycleDate(monthAnchor: Date, requestedDay: Int, calendar: Calendar) -> Date {
        let availableDays = calendar.range(of: .day, in: .month, for: monthAnchor)?.count ?? 28
        var components = calendar.dateComponents([.year, .month], from: monthAnchor)
        components.day = min(requestedDay, availableDays)
        return calendar.date(from: components) ?? monthAnchor
    }
}

internal final class TrafficOverviewView: NSView {
    private let engine: TrafficAnalyticsEngine
    private let planStore: TrafficRuleStore
    private let networkRegistry: NetworkRegistry
    private var selectedNetworkID: String?
    private let networkControl = NSPopUpButton()
    private let usedLabel = NSTextField(labelWithString: "—")
    private let periodLabel = NSTextField(labelWithString: "—")
    private let quotaLabel = NSTextField(labelWithString: "—")
    private let forecastLabel = NSTextField(labelWithString: "—")
    private let progress = NSProgressIndicator()
    private let trendView = TrafficOverviewTrendView()
    private let appsView: TrafficOverviewAppsView

    init(
        engine: TrafficAnalyticsEngine,
        planStore: TrafficRuleStore,
        networkRegistry: NetworkRegistry = NetworkRegistry(),
        iconResolver: ApplicationIconResolving = ApplicationIconResolver()
    ) {
        self.engine = engine
        self.planStore = planStore
        self.networkRegistry = networkRegistry
        self.appsView = TrafficOverviewAppsView(iconResolver: iconResolver)
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.build()
        self.reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload(networkID: String? = nil) {
        if let networkID { self.selectedNetworkID = networkID }
        let now = Date()
        let plan = self.selectedNetworkID.map { self.planStore.networkPlan(for: $0) } ?? self.planStore.networkPlan()
        let billingPeriod = TrafficOverviewBillingPeriod(containing: now, cycleDay: plan.billingCycleDay)
        let snapshot = self.engine.snapshot(for: billingPeriod.query(networkID: self.selectedNetworkID, now: now))

        self.usedLabel.stringValue = Units(bytes: Int64(snapshot.total)).getReadableMemory()
        let elapsed = billingPeriod.elapsedDays(at: now)
        let days = billingPeriod.totalDays
        self.periodLabel.stringValue = "\(localizedString("Billing progress"))  \(elapsed) / \(days)"
        self.progress.doubleValue = min(100, Double(elapsed) / Double(days) * 100)

        if let limit = plan.byteLimit {
            let remaining = limit > snapshot.total ? limit - snapshot.total : 0
            self.quotaLabel.stringValue = "\(localizedString("Remaining quota"))  \(Units(bytes: Int64(remaining)).getReadableMemory())"
        } else {
            self.quotaLabel.stringValue = localizedString("No quota configured")
        }
        if let forecast = snapshot.forecast, forecast.state == .ready, let projected = forecast.projectedBytes {
            self.forecastLabel.stringValue = "\(localizedString("Month-end forecast"))  \(Units(bytes: Int64(projected)).getReadableMemory())"
        } else {
            self.forecastLabel.stringValue = "\(localizedString("Month-end forecast"))  \(localizedString("Insufficient data"))"
        }

        let week = self.engine.snapshot(for: TrafficAnalyticsQuery(
            range: .sevenDays,
            networkID: self.selectedNetworkID,
            billingCycleDay: plan.billingCycleDay,
            now: now
        ))
        self.trendView.buckets = Array(week.buckets.suffix(7))
        self.appsView.update(Array(snapshot.ranking.prefix(6)), total: max(snapshot.total, 1))
    }

    private func build() {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let content = FlippedStackView()
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content
        self.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: self.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        let status = self.makeStatusStrip()
        status.identifier = NSUserInterfaceItemIdentifier("overview-anomaly-status")
        content.addArrangedSubview(status)
        self.pin(status, height: 32, to: content)

        let period = self.makePeriodCard()
        period.identifier = NSUserInterfaceItemIdentifier("overview-period-card")
        content.addArrangedSubview(period)
        self.pin(period, height: 145, to: content)

        let trend = self.makeTrendCard()
        trend.identifier = NSUserInterfaceItemIdentifier("overview-seven-day-card")
        content.addArrangedSubview(trend)
        self.pin(trend, height: 172, to: content)

        let apps = self.makeAppsCard()
        apps.identifier = NSUserInterfaceItemIdentifier("overview-top-applications")
        content.addArrangedSubview(apps)
        self.pin(apps, height: 202, to: content)

        let footer = NSTextField(labelWithString: localizedString("Analytics stay on this Mac"))
        footer.alignment = .center
        footer.textColor = .tertiaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        footer.setAccessibilityLabel(localizedString("Analytics stay on this Mac"))
        content.addArrangedSubview(footer)
        self.pin(footer, height: 28, to: content)
    }

    private func makeStatusStrip() -> NSView {
        let card = OverviewCardView(radius: 8, color: .systemGreen.withAlphaComponent(0.10))
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemGreen
        let label = NSTextField(labelWithString: localizedString("No unusual traffic detected"))
        label.font = .systemFont(ofSize: 11, weight: .medium)
        let network = self.networkControl
        self.reloadNetworkMenu()
        network.target = self
        network.action = #selector(self.networkChanged)
        network.controlSize = .small
        let row = NSStackView(views: [icon, label, NSView(), network])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15), icon.heightAnchor.constraint(equalToConstant: 15)
        ])
        return card
    }

    private func makePeriodCard() -> NSView {
        let card = OverviewCardView()
        let title = self.label("Current period usage", size: 12, weight: .semibold)
        self.usedLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        self.progress.style = .bar
        self.progress.isIndeterminate = false
        self.progress.minValue = 0
        self.progress.maxValue = 100
        self.progress.controlTint = .blueControlTint
        let left = NSStackView(views: [title, self.usedLabel, self.progress, self.periodLabel])
        left.orientation = .vertical; left.alignment = .leading; left.spacing = 6
        self.progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let details = NSStackView(views: [
            self.metric("gauge.with.dots.needle.50percent", self.quotaLabel),
            self.metric("calendar.badge.clock", self.forecastLabel)
        ])
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 14
        let row = NSStackView(views: [left, NSView(), details])
        row.orientation = .horizontal; row.alignment = .centerY
        self.install(row, in: card, inset: 16)
        return card
    }

    private func makeTrendCard() -> NSView {
        let card = OverviewCardView()
        let title = self.label("Last 7 days", size: 12, weight: .semibold)
        self.trendView.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, self.trendView])
        stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 5
        self.install(stack, in: card, inset: 12)
        return card
    }

    private func makeAppsCard() -> NSView {
        let card = OverviewCardView()
        let title = self.label("Top applications", size: 12, weight: .semibold)
        self.appsView.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [title, self.appsView])
        stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 7
        self.install(stack, in: card, inset: 12)
        return card
    }

    private func metric(_ symbol: String, _ value: NSTextField) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        value.textColor = .secondaryLabelColor
        value.font = .systemFont(ofSize: 11)
        let row = NSStackView(views: [icon, value])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 7
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        return row
    }

    private func label(_ key: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: localizedString(key))
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }

    private func install(_ view: NSView, in card: NSView, inset: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset)
        ])
    }

    private func pin(_ view: NSView, height: CGFloat, to stack: NSStackView) {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -stack.edgeInsets.left - stack.edgeInsets.right).isActive = true
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    private func reloadNetworkMenu() {
        self.networkControl.removeAllItems()
        self.networkControl.addItem(withTitle: localizedString("All networks"))
        for registered in self.networkRegistry.all() {
            self.networkControl.addItem(withTitle: self.networkRegistry.displayName(for: registered.identity.id))
            self.networkControl.lastItem?.representedObject = registered.identity.id
        }
        if let selectedNetworkID,
           let index = self.networkControl.itemArray.firstIndex(where: { $0.representedObject as? String == selectedNetworkID }) {
            self.networkControl.selectItem(at: index)
        } else {
            self.networkControl.selectItem(at: 0)
        }
    }

    @objc private func networkChanged() {
        self.selectedNetworkID = self.networkControl.indexOfSelectedItem <= 0 ? nil : self.networkControl.selectedItem?.representedObject as? String
        self.reload()
    }
}

private final class OverviewCardView: NSView {
    private let fillColor: NSColor
    init(radius: CGFloat = 10, color: NSColor = .controlBackgroundColor) {
        self.fillColor = color
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer?.cornerRadius = radius
        self.updateColor()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); self.updateColor() }
    private func updateColor() { self.layer?.backgroundColor = self.fillColor.cgColor }
}

private final class TrafficOverviewTrendView: NSView {
    var buckets: [TrafficBucket] = [] { didSet { self.needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !self.buckets.isEmpty else { self.drawCentered(localizedString("Insufficient data")); return }
        let totals = self.buckets.map { $0.download + $0.upload }
        let points = TrafficChartGeometry.overviewPoints(values: totals, in: self.bounds.insetBy(dx: 16, dy: 30))
        guard let first = points.first, let last = points.last else { return }
        let line = NSBezierPath(); let fill = NSBezierPath()
        line.move(to: first); fill.move(to: CGPoint(x: first.x, y: self.bounds.maxY - 24)); fill.line(to: first)
        points.dropFirst().forEach { line.line(to: $0); fill.line(to: $0) }
        fill.line(to: CGPoint(x: last.x, y: self.bounds.maxY - 24)); fill.close()
        NSColor.systemBlue.withAlphaComponent(0.13).setFill(); fill.fill()
        NSColor.systemBlue.setStroke(); line.lineWidth = 1.6; line.stroke()

        let formatter = DateFormatter(); formatter.setLocalizedDateFormatFromTemplate("EEE")
        for (index, bucket) in self.buckets.enumerated() where points.indices.contains(index) {
            let point = points[index]
            let value = Units(bytes: Int64(totals[index])).getReadableMemory() as NSString
            value.draw(at: CGPoint(x: point.x - 18, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor])
            (formatter.string(from: bucket.start) as NSString).draw(at: CGPoint(x: point.x - 13, y: self.bounds.maxY - 16), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    private func drawCentered(_ text: String) {
        (text as NSString).draw(at: CGPoint(x: self.bounds.midX - 42, y: self.bounds.midY - 7), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

private final class TrafficOverviewAppsView: NSView {
    private let iconResolver: ApplicationIconResolving
    private var items: [ApplicationTrafficSummary] = []
    private var total: UInt64 = 1
    override var isFlipped: Bool { true }
    init(iconResolver: ApplicationIconResolving) { self.iconResolver = iconResolver; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ items: [ApplicationTrafficSummary], total: UInt64) { self.items = items; self.total = max(total, 1); self.needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !self.items.isEmpty else {
            (localizedString("No application traffic yet") as NSString).draw(at: CGPoint(x: self.bounds.midX - 60, y: self.bounds.midY - 7), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let columns = self.bounds.width >= 720 ? 3 : 2
        let rows = Int(ceil(Double(min(self.items.count, 6)) / Double(columns)))
        let gap: CGFloat = 8
        let cellWidth = (self.bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (self.bounds.height - gap * CGFloat(max(rows - 1, 0))) / CGFloat(max(rows, 1))
        for (index, item) in self.items.prefix(6).enumerated() {
            let rect = CGRect(x: CGFloat(index % columns) * (cellWidth + gap), y: CGFloat(index / columns) * (cellHeight + gap), width: cellWidth, height: cellHeight)
            NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            self.iconResolver.icon(for: item.identity).draw(in: CGRect(x: rect.minX + 9, y: rect.midY - 10, width: 20, height: 20))
            (item.identity.displayName as NSString).draw(in: CGRect(x: rect.minX + 36, y: rect.minY + 7, width: rect.width - 44, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.labelColor])
            let percent = Int(Double(item.total) / Double(self.total) * 100)
            var detail = "\(Units(bytes: Int64(item.total)).getReadableMemory()) · \(percent)%"
            if item.routeContexts.contains(where: { $0.kind == .tunnel }) { detail += " · \(localizedString("Tunnel"))" }
            else if item.routeContexts.contains(where: { $0.kind == .systemProxy }) { detail += " · \(localizedString("Proxy"))" }
            (detail as NSString).draw(in: CGRect(x: rect.minX + 36, y: rect.minY + 24, width: rect.width - 44, height: 15), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

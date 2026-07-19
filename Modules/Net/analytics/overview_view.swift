//
//  overview_view.swift
//  Net
//

import Cocoa
import Kit

internal final class TrafficOverviewView: NSView {
    private let engine: TrafficAnalyticsEngine
    private let planStore: TrafficRuleStore
    private let networkRegistry: NetworkRegistry
    private var selectedNetworkID: String?
    private let networkControl = NSPopUpButton()
    private let periodLabel = NSTextField(labelWithString: "—")
    private let usedLabel = NSTextField(labelWithString: "—")
    private let quotaLabel = NSTextField(labelWithString: "—")
    private let forecastLabel = NSTextField(labelWithString: "—")
    private let trendView = TrafficOverviewTrendView()
    private let appsView = TrafficOverviewAppsView()

    init(
        engine: TrafficAnalyticsEngine,
        planStore: TrafficRuleStore,
        networkRegistry: NetworkRegistry = NetworkRegistry()
    ) {
        self.engine = engine
        self.planStore = planStore
        self.networkRegistry = networkRegistry
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.build()
        self.reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload(networkID: String? = nil) {
        if let networkID {
            self.selectedNetworkID = networkID
        }
        let now = Date()
        let plan = self.selectedNetworkID.map { self.planStore.networkPlan(for: $0) } ?? self.planStore.networkPlan()
        let snapshot = self.engine.snapshot(for: TrafficAnalyticsQuery(
            range: .currentMonth,
            networkID: self.selectedNetworkID,
            billingCycleDay: plan.billingCycleDay,
            now: now
        ))
        self.periodLabel.stringValue = "\(localizedString("Billing cycle day")): \(plan.billingCycleDay)"
        self.usedLabel.stringValue = Units(bytes: Int64(snapshot.total)).getReadableMemory()
        if let limit = plan.byteLimit {
            let percent = limit == 0 ? 0 : Int((Double(snapshot.total) / Double(limit)) * 100)
            self.quotaLabel.stringValue = "\(Units(bytes: Int64(snapshot.total)).getReadableMemory()) / \(Units(bytes: Int64(limit)).getReadableMemory()) (\(percent)%)"
        } else {
            self.quotaLabel.stringValue = localizedString("No quota")
        }
        if let forecast = snapshot.forecast {
            switch forecast.state {
            case .insufficientData:
                self.forecastLabel.stringValue = localizedString("Insufficient data")
            case .ready:
                let projected = forecast.projectedBytes.map { Units(bytes: Int64($0)).getReadableMemory() } ?? "—"
                self.forecastLabel.stringValue = "\(localizedString("Projected")): \(projected) · \(forecast.remainingDays)d"
            }
        } else {
            self.forecastLabel.stringValue = localizedString("Insufficient data")
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
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .width
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.setContentCompressionResistancePriority(.required, for: .vertical)
        self.heightAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        self.reloadNetworkMenu()
        self.networkControl.target = self
        self.networkControl.action = #selector(self.networkChanged)
        let networkRow = NSStackView(views: [
            NSTextField(labelWithString: localizedString("Network")),
            self.networkControl
        ])
        networkRow.orientation = .horizontal
        networkRow.alignment = .centerY
        networkRow.spacing = 8
        stack.addArrangedSubview(networkRow)
        networkRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.usedLabel.font = .systemFont(ofSize: 32, weight: .semibold)
        let usedBlock = NSStackView(views: [
            NSTextField(labelWithString: localizedString("Used this month")),
            self.usedLabel
        ])
        usedBlock.orientation = .vertical
        usedBlock.alignment = .leading
        usedBlock.spacing = 4

        let details = NSStackView(views: [self.periodLabel, self.quotaLabel, self.forecastLabel])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6
        details.arrangedSubviews.compactMap { $0 as? NSTextField }.forEach {
            $0.textColor = .secondaryLabelColor
            $0.font = .systemFont(ofSize: 11)
        }

        let hero = NSStackView(views: [usedBlock, details])
        hero.identifier = NSUserInterfaceItemIdentifier("traffic-overview-cards")
        hero.orientation = .horizontal
        hero.alignment = .centerY
        hero.distribution = .fill
        hero.spacing = 24
        hero.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        hero.wantsLayer = true
        hero.layer?.cornerRadius = 10
        hero.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        hero.heightAnchor.constraint(greaterThanOrEqualToConstant: 106).isActive = true
        stack.addArrangedSubview(hero)
        hero.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.trendView.translatesAutoresizingMaskIntoConstraints = false
        self.trendView.heightAnchor.constraint(equalToConstant: 155).isActive = true
        let trend = self.sectionCard(title: localizedString("Last 7 days"), value: self.trendView)
        stack.addArrangedSubview(trend)
        trend.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.appsView.translatesAutoresizingMaskIntoConstraints = false
        self.appsView.heightAnchor.constraint(equalToConstant: 142).isActive = true
        let top = self.sectionCard(title: localizedString("Top applications"), value: self.appsView)
        top.identifier = NSUserInterfaceItemIdentifier("traffic-overview-top-apps")
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)
        spacer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addSubview(hero, positioned: .above, relativeTo: nil)
        stack.addSubview(trend, positioned: .above, relativeTo: nil)
        stack.addSubview(top, positioned: .above, relativeTo: nil)
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
        self.selectedNetworkID = self.networkControl.indexOfSelectedItem <= 0
            ? nil
            : self.networkControl.selectedItem?.representedObject as? String
        self.reload()
    }

    private func sectionCard(title: String, value: NSView) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        let box = NSStackView(views: [titleField, value])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        box.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        return box
    }

}

private final class TrafficOverviewTrendView: NSView {
    var buckets: [TrafficBucket] = [] {
        didSet { self.needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let plot = self.bounds.insetBy(dx: 8, dy: 12)
        guard !self.buckets.isEmpty else {
            (localizedString("Insufficient data") as NSString).draw(
                at: CGPoint(x: plot.midX - 45, y: plot.midY - 8),
                withAttributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
            )
            return
        }

        let totals = self.buckets.map { CGFloat($0.download + $0.upload) }
        let maximum = max(totals.max() ?? 1, 1)
        let line = NSBezierPath()
        let fill = NSBezierPath()
        for (index, total) in totals.enumerated() {
            let x = plot.minX + plot.width * CGFloat(index) / CGFloat(max(totals.count - 1, 1))
            let y = plot.maxY - (plot.height * total / maximum)
            if index == 0 {
                line.move(to: CGPoint(x: x, y: y))
                fill.move(to: CGPoint(x: x, y: plot.maxY))
                fill.line(to: CGPoint(x: x, y: y))
            } else {
                line.line(to: CGPoint(x: x, y: y))
                fill.line(to: CGPoint(x: x, y: y))
            }
        }
        fill.line(to: CGPoint(x: plot.maxX, y: plot.maxY))
        fill.close()
        NSColor.systemBlue.withAlphaComponent(0.12).setFill()
        fill.fill()
        NSColor.systemBlue.setStroke()
        line.lineWidth = 1.5
        line.stroke()
    }
}

private final class TrafficOverviewAppsView: NSView {
    private var items: [ApplicationTrafficSummary] = []
    private var total: UInt64 = 1

    override var isFlipped: Bool { true }

    func update(_ items: [ApplicationTrafficSummary], total: UInt64) {
        self.items = items
        self.total = max(total, 1)
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !self.items.isEmpty else { return }
        let columns = 3
        let rows = 2
        let gap: CGFloat = 8
        let width = (self.bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (self.bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)

        for (index, item) in self.items.prefix(columns * rows).enumerated() {
            let column = index % columns
            let row = index / columns
            let rect = CGRect(
                x: CGFloat(column) * (width + gap),
                y: CGFloat(row) * (height + gap),
                width: width,
                height: height
            )
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.controlBackgroundColor.setFill()
            path.fill()

            let name = item.identity.displayName as NSString
            name.draw(
                in: rect.insetBy(dx: 10, dy: 9),
                withAttributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11, weight: .medium)]
            )
            let percent = Int(Double(item.total) / Double(self.total) * 100)
            let detail = "\(Units(bytes: Int64(item.total)).getReadableMemory()) · \(percent)%" as NSString
            detail.draw(
                at: CGPoint(x: rect.minX + 10, y: rect.maxY - 25),
                withAttributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 10)]
            )
        }
    }
}

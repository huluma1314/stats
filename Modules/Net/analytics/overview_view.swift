//
//  overview_view.swift
//  Net
//

import Cocoa
import Kit

internal final class TrafficOverviewView: NSView {
    private let engine: TrafficAnalyticsEngine
    private let planStore: TrafficRuleStore
    private let periodLabel = NSTextField(labelWithString: "—")
    private let usedLabel = NSTextField(labelWithString: "—")
    private let quotaLabel = NSTextField(labelWithString: "—")
    private let forecastLabel = NSTextField(labelWithString: "—")
    private let trendLabel = NSTextField(labelWithString: "")
    private let topAppsLabel = NSTextField(labelWithString: "")

    init(engine: TrafficAnalyticsEngine, planStore: TrafficRuleStore) {
        self.engine = engine
        self.planStore = planStore
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.build()
        self.reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        let now = Date()
        let snapshot = self.engine.snapshot(for: TrafficAnalyticsQuery(range: .currentMonth, now: now))
        let plan = self.planStore.networkPlan()
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

        let week = self.engine.snapshot(for: TrafficAnalyticsQuery(range: .sevenDays, now: now))
        self.trendLabel.stringValue = week.buckets.suffix(7).map {
            "\(Self.dayFormatter.string(from: $0.start)): \(Units(bytes: Int64($0.download + $0.upload)).getReadableMemory())"
        }.joined(separator: "\n")

        let top = snapshot.ranking.prefix(5)
        let total = max(snapshot.total, 1)
        self.topAppsLabel.stringValue = top.map {
            let percent = Int((Double($0.total) / Double(total)) * 100)
            return "\($0.identity.displayName): \(Units(bytes: Int64($0.total)).getReadableMemory()) (\(percent)%)"
        }.joined(separator: "\n")
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

        let cards = NSStackView(views: [
            self.card(title: localizedString("Current period"), value: self.periodLabel),
            self.card(title: localizedString("Used"), value: self.usedLabel),
            self.card(title: localizedString("Quota"), value: self.quotaLabel),
            self.card(title: localizedString("Forecast"), value: self.forecastLabel)
        ])
        cards.identifier = NSUserInterfaceItemIdentifier("traffic-overview-cards")
        cards.orientation = .horizontal
        cards.alignment = .top
        cards.distribution = .fillEqually
        cards.spacing = 8
        stack.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.trendLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        self.trendLabel.maximumNumberOfLines = 8
        let trend = self.sectionCard(title: localizedString("Last 7 days"), value: self.trendLabel)
        stack.addArrangedSubview(trend)
        trend.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.topAppsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        self.topAppsLabel.maximumNumberOfLines = 8
        let top = self.sectionCard(title: localizedString("Top applications"), value: self.topAppsLabel)
        top.identifier = NSUserInterfaceItemIdentifier("traffic-overview-top-apps")
        stack.addArrangedSubview(top)
        top.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)
        spacer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addSubview(cards, positioned: .above, relativeTo: nil)
        stack.addSubview(trend, positioned: .above, relativeTo: nil)
        stack.addSubview(top, positioned: .above, relativeTo: nil)
    }

    private func card(title: String, value: NSTextField) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.textColor = .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        value.font = .systemFont(ofSize: 16, weight: .semibold)
        let box = NSStackView(views: [titleField, value])
        box.orientation = .vertical
        box.alignment = .leading
        box.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        return box
    }

    private func sectionCard(title: String, value: NSTextField) -> NSView {
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()
}

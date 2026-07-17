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
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        stack.addArrangedSubview(self.card(title: localizedString("Current period"), value: self.periodLabel))
        stack.addArrangedSubview(self.card(title: localizedString("Used"), value: self.usedLabel))
        stack.addArrangedSubview(self.card(title: localizedString("Quota"), value: self.quotaLabel))
        stack.addArrangedSubview(self.card(title: localizedString("Forecast"), value: self.forecastLabel))

        let trendTitle = NSTextField(labelWithString: localizedString("Last 7 days"))
        trendTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        self.trendLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        self.trendLabel.maximumNumberOfLines = 8
        stack.addArrangedSubview(trendTitle)
        stack.addArrangedSubview(self.trendLabel)

        let topTitle = NSTextField(labelWithString: localizedString("Top applications"))
        topTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        self.topAppsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        self.topAppsLabel.maximumNumberOfLines = 8
        stack.addArrangedSubview(topTitle)
        stack.addArrangedSubview(self.topAppsLabel)
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd"
        return formatter
    }()
}

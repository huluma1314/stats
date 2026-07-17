//
//  analysis_view.swift
//  Net
//

import Cocoa
import Kit

internal final class TrafficAnalysisView: NSView {
    private let engine: TrafficAnalyticsEngine
    private var selection = TrafficSelection()
    private var snapshot: TrafficAnalyticsSnapshot?
    private var refreshTimer: Timer?

    private let rangeControl = NSSegmentedControl()
    private let chartModeControl = NSSegmentedControl()
    private let refreshControl = NSPopUpButton()
    private let networkControl = NSPopUpButton()
    private let refreshButton = NSButton()
    private let downloadLabel = NSTextField(labelWithString: "—")
    private let uploadLabel = NSTextField(labelWithString: "—")
    private let totalLabel = NSTextField(labelWithString: "—")
    private let rankingLabel = NSTextField(labelWithString: "")

    init(engine: TrafficAnalyticsEngine) {
        self.engine = engine
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.build()
        self.reload()
        self.scheduleRefresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.refreshTimer?.invalidate()
    }

    func reload(selection: TrafficSelection? = nil) {
        if let selection {
            self.selection = selection
        }
        self.snapshot = self.engine.snapshot(for: self.selection.analyticsQuery())
        self.render()
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        self.rangeControl.segmentCount = TrafficRange.allCases.count
        for (index, range) in TrafficRange.allCases.enumerated() {
            self.rangeControl.setLabel(self.rangeTitle(range), forSegment: index)
        }
        self.rangeControl.selectedSegment = 0
        self.rangeControl.target = self
        self.rangeControl.action = #selector(self.controlsChanged)

        self.chartModeControl.segmentCount = 2
        self.chartModeControl.setLabel(localizedString("Line"), forSegment: 0)
        self.chartModeControl.setLabel(localizedString("Heatmap"), forSegment: 1)
        self.chartModeControl.selectedSegment = 0
        self.chartModeControl.target = self
        self.chartModeControl.action = #selector(self.controlsChanged)

        self.refreshControl.removeAllItems()
        for mode in TrafficRefreshMode.allCases {
            self.refreshControl.addItem(withTitle: self.refreshTitle(mode))
        }
        self.refreshControl.selectItem(at: 2)
        self.refreshControl.target = self
        self.refreshControl.action = #selector(self.controlsChanged)

        self.networkControl.removeAllItems()
        self.networkControl.addItem(withTitle: localizedString("All networks"))
        for kind in NetworkKind.allCases {
            self.networkControl.addItem(withTitle: kind.rawValue.capitalized)
        }
        self.networkControl.target = self
        self.networkControl.action = #selector(self.controlsChanged)

        self.refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        self.refreshButton.bezelStyle = .texturedRounded
        self.refreshButton.target = self
        self.refreshButton.action = #selector(self.refreshClicked)

        let controls = NSStackView(views: [
            self.rangeControl,
            self.chartModeControl,
            self.networkControl,
            self.refreshControl,
            self.refreshButton
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        stack.addArrangedSubview(controls)

        let cards = NSStackView(views: [
            self.summaryCard(title: localizedString("Download"), field: self.downloadLabel),
            self.summaryCard(title: localizedString("Upload"), field: self.uploadLabel),
            self.summaryCard(title: localizedString("Total"), field: self.totalLabel)
        ])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 8
        stack.addArrangedSubview(cards)

        self.rankingLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        self.rankingLabel.maximumNumberOfLines = 12
        stack.addArrangedSubview(self.rankingLabel)
    }

    private func summaryCard(title: String, field: NSTextField) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        titleField.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 18, weight: .semibold)
        let box = NSStackView(views: [titleField, field])
        box.orientation = .vertical
        box.alignment = .leading
        box.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        box.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        return box
    }

    @objc private func controlsChanged() {
        let ranges = TrafficRange.allCases
        if self.rangeControl.selectedSegment >= 0, self.rangeControl.selectedSegment < ranges.count {
            self.selection.range = ranges[self.rangeControl.selectedSegment]
        }
        self.selection.chartMode = self.chartModeControl.selectedSegment == 1 ? .heatmap : .line
        let refreshModes = TrafficRefreshMode.allCases
        if self.refreshControl.indexOfSelectedItem >= 0, self.refreshControl.indexOfSelectedItem < refreshModes.count {
            self.selection.refreshMode = refreshModes[self.refreshControl.indexOfSelectedItem]
        }
        if self.networkControl.indexOfSelectedItem <= 0 {
            self.selection.networkFilter = nil
        } else {
            let kinds = NetworkKind.allCases
            let index = self.networkControl.indexOfSelectedItem - 1
            if index >= 0, index < kinds.count {
                self.selection.networkFilter = kinds[index]
            }
        }
        self.scheduleRefresh()
        self.reload()
    }

    @objc private func refreshClicked() {
        self.reload()
    }

    private func scheduleRefresh() {
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        guard let interval = self.selection.refreshMode.interval else { return }
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.reload()
        }
    }

    private func render() {
        guard let snapshot else { return }
        self.downloadLabel.stringValue = Units(bytes: Int64(snapshot.download)).getReadableMemory()
        self.uploadLabel.stringValue = Units(bytes: Int64(snapshot.upload)).getReadableMemory()
        self.totalLabel.stringValue = Units(bytes: Int64(snapshot.total)).getReadableMemory()

        let lines = snapshot.ranking.prefix(8).map { item in
            let total = Units(bytes: Int64(item.total)).getReadableMemory()
            return "\(item.identity.displayName)  ↓\(Units(bytes: Int64(item.download)).getReadableMemory())  ↑\(Units(bytes: Int64(item.upload)).getReadableMemory())  Σ\(total)"
        }
        self.rankingLabel.stringValue = lines.isEmpty ? localizedString("No application traffic yet") : lines.joined(separator: "\n")
    }

    private func rangeTitle(_ range: TrafficRange) -> String {
        switch range {
        case .tenMinutes: return "10m"
        case .oneHour: return "1h"
        case .today: return localizedString("Today")
        case .sevenDays: return "7d"
        case .thirtyDays: return "30d"
        case .currentMonth: return localizedString("Month")
        }
    }

    private func refreshTitle(_ mode: TrafficRefreshMode) -> String {
        switch mode {
        case .manual: return localizedString("Manual")
        case .fiveSeconds: return "5s"
        case .tenSeconds: return "10s"
        case .thirtySeconds: return "30s"
        case .oneMinute: return "1m"
        case .fiveMinutes: return "5m"
        }
    }
}

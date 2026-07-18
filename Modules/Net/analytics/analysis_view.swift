//
//  analysis_view.swift
//  Net
//

import Cocoa
import Kit

internal final class TrafficAnalysisView: NSView {
    private let engine: TrafficAnalyticsEngine
    private let repository: TrafficHistoryRepository
    private var selection = TrafficSelection()
    private var snapshot: TrafficAnalyticsSnapshot?
    private var refreshTimer: Timer?
    private var fullRanking: [ApplicationTrafficSummary] = []

    private let rangeControl = NSSegmentedControl()
    private let chartModeControl = NSSegmentedControl()
    private let refreshControl = NSPopUpButton()
    private let networkControl = NSPopUpButton()
    private let exportControl = NSPopUpButton()
    private let refreshButton = NSButton()
    private let downloadLabel = NSTextField(labelWithString: "—")
    private let uploadLabel = NSTextField(labelWithString: "—")
    private let totalLabel = NSTextField(labelWithString: "—")
    private let hoverLabel = NSTextField(labelWithString: "")
    private let lineChart = TrafficTimelineChartView()
    private let heatmap = TrafficHeatmapView()
    private let table = ApplicationTrafficTableController()
    private let detail = ApplicationDetailView()
    private let contentStack = FlippedStackView()

    init(engine: TrafficAnalyticsEngine, repository: TrafficHistoryRepository) {
        self.engine = engine
        self.repository = repository
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
        var query = self.selection.analyticsQuery()
        query = TrafficAnalyticsQuery(
            range: query.range,
            networkFilter: query.networkFilter,
            includeLocalNetwork: TrafficRuleStore().includeLocalNetwork,
            applicationSearch: query.applicationSearch,
            selectedInterval: query.selectedInterval,
            billingCycleDay: TrafficRuleStore().networkPlan().billingCycleDay,
            now: Date()
        )
        self.snapshot = self.engine.snapshot(for: query)
        self.render()
    }

    private func build() {
        self.contentStack.orientation = .vertical
        self.contentStack.alignment = .width
        self.contentStack.distribution = .fill
        self.contentStack.spacing = 12
        self.contentStack.translatesAutoresizingMaskIntoConstraints = false
        self.setContentCompressionResistancePriority(.required, for: .vertical)
        self.contentStack.setContentCompressionResistancePriority(.required, for: .vertical)
        self.heightAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        self.addSubview(self.contentStack)
        NSLayoutConstraint.activate([
            self.contentStack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.contentStack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.contentStack.topAnchor.constraint(equalTo: self.topAnchor),
            self.contentStack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
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

        self.exportControl.removeAllItems()
        self.exportControl.addItem(withTitle: localizedString("Export"))
        self.exportControl.addItem(withTitle: "CSV")
        self.exportControl.addItem(withTitle: "JSON")
        self.exportControl.target = self
        self.exportControl.action = #selector(self.exportChanged)

        self.refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        self.refreshButton.bezelStyle = .texturedRounded
        self.refreshButton.target = self
        self.refreshButton.action = #selector(self.refreshClicked)

        let controls = NSStackView(views: [
            self.rangeControl,
            self.chartModeControl,
            self.networkControl,
            self.refreshControl,
            self.exportControl,
            self.refreshButton
        ])
        controls.orientation = .horizontal
        controls.spacing = 8
        self.contentStack.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: self.contentStack.widthAnchor).isActive = true

        let cards = NSStackView(views: [
            self.summaryCard(title: localizedString("Download"), field: self.downloadLabel),
            self.summaryCard(title: localizedString("Upload"), field: self.uploadLabel),
            self.summaryCard(title: localizedString("Total"), field: self.totalLabel)
        ])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 8
        cards.identifier = NSUserInterfaceItemIdentifier("traffic-summary-cards")
        self.contentStack.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: self.contentStack.widthAnchor).isActive = true

        self.hoverLabel.textColor = .secondaryLabelColor
        self.hoverLabel.font = .systemFont(ofSize: 11)
        self.contentStack.addArrangedSubview(self.hoverLabel)

        self.lineChart.translatesAutoresizingMaskIntoConstraints = false
        self.lineChart.heightAnchor.constraint(equalToConstant: 180).isActive = true
        self.heatmap.translatesAutoresizingMaskIntoConstraints = false
        self.heatmap.heightAnchor.constraint(equalToConstant: 180).isActive = true
        self.heatmap.isHidden = true
        self.contentStack.addArrangedSubview(self.lineChart)
        self.contentStack.addArrangedSubview(self.heatmap)

        self.lineChart.onSelection = { [weak self] interval in
            guard let self else { return }
            self.selection.selectedInterval = interval
            self.reload()
        }
        self.lineChart.onHover = { [weak self] point in
            guard let self, let point else {
                self?.hoverLabel.stringValue = ""
                return
            }
            self.hoverLabel.stringValue = "↓\(Units(bytes: Int64(point.download)).getReadableMemory())  ↑\(Units(bytes: Int64(point.upload)).getReadableMemory())  Σ\(Units(bytes: Int64(point.total)).getReadableMemory())"
        }
        self.heatmap.onSelect = { [weak self] cell in
            guard let self else { return }
            if let cell {
                self.selection.selectedInterval = DateInterval(start: cell.start, end: cell.end)
            } else {
                self.selection.selectedInterval = nil
            }
            self.reload()
        }
        self.heatmap.onHover = { [weak self] cell in
            guard let self, let cell else {
                self?.hoverLabel.stringValue = ""
                return
            }
            self.hoverLabel.stringValue = "↓\(Units(bytes: Int64(cell.download)).getReadableMemory())  ↑\(Units(bytes: Int64(cell.upload)).getReadableMemory())  Σ\(Units(bytes: Int64(cell.total)).getReadableMemory())"
        }

        self.table.onSelect = { [weak self] summary in
            guard let self, let summary else { return }
            self.detail.show(summary)
            self.table.rootView().isHidden = true
        }
        self.detail.onClose = { [weak self] in
            self?.table.rootView().isHidden = false
        }
        self.contentStack.addArrangedSubview(self.table.rootView())
        self.contentStack.addArrangedSubview(self.detail)
        self.contentStack.addSubview(cards, positioned: .above, relativeTo: nil)
        self.contentStack.addSubview(controls, positioned: .above, relativeTo: nil)
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
            self.selection.selectedInterval = nil
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
        self.lineChart.isHidden = self.selection.chartMode != .line
        self.heatmap.isHidden = self.selection.chartMode != .heatmap
        self.scheduleRefresh()
        self.reload()
    }

    @objc private func exportChanged() {
        guard self.exportControl.indexOfSelectedItem > 0 else { return }
        let format: TrafficExportFormat = self.exportControl.indexOfSelectedItem == 1 ? .csv : .json
        self.exportControl.selectItem(at: 0)
        guard let snapshot else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format == .csv ? "network-traffic.csv" : "network-traffic.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try TrafficExporter.write(
                        snapshot: snapshot,
                        networkFilter: self.selection.networkFilter,
                        format: format,
                        to: url
                    )
                } catch {
                    DispatchQueue.main.async {
                        let alert = NSAlert()
                        alert.messageText = localizedString("Export failed")
                        alert.informativeText = error.localizedDescription
                        alert.runModal()
                    }
                }
            }
        }
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
        self.fullRanking = snapshot.ranking
        self.lineChart.points = TrafficChartGeometry.points(from: snapshot.buckets)
        self.heatmap.cells = TrafficChartGeometry.heatmapCells(from: snapshot.buckets)
        self.table.update(snapshot.ranking)
        self.lineChart.isHidden = self.selection.chartMode != .line
        self.heatmap.isHidden = self.selection.chartMode != .heatmap
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

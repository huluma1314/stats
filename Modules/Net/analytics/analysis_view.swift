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

internal final class LiveTrafficView: NSView {
    private let engine: TrafficAnalyticsEngine
    private var windowSelection: LiveTrafficWindow = .sixtySeconds
    private var applicationID: String? = nil
    private var applicationIDs: [String?] = [nil]
    private var refreshTimer: Timer? = nil

    private let focusControl = NSPopUpButton()
    private let windowControl = NSSegmentedControl()
    private let downloadLabel = NSTextField(labelWithString: "0 KB/s")
    private let uploadLabel = NSTextField(labelWithString: "0 KB/s")
    private let totalLabel = NSTextField(labelWithString: "0 KB/s")
    private let chart = LiveTrafficChartView()
    private let apps = LiveTrafficAppsView()

    init(engine: TrafficAnalyticsEngine) {
        self.engine = engine
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.build()
        self.reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.refreshTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        guard self.window != nil else { return }
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.reload()
        }
        self.reload()
    }

    func reload(now: Date = Date()) {
        let snapshot = self.engine.liveSnapshot(
            window: self.windowSelection,
            applicationID: self.applicationID,
            now: now
        )
        self.downloadLabel.stringValue = self.rate(snapshot.downloadBytesPerSecond)
        self.uploadLabel.stringValue = self.rate(snapshot.uploadBytesPerSecond)
        self.totalLabel.stringValue = self.rate(snapshot.totalBytesPerSecond)
        self.chart.points = snapshot.points
        self.apps.items = snapshot.activeApplications
        self.updateFocusControl(snapshot.applications)
    }

    private func build() {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)
        self.heightAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        self.focusControl.addItem(withTitle: localizedString("All applications"))
        self.focusControl.target = self
        self.focusControl.action = #selector(self.focusChanged)

        self.windowControl.segmentCount = LiveTrafficWindow.allCases.count
        for (index, item) in LiveTrafficWindow.allCases.enumerated() {
            self.windowControl.setLabel(self.windowTitle(item), forSegment: index)
        }
        self.windowControl.selectedSegment = 0
        self.windowControl.target = self
        self.windowControl.action = #selector(self.windowChanged)

        let controls = NSStackView(views: [self.focusControl, self.windowControl])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .fill
        controls.spacing = 8
        stack.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let cards = NSStackView(views: [
            self.rateCard(title: localizedString("Download"), value: self.downloadLabel, color: .systemBlue),
            self.rateCard(title: localizedString("Upload"), value: self.uploadLabel, color: .systemRed),
            self.rateCard(title: localizedString("Total"), value: self.totalLabel, color: .labelColor)
        ])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 8
        stack.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let chartTitle = NSTextField(labelWithString: localizedString("Live application traffic"))
        chartTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        chartTitle.alignment = .left
        stack.addArrangedSubview(chartTitle)
        chartTitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.chart.translatesAutoresizingMaskIntoConstraints = false
        self.chart.heightAnchor.constraint(equalToConstant: 190).isActive = true
        stack.addArrangedSubview(self.chart)
        self.chart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let activeTitle = NSTextField(labelWithString: localizedString("Active processes"))
        activeTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        activeTitle.alignment = .left
        stack.addArrangedSubview(activeTitle)
        activeTitle.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        self.apps.translatesAutoresizingMaskIntoConstraints = false
        self.apps.heightAnchor.constraint(equalToConstant: 150).isActive = true
        stack.addArrangedSubview(self.apps)
        self.apps.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addSubview(cards, positioned: .above, relativeTo: nil)
        stack.addSubview(controls, positioned: .above, relativeTo: nil)
        stack.addSubview(chartTitle, positioned: .above, relativeTo: nil)
        stack.addSubview(activeTitle, positioned: .above, relativeTo: nil)
    }

    private func rateCard(title: String, value: NSTextField, color: NSColor) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.textColor = .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 11)
        value.font = .systemFont(ofSize: 18, weight: .semibold)
        value.textColor = color
        let stack = NSStackView(views: [titleField, value])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 11, bottom: 9, right: 11)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 8
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        return stack
    }

    private func updateFocusControl(_ applications: [ApplicationTrafficSummary]) {
        let nextIDs: [String?] = [nil] + applications.map(\.identity.id)
        guard nextIDs != self.applicationIDs else { return }
        let selectedID = self.applicationID
        self.applicationIDs = nextIDs
        self.focusControl.removeAllItems()
        self.focusControl.addItem(withTitle: localizedString("All applications"))
        applications.forEach { self.focusControl.addItem(withTitle: $0.identity.displayName) }
        if let selectedID, let index = self.applicationIDs.firstIndex(where: { $0 == selectedID }) {
            self.focusControl.selectItem(at: index)
        } else {
            self.applicationID = nil
            self.focusControl.selectItem(at: 0)
        }
    }

    @objc private func focusChanged() {
        let index = self.focusControl.indexOfSelectedItem
        self.applicationID = self.applicationIDs.indices.contains(index) ? self.applicationIDs[index] : nil
        self.reload()
    }

    @objc private func windowChanged() {
        let windows = LiveTrafficWindow.allCases
        guard windows.indices.contains(self.windowControl.selectedSegment) else { return }
        self.windowSelection = windows[self.windowControl.selectedSegment]
        self.reload()
    }

    private func rate(_ bytes: UInt64) -> String {
        Units(bytes: Int64(bytes)).getReadableMemory() + "/s"
    }

    private func windowTitle(_ window: LiveTrafficWindow) -> String {
        switch window {
        case .sixtySeconds: return "60s"
        case .fiveMinutes: return "5m"
        case .fifteenMinutes: return "15m"
        }
    }
}

internal final class LiveTrafficChartView: NSView {
    var points: [LiveTrafficPoint] = [] {
        didSet { self.needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let plot = self.bounds.insetBy(dx: 10, dy: 14)
        let baseline = plot.midY
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let axis = NSBezierPath()
        axis.move(to: CGPoint(x: plot.minX, y: baseline))
        axis.line(to: CGPoint(x: plot.maxX, y: baseline))
        axis.stroke()
        guard !self.points.isEmpty else { return }

        let maximum = max(self.points.map { max($0.download, $0.upload) }.max() ?? 1, 1)
        let download = NSBezierPath()
        let upload = NSBezierPath()
        for (index, point) in self.points.enumerated() {
            let x = plot.minX + plot.width * CGFloat(index) / CGFloat(max(self.points.count - 1, 1))
            let downloadY = baseline + (plot.height / 2) * CGFloat(point.download) / CGFloat(maximum)
            let uploadY = baseline - (plot.height / 2) * CGFloat(point.upload) / CGFloat(maximum)
            if index == 0 {
                download.move(to: CGPoint(x: x, y: downloadY))
                upload.move(to: CGPoint(x: x, y: uploadY))
            } else {
                download.line(to: CGPoint(x: x, y: downloadY))
                upload.line(to: CGPoint(x: x, y: uploadY))
            }
        }
        NSColor.systemBlue.setStroke()
        download.lineWidth = 1.5
        download.stroke()
        NSColor.systemRed.setStroke()
        upload.lineWidth = 1.5
        upload.stroke()
    }
}

internal final class LiveTrafficAppsView: NSView {
    var items: [ApplicationTrafficSummary] = [] {
        didSet { self.needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !self.items.isEmpty else {
            (localizedString("No active processes") as NSString).draw(
                at: CGPoint(x: 8, y: 8),
                withAttributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 11)]
            )
            return
        }

        let rowHeight: CGFloat = 32
        for (index, item) in self.items.prefix(4).enumerated() {
            let rect = CGRect(x: 0, y: CGFloat(index) * (rowHeight + 4), width: self.bounds.width, height: rowHeight)
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            (item.identity.displayName as NSString).draw(
                at: CGPoint(x: 10, y: rect.minY + 8),
                withAttributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11, weight: .medium)]
            )
            let value = "↓ \(self.rate(item.download))   ↑ \(self.rate(item.upload))" as NSString
            let size = value.size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)])
            value.draw(
                at: CGPoint(x: rect.maxX - size.width - 10, y: rect.minY + 8),
                withAttributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)]
            )
        }
    }

    private func rate(_ bytes: UInt64) -> String {
        Units(bytes: Int64(bytes)).getReadableMemory() + "/s"
    }
}

//
//  analysis_view.swift
//  Net
//

import Cocoa
import Kit

internal final class TrafficAnalysisView: NSView {
    private let engine: TrafficAnalyticsEngine
    private let repository: TrafficHistoryRepository
    private let networkRegistry: NetworkRegistry
    private let ruleStore: TrafficRuleStore
    private let selectionStore: TrafficSelectionStore
    private var selection: TrafficSelection
    private var snapshot: TrafficAnalyticsSnapshot?
    private var refreshTimer: Timer?
    private var fullRanking: [ApplicationTrafficSummary] = []

    private let rangeControl = NSSegmentedControl()
    private let chartModeControl = NSSegmentedControl()
    private let refreshControl = NSPopUpButton()
    private let networkControl = NSPopUpButton()
    private let exportControl = NSPopUpButton()
    private let moreControl = NSPopUpButton()
    private let refreshButton = NSButton()
    private let alertButton = NSButton(title: localizedString("Alerts"), target: nil, action: nil)
    private let dateButton = NSButton()
    private let datePopover = NSPopover()
    private let downloadLabel = NSTextField(labelWithString: "—")
    private let uploadLabel = NSTextField(labelWithString: "—")
    private let totalLabel = NSTextField(labelWithString: "—")
    private let hoverLabel = NSTextField(labelWithString: "")
    private let lineChart = TrafficTimelineChartView()
    private let heatmap = TrafficHeatmapView()
    private let table: ApplicationTrafficTableController
    private let detail: ApplicationDetailView
    private let contentStack = FlippedStackView()
    private let secondaryOptionsRow = NSStackView()
    private var appearanceCards: [NSView] = []

    init(
        engine: TrafficAnalyticsEngine,
        repository: TrafficHistoryRepository,
        networkRegistry: NetworkRegistry = NetworkRegistry(),
        ruleStore: TrafficRuleStore = TrafficRuleStore(),
        selectionStore: TrafficSelectionStore = TrafficSelectionStore(),
        iconResolver: ApplicationIconResolving = ApplicationIconResolver()
    ) {
        self.engine = engine
        self.repository = repository
        self.networkRegistry = networkRegistry
        self.ruleStore = ruleStore
        self.selectionStore = selectionStore
        var restoredSelection = selectionStore.load()
        if !selectionStore.hasSavedSelection {
            restoredSelection.includeLocalNetwork = ruleStore.includeLocalNetwork
        }
        self.selection = restoredSelection
        self.table = ApplicationTrafficTableController(iconResolver: iconResolver)
        self.detail = ApplicationDetailView(ruleStore: ruleStore, iconResolver: iconResolver)
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
            networkID: query.networkID,
            includeLocalNetwork: self.selection.includeLocalNetwork,
            applicationSearch: query.applicationSearch,
            selectedInterval: query.selectedInterval,
            billingCycleDay: query.networkID.map { self.ruleStore.networkPlan(for: $0).billingCycleDay }
                ?? self.ruleStore.networkPlan().billingCycleDay,
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
        self.rangeControl.identifier = NSUserInterfaceItemIdentifier("traffic-range")
        self.rangeControl.target = self
        self.rangeControl.action = #selector(self.controlsChanged)

        self.chartModeControl.segmentCount = 2
        self.chartModeControl.setLabel(localizedString("Line"), forSegment: 0)
        self.chartModeControl.setLabel(localizedString("Heatmap"), forSegment: 1)
        self.chartModeControl.selectedSegment = 0
        self.chartModeControl.identifier = NSUserInterfaceItemIdentifier("traffic-chart-mode")
        self.chartModeControl.target = self
        self.chartModeControl.action = #selector(self.controlsChanged)

        self.refreshControl.removeAllItems()
        for mode in TrafficRefreshMode.allCases {
            self.refreshControl.addItem(withTitle: self.refreshTitle(mode))
        }
        self.refreshControl.selectItem(at: 2)
        self.refreshControl.identifier = NSUserInterfaceItemIdentifier("traffic-refresh-mode")
        self.refreshControl.target = self
        self.refreshControl.action = #selector(self.controlsChanged)

        self.reloadNetworkMenu()
        self.networkControl.target = self
        self.networkControl.identifier = NSUserInterfaceItemIdentifier("traffic-network")
        self.networkControl.action = #selector(self.controlsChanged)

        self.exportControl.removeAllItems()
        self.exportControl.addItem(withTitle: localizedString("Export"))
        self.exportControl.addItem(withTitle: "CSV")
        self.exportControl.addItem(withTitle: "JSON")
        self.exportControl.target = self
        self.exportControl.identifier = NSUserInterfaceItemIdentifier("traffic-export")
        self.exportControl.action = #selector(self.exportChanged)

        self.moreControl.addItem(withTitle: localizedString("More"))
        self.moreControl.addItem(withTitle: localizedString("Full timeline"))
        self.moreControl.addItem(withTitle: localizedString("Show download"))
        self.moreControl.addItem(withTitle: localizedString("Show upload"))
        self.moreControl.addItem(withTitle: localizedString("Group by process"))
        self.moreControl.addItem(withTitle: localizedString("Show proxy labels"))
        self.moreControl.addItem(withTitle: localizedString("Show alert markers"))
        self.moreControl.addItem(withTitle: localizedString("Include local network"))
        self.moreControl.addItem(withTitle: localizedString("Line"))
        self.moreControl.lastItem?.representedObject = "chart-line"
        self.moreControl.addItem(withTitle: localizedString("Heatmap"))
        self.moreControl.lastItem?.representedObject = "chart-heatmap"
        for mode in TrafficRefreshMode.allCases {
            self.moreControl.addItem(withTitle: "\(localizedString("Refresh")): \(self.refreshTitle(mode))")
            self.moreControl.lastItem?.representedObject = "refresh-\(mode.rawValue)"
        }
        self.moreControl.identifier = NSUserInterfaceItemIdentifier("traffic-more-options")
        self.moreControl.target = self
        self.moreControl.action = #selector(self.moreChanged)
        self.updateMoreMenuStates()

        self.dateButton.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: localizedString("Custom time range"))
        self.dateButton.identifier = NSUserInterfaceItemIdentifier("traffic-custom-range")
        self.dateButton.bezelStyle = .texturedRounded
        self.dateButton.toolTip = localizedString("Custom time range")
        self.dateButton.target = self
        self.dateButton.action = #selector(self.showCustomRange)

        self.alertButton.identifier = NSUserInterfaceItemIdentifier("traffic-alert-list")
        self.alertButton.bezelStyle = .texturedRounded
        self.alertButton.target = self
        self.alertButton.action = #selector(self.showAlerts)

        self.refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: localizedString("Refresh"))
        self.refreshButton.bezelStyle = .texturedRounded
        self.refreshButton.identifier = NSUserInterfaceItemIdentifier("traffic-refresh")
        self.refreshButton.toolTip = localizedString("Refresh")
        self.refreshButton.target = self
        self.refreshButton.action = #selector(self.refreshClicked)

        let rangeRow = NSStackView(views: [self.rangeControl, self.dateButton])
        rangeRow.orientation = .horizontal
        rangeRow.alignment = .centerY
        rangeRow.spacing = 8

        let primaryOptionsRow = NSStackView(views: [
            self.networkControl,
            self.exportControl,
            self.alertButton,
            self.refreshButton
        ])
        primaryOptionsRow.orientation = .horizontal
        primaryOptionsRow.alignment = .centerY
        primaryOptionsRow.spacing = 8

        self.secondaryOptionsRow.setViews([
            self.chartModeControl,
            self.refreshControl,
            self.moreControl
        ], in: .leading)
        self.secondaryOptionsRow.orientation = .horizontal
        self.secondaryOptionsRow.alignment = .centerY
        self.secondaryOptionsRow.spacing = 8

        let controls = FlippedStackView(views: [rangeRow, primaryOptionsRow, self.secondaryOptionsRow])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 7
        controls.identifier = NSUserInterfaceItemIdentifier("history-toolbar")
        self.contentStack.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: self.contentStack.widthAnchor).isActive = true

        let cards = NSStackView(views: [
            self.summaryCard(title: localizedString("Download"), field: self.downloadLabel, identifier: "history-download-card"),
            self.summaryCard(title: localizedString("Upload"), field: self.uploadLabel, identifier: "history-upload-card"),
            self.summaryCard(title: localizedString("Total"), field: self.totalLabel, identifier: "history-total-card")
        ])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 8
        cards.identifier = NSUserInterfaceItemIdentifier("traffic-summary-cards")
        self.contentStack.addArrangedSubview(cards)
        cards.widthAnchor.constraint(equalTo: self.contentStack.widthAnchor).isActive = true

        self.hoverLabel.textColor = .secondaryLabelColor
        self.hoverLabel.font = .systemFont(ofSize: 11)

        self.lineChart.translatesAutoresizingMaskIntoConstraints = false
        self.lineChart.heightAnchor.constraint(equalToConstant: 180).isActive = true
        self.heatmap.translatesAutoresizingMaskIntoConstraints = false
        self.heatmap.heightAnchor.constraint(equalToConstant: 180).isActive = true
        self.heatmap.isHidden = true
        let timelineTitle = NSTextField(labelWithString: localizedString("Traffic timeline"))
        timelineTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let timelineHelp = NSTextField(labelWithString: localizedString("Drag to select an interval. Alert markers show detected anomalies."))
        timelineHelp.font = .systemFont(ofSize: 11)
        timelineHelp.textColor = .secondaryLabelColor
        let timelineStack = FlippedStackView(views: [timelineTitle, timelineHelp, self.hoverLabel, self.lineChart, self.heatmap])
        timelineStack.orientation = .vertical
        timelineStack.alignment = .width
        timelineStack.spacing = 6
        let timelineCard = self.card(containing: timelineStack, identifier: "history-timeline-card")
        self.contentStack.addArrangedSubview(timelineCard)
        timelineCard.widthAnchor.constraint(equalTo: self.contentStack.widthAnchor).isActive = true

        self.lineChart.onSelection = { [weak self] interval in
            guard let self else { return }
            self.selection.selectedInterval = interval
            self.persistSelection()
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
            self.persistSelection()
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
        self.table.onStateChange = { [weak self] search, sortKey, ascending in
            guard let self else { return }
            self.selection.search = search
            self.selection.sortKey = sortKey
            self.selection.sortAscending = ascending
            self.persistSelection()
        }
        self.detail.onClose = { [weak self] in
            self?.table.rootView().isHidden = false
        }
        let rankingTitle = NSTextField(labelWithString: localizedString("Application ranking"))
        rankingTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let rankingHelp = NSTextField(labelWithString: localizedString("Select an interval in the timeline to filter this ranking."))
        rankingHelp.font = .systemFont(ofSize: 11)
        rankingHelp.textColor = .secondaryLabelColor
        let rankingStack = FlippedStackView(views: [rankingTitle, rankingHelp, self.table.rootView(), self.detail])
        rankingStack.orientation = .vertical
        rankingStack.alignment = .width
        rankingStack.spacing = 6
        let rankingCard = self.card(containing: rankingStack, identifier: "history-ranking-card")
        self.contentStack.addArrangedSubview(rankingCard)
        rankingCard.widthAnchor.constraint(equalTo: self.contentStack.widthAnchor).isActive = true
        self.detail.widthAnchor.constraint(equalTo: rankingStack.widthAnchor).isActive = true
        self.contentStack.addSubview(cards, positioned: .above, relativeTo: nil)
        self.contentStack.addSubview(controls, positioned: .above, relativeTo: nil)
        self.synchronizeControls()
    }

    override func layout() {
        super.layout()
        let compact = self.bounds.width < 900
        if self.chartModeControl.isHidden != compact {
            self.chartModeControl.isHidden = compact
        }
        if self.refreshControl.isHidden != compact {
            self.refreshControl.isHidden = compact
        }
        if self.moreControl.isHidden {
            self.moreControl.isHidden = false
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.updateAppearanceColors()
    }

    private func summaryCard(title: String, field: NSTextField, identifier: String) -> NSView {
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
        box.identifier = NSUserInterfaceItemIdentifier(identifier)
        box.heightAnchor.constraint(equalToConstant: 72).isActive = true
        self.appearanceCards.append(box)
        self.updateAppearanceColors()
        return box
    }

    private func card(containing content: NSView, identifier: String) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.identifier = NSUserInterfaceItemIdentifier(identifier)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        self.appearanceCards.append(card)
        self.updateAppearanceColors()
        return card
    }

    private func updateAppearanceColors() {
        self.effectiveAppearance.performAsCurrentDrawingAppearance {
            let backgroundColor = NSColor.controlBackgroundColor.cgColor
            self.appearanceCards.forEach { $0.layer?.backgroundColor = backgroundColor }
        }
    }

    private func reloadNetworkMenu() {
        self.networkControl.removeAllItems()
        self.networkControl.addItem(withTitle: localizedString("All networks"))
        for registered in self.networkRegistry.all() {
            self.networkControl.addItem(withTitle: self.networkRegistry.displayName(for: registered.identity.id))
            self.networkControl.lastItem?.representedObject = registered.identity.id
            self.networkControl.lastItem?.toolTip = registered.identity.id
        }
        if let networkID = self.selection.networkID,
           let index = self.networkControl.itemArray.firstIndex(where: { $0.representedObject as? String == networkID }) {
            self.networkControl.selectItem(at: index)
        } else {
            self.networkControl.selectItem(at: 0)
        }
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
            self.selection.networkID = nil
            self.selection.networkFilter = nil
        } else if let id = self.networkControl.selectedItem?.representedObject as? String {
            self.selection.networkID = id
            self.selection.networkFilter = nil
        }
        self.lineChart.isHidden = self.selection.chartMode != .line
        self.heatmap.isHidden = self.selection.chartMode != .heatmap
        self.scheduleRefresh()
        self.persistSelection()
        self.updateMoreMenuStates()
        self.reload()
    }

    @objc private func exportChanged() {
        guard self.exportControl.indexOfSelectedItem > 0 else { return }
        let format: TrafficExportFormat = self.exportControl.indexOfSelectedItem == 1 ? .csv : .json
        self.exportControl.selectItem(at: 0)
        guard let snapshot else { return }
        // Capture every export input while still on the main thread. The save panel may
        // stay open while the user changes the visible selection in another window.
        let networkFilter = self.selection.networkFilter
        let context = self.exportContext()

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = format == .csv ? "network-traffic.csv" : "network-traffic.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try TrafficExporter.write(
                        snapshot: snapshot,
                        networkFilter: networkFilter,
                        context: context,
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

    @objc private func moreChanged() {
        let selected = self.moreControl.indexOfSelectedItem
        let representedObject = self.moreControl.selectedItem?.representedObject as? String
        self.moreControl.selectItem(at: 0)
        if representedObject == "chart-line" || representedObject == "chart-heatmap" {
            self.selection.chartMode = representedObject == "chart-heatmap" ? .heatmap : .line
            self.chartModeControl.selectedSegment = self.selection.chartMode == .heatmap ? 1 : 0
            self.lineChart.isHidden = self.selection.chartMode != .line
            self.heatmap.isHidden = self.selection.chartMode != .heatmap
            self.persistSelection()
            self.updateMoreMenuStates()
            self.reload()
            return
        }
        if let representedObject, representedObject.hasPrefix("refresh-"),
           let mode = TrafficRefreshMode(rawValue: String(representedObject.dropFirst("refresh-".count))) {
            self.selection.refreshMode = mode
            self.refreshControl.selectItem(at: TrafficRefreshMode.allCases.firstIndex(of: mode) ?? 0)
            self.scheduleRefresh()
            self.persistSelection()
            self.updateMoreMenuStates()
            self.reload()
            return
        }
        switch selected {
        case 1:
            self.selection.selectedInterval = nil
            if let index = TrafficRange.allCases.firstIndex(of: self.selection.range) {
                self.rangeControl.selectedSegment = index
            }
        case 2: self.selection.showDownload.toggle()
        case 3: self.selection.showUpload.toggle()
        case 4: self.selection.groupByProcess.toggle()
        case 5: self.selection.showProxyLabels.toggle()
        case 6: self.selection.showAlertMarkers.toggle()
        case 7:
            self.selection.includeLocalNetwork.toggle()
            self.ruleStore.includeLocalNetwork = self.selection.includeLocalNetwork
        default: return
        }
        self.persistSelection()
        self.updateMoreMenuStates()
        self.reload()
    }

    @objc private func showCustomRange() {
        let now = Date()
        let end = self.selection.selectedInterval?.end ?? now
        let start = self.selection.selectedInterval?.start ?? end.addingTimeInterval(-3_600)
        let view = TrafficCustomRangePopoverView(
            start: start,
            end: end,
            onCancel: { [weak self] in self?.datePopover.close() },
            onApply: { [weak self] start, end in
                guard let self,
                      let interval = TrafficCustomRange.interval(start: start, end: end) else { return }
                self.selection.selectedInterval = interval
                self.selection.range = TrafficCustomRange.range(for: interval.duration)
                self.rangeControl.selectedSegment = -1
                self.datePopover.close()
                self.persistSelection()
                self.reload()
            }
        )
        let controller = NSViewController()
        controller.view = view
        self.datePopover.contentViewController = controller
        self.datePopover.contentSize = NSSize(width: 330, height: 190)
        self.datePopover.behavior = .transient
        self.datePopover.show(relativeTo: self.dateButton.bounds, of: self.dateButton, preferredEdge: .maxY)
    }

    @objc private func showAlerts() {
        let events = self.repository.trafficAlerts()
        let alert = NSAlert()
        alert.messageText = localizedString("Traffic alerts")
        if events.isEmpty {
            alert.informativeText = localizedString("No traffic alerts")
        } else {
            alert.informativeText = events.prefix(20).map { event in
                let measured = event.measuredValue.map { " · \(localizedString("Measured")): \($0)" } ?? ""
                let threshold = event.thresholdValue.map { " · \(localizedString("Threshold")): \($0)" } ?? ""
                return "[\(event.severity.rawValue.uppercased())] \(event.message)\(measured)\(threshold)"
            }.joined(separator: "\n")
            alert.addButton(withTitle: localizedString("Clear alerts"))
        }
        alert.addButton(withTitle: localizedString("Close"))
        if !events.isEmpty, alert.runModal() == .alertFirstButtonReturn {
            self.repository.runtimeAlertStore.clear()
            self.reload()
        } else if events.isEmpty {
            alert.runModal()
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
        self.lineChart.alerts = snapshot.alerts
        self.lineChart.showDownload = self.selection.showDownload
        self.lineChart.showUpload = self.selection.showUpload
        self.lineChart.showAlertMarkers = self.selection.showAlertMarkers
        self.heatmap.cells = TrafficChartGeometry.heatmapCells(from: snapshot.buckets)
        self.table.update(
            snapshot.ranking,
            search: self.selection.search,
            sortKey: self.selection.sortKey,
            ascending: self.selection.sortAscending,
            groupByProcess: self.selection.groupByProcess,
            showProxyLabels: self.selection.showProxyLabels
        )
        self.lineChart.isHidden = self.selection.chartMode != .line
        self.heatmap.isHidden = self.selection.chartMode != .heatmap
    }

    private func synchronizeControls() {
        if let index = TrafficRange.allCases.firstIndex(of: self.selection.range) {
            self.rangeControl.selectedSegment = self.selection.selectedInterval == nil ? index : -1
        }
        self.chartModeControl.selectedSegment = self.selection.chartMode == .heatmap ? 1 : 0
        self.refreshControl.selectItem(at: TrafficRefreshMode.allCases.firstIndex(of: self.selection.refreshMode) ?? 2)
        self.reloadNetworkMenu()
        self.updateMoreMenuStates()
    }

    private func updateMoreMenuStates() {
        let states = [
            2: self.selection.showDownload,
            3: self.selection.showUpload,
            4: self.selection.groupByProcess,
            5: self.selection.showProxyLabels,
            6: self.selection.showAlertMarkers,
            7: self.selection.includeLocalNetwork
        ]
        for (index, enabled) in states where self.moreControl.itemArray.indices.contains(index) {
            self.moreControl.item(at: index)?.state = enabled ? .on : .off
        }
        for item in self.moreControl.itemArray {
            guard let value = item.representedObject as? String else { continue }
            if value == "chart-line" {
                item.state = self.selection.chartMode == .line ? .on : .off
            } else if value == "chart-heatmap" {
                item.state = self.selection.chartMode == .heatmap ? .on : .off
            } else if value.hasPrefix("refresh-") {
                item.state = value == "refresh-\(self.selection.refreshMode.rawValue)" ? .on : .off
            }
        }
    }

    private func persistSelection() {
        self.selectionStore.save(self.selection)
    }

    private func exportContext() -> TrafficExportContext {
        let registered = self.selection.networkID.flatMap { id in
            self.networkRegistry.all().first { $0.identity.id == id }
        }
        return TrafficExportContext(
            networkID: self.selection.networkID,
            networkAlias: registered.map { self.networkRegistry.displayName(for: $0.identity.id) },
            network: registered?.identity,
            chartInterval: self.selection.selectedInterval,
            groupByProcess: self.selection.groupByProcess
        )
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
    private var applicationID: String?
    private var applicationIDs: [String?] = [nil]
    private var refreshTimer: Timer?
    private var appearanceCards: [NSView] = []

    private let focusControl = NSPopUpButton()
    private let windowControl = NSSegmentedControl()
    private let downloadLabel = NSTextField(labelWithString: "0 KB/s")
    private let uploadLabel = NSTextField(labelWithString: "0 KB/s")
    private let totalLabel = NSTextField(labelWithString: "0 KB/s")
    private let chart = LiveTrafficChartView()
    private let apps: LiveTrafficAppsView

    init(engine: TrafficAnalyticsEngine, iconResolver: ApplicationIconResolving = ApplicationIconResolver()) {
        self.engine = engine
        self.apps = LiveTrafficAppsView(iconResolver: iconResolver)
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.build()
        self.reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { self.refreshTimer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.refreshTimer?.invalidate()
        self.refreshTimer = nil
        guard self.window != nil else { return }
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.reload() }
        self.reload()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        self.updateCardAppearance()
    }

    func reload(now: Date = Date()) {
        let snapshot = self.engine.liveSnapshot(window: self.windowSelection, applicationID: self.applicationID, now: now)
        self.downloadLabel.stringValue = self.rate(snapshot.downloadBytesPerSecond)
        self.uploadLabel.stringValue = self.rate(snapshot.uploadBytesPerSecond)
        self.totalLabel.stringValue = self.rate(snapshot.totalBytesPerSecond)
        self.chart.points = snapshot.points
        self.apps.items = LiveTrafficProcessRow.flatten(snapshot.activeApplications)
        self.updateFocusControl(snapshot.applications)
    }

    private func build() {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = stack
        self.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: self.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: self.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 560)
        ])

        self.focusControl.addItem(withTitle: localizedString("All applications"))
        self.focusControl.identifier = NSUserInterfaceItemIdentifier("live-focus")
        self.focusControl.target = self
        self.focusControl.action = #selector(self.focusChanged)
        self.focusControl.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let focusLabel = NSTextField(labelWithString: localizedString("Application focus"))
        focusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let controls = NSStackView(views: [focusLabel, self.focusControl])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        stack.addArrangedSubview(controls)
        controls.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let rateContent = NSStackView(views: [
            self.rateMetric(title: localizedString("Download"), value: self.downloadLabel, color: .systemBlue),
            self.rateMetric(title: localizedString("Upload"), value: self.uploadLabel, color: .systemOrange),
            self.rateMetric(title: localizedString("Total"), value: self.totalLabel, color: .labelColor)
        ])
        rateContent.orientation = .horizontal
        rateContent.distribution = .fillEqually
        rateContent.spacing = 8
        let rateCard = self.card(containing: rateContent, identifier: "live-rate-card")
        rateCard.heightAnchor.constraint(equalToConstant: 92).isActive = true
        stack.addArrangedSubview(rateCard)

        self.windowControl.segmentCount = LiveTrafficWindow.allCases.count
        for (index, item) in LiveTrafficWindow.allCases.enumerated() { self.windowControl.setLabel(self.windowTitle(item), forSegment: index) }
        self.windowControl.selectedSegment = 0
        self.windowControl.target = self
        self.windowControl.action = #selector(self.windowChanged)

        let chartTitle = NSTextField(labelWithString: localizedString("Live application traffic"))
        chartTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let chartHeader = NSStackView(views: [chartTitle, NSView(), self.windowControl])
        chartHeader.orientation = .horizontal
        chartHeader.alignment = .centerY
        self.chart.translatesAutoresizingMaskIntoConstraints = false
        let chartStack = FlippedStackView(views: [chartHeader, self.chart])
        chartStack.orientation = .vertical
        chartStack.alignment = .width
        chartStack.spacing = 8
        let chartCard = self.card(containing: chartStack, identifier: "live-chart-card")
        chartCard.heightAnchor.constraint(equalToConstant: 218).isActive = true
        stack.addArrangedSubview(chartCard)

        let activeTitle = NSTextField(labelWithString: localizedString("Active processes"))
        activeTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let activeHelp = NSTextField(labelWithString: localizedString("Sorted by current total rate"))
        activeHelp.font = .systemFont(ofSize: 11)
        activeHelp.textColor = .secondaryLabelColor
        let activeHeader = NSStackView(views: [activeTitle, NSView(), activeHelp])
        activeHeader.orientation = .horizontal
        activeHeader.alignment = .centerY
        self.apps.translatesAutoresizingMaskIntoConstraints = false
        let activeStack = FlippedStackView(views: [activeHeader, self.apps])
        activeStack.orientation = .vertical
        activeStack.alignment = .width
        activeStack.spacing = 7
        let activeCard = self.card(containing: activeStack, identifier: "live-active-processes")
        activeCard.heightAnchor.constraint(equalToConstant: 174).isActive = true
        stack.addArrangedSubview(activeCard)

        [rateCard, chartCard, activeCard].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        self.updateCardAppearance()
    }

    private func card(containing content: NSView, identifier: String) -> NSView {
        let card = NSView()
        card.identifier = NSUserInterfaceItemIdentifier(identifier)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
        ])
        self.appearanceCards.append(card)
        return card
    }

    private func rateMetric(title: String, value: NSTextField, color: NSColor) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.textColor = .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 11)
        value.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        value.textColor = color
        let metric = NSStackView(views: [titleField, value])
        metric.orientation = .vertical
        metric.alignment = .leading
        metric.spacing = 5
        return metric
    }

    private func updateCardAppearance() {
        self.appearanceCards.forEach { $0.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor }
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

    private func rate(_ bytes: UInt64) -> String { Units(bytes: Int64(bytes)).getReadableMemory() + "/s" }

    private func windowTitle(_ window: LiveTrafficWindow) -> String {
        switch window { case .sixtySeconds: return "60s"; case .fiveMinutes: return "5m"; case .fifteenMinutes: return "15m" }
    }
}

internal final class TrafficCustomRangePopoverView: NSView {
    private let startPicker = NSDatePicker()
    private let endPicker = NSDatePicker()
    private let onCancel: () -> Void
    private let onApply: (Date, Date) -> Void

    init(start: Date, end: Date, onCancel: @escaping () -> Void, onApply: @escaping (Date, Date) -> Void) {
        self.onCancel = onCancel
        self.onApply = onApply
        super.init(frame: NSRect(x: 0, y: 0, width: 330, height: 190))
        self.translatesAutoresizingMaskIntoConstraints = false
        self.startPicker.dateValue = start
        self.endPicker.dateValue = end
        self.build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func build() {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stack)
        NSLayoutConstraint.activate([
            self.widthAnchor.constraint(equalToConstant: 330),
            self.heightAnchor.constraint(equalToConstant: 190),
            stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            stack.topAnchor.constraint(equalTo: self.topAnchor),
            stack.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: localizedString("Custom time range"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(title)

        [self.startPicker, self.endPicker].forEach {
            $0.datePickerStyle = .textFieldAndStepper
            $0.datePickerElements = [.yearMonthDay, .hourMinute]
        }
        stack.addArrangedSubview(self.pickerRow(title: localizedString("Start"), picker: self.startPicker))
        stack.addArrangedSubview(self.pickerRow(title: localizedString("End"), picker: self.endPicker))

        let quick = NSStackView()
        quick.orientation = .horizontal
        quick.distribution = .fillEqually
        quick.spacing = 6
        [(1, localizedString("Last hour")), (3, localizedString("Last 3 hours")), (24, localizedString("Last 24 hours"))].forEach { hours, title in
            let button = NSButton(title: title, target: self, action: #selector(self.quickRange(_:)))
            button.tag = hours
            button.bezelStyle = .rounded
            quick.addArrangedSubview(button)
        }
        stack.addArrangedSubview(quick)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.distribution = .equalSpacing
        let cancel = NSButton(title: localizedString("Cancel"), target: self, action: #selector(self.cancel))
        let apply = NSButton(title: localizedString("Apply"), target: self, action: #selector(self.apply))
        apply.keyEquivalent = "\r"
        actions.addArrangedSubview(cancel)
        actions.addArrangedSubview(apply)
        stack.addArrangedSubview(actions)
    }

    private func pickerRow(title: String, picker: NSDatePicker) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let row = NSStackView(views: [label, picker])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func quickRange(_ sender: NSButton) {
        let end = Date()
        self.endPicker.dateValue = end
        self.startPicker.dateValue = end.addingTimeInterval(-TimeInterval(sender.tag) * 3_600)
    }

    @objc private func cancel() {
        self.onCancel()
    }

    @objc private func apply() {
        self.onApply(self.startPicker.dateValue, self.endPicker.dateValue)
    }
}

internal final class LiveTrafficChartView: NSView {
    private(set) var displayMaximum: UInt64 = 1
    private var lowerScaleRefreshCount = 0
    var points: [LiveTrafficPoint] = [] {
        didSet {
            self.updateDisplayMaximum()
            self.needsDisplay = true
        }
    }

    private func updateDisplayMaximum() {
        let observed = max(self.points.map { max($0.download, $0.upload) }.max() ?? 1, 1)
        if observed >= self.displayMaximum {
            self.displayMaximum = observed
            self.lowerScaleRefreshCount = 0
        } else if observed * 2 < self.displayMaximum {
            self.lowerScaleRefreshCount += 1
            if self.lowerScaleRefreshCount >= 5 {
                self.displayMaximum = max(observed, 1)
                self.lowerScaleRefreshCount = 0
            }
        } else {
            self.lowerScaleRefreshCount = 0
        }
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

        let maximum = self.displayMaximum
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
        NSColor.systemOrange.setStroke()
        upload.lineWidth = 1.5
        upload.stroke()
    }
}

internal struct LiveTrafficProcessRow: Equatable {
    let owner: ApplicationIdentity
    let process: ProcessTrafficSummary
    let routeContexts: [TrafficRouteContext]

    var total: UInt64 { self.process.download + self.process.upload }
    var iconIdentity: ApplicationIdentity { self.process.identity ?? self.owner }

    static func flatten(_ applications: [ApplicationTrafficSummary]) -> [LiveTrafficProcessRow] {
        applications.flatMap { application in
            application.processes.map {
                LiveTrafficProcessRow(owner: application.identity, process: $0, routeContexts: $0.routeContexts)
            }
        }.sorted {
            if $0.total == $1.total { return $0.process.processName.localizedCaseInsensitiveCompare($1.process.processName) == .orderedAscending }
            return $0.total > $1.total
        }
    }
}

internal final class LiveTrafficAppsView: NSView {
    private let iconResolver: ApplicationIconResolving
    var items: [LiveTrafficProcessRow] = [] {
        didSet { self.needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    init(iconResolver: ApplicationIconResolving) {
        self.iconResolver = iconResolver
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
            self.iconResolver.icon(for: item.iconIdentity).draw(
                in: CGRect(x: rect.minX + 9, y: rect.minY + 8, width: 16, height: 16)
            )
            let route = item.routeContexts.first.map {
                localizedString(TrafficRouteClassifier.label(for: $0, systemProxyConfigured: $0.systemProxyConfigured))
            }
            let ownerAndProcess = "\(item.owner.displayName) › \(item.process.processName)"
            let name = route.map { "\(ownerAndProcess)  ·  \($0)" } ?? ownerAndProcess
            (name as NSString).draw(
                at: CGPoint(x: 31, y: rect.minY + 8),
                withAttributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11, weight: .medium)]
            )
            let value = "↓ \(self.rate(item.process.download))   ↑ \(self.rate(item.process.upload))" as NSString
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

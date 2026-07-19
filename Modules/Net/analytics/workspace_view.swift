//
//  workspace_view.swift
//  Net
//

import Cocoa
import Kit

internal enum NetworkAnalyticsWorkspacePage: String, CaseIterable {
    case overview
    case history
    case live

    var title: String {
        switch self {
        case .overview: return localizedString("Overview")
        case .history: return localizedString("History")
        case .live: return localizedString("Live")
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "chart.xyaxis.line"
        case .history: return "chart.bar.fill"
        case .live: return "waveform.path.ecg"
        }
    }

    var accessibilityText: String {
        switch self {
        case .overview: return localizedString("Show overview analytics")
        case .history: return localizedString("Show history analytics")
        case .live: return localizedString("Show live analytics")
        }
    }
}

internal final class NetworkAnalyticsWorkspaceView: NSView {
    private let engine: TrafficAnalyticsEngine
    private let repository: TrafficHistoryRepository
    private let pageHost = NSView()
    private let pages: [NetworkAnalyticsWorkspacePage: NSView]
    private var pageButtons: [NetworkAnalyticsWorkspacePage: NSButton] = [:]
    private var hostedPage: NSView?
    private(set) var visiblePage: NetworkAnalyticsWorkspacePage?
    private let onSelect: (NetworkAnalyticsWorkspacePage) -> Void
    var repositoryIdentity: ObjectIdentifier { ObjectIdentifier(self.repository) }
    var engineIdentity: ObjectIdentifier { ObjectIdentifier(self.engine) }
    var hostedPageCount: Int { self.pageHost.subviews.count }
    var hostedPageFillsHost: Bool {
        guard let hostedPage else { return false }
        return self.pageHost.constraints.filter {
            ($0.firstItem as? NSView) === hostedPage || ($0.secondItem as? NSView) === hostedPage
        }.count == 4
    }

    init(
        engine: TrafficAnalyticsEngine,
        repository: TrafficHistoryRepository,
        ruleStore: TrafficRuleStore,
        networkRegistry: NetworkRegistry,
        selectedPage: NetworkAnalyticsWorkspacePage,
        openSettings: @escaping () -> Void,
        onSelect: @escaping (NetworkAnalyticsWorkspacePage) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.engine = engine
        self.repository = repository
        self.onSelect = onSelect
        self.pages = [
            .overview: TrafficOverviewView(engine: engine, planStore: ruleStore, networkRegistry: networkRegistry),
            .history: TrafficAnalysisView(
                engine: engine,
                repository: repository,
                networkRegistry: networkRegistry,
                ruleStore: ruleStore
            ),
            .live: LiveTrafficView(engine: engine)
        ]
        super.init(frame: .zero)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.build(openSettings: openSettings)
        self.select(selectedPage)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func select(_ page: NetworkAnalyticsWorkspacePage) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let view = self.pages[page] else { return }
        self.pageButtons.forEach { $0.value.state = $0.key == page ? .on : .off }

        if self.hostedPage !== view {
            self.hostedPage?.removeFromSuperview()
            self.hostedPage = view
            self.visiblePage = page
            view.translatesAutoresizingMaskIntoConstraints = false
            self.pageHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: self.pageHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: self.pageHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: self.pageHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: self.pageHost.bottomAnchor)
            ])
        }
        self.reload(page)
    }

    private func build(openSettings: @escaping () -> Void) {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let selector = self.makePageSelector()
        let actions = self.makeActionGroup(openSettings: openSettings)

        self.pageHost.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(header)
        header.addSubview(selector)
        header.addSubview(actions)
        self.addSubview(self.pageHost)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            header.topAnchor.constraint(equalTo: self.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            selector.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            selector.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            self.pageHost.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            self.pageHost.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            self.pageHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            self.pageHost.bottomAnchor.constraint(equalTo: self.bottomAnchor)
        ])
    }

    private func makePageSelector() -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 8
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        for page in NetworkAnalyticsWorkspacePage.allCases {
            let button = self.iconButton(
                symbol: page.symbolName,
                description: page.accessibilityText,
                identifier: "analytics-page-\(page.rawValue)",
                action: #selector(self.pageClicked(_:))
            )
            button.setButtonType(.toggle)
            button.isBordered = true
            button.bezelStyle = .texturedRounded
            button.tag = NetworkAnalyticsWorkspacePage.allCases.firstIndex(of: page) ?? 0
            button.widthAnchor.constraint(equalToConstant: 38).isActive = true
            self.pageButtons[page] = button
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func makeActionGroup(openSettings: @escaping () -> Void) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 8
        stack.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        stack.addArrangedSubview(self.iconButton(
            symbol: "bell",
            description: localizedString("Show traffic alerts"),
            identifier: "analytics-alerts",
            action: #selector(self.showAlerts)
        ))
        stack.addArrangedSubview(self.iconButton(
            symbol: "arrow.clockwise",
            description: localizedString("Refresh current analytics page"),
            identifier: "analytics-refresh",
            action: #selector(self.refreshCurrentPage)
        ))
        stack.addArrangedSubview(ClosureIconButton(
            symbol: "gearshape",
            description: localizedString("Open network settings"),
            identifier: "analytics-settings",
            action: openSettings
        ))
        return stack
    }

    private func iconButton(
        symbol: String,
        description: String,
        identifier: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = description
        button.setAccessibilityElement(true)
        button.setAccessibilityLabel(description)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func reload(_ page: NetworkAnalyticsWorkspacePage) {
        guard let view = self.pages[page] else { return }
        if let analysis = view as? TrafficAnalysisView { analysis.reload() }
        if let overview = view as? TrafficOverviewView { overview.reload() }
        if let live = view as? LiveTrafficView { live.reload() }
    }

    @objc private func pageClicked(_ sender: NSButton) {
        let pages = NetworkAnalyticsWorkspacePage.allCases
        guard sender.tag >= 0, sender.tag < pages.count else { return }
        self.onSelect(pages[sender.tag])
    }

    @objc private func refreshCurrentPage() {
        guard let visiblePage else { return }
        self.reload(visiblePage)
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
            if let visiblePage { self.reload(visiblePage) }
        } else if events.isEmpty {
            alert.runModal()
        }
    }
}

private final class ClosureIconButton: NSButton {
    private let closure: () -> Void

    init(symbol: String, description: String, identifier: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        self.imagePosition = .imageOnly
        self.isBordered = false
        self.toolTip = description
        self.setAccessibilityElement(true)
        self.setAccessibilityLabel(description)
        self.target = self
        self.action = #selector(self.invoke)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.widthAnchor.constraint(equalToConstant: 32).isActive = true
        self.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        self.closure()
    }
}

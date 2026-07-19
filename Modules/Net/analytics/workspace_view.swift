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
}

internal final class NetworkAnalyticsWorkspaceView: NSView {
    private let engine: TrafficAnalyticsEngine
    private let repository: TrafficHistoryRepository
    private let pageControl: NSSegmentedControl
    private let pageHost = NSView()
    private let pages: [NetworkAnalyticsWorkspacePage: NSView]
    private var hostedPage: NSView?
    private(set) var visiblePageForTesting: NetworkAnalyticsWorkspacePage?
    private let onSelect: (NetworkAnalyticsWorkspacePage) -> Void
    var repositoryIdentityForTesting: ObjectIdentifier { ObjectIdentifier(self.repository) }
    var engineIdentityForTesting: ObjectIdentifier { ObjectIdentifier(self.engine) }

    init(
        engine: TrafficAnalyticsEngine,
        repository: TrafficHistoryRepository,
        ruleStore: TrafficRuleStore,
        networkRegistry: NetworkRegistry,
        selectedPage: NetworkAnalyticsWorkspacePage,
        openSettings: @escaping () -> Void,
        onSelect: @escaping (NetworkAnalyticsWorkspacePage) -> Void
    ) {
        self.engine = engine
        self.repository = repository
        self.onSelect = onSelect
        self.pageControl = NSSegmentedControl(
            labels: NetworkAnalyticsWorkspacePage.allCases.map(\.title),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        self.pages = [
            .overview: TrafficOverviewView(
                engine: engine,
                planStore: ruleStore,
                networkRegistry: networkRegistry
            ),
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
        guard let view = self.pages[page] else { return }
        if let index = NetworkAnalyticsWorkspacePage.allCases.firstIndex(of: page) {
            self.pageControl.selectedSegment = index
        }
        guard self.hostedPage !== view else { return }
        self.hostedPage?.removeFromSuperview()
        self.hostedPage = view
        self.visiblePageForTesting = page
        view.translatesAutoresizingMaskIntoConstraints = false
        self.pageHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.pageHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.pageHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: self.pageHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: self.pageHost.bottomAnchor)
        ])
        if let analysis = view as? TrafficAnalysisView { analysis.reload() }
        if let overview = view as? TrafficOverviewView { overview.reload() }
    }

    private func build(openSettings: @escaping () -> Void) {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        header.translatesAutoresizingMaskIntoConstraints = false

        self.pageControl.target = self
        self.pageControl.action = #selector(self.pageChanged(_:))
        header.addArrangedSubview(self.pageControl)
        header.addArrangedSubview(NSView())

        let settings = ClosureButton(title: localizedString("Network Settings"), action: openSettings)
        header.addArrangedSubview(settings)

        self.pageHost.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(header)
        self.addSubview(self.pageHost)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: self.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: self.trailingAnchor),
            header.topAnchor.constraint(equalTo: self.topAnchor),
            self.pageHost.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 16),
            self.pageHost.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -16),
            self.pageHost.topAnchor.constraint(equalTo: header.bottomAnchor),
            self.pageHost.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -16)
        ])
    }

    @objc private func pageChanged(_ sender: NSSegmentedControl) {
        let pages = NetworkAnalyticsWorkspacePage.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < pages.count else { return }
        self.onSelect(pages[sender.selectedSegment])
    }
}

private final class ClosureButton: NSButton {
    private let closure: () -> Void

    init(title: String, action: @escaping () -> Void) {
        self.closure = action
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .rounded
        self.target = self
        self.action = #selector(self.invoke)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        self.closure()
    }
}

//
//  workspace_window.swift
//  Net
//

import Cocoa
import Kit

internal final class NetworkAnalyticsWindowController: NSWindowController {
    static let frameAutosaveName = "NetworkAnalyticsWorkspaceWindow"
    static let defaultContentSize = NSSize(width: 1080, height: 760)
    static let minimumContentSize = NSSize(width: 720, height: 480)
    private static let selectedPageKey = "NetworkAnalyticsWorkspace.selectedPage"

    private let repository: TrafficHistoryRepository
    private let ruleStore: TrafficRuleStore
    private let networkRegistry: NetworkRegistry
    private let defaults: UserDefaults
    private let openSettings: () -> Void
    internal let analyticsEngine: TrafficAnalyticsEngine
    private var workspaceWindow: NSWindow?
    private weak var workspaceView: NetworkAnalyticsWorkspaceView?

    private(set) var selectedPage: NetworkAnalyticsWorkspacePage

    init(
        repository: TrafficHistoryRepository,
        ruleStore: TrafficRuleStore,
        networkRegistry: NetworkRegistry,
        defaults: UserDefaults = .standard,
        analyticsEngine: TrafficAnalyticsEngine? = nil,
        openSettings: @escaping () -> Void
    ) {
        self.repository = repository
        self.ruleStore = ruleStore
        self.networkRegistry = networkRegistry
        self.defaults = defaults
        self.analyticsEngine = analyticsEngine ?? TrafficAnalyticsEngine(repository: repository)
        self.openSettings = openSettings
        self.selectedPage = defaults.string(forKey: Self.selectedPageKey)
            .flatMap(NetworkAnalyticsWorkspacePage.init(rawValue:)) ?? .overview
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func show() -> NSWindow {
        let window = self.workspaceWindow ?? self.makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    func select(_ page: NetworkAnalyticsWorkspacePage) {
        self.selectedPage = page
        self.defaults.set(page.rawValue, forKey: Self.selectedPageKey)
        self.workspaceView?.select(page)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localizedString("Network Analytics")
        window.contentMinSize = Self.minimumContentSize
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.center()

        let view = NetworkAnalyticsWorkspaceView(
            engine: self.analyticsEngine,
            repository: self.repository,
            ruleStore: self.ruleStore,
            networkRegistry: self.networkRegistry,
            selectedPage: self.selectedPage,
            openSettings: self.openSettings,
            onSelect: { [weak self] page in self?.select(page) }
        )
        window.contentView = view
        self.workspaceView = view
        self.workspaceWindow = window
        self.window = window
        return window
    }
}

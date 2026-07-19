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

    private let repository: TrafficHistoryRepository
    private let ruleStore: TrafficRuleStore
    private let networkRegistry: NetworkRegistry
    private let defaults: UserDefaults
    private let openSettings: () -> Void
    internal let analyticsEngine: TrafficAnalyticsEngine
    private var workspaceWindow: NSWindow?
    private weak var workspaceView: NetworkAnalyticsWorkspaceView?

    private(set) var selectedPage: NetworkAnalyticsWorkspacePage
    var repositoryIdentity: ObjectIdentifier { ObjectIdentifier(self.repository) }
    var engineIdentity: ObjectIdentifier { ObjectIdentifier(self.analyticsEngine) }
    var networkRegistryIdentity: ObjectIdentifier { ObjectIdentifier(self.networkRegistry) }

    init(
        repository: TrafficHistoryRepository,
        ruleStore: TrafficRuleStore,
        networkRegistry: NetworkRegistry,
        defaults: UserDefaults = .standard,
        analyticsEngine: TrafficAnalyticsEngine? = nil,
        openSettings: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.repository = repository
        self.ruleStore = ruleStore
        self.networkRegistry = networkRegistry
        self.defaults = defaults
        self.analyticsEngine = analyticsEngine ?? TrafficAnalyticsEngine(repository: repository)
        self.openSettings = openSettings
        let storedPage = defaults.string(forKey: NetworkAnalyticsWorkspacePage.storageKey)
        let legacyPage = defaults.string(forKey: NetworkAnalyticsWorkspacePage.legacyStorageKey)
        self.selectedPage = NetworkAnalyticsWorkspacePage(storedRawValue: storedPage ?? legacyPage)
        if storedPage.flatMap(NetworkAnalyticsWorkspacePage.init(rawValue:)) == nil {
            defaults.set(self.selectedPage.rawValue, forKey: NetworkAnalyticsWorkspacePage.storageKey)
        }
        if storedPage == nil, legacyPage != nil {
            defaults.removeObject(forKey: NetworkAnalyticsWorkspacePage.legacyStorageKey)
        }
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func show() -> NSWindow {
        dispatchPrecondition(condition: .onQueue(.main))
        let window = self.workspaceWindow ?? self.makeWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    func select(_ page: NetworkAnalyticsWorkspacePage) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.selectedPage = page
        self.defaults.set(page.rawValue, forKey: NetworkAnalyticsWorkspacePage.storageKey)
        self.workspaceView?.select(page)
    }

    private func makeWindow() -> NSWindow {
        dispatchPrecondition(condition: .onQueue(.main))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localizedString("Network Analytics")
        window.contentMinSize = Self.minimumContentSize
        window.isReleasedWhenClosed = false
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
        window.setFrameAutosaveName(Self.frameAutosaveName)
        return window
    }
}

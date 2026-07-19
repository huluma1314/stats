//
//  application_table.swift
//  Net
//

import Cocoa
import Foundation
import Kit

public enum ApplicationTrafficSortKey: String, CaseIterable, Codable {
    case name
    case download
    case upload
    case peak
    case total
}

public enum ApplicationTrafficPresenter {
    public static func sort(
        _ items: [ApplicationTrafficSummary],
        by key: ApplicationTrafficSortKey,
        ascending: Bool
    ) -> [ApplicationTrafficSummary] {
        items.sorted { lhs, rhs in
            let result: ComparisonResult
            switch key {
            case .name:
                result = lhs.identity.displayName.localizedCaseInsensitiveCompare(rhs.identity.displayName)
            case .download:
                result = compare(lhs.download, rhs.download)
            case .upload:
                result = compare(lhs.upload, rhs.upload)
            case .peak:
                result = compare(lhs.peakBytesPerSecond, rhs.peakBytesPerSecond)
            case .total:
                result = compare(lhs.total, rhs.total)
            }
            if result == .orderedSame {
                return lhs.identity.id < rhs.identity.id
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    public static func filter(
        _ items: [ApplicationTrafficSummary],
        search: String
    ) -> [ApplicationTrafficSummary] {
        items.filter { ApplicationIdentityResolver.matches($0, search: search) }
    }

    private static func compare(_ lhs: UInt64, _ rhs: UInt64) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }
}

internal final class ApplicationTrafficTableController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let iconResolver: ApplicationIconResolving
    private let root = NSStackView()
    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private var source: [ApplicationTrafficSummary] = []
    private var items: [ApplicationTrafficSummary] = []
    private var sortKey: ApplicationTrafficSortKey = .total
    private var ascending = false
    private var groupByProcess = false
    private var showProxyLabels = true
    var onSelect: ((ApplicationTrafficSummary?) -> Void)?
    var onStateChange: ((String, ApplicationTrafficSortKey, Bool) -> Void)?

    init(iconResolver: ApplicationIconResolving = ApplicationIconResolver()) {
        self.iconResolver = iconResolver
        super.init()
        self.configure()
    }

    func rootView() -> NSView { self.root }

    func update(
        _ ranking: [ApplicationTrafficSummary],
        search: String? = nil,
        sortKey: ApplicationTrafficSortKey? = nil,
        ascending: Bool? = nil,
        groupByProcess: Bool? = nil,
        showProxyLabels: Bool? = nil
    ) {
        self.source = ranking
        if let search { self.searchField.stringValue = search }
        if let sortKey { self.sortKey = sortKey }
        if let ascending { self.ascending = ascending }
        if let groupByProcess { self.groupByProcess = groupByProcess }
        if let showProxyLabels { self.showProxyLabels = showProxyLabels }
        self.rebuild()
    }

    private func configure() {
        self.root.orientation = .vertical
        self.root.spacing = 8
        self.root.translatesAutoresizingMaskIntoConstraints = false

        self.searchField.placeholderString = localizedString("Search applications")
        self.searchField.target = self
        self.searchField.action = #selector(self.searchChanged)
        self.root.addArrangedSubview(self.searchField)

        self.outlineView.style = .plain
        self.outlineView.rowHeight = 24
        self.outlineView.usesAlternatingRowBackgroundColors = true
        self.outlineView.delegate = self
        self.outlineView.dataSource = self
        self.outlineView.doubleAction = #selector(self.rowActivated)
        self.outlineView.target = self

        for (identifier, title, width) in [
            ("name", localizedString("Application"), 180.0),
            ("download", localizedString("Download"), 90.0),
            ("upload", localizedString("Upload"), 90.0),
            ("peak", localizedString("Peak"), 90.0),
            ("total", localizedString("Total"), 90.0)
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            column.minWidth = 70
            self.outlineView.addTableColumn(column)
        }
        self.outlineView.outlineTableColumn = self.outlineView.tableColumns.first

        self.scrollView.documentView = self.outlineView
        self.scrollView.hasVerticalScroller = true
        self.scrollView.borderType = .bezelBorder
        self.scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        self.root.addArrangedSubview(self.scrollView)
    }

    private func rebuild() {
        self.items = ApplicationTrafficPresenter.sort(
            ApplicationTrafficPresenter.filter(self.source, search: self.searchField.stringValue),
            by: self.sortKey,
            ascending: self.ascending
        )
        self.outlineView.reloadData()
        if self.groupByProcess {
            self.items.forEach { self.outlineView.expandItem($0) }
        }
    }

    @objc private func searchChanged() {
        self.rebuild()
        self.onStateChange?(self.searchField.stringValue, self.sortKey, self.ascending)
    }

    @objc private func rowActivated() {
        let item = self.outlineView.item(atRow: self.outlineView.selectedRow)
        self.onSelect?(item as? ApplicationTrafficSummary)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return self.items.count }
        return (item as? ApplicationTrafficSummary)?.processes.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ApplicationTrafficSummary)?.processes.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return self.items[index] }
        return (item as! ApplicationTrafficSummary).processes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? "name"
        let text = NSTextField(labelWithString: self.text(for: item, column: id))
        text.font = .systemFont(ofSize: 11)
        text.lineBreakMode = .byTruncatingTail
        guard id == "name" else { return text }
        let owner = (item as? ApplicationTrafficSummary)
            ?? (outlineView.parent(forItem: item) as? ApplicationTrafficSummary)
        guard let owner else { return text }
        let identity = (item as? ProcessTrafficSummary)?.identity ?? owner.identity
        let imageView = NSImageView(image: self.iconResolver.icon(for: identity))
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16)
        ])
        let row = NSStackView(views: [imageView, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.toolTip = owner.identity.executablePath ?? owner.identity.bundleIdentifier
        return row
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let item = self.outlineView.item(atRow: self.outlineView.selectedRow)
        self.onSelect?(item as? ApplicationTrafficSummary)
    }

    private func text(for item: Any, column: String) -> String {
        if let summary = item as? ApplicationTrafficSummary {
            switch column {
            case "download": return Units(bytes: Int64(summary.download)).getReadableMemory()
            case "upload": return Units(bytes: Int64(summary.upload)).getReadableMemory()
            case "peak": return Units(bytes: Int64(summary.peakBytesPerSecond)).getReadableMemory() + "/s"
            case "total": return Units(bytes: Int64(summary.total)).getReadableMemory()
            default:
                guard self.showProxyLabels else { return summary.identity.displayName }
                let labels = summary.routeContexts.filter {
                    $0.kind != .direct || $0.systemProxyConfigured
                }.map {
                    localizedString(TrafficRouteClassifier.label(for: $0, systemProxyConfigured: $0.systemProxyConfigured))
                }
                return ([summary.identity.displayName] + Array(Set(labels)).sorted()).joined(separator: " · ")
            }
        }
        if let process = item as? ProcessTrafficSummary {
            switch column {
            case "download": return Units(bytes: Int64(process.download)).getReadableMemory()
            case "upload": return Units(bytes: Int64(process.upload)).getReadableMemory()
            case "peak": return Units(bytes: Int64(process.peakBytesPerSecond)).getReadableMemory() + "/s"
            case "total": return Units(bytes: Int64(process.download + process.upload)).getReadableMemory()
            default: return "\(process.processName) (\(process.processID))"
            }
        }
        return ""
    }
}

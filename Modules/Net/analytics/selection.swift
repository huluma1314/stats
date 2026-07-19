//
//  selection.swift
//  Net
//

import Foundation

public enum TrafficCustomRange {
    public static func interval(start: Date, end: Date, now: Date = Date()) -> DateInterval? {
        let clampedEnd = min(end, now)
        guard start < clampedEnd else { return nil }
        return DateInterval(start: start, end: clampedEnd)
    }

    public static func range(for duration: TimeInterval) -> TrafficRange {
        switch duration {
        case ...600: return .tenMinutes
        case ...3_600: return .oneHour
        case ...86_400: return .today
        case ...(7 * 86_400): return .sevenDays
        case ...(30 * 86_400): return .thirtyDays
        default: return .currentMonth
        }
    }
}

public enum TrafficChartMode: String, CaseIterable, Codable {
    case line
    case heatmap
}

public enum TrafficRefreshMode: String, CaseIterable, Codable {
    case manual
    case fiveSeconds
    case tenSeconds
    case thirtySeconds
    case oneMinute
    case fiveMinutes

    public var interval: TimeInterval? {
        switch self {
        case .manual: return nil
        case .fiveSeconds: return 5
        case .tenSeconds: return 10
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        }
    }
}

public struct TrafficSelection: Equatable {
    public var range: TrafficRange
    public var chartMode: TrafficChartMode
    public var networkFilter: NetworkKind?
    public var networkID: String?
    public var refreshMode: TrafficRefreshMode
    public var search: String
    public var selectedInterval: DateInterval?
    public var showDownload: Bool
    public var showUpload: Bool
    public var groupByProcess: Bool
    public var showProxyLabels: Bool
    public var showAlertMarkers: Bool
    public var includeLocalNetwork: Bool
    public var sortKey: ApplicationTrafficSortKey
    public var sortAscending: Bool

    public init(
        range: TrafficRange = .tenMinutes,
        chartMode: TrafficChartMode = .line,
        networkFilter: NetworkKind? = nil,
        networkID: String? = nil,
        refreshMode: TrafficRefreshMode = .tenSeconds,
        search: String = "",
        selectedInterval: DateInterval? = nil,
        showDownload: Bool = true,
        showUpload: Bool = true,
        groupByProcess: Bool = false,
        showProxyLabels: Bool = true,
        showAlertMarkers: Bool = true,
        includeLocalNetwork: Bool = true,
        sortKey: ApplicationTrafficSortKey = .total,
        sortAscending: Bool = false
    ) {
        self.range = range
        self.chartMode = chartMode
        self.networkFilter = networkFilter
        self.networkID = networkID
        self.refreshMode = refreshMode
        self.search = search
        self.selectedInterval = selectedInterval
        self.showDownload = showDownload
        self.showUpload = showUpload
        self.groupByProcess = groupByProcess
        self.showProxyLabels = showProxyLabels
        self.showAlertMarkers = showAlertMarkers
        self.includeLocalNetwork = includeLocalNetwork
        self.sortKey = sortKey
        self.sortAscending = sortAscending
    }

    public func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        if let selectedInterval {
            return selectedInterval
        }
        let pair = TrafficAggregation.interval(for: self.range, now: now, calendar: calendar)
        return DateInterval(start: pair.start, end: pair.end)
    }

    public func analyticsQuery(now: Date = Date()) -> TrafficAnalyticsQuery {
        TrafficAnalyticsQuery(
            range: self.range,
            networkFilter: self.networkFilter,
            networkID: self.networkID,
            includeLocalNetwork: self.includeLocalNetwork,
            applicationSearch: self.search,
            selectedInterval: self.selectedInterval,
            now: now
        )
    }
}

public final class TrafficSelectionStore {
    private let defaults: UserDefaults
    private let key = "net.analytics.ui.selection.v2"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var hasSavedSelection: Bool { self.defaults.object(forKey: self.key) != nil }

    public func save(_ selection: TrafficSelection) {
        guard let data = try? JSONEncoder().encode(PersistedTrafficSelection(selection)) else { return }
        self.defaults.set(data, forKey: self.key)
    }

    public func load() -> TrafficSelection {
        guard let data = self.defaults.data(forKey: self.key),
              let stored = try? JSONDecoder().decode(PersistedTrafficSelection.self, from: data) else {
            return TrafficSelection()
        }
        return stored.selection
    }
}

private struct PersistedTrafficSelection: Codable {
    let range: TrafficRange
    let chartMode: TrafficChartMode
    let networkFilter: NetworkKind?
    let networkID: String?
    let refreshMode: TrafficRefreshMode
    let search: String
    let selectedStart: Date?
    let selectedEnd: Date?
    let showDownload: Bool?
    let showUpload: Bool?
    let groupByProcess: Bool?
    let showProxyLabels: Bool?
    let showAlertMarkers: Bool?
    let includeLocalNetwork: Bool?
    let sortKey: ApplicationTrafficSortKey?
    let sortAscending: Bool?

    init(_ value: TrafficSelection) {
        self.range = value.range
        self.chartMode = value.chartMode
        self.networkFilter = value.networkFilter
        self.networkID = value.networkID
        self.refreshMode = value.refreshMode
        self.search = value.search
        self.selectedStart = value.selectedInterval?.start
        self.selectedEnd = value.selectedInterval?.end
        self.showDownload = value.showDownload
        self.showUpload = value.showUpload
        self.groupByProcess = value.groupByProcess
        self.showProxyLabels = value.showProxyLabels
        self.showAlertMarkers = value.showAlertMarkers
        self.includeLocalNetwork = value.includeLocalNetwork
        self.sortKey = value.sortKey
        self.sortAscending = value.sortAscending
    }

    var selection: TrafficSelection {
        TrafficSelection(
            range: self.range,
            chartMode: self.chartMode,
            networkFilter: self.networkFilter,
            networkID: self.networkID,
            refreshMode: self.refreshMode,
            search: self.search,
            selectedInterval: self.selectedStart.flatMap { start in self.selectedEnd.map { DateInterval(start: start, end: $0) } },
            showDownload: self.showDownload ?? true,
            showUpload: self.showUpload ?? true,
            groupByProcess: self.groupByProcess ?? false,
            showProxyLabels: self.showProxyLabels ?? true,
            showAlertMarkers: self.showAlertMarkers ?? true,
            includeLocalNetwork: self.includeLocalNetwork ?? true,
            sortKey: self.sortKey ?? .total,
            sortAscending: self.sortAscending ?? false
        )
    }
}

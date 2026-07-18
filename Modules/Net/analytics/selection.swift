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

public enum TrafficChartMode: String, CaseIterable {
    case line
    case heatmap
}

public enum TrafficRefreshMode: String, CaseIterable {
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
    public var refreshMode: TrafficRefreshMode
    public var search: String
    public var selectedInterval: DateInterval?

    public init(
        range: TrafficRange = .tenMinutes,
        chartMode: TrafficChartMode = .line,
        networkFilter: NetworkKind? = nil,
        refreshMode: TrafficRefreshMode = .tenSeconds,
        search: String = "",
        selectedInterval: DateInterval? = nil
    ) {
        self.range = range
        self.chartMode = chartMode
        self.networkFilter = networkFilter
        self.refreshMode = refreshMode
        self.search = search
        self.selectedInterval = selectedInterval
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
            includeLocalNetwork: true,
            applicationSearch: self.search,
            selectedInterval: self.selectedInterval,
            now: now
        )
    }
}

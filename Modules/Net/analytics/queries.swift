//
//  queries.swift
//  Net
//

import Foundation

public struct TrafficForecast: Codable, Equatable {
    public enum State: String, Codable, Equatable {
        case ready
        case insufficientData
    }

    public let state: State
    public let projectedBytes: UInt64?
    public let remainingDays: Int
    public let averageBytesPerDay: UInt64?

    public init(
        state: State,
        projectedBytes: UInt64?,
        remainingDays: Int,
        averageBytesPerDay: UInt64?
    ) {
        self.state = state
        self.projectedBytes = projectedBytes
        self.remainingDays = remainingDays
        self.averageBytesPerDay = averageBytesPerDay
    }
}

public struct TrafficAnalyticsSnapshot: Codable, Equatable {
    public let range: TrafficRange
    public let start: Date
    public let end: Date
    public let download: UInt64
    public let upload: UInt64
    public let total: UInt64
    public let buckets: [TrafficBucket]
    public let ranking: [ApplicationTrafficSummary]
    public let forecast: TrafficForecast?

    public init(
        range: TrafficRange,
        start: Date,
        end: Date,
        download: UInt64,
        upload: UInt64,
        total: UInt64,
        buckets: [TrafficBucket],
        ranking: [ApplicationTrafficSummary],
        forecast: TrafficForecast?
    ) {
        self.range = range
        self.start = start
        self.end = end
        self.download = download
        self.upload = upload
        self.total = total
        self.buckets = buckets
        self.ranking = ranking
        self.forecast = forecast
    }
}

public struct TrafficAnalyticsQuery: Equatable {
    public let range: TrafficRange
    public let networkFilter: NetworkKind?
    public let includeLocalNetwork: Bool
    public let applicationSearch: String
    public let selectedInterval: DateInterval?
    public let billingCycleDay: Int
    public let now: Date

    public init(
        range: TrafficRange,
        networkFilter: NetworkKind? = nil,
        includeLocalNetwork: Bool = true,
        applicationSearch: String = "",
        selectedInterval: DateInterval? = nil,
        billingCycleDay: Int = 1,
        now: Date = Date()
    ) {
        self.range = range
        self.networkFilter = networkFilter
        self.includeLocalNetwork = includeLocalNetwork
        self.applicationSearch = applicationSearch
        self.selectedInterval = selectedInterval
        self.billingCycleDay = billingCycleDay
        self.now = now
    }
}

public final class TrafficAnalyticsEngine {
    private let repository: TrafficHistoryRepository
    private let calendar: Calendar

    public init(repository: TrafficHistoryRepository, calendar: Calendar = .current) {
        self.repository = repository
        self.calendar = calendar
    }

    public func snapshot(for query: TrafficAnalyticsQuery) -> TrafficAnalyticsSnapshot {
        let interval = TrafficAggregation.interval(
            for: query.range,
            now: query.now,
            calendar: self.calendar
        )
        let level = self.storageLevel(for: query.range)
        var samples = self.repository.fetch(
            TrafficHistoryQuery(level: level, start: interval.start, end: interval.end)
        )

        if level != .second {
            let finer = self.repository.fetch(
                TrafficHistoryQuery(level: .second, start: interval.start, end: interval.end)
            )
            if !finer.isEmpty {
                samples.append(contentsOf: finer)
            }
        }

        samples = self.deduplicate(samples)
        if let kind = query.networkFilter {
            samples = samples.filter { $0.network.kind == kind }
        }
        if !query.includeLocalNetwork {
            samples = samples.filter { $0.network.kind != .other }
        }
        if let selected = query.selectedInterval {
            samples = samples.filter { $0.timestamp >= selected.start && $0.timestamp <= selected.end }
        }

        let download = samples.reduce(UInt64(0)) { $0 + $1.delta.download }
        let upload = samples.reduce(UInt64(0)) { $0 + $1.delta.upload }
        let buckets = TrafficAggregation.buckets(
            samples: samples,
            range: query.range,
            now: query.now,
            calendar: self.calendar
        )
        let ranking = self.rank(samples: samples, search: query.applicationSearch)
        let forecast = self.forecast(
            samples: samples,
            billingCycleDay: query.billingCycleDay,
            now: query.now
        )

        return TrafficAnalyticsSnapshot(
            range: query.range,
            start: interval.start,
            end: interval.end,
            download: download,
            upload: upload,
            total: download + upload,
            buckets: buckets,
            ranking: ranking,
            forecast: forecast
        )
    }

    public func rank(samples: [TrafficSample], search: String = "") -> [ApplicationTrafficSummary] {
        var grouped: [String: (identity: ApplicationIdentity, download: UInt64, upload: UInt64, peak: UInt64, processes: [Int32: ProcessTrafficSummary])] = [:]

        for sample in samples {
            var bucket = grouped[sample.application.id] ?? (
                identity: sample.application,
                download: 0,
                upload: 0,
                peak: 0,
                processes: [:]
            )
            bucket.download += sample.delta.download
            bucket.upload += sample.delta.upload
            bucket.peak = max(bucket.peak, sample.peakBytesPerSecond)

            var process = bucket.processes[sample.processID] ?? ProcessTrafficSummary(
                processID: sample.processID,
                processName: sample.application.displayName,
                download: 0,
                upload: 0,
                peakBytesPerSecond: 0
            )
            process = ProcessTrafficSummary(
                processID: process.processID,
                processName: process.processName,
                download: process.download + sample.delta.download,
                upload: process.upload + sample.delta.upload,
                peakBytesPerSecond: max(process.peakBytesPerSecond, sample.peakBytesPerSecond)
            )
            bucket.processes[sample.processID] = process
            grouped[sample.application.id] = bucket
        }

        let summaries = grouped.values.map {
            ApplicationTrafficSummary(
                identity: $0.identity,
                download: $0.download,
                upload: $0.upload,
                peakBytesPerSecond: $0.peak,
                processes: $0.processes.values.sorted { $0.processID < $1.processID }
            )
        }
        .filter { ApplicationIdentityResolver.matches($0, search: search) }
        .sorted {
            if $0.total == $1.total {
                return $0.identity.displayName.localizedCaseInsensitiveCompare($1.identity.displayName) == .orderedAscending
            }
            return $0.total > $1.total
        }
        return summaries
    }

    public func forecast(
        samples: [TrafficSample],
        billingCycleDay: Int,
        now: Date
    ) -> TrafficForecast {
        let period = self.billingPeriod(containing: now, cycleDay: billingCycleDay)
        let periodSamples = samples.filter { $0.timestamp >= period.start && $0.timestamp <= now }
        let used = periodSamples.reduce(UInt64(0)) { $0 + $1.delta.total }
        let elapsedDays = max(1, Int(ceil(now.timeIntervalSince(period.start) / 86_400)))
        let remainingDays = max(0, Int(ceil(period.end.timeIntervalSince(now) / 86_400)))

        guard periodSamples.count >= 2 || used > 0, elapsedDays >= 1 else {
            return TrafficForecast(
                state: .insufficientData,
                projectedBytes: nil,
                remainingDays: remainingDays,
                averageBytesPerDay: nil
            )
        }

        let average = used / UInt64(elapsedDays)
        let projected = used + average * UInt64(remainingDays)
        return TrafficForecast(
            state: .ready,
            projectedBytes: projected,
            remainingDays: remainingDays,
            averageBytesPerDay: average
        )
    }

    public func deduplicate(_ samples: [TrafficSample]) -> [TrafficSample] {
        // Prefer physical interfaces when the same application reports traffic on both
        // tunnel and physical layers in the same second.
        var bySecondApp: [String: [TrafficSample]] = [:]
        for sample in samples {
            let second = Int64(sample.timestamp.timeIntervalSince1970)
            let key = "\(second)|\(sample.application.id)"
            bySecondApp[key, default: []].append(sample)
        }

        var result: [TrafficSample] = []
        for group in bySecondApp.values {
            let hasTunnel = group.contains { $0.network.kind == .tunnel }
            let hasPhysical = group.contains { $0.network.kind == .wifi || $0.network.kind == .ethernet || $0.network.kind == .hotspot }
            if hasTunnel && hasPhysical {
                result.append(contentsOf: group.filter { $0.network.kind != .tunnel })
            } else {
                result.append(contentsOf: group)
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    private func storageLevel(for range: TrafficRange) -> TrafficAggregationLevel {
        switch range {
        case .tenMinutes, .oneHour, .today:
            return .second
        case .sevenDays, .thirtyDays:
            return .minute
        case .currentMonth:
            return .hour
        }
    }

    private func billingPeriod(containing date: Date, cycleDay: Int) -> DateInterval {
        let day = min(max(cycleDay, 1), 28)
        var components = self.calendar.dateComponents([.year, .month], from: date)
        components.day = day
        let thisCycle = self.calendar.date(from: components) ?? self.calendar.startOfDay(for: date)
        if date >= thisCycle {
            let next = self.calendar.date(byAdding: .month, value: 1, to: thisCycle) ?? thisCycle.addingTimeInterval(30 * 86_400)
            return DateInterval(start: thisCycle, end: next)
        }
        let previous = self.calendar.date(byAdding: .month, value: -1, to: thisCycle) ?? thisCycle.addingTimeInterval(-30 * 86_400)
        return DateInterval(start: previous, end: thisCycle)
    }
}

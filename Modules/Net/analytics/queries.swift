//
//  queries.swift
//  Net
//

import Foundation

public enum LiveTrafficWindow: Int, CaseIterable, Codable {
    case sixtySeconds = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    public var duration: TimeInterval { TimeInterval(self.rawValue) }
}

public struct LiveTrafficPoint: Codable, Equatable {
    public let timestamp: Date
    public let download: UInt64
    public let upload: UInt64

    public init(timestamp: Date, download: UInt64, upload: UInt64) {
        self.timestamp = timestamp
        self.download = download
        self.upload = upload
    }
}

public struct LiveTrafficSnapshot: Codable, Equatable {
    public let window: LiveTrafficWindow
    public let applicationID: String?
    public let downloadBytesPerSecond: UInt64
    public let uploadBytesPerSecond: UInt64
    public let points: [LiveTrafficPoint]
    public let applications: [ApplicationTrafficSummary]
    public let activeApplications: [ApplicationTrafficSummary]

    public var totalBytesPerSecond: UInt64 {
        self.downloadBytesPerSecond + self.uploadBytesPerSecond
    }

    public init(
        window: LiveTrafficWindow,
        applicationID: String?,
        downloadBytesPerSecond: UInt64,
        uploadBytesPerSecond: UInt64,
        points: [LiveTrafficPoint],
        applications: [ApplicationTrafficSummary],
        activeApplications: [ApplicationTrafficSummary]
    ) {
        self.window = window
        self.applicationID = applicationID
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.points = points
        self.applications = applications
        self.activeApplications = activeApplications
    }
}

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
    public let alerts: [TrafficAlertEvent]

    public init(
        range: TrafficRange,
        start: Date,
        end: Date,
        download: UInt64,
        upload: UInt64,
        total: UInt64,
        buckets: [TrafficBucket],
        ranking: [ApplicationTrafficSummary],
        forecast: TrafficForecast?,
        alerts: [TrafficAlertEvent] = []
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
        self.alerts = alerts
    }
}

public struct TrafficQuerySegment: Equatable {
    public let level: TrafficAggregationLevel
    public let interval: DateInterval

    public init(level: TrafficAggregationLevel, interval: DateInterval) {
        self.level = level
        self.interval = interval
    }
}

public struct TrafficQueryPlan: Equatable {
    public let segments: [TrafficQuerySegment]

    public init(segments: [TrafficQuerySegment]) {
        self.segments = segments
    }
}

public struct TrafficQueryPlanner {
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public func plan(
        interval: DateInterval,
        now: Date,
        policy: TrafficRetentionPolicy
    ) -> TrafficQueryPlan {
        guard interval.start < interval.end else { return TrafficQueryPlan(segments: []) }
        let minuteCutoff = self.calendar.date(byAdding: .day, value: -policy.minuteRetentionDays, to: now)
            ?? now.addingTimeInterval(-TimeInterval(policy.minuteRetentionDays) * 86_400)
        let hourCutoff = self.calendar.date(byAdding: .day, value: -policy.hourRetentionDays, to: now)
            ?? now.addingTimeInterval(-TimeInterval(policy.hourRetentionDays) * 86_400)
        let dayCutoff = self.calendar.date(byAdding: .day, value: -policy.dayRetentionDays, to: now)
            ?? now.addingTimeInterval(-TimeInterval(policy.dayRetentionDays) * 86_400)
        let secondCutoff = now.addingTimeInterval(-TrafficRetentionPolicy.secondRetention)
        let monthBoundary = TrafficAggregation.bucketInterval(for: dayCutoff, level: .month, calendar: self.calendar).start
        let dayBoundary = TrafficAggregation.bucketInterval(for: hourCutoff, level: .day, calendar: self.calendar).start
        let hourBoundary = TrafficAggregation.bucketInterval(for: minuteCutoff, level: .hour, calendar: self.calendar).start
        let minuteBoundary = TrafficAggregation.bucketInterval(for: secondCutoff, level: .minute, calendar: self.calendar).start

        var segments: [TrafficQuerySegment] = []
        var cursor = interval.start
        let oldEnd = min(interval.end, monthBoundary)
        if cursor < oldEnd {
            cursor = self.appendPermanentSegments(from: cursor, to: oldEnd, into: &segments)
        }
        self.append(.day, from: &cursor, to: min(interval.end, dayBoundary), into: &segments)
        self.append(.hour, from: &cursor, to: min(interval.end, hourBoundary), into: &segments)
        self.append(.minute, from: &cursor, to: min(interval.end, minuteBoundary), into: &segments)
        self.append(.second, from: &cursor, to: interval.end, into: &segments)
        return TrafficQueryPlan(segments: segments)
    }

    private func appendPermanentSegments(
        from start: Date,
        to end: Date,
        into segments: inout [TrafficQuerySegment]
    ) -> Date {
        var cursor = start
        let firstFullYearStart = self.calendar.dateInterval(of: .year, for: cursor)?.start == cursor
            ? cursor
            : (self.calendar.date(byAdding: .year, value: 1, to: self.calendar.dateInterval(of: .year, for: cursor)?.start ?? cursor) ?? end)
        let yearlyStart = min(max(firstFullYearStart, cursor), end)
        if cursor < yearlyStart {
            segments.append(TrafficQuerySegment(level: .month, interval: DateInterval(start: cursor, end: yearlyStart)))
            cursor = yearlyStart
        }

        var fullYearEnd = cursor
        while fullYearEnd < end,
              let yearInterval = self.calendar.dateInterval(of: .year, for: fullYearEnd),
              yearInterval.start == fullYearEnd,
              yearInterval.end <= end {
            fullYearEnd = yearInterval.end
        }
        if cursor < fullYearEnd {
            segments.append(TrafficQuerySegment(level: .year, interval: DateInterval(start: cursor, end: fullYearEnd)))
            cursor = fullYearEnd
        }
        if cursor < end {
            segments.append(TrafficQuerySegment(level: .month, interval: DateInterval(start: cursor, end: end)))
            cursor = end
        }
        return cursor
    }

    private func append(
        _ level: TrafficAggregationLevel,
        from cursor: inout Date,
        to end: Date,
        into segments: inout [TrafficQuerySegment]
    ) {
        guard cursor < end else { return }
        segments.append(TrafficQuerySegment(level: level, interval: DateInterval(start: cursor, end: end)))
        cursor = end
    }
}

public struct TrafficAnalyticsQuery: Equatable {
    public let range: TrafficRange
    public let networkFilter: NetworkKind?
    public let networkID: String?
    public let includeLocalNetwork: Bool
    public let applicationSearch: String
    public let selectedInterval: DateInterval?
    public let billingCycleDay: Int
    public let now: Date

    public init(
        range: TrafficRange,
        networkFilter: NetworkKind? = nil,
        networkID: String? = nil,
        includeLocalNetwork: Bool = true,
        applicationSearch: String = "",
        selectedInterval: DateInterval? = nil,
        billingCycleDay: Int = 1,
        now: Date = Date()
    ) {
        self.range = range
        self.networkFilter = networkFilter
        self.networkID = networkID
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
    private let retentionPolicy: TrafficRetentionPolicy
    private let alertStore: TrafficAlertStore

    public init(
        repository: TrafficHistoryRepository,
        calendar: Calendar = .current,
        retentionPolicy: TrafficRetentionPolicy = .standard,
        alertStore: TrafficAlertStore? = nil
    ) {
        self.repository = repository
        self.calendar = calendar
        self.retentionPolicy = retentionPolicy
        self.alertStore = alertStore ?? repository.runtimeAlertStore
    }

    public func snapshot(for query: TrafficAnalyticsQuery) -> TrafficAnalyticsSnapshot {
        let preset = TrafficAggregation.interval(
            for: query.range,
            now: query.now,
            calendar: self.calendar
        )
        let interval = query.selectedInterval ?? DateInterval(start: preset.start, end: preset.end)
        let effectiveRange = query.selectedInterval.map { TrafficCustomRange.range(for: $0.duration) } ?? query.range
        let halfOpenEnd = interval.end.addingTimeInterval(1)
        let plan = TrafficQueryPlanner(calendar: self.calendar).plan(
            interval: DateInterval(start: interval.start, end: halfOpenEnd),
            now: query.now,
            policy: self.retentionPolicy
        )
        var records = plan.segments.flatMap { segment in
            self.repository.fetchRecords(TrafficHistoryQuery(
                level: segment.level,
                start: segment.interval.start,
                end: segment.interval.end,
                endExclusive: true
            ))
        }

        if let networkID = query.networkID {
            // A concrete network is already one accounting layer. Do not drop a selected
            // tunnel merely because a physical sample exists in the same second.
            records = records.filter { $0.sample.network.id == networkID }
        } else {
            records = self.deduplicate(records)
            if let kind = query.networkFilter {
                records = records.filter { $0.sample.network.kind == kind }
            }
        }
        if !query.includeLocalNetwork {
            records = records.filter { $0.sample.network.kind != .other }
        }
        let samples = records.map(\.sample)
        let download = samples.reduce(UInt64(0)) { $0 + $1.delta.download }
        let upload = samples.reduce(UInt64(0)) { $0 + $1.delta.upload }
        let buckets = TrafficAggregation.buckets(
            samples: samples,
            range: effectiveRange,
            now: interval.end,
            calendar: self.calendar,
            interval: interval
        )
        let ranking = self.rank(records: records, search: query.applicationSearch)
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
            forecast: forecast,
            alerts: self.alertStore.all().filter { $0.timestamp >= interval.start && $0.timestamp <= interval.end }
        )
    }

    public func liveSnapshot(
        window: LiveTrafficWindow,
        applicationID: String? = nil,
        now: Date = Date()
    ) -> LiveTrafficSnapshot {
        let start = now.addingTimeInterval(-window.duration)
        var samples = self.repository.fetch(
            TrafficHistoryQuery(level: .second, start: start, end: now)
        )
        samples = self.deduplicate(samples)
        if let applicationID {
            samples = samples.filter { $0.application.id == applicationID }
        }

        var grouped: [Int64: (download: UInt64, upload: UInt64)] = [:]
        for sample in samples {
            let second = Int64(sample.timestamp.timeIntervalSince1970.rounded(.down))
            var value = grouped[second] ?? (0, 0)
            value.download += sample.delta.download
            value.upload += sample.delta.upload
            grouped[second] = value
        }
        let points = grouped.keys.sorted().map { second in
            let value = grouped[second]!
            return LiveTrafficPoint(
                timestamp: Date(timeIntervalSince1970: TimeInterval(second)),
                download: value.download,
                upload: value.upload
            )
        }

        let latestSecond = points.last.map { Int64($0.timestamp.timeIntervalSince1970) }
        let activeSamples: [TrafficSample]
        if let latestSecond {
            activeSamples = samples.filter {
                Int64($0.timestamp.timeIntervalSince1970.rounded(.down)) == latestSecond
            }
        } else {
            activeSamples = []
        }
        let latest = points.last

        return LiveTrafficSnapshot(
            window: window,
            applicationID: applicationID,
            downloadBytesPerSecond: latest?.download ?? 0,
            uploadBytesPerSecond: latest?.upload ?? 0,
            points: points,
            applications: self.rank(samples: samples),
            activeApplications: self.rank(samples: activeSamples)
        )
    }

    public func rank(samples: [TrafficSample], search: String = "") -> [ApplicationTrafficSummary] {
        self.rank(
            records: samples.map {
                StoredTrafficRecord(schema: .v2, level: .second, sample: $0, sampleCount: 1)
            },
            search: search
        )
    }

    public func rank(records: [StoredTrafficRecord], search: String = "") -> [ApplicationTrafficSummary] {
        var grouped: [String: (identity: ApplicationIdentity, download: UInt64, upload: UInt64, peak: UInt64, sampleCount: Int?, routes: [TrafficRouteContext], processes: [String: ProcessTrafficSummary])] = [:]

        for record in records {
            let sample = record.sample
            var bucket = grouped[sample.application.id] ?? (
                identity: sample.application,
                download: 0,
                upload: 0,
                peak: 0,
                sampleCount: 0,
                routes: [],
                processes: [:]
            )
            bucket.download += sample.delta.download
            bucket.upload += sample.delta.upload
            bucket.peak = max(bucket.peak, sample.peakBytesPerSecond)
            if let current = bucket.sampleCount, let count = record.sampleCount {
                bucket.sampleCount = current + count
            } else {
                bucket.sampleCount = nil
            }
            if !bucket.routes.contains(sample.routeContext) { bucket.routes.append(sample.routeContext) }

            let processSummaries = record.processSummaries ?? [
                StoredProcessTrafficSummary(
                    processDiscriminator: sample.processDiscriminator,
                    processID: sample.processID,
                    processName: sample.processName,
                    download: sample.delta.download,
                    upload: sample.delta.upload,
                    peakBytesPerSecond: sample.peakBytesPerSecond,
                    sampleCount: record.sampleCount,
                    identity: sample.processIdentity,
                    routeContexts: [sample.routeContext]
                )
            ]
            for summary in processSummaries {
                let processKey = summary.processDiscriminator.isEmpty
                    ? "legacy-pid:\(summary.processID)"
                    : summary.processDiscriminator
                let process = bucket.processes[processKey] ?? ProcessTrafficSummary(
                    processDiscriminator: summary.processDiscriminator.isEmpty ? nil : summary.processDiscriminator,
                    processID: summary.processID,
                    processName: summary.processName,
                    download: 0,
                    upload: 0,
                    peakBytesPerSecond: 0,
                    sampleCount: 0,
                    identity: summary.identity,
                    routeContexts: summary.routeContexts
                )
                bucket.processes[processKey] = ProcessTrafficSummary(
                    processDiscriminator: process.processDiscriminator,
                    processID: process.processID,
                    processName: process.processName,
                    download: process.download + summary.download,
                    upload: process.upload + summary.upload,
                    peakBytesPerSecond: max(process.peakBytesPerSecond, summary.peakBytesPerSecond),
                    sampleCount: process.sampleCount.flatMap { current in summary.sampleCount.map { current + $0 } },
                    identity: process.identity ?? summary.identity,
                    routeContexts: process.routeContexts + summary.routeContexts.filter { !process.routeContexts.contains($0) }
                )
            }
            grouped[sample.application.id] = bucket
        }

        let summaries = grouped.values.map {
            ApplicationTrafficSummary(
                identity: $0.identity,
                download: $0.download,
                upload: $0.upload,
                peakBytesPerSecond: $0.peak,
                processes: $0.processes.values.sorted {
                    if $0.processID == $1.processID {
                        return ($0.processDiscriminator ?? "") < ($1.processDiscriminator ?? "")
                    }
                    return $0.processID < $1.processID
                },
                routeContexts: $0.routes,
                sampleCount: $0.sampleCount
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
        self.deduplicate(
            samples,
            sample: { $0 }
        )
    }

    public func deduplicate(_ records: [StoredTrafficRecord]) -> [StoredTrafficRecord] {
        self.deduplicate(
            records,
            sample: { $0.sample }
        )
    }

    private func deduplicate<Value>(
        _ values: [Value],
        sample: (Value) -> TrafficSample
    ) -> [Value] {
        // Prefer physical interfaces when the same application reports traffic on both
        // tunnel and physical layers in the same second.
        var bySecondApp: [String: [Value]] = [:]
        for value in values {
            let traffic = sample(value)
            let second = Int64(traffic.timestamp.timeIntervalSince1970)
            let key = "\(second)|\(traffic.application.id)"
            bySecondApp[key, default: []].append(value)
        }

        var result: [Value] = []
        for group in bySecondApp.values {
            let hasTunnel = group.contains { sample($0).network.kind == .tunnel }
            let hasPhysical = group.contains {
                let kind = sample($0).network.kind
                return kind == .wifi || kind == .ethernet || kind == .hotspot
            }
            if hasTunnel && hasPhysical {
                result.append(contentsOf: group.filter { sample($0).network.kind != .tunnel })
            } else {
                result.append(contentsOf: group)
            }
        }
        return result.sorted { sample($0).timestamp < sample($1).timestamp }
    }

    private func billingPeriod(containing date: Date, cycleDay: Int) -> DateInterval {
        let requestedDay = min(max(cycleDay, 1), 31)
        let monthAnchor = self.calendar.date(from: self.calendar.dateComponents([.year, .month], from: date))
            ?? self.calendar.startOfDay(for: date)
        let thisCycle = self.cycleDate(monthAnchor: monthAnchor, requestedDay: requestedDay)
        if date >= thisCycle {
            let nextMonth = self.calendar.date(byAdding: .month, value: 1, to: monthAnchor)
                ?? monthAnchor.addingTimeInterval(31 * 86_400)
            return DateInterval(start: thisCycle, end: self.cycleDate(monthAnchor: nextMonth, requestedDay: requestedDay))
        }
        let previousMonth = self.calendar.date(byAdding: .month, value: -1, to: monthAnchor)
            ?? monthAnchor.addingTimeInterval(-31 * 86_400)
        return DateInterval(start: self.cycleDate(monthAnchor: previousMonth, requestedDay: requestedDay), end: thisCycle)
    }

    private func cycleDate(monthAnchor: Date, requestedDay: Int) -> Date {
        let availableDays = self.calendar.range(of: .day, in: .month, for: monthAnchor)?.count ?? 28
        var components = self.calendar.dateComponents([.year, .month], from: monthAnchor)
        components.day = min(requestedDay, availableDays)
        return self.calendar.date(from: components) ?? monthAnchor
    }
}

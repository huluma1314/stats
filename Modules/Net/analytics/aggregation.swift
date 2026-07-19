//
//  aggregation.swift
//  Net
//

import Foundation

public enum TrafficRange: String, Codable, CaseIterable {
    case tenMinutes
    case oneHour
    case today
    case sevenDays
    case thirtyDays
    case currentMonth
}

public enum HeatmapBucketKind: String, Codable, Equatable {
    case thirtySeconds
    case fiveMinutes
    case oneHour
    case weekdayHour
    case oneDay
}

public struct TrafficRetentionPolicy: Equatable {
    public static let secondRetention: TimeInterval = 24 * 60 * 60

    public let minuteRetentionDays: Int
    public let hourRetentionDays: Int
    public let dayRetentionDays: Int
    public let compactionBatchSize: Int

    public static let standard = TrafficRetentionPolicy(
        minuteRetentionDays: 7,
        hourRetentionDays: 60,
        dayRetentionDays: 730,
        compactionBatchSize: 2_000
    )

    public init(
        minuteRetentionDays: Int,
        hourRetentionDays: Int,
        dayRetentionDays: Int,
        compactionBatchSize: Int = 2_000
    ) {
        self.minuteRetentionDays = max(1, minuteRetentionDays)
        self.hourRetentionDays = max(1, hourRetentionDays)
        self.dayRetentionDays = max(1, dayRetentionDays)
        self.compactionBatchSize = max(1, compactionBatchSize)
    }

    public init(preferences: TrafficAnalyticsPreferences, compactionBatchSize: Int = 2_000) {
        self.init(
            minuteRetentionDays: preferences.minuteRetentionDays,
            hourRetentionDays: preferences.hourRetentionDays,
            dayRetentionDays: preferences.dayRetentionDays,
            compactionBatchSize: compactionBatchSize
        )
    }
}

public enum TrafficAggregation {
    public static func heatmapKind(for range: TrafficRange) -> HeatmapBucketKind {
        switch range {
        case .tenMinutes: return .thirtySeconds
        case .oneHour: return .fiveMinutes
        case .today: return .oneHour
        case .sevenDays: return .weekdayHour
        case .thirtyDays, .currentMonth: return .oneDay
        }
    }

    public static func bucketDuration(for kind: HeatmapBucketKind) -> TimeInterval {
        switch kind {
        case .thirtySeconds: return 30
        case .fiveMinutes: return 5 * 60
        case .oneHour: return 60 * 60
        case .weekdayHour: return 60 * 60
        case .oneDay: return 24 * 60 * 60
        }
    }

    public static func interval(
        for range: TrafficRange,
        now: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        switch range {
        case .tenMinutes:
            return (now.addingTimeInterval(-10 * 60), now)
        case .oneHour:
            return (now.addingTimeInterval(-60 * 60), now)
        case .today:
            let start = calendar.startOfDay(for: now)
            return (start, now)
        case .sevenDays:
            return (now.addingTimeInterval(-7 * 24 * 60 * 60), now)
        case .thirtyDays:
            return (now.addingTimeInterval(-30 * 24 * 60 * 60), now)
        case .currentMonth:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let start = calendar.date(from: comps) ?? calendar.startOfDay(for: now)
            return (start, now)
        }
    }

    public static func floor(
        _ date: Date,
        to kind: HeatmapBucketKind,
        calendar: Calendar
    ) -> Date {
        switch kind {
        case .thirtySeconds:
            let seconds = Int(date.timeIntervalSince1970)
            return Date(timeIntervalSince1970: TimeInterval(seconds - (seconds % 30)))
        case .fiveMinutes:
            let seconds = Int(date.timeIntervalSince1970)
            return Date(timeIntervalSince1970: TimeInterval(seconds - (seconds % 300)))
        case .oneHour, .weekdayHour:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .oneDay:
            return calendar.startOfDay(for: date)
        }
    }

    public static func buckets(
        samples: [TrafficSample],
        range: TrafficRange,
        now: Date,
        calendar: Calendar,
        interval customInterval: DateInterval? = nil
    ) -> [TrafficBucket] {
        let kind = self.heatmapKind(for: range)
        let preset = self.interval(for: range, now: now, calendar: calendar)
        let interval = customInterval ?? DateInterval(start: preset.start, end: preset.end)
        var grouped: [Date: (download: UInt64, upload: UInt64, peak: UInt64, count: Int)] = [:]

        for sample in samples where sample.timestamp >= interval.start && sample.timestamp <= interval.end {
            let start = self.floor(sample.timestamp, to: kind, calendar: calendar)
            var value = grouped[start] ?? (0, 0, 0, 0)
            value.download += sample.delta.download
            value.upload += sample.delta.upload
            value.peak = max(value.peak, sample.peakBytesPerSecond)
            value.count += 1
            grouped[start] = value
        }

        let duration = self.bucketDuration(for: kind)
        return grouped.keys.sorted().map { start in
            let value = grouped[start]!
            return TrafficBucket(
                start: start,
                end: start.addingTimeInterval(duration),
                download: value.download,
                upload: value.upload,
                peakBytesPerSecond: value.peak,
                sampleCount: value.count
            )
        }
    }

    public static func compact(
        repository: TrafficHistoryRepository,
        now: Date = Date(),
        policy: TrafficRetentionPolicy = .standard,
        calendar: Calendar = .current
    ) throws {
        let secondCutoff = now.addingTimeInterval(-TrafficRetentionPolicy.secondRetention)
        let minuteCutoff = calendar.date(byAdding: .day, value: -policy.minuteRetentionDays, to: now)
            ?? now.addingTimeInterval(-TimeInterval(policy.minuteRetentionDays) * 86_400)
        let hourCutoff = calendar.date(byAdding: .day, value: -policy.hourRetentionDays, to: now)
            ?? now.addingTimeInterval(-TimeInterval(policy.hourRetentionDays) * 86_400)
        let dayCutoff = calendar.date(byAdding: .day, value: -policy.dayRetentionDays, to: now)
            ?? now.addingTimeInterval(-TimeInterval(policy.dayRetentionDays) * 86_400)

        try self.compactLevel(
            repository: repository,
            source: .second,
            destination: .minute,
            cutoff: secondCutoff,
            batchSize: policy.compactionBatchSize,
            calendar: calendar,
            deleteSources: true
        )
        try self.compactLevel(
            repository: repository,
            source: .minute,
            destination: .hour,
            cutoff: minuteCutoff,
            batchSize: policy.compactionBatchSize,
            calendar: calendar,
            deleteSources: true
        )
        try self.compactLevel(
            repository: repository,
            source: .hour,
            destination: .day,
            cutoff: hourCutoff,
            batchSize: policy.compactionBatchSize,
            calendar: calendar,
            deleteSources: true
        )
        try self.compactLevel(
            repository: repository,
            source: .day,
            destination: .month,
            cutoff: dayCutoff,
            batchSize: policy.compactionBatchSize,
            calendar: calendar,
            deleteSources: true
        )
        try self.buildCompletedYears(
            repository: repository,
            now: now,
            batchSize: policy.compactionBatchSize,
            calendar: calendar
        )
    }

    private struct CompactionBucketKey: Hashable {
        let start: Date
        let networkID: String
        let applicationID: String
    }

    private static func compactLevel(
        repository: TrafficHistoryRepository,
        source: TrafficAggregationLevel,
        destination: TrafficAggregationLevel,
        cutoff: Date,
        batchSize: Int,
        calendar: Calendar,
        deleteSources: Bool
    ) throws {
        let sourceRows = repository.recordsWithKeys(TrafficHistoryQuery(
            level: source,
            start: Date.distantPast,
            end: cutoff,
            endExclusive: true
        ))
        guard !sourceRows.isEmpty else { return }

        let groupedByTime = Dictionary(grouping: sourceRows) { row in
            self.bucketInterval(for: row.record.sample.timestamp, level: destination, calendar: calendar).start
        }
        let eligible = groupedByTime.compactMap { start, rows -> (Date, [(key: String, record: StoredTrafficRecord)])? in
            let end = self.bucketInterval(for: start, level: destination, calendar: calendar).end
            return end <= cutoff ? (start, rows) : nil
        }.sorted { $0.0 < $1.0 }

        var admittedCount = 0
        for (_, rows) in eligible {
            guard admittedCount < batchSize else { break }
            let groupedRecords = Dictionary(grouping: rows, by: { row -> CompactionBucketKey in
                let sample = row.record.sample
                return CompactionBucketKey(
                    start: self.bucketInterval(for: sample.timestamp, level: destination, calendar: calendar).start,
                    networkID: sample.network.id,
                    applicationID: sample.application.id
                )
            })
            let aggregates = groupedRecords.values.flatMap { group in
                self.aggregate(records: group.map(\.record), level: destination, calendar: calendar)
            }
            let deletes = deleteSources ? rows.map(\.key) : []
            try repository.replaceAtomically(records: aggregates, deleting: deletes)
            admittedCount += rows.count
        }
    }

    private static func buildCompletedYears(
        repository: TrafficHistoryRepository,
        now: Date,
        batchSize: Int,
        calendar: Calendar
    ) throws {
        let currentYearStart = self.bucketInterval(for: now, level: .year, calendar: calendar).start
        let months = repository.recordsWithKeys(TrafficHistoryQuery(
            level: .month,
            start: Date.distantPast,
            end: currentYearStart,
            endExclusive: true
        ))
        guard !months.isEmpty else { return }

        let existingYears = repository.fetchRecords(TrafficHistoryQuery(
            level: .year,
            start: Date.distantPast,
            end: currentYearStart,
            endExclusive: true
        ))
        let existingKeys = Set(existingYears.map {
            CompactionBucketKey(
                start: $0.sample.timestamp,
                networkID: $0.sample.network.id,
                applicationID: $0.sample.application.id
            )
        })
        let grouped = Dictionary(grouping: months) { row -> CompactionBucketKey in
            let sample = row.record.sample
            return CompactionBucketKey(
                start: self.bucketInterval(for: sample.timestamp, level: .year, calendar: calendar).start,
                networkID: sample.network.id,
                applicationID: sample.application.id
            )
        }
        let groupedByYear = Dictionary(grouping: grouped, by: { $0.key.start })
        var admittedCount = 0
        for (yearStart, yearGroups) in groupedByYear.sorted(by: { $0.key < $1.key }) {
            guard admittedCount < batchSize else { break }
            let end = self.bucketInterval(for: yearStart, level: .year, calendar: calendar).end
            guard end <= currentYearStart else { continue }
            let newGroups = yearGroups.filter { !existingKeys.contains($0.key) }
            guard !newGroups.isEmpty else { continue }
            let aggregate = newGroups.flatMap { group in
                self.aggregate(records: group.value.map(\.record), level: .year, calendar: calendar)
            }
            try repository.storeAtomically(records: aggregate)
            admittedCount += newGroups.reduce(0) { $0 + $1.value.count }
        }
    }

    public static func bucketInterval(
        for date: Date,
        level: TrafficAggregationLevel,
        calendar: Calendar
    ) -> DateInterval {
        switch level {
        case .second:
            let start = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
            return DateInterval(start: start, end: start.addingTimeInterval(1))
        case .minute:
            let seconds = (date.timeIntervalSince1970 / 60).rounded(.down) * 60
            let start = Date(timeIntervalSince1970: seconds)
            return DateInterval(start: start, end: start.addingTimeInterval(60))
        case .hour:
            if let interval = calendar.dateInterval(of: .hour, for: date) { return interval }
        case .day:
            if let interval = calendar.dateInterval(of: .day, for: date) { return interval }
        case .month:
            if let interval = calendar.dateInterval(of: .month, for: date) { return interval }
        case .year:
            if let interval = calendar.dateInterval(of: .year, for: date) { return interval }
        }
        return DateInterval(start: date, end: date)
    }

    public static func aggregate(
        samples: [TrafficSample],
        level: TrafficAggregationLevel,
        calendar: Calendar
    ) -> [TrafficSample] {
        var grouped: [String: TrafficSample] = [:]
        for sample in samples {
            let bucketStart = self.bucketInterval(for: sample.timestamp, level: level, calendar: calendar).start

            let key = "\(bucketStart.timeIntervalSince1970)|\(sample.network.id)|\(sample.application.id)"
            if var existing = grouped[key] {
                existing = TrafficSample(
                    timestamp: bucketStart,
                    application: existing.application,
                    network: existing.network,
                    processID: existing.processID,
                    processName: existing.processName,
                    delta: TrafficDelta(
                        download: existing.delta.download + sample.delta.download,
                        upload: existing.delta.upload + sample.delta.upload
                    ),
                    peakBytesPerSecond: max(existing.peakBytesPerSecond, sample.peakBytesPerSecond),
                    routeContext: self.mergedRoute(existing.routeContext, sample.routeContext),
                    processIdentity: existing.processIdentity ?? sample.processIdentity
                )
                grouped[key] = existing
            } else {
                grouped[key] = TrafficSample(
                    timestamp: bucketStart,
                    application: sample.application,
                    network: sample.network,
                    processID: sample.processID,
                    processName: sample.processName,
                    delta: sample.delta,
                    peakBytesPerSecond: sample.peakBytesPerSecond,
                    routeContext: sample.routeContext,
                    processIdentity: sample.processIdentity
                )
            }
        }
        return grouped.values.sorted { $0.timestamp < $1.timestamp }
    }

    public static func aggregate(
        records: [StoredTrafficRecord],
        level: TrafficAggregationLevel,
        calendar: Calendar
    ) -> [StoredTrafficRecord] {
        struct Group {
            var sample: TrafficSample
            var sampleCount: Int?
            var processes: [String: StoredProcessTrafficSummary]
        }

        var grouped: [String: Group] = [:]
        for record in records {
            guard let bucketSample = self.aggregate(samples: [record.sample], level: level, calendar: calendar).first else { continue }
            let key = "\(bucketSample.timestamp.timeIntervalSince1970)|\(bucketSample.network.id)|\(bucketSample.application.id)"
            let sourceProcesses = record.processSummaries ?? [
                StoredProcessTrafficSummary(
                    processDiscriminator: record.sample.processDiscriminator,
                    processID: record.sample.processID,
                    processName: record.sample.processName,
                    download: record.sample.delta.download,
                    upload: record.sample.delta.upload,
                    peakBytesPerSecond: record.sample.peakBytesPerSecond,
                    sampleCount: record.sampleCount,
                    identity: record.sample.processIdentity,
                    routeContexts: [record.sample.routeContext]
                )
            ]

            if var group = grouped[key] {
                group.sample = TrafficSample(
                    timestamp: bucketSample.timestamp,
                    application: group.sample.application,
                    network: group.sample.network,
                    processID: group.sample.processID,
                    processName: group.sample.processName,
                    processStartToken: group.sample.processStartToken,
                    processDiscriminator: group.sample.processDiscriminator,
                    delta: TrafficDelta(
                        download: group.sample.delta.download + record.sample.delta.download,
                        upload: group.sample.delta.upload + record.sample.delta.upload
                    ),
                    peakBytesPerSecond: max(group.sample.peakBytesPerSecond, record.sample.peakBytesPerSecond),
                    routeContext: self.mergedRoute(group.sample.routeContext, record.sample.routeContext),
                    processIdentity: group.sample.processIdentity ?? record.sample.processIdentity
                )
                group.sampleCount = self.mergedCount(group.sampleCount, record.sampleCount)
                for process in sourceProcesses {
                    if let existing = group.processes[process.processDiscriminator] {
                        group.processes[process.processDiscriminator] = StoredProcessTrafficSummary(
                            processDiscriminator: process.processDiscriminator,
                            processID: process.processID,
                            processName: process.processName,
                            download: existing.download + process.download,
                            upload: existing.upload + process.upload,
                            peakBytesPerSecond: max(existing.peakBytesPerSecond, process.peakBytesPerSecond),
                            sampleCount: self.mergedCount(existing.sampleCount, process.sampleCount),
                            identity: existing.identity ?? process.identity,
                            routeContexts: self.mergedRoutes(existing.routeContexts, process.routeContexts)
                        )
                    } else {
                        group.processes[process.processDiscriminator] = process
                    }
                }
                grouped[key] = group
            } else {
                grouped[key] = Group(
                    sample: bucketSample,
                    sampleCount: record.sampleCount,
                    processes: Dictionary(uniqueKeysWithValues: sourceProcesses.map { ($0.processDiscriminator, $0) })
                )
            }
        }

        return grouped.values.map { group in
            StoredTrafficRecord(
                schema: .v2,
                level: level,
                sample: group.sample,
                sampleCount: group.sampleCount,
                processSummaries: group.processes.values.sorted { $0.processDiscriminator < $1.processDiscriminator }
            )
        }.sorted { $0.sample.timestamp < $1.sample.timestamp }
    }

    static func merge(
        _ existing: StoredTrafficRecord,
        _ contribution: StoredTrafficRecord,
        level: TrafficAggregationLevel
    ) -> StoredTrafficRecord {
        let sample = TrafficSample(
            timestamp: contribution.sample.timestamp,
            application: existing.sample.application,
            network: existing.sample.network,
            processID: existing.sample.processID,
            processName: existing.sample.processName,
            processStartToken: existing.sample.processStartToken,
            processDiscriminator: existing.sample.processDiscriminator,
            delta: TrafficDelta(
                download: existing.sample.delta.download + contribution.sample.delta.download,
                upload: existing.sample.delta.upload + contribution.sample.delta.upload
            ),
            peakBytesPerSecond: max(existing.sample.peakBytesPerSecond, contribution.sample.peakBytesPerSecond),
            routeContext: self.mergedRoute(existing.sample.routeContext, contribution.sample.routeContext),
            processIdentity: existing.sample.processIdentity ?? contribution.sample.processIdentity
        )
        var processes: [String: StoredProcessTrafficSummary] = [:]
        for process in self.processSummaries(for: existing) + self.processSummaries(for: contribution) {
            if let current = processes[process.processDiscriminator] {
                processes[process.processDiscriminator] = StoredProcessTrafficSummary(
                    processDiscriminator: current.processDiscriminator,
                    processID: current.processID,
                    processName: current.processName,
                    download: current.download + process.download,
                    upload: current.upload + process.upload,
                    peakBytesPerSecond: max(current.peakBytesPerSecond, process.peakBytesPerSecond),
                    sampleCount: self.mergedCount(current.sampleCount, process.sampleCount),
                    identity: current.identity ?? process.identity,
                    routeContexts: self.mergedRoutes(current.routeContexts, process.routeContexts)
                )
            } else {
                processes[process.processDiscriminator] = process
            }
        }

        return StoredTrafficRecord(
            schema: .v2,
            level: level,
            sample: sample,
            sampleCount: self.mergedCount(existing.sampleCount, contribution.sampleCount),
            processSummaries: processes.values.sorted { $0.processDiscriminator < $1.processDiscriminator }
        )
    }

    private static func mergedRoute(_ lhs: TrafficRouteContext, _ rhs: TrafficRouteContext) -> TrafficRouteContext {
        if lhs.kind == .tunnel || rhs.kind == .tunnel { return lhs.kind == .tunnel ? lhs : rhs }
        if lhs.kind == .systemProxy || rhs.kind == .systemProxy { return lhs.kind == .systemProxy ? lhs : rhs }
        return lhs
    }

    private static func processSummaries(for record: StoredTrafficRecord) -> [StoredProcessTrafficSummary] {
        record.processSummaries ?? [
            StoredProcessTrafficSummary(
                processDiscriminator: record.sample.processDiscriminator,
                processID: record.sample.processID,
                processName: record.sample.processName,
                download: record.sample.delta.download,
                upload: record.sample.delta.upload,
                peakBytesPerSecond: record.sample.peakBytesPerSecond,
                sampleCount: record.sampleCount,
                identity: record.sample.processIdentity,
                routeContexts: [record.sample.routeContext]
            )
        ]
    }

    private static func mergedCount(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }

    private static func mergedRoutes(_ lhs: [TrafficRouteContext], _ rhs: [TrafficRouteContext]) -> [TrafficRouteContext] {
        lhs + rhs.filter { !lhs.contains($0) }
    }
}

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
    public let secondRetention: TimeInterval
    public let minuteRetention: TimeInterval
    public let hourRetention: TimeInterval

    public static let standard = TrafficRetentionPolicy(
        secondRetention: 24 * 60 * 60,
        minuteRetention: 30 * 24 * 60 * 60,
        hourRetention: 2 * 365 * 24 * 60 * 60
    )

    public init(
        secondRetention: TimeInterval,
        minuteRetention: TimeInterval,
        hourRetention: TimeInterval
    ) {
        self.secondRetention = secondRetention
        self.minuteRetention = minuteRetention
        self.hourRetention = hourRetention
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
        let secondCutoff = now.addingTimeInterval(-policy.secondRetention)
        let minuteCutoff = now.addingTimeInterval(-policy.minuteRetention)
        let hourCutoff = now.addingTimeInterval(-policy.hourRetention)

        let secondQuery = TrafficHistoryQuery(
            level: .second,
            start: Date(timeIntervalSince1970: 0),
            end: secondCutoff
        )
        let oldSeconds = repository.fetchRecords(secondQuery)
        if !oldSeconds.isEmpty {
            try repository.replaceAtomically(
                records: self.aggregate(records: oldSeconds, level: .minute, calendar: calendar),
                deleting: secondQuery
            )
        }

        let minuteQuery = TrafficHistoryQuery(
            level: .minute,
            start: Date(timeIntervalSince1970: 0),
            end: minuteCutoff
        )
        let oldMinutes = repository.fetchRecords(minuteQuery)
        if !oldMinutes.isEmpty {
            try repository.replaceAtomically(
                records: self.aggregate(records: oldMinutes, level: .hour, calendar: calendar),
                deleting: minuteQuery
            )
        }

        let hourQuery = TrafficHistoryQuery(
            level: .hour,
            start: Date(timeIntervalSince1970: 0),
            end: hourCutoff
        )
        let oldHours = repository.fetchRecords(hourQuery)
        if !oldHours.isEmpty {
            try repository.replaceAtomically(
                records: self.aggregate(records: oldHours, level: .month, calendar: calendar),
                deleting: hourQuery
            )
        }
    }

    public static func aggregate(
        samples: [TrafficSample],
        level: TrafficAggregationLevel,
        calendar: Calendar
    ) -> [TrafficSample] {
        var grouped: [String: TrafficSample] = [:]
        for sample in samples {
            let bucketStart: Date
            switch level {
            case .second:
                bucketStart = sample.timestamp
            case .minute:
                let seconds = Int(sample.timestamp.timeIntervalSince1970)
                bucketStart = Date(timeIntervalSince1970: TimeInterval(seconds - (seconds % 60)))
            case .hour:
                bucketStart = calendar.dateInterval(of: .hour, for: sample.timestamp)?.start ?? sample.timestamp
            case .day:
                bucketStart = calendar.startOfDay(for: sample.timestamp)
            case .month:
                let comps = calendar.dateComponents([.year, .month], from: sample.timestamp)
                bucketStart = calendar.date(from: comps) ?? sample.timestamp
            case .year:
                let comps = calendar.dateComponents([.year], from: sample.timestamp)
                bucketStart = calendar.date(from: comps) ?? sample.timestamp
            }

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
                    peakBytesPerSecond: max(existing.peakBytesPerSecond, sample.peakBytesPerSecond)
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
                    peakBytesPerSecond: sample.peakBytesPerSecond
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
                    sampleCount: record.sampleCount
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
                    peakBytesPerSecond: max(group.sample.peakBytesPerSecond, record.sample.peakBytesPerSecond)
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
                            sampleCount: self.mergedCount(existing.sampleCount, process.sampleCount)
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
            peakBytesPerSecond: max(existing.sample.peakBytesPerSecond, contribution.sample.peakBytesPerSecond)
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
                    sampleCount: self.mergedCount(current.sampleCount, process.sampleCount)
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

    private static func processSummaries(for record: StoredTrafficRecord) -> [StoredProcessTrafficSummary] {
        record.processSummaries ?? [
            StoredProcessTrafficSummary(
                processDiscriminator: record.sample.processDiscriminator,
                processID: record.sample.processID,
                processName: record.sample.processName,
                download: record.sample.delta.download,
                upload: record.sample.delta.upload,
                peakBytesPerSecond: record.sample.peakBytesPerSecond,
                sampleCount: record.sampleCount
            )
        ]
    }

    private static func mergedCount(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard let lhs, let rhs else { return nil }
        return lhs + rhs
    }
}

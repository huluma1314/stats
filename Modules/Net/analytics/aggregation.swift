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
        calendar: Calendar
    ) -> [TrafficBucket] {
        let kind = self.heatmapKind(for: range)
        let interval = self.interval(for: range, now: now, calendar: calendar)
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
    ) {
        let secondCutoff = now.addingTimeInterval(-policy.secondRetention)
        let minuteCutoff = now.addingTimeInterval(-policy.minuteRetention)
        let hourCutoff = now.addingTimeInterval(-policy.hourRetention)

        let oldSeconds = repository.fetch(
            TrafficHistoryQuery(
                level: .second,
                start: Date(timeIntervalSince1970: 0),
                end: secondCutoff
            )
        )
        if !oldSeconds.isEmpty {
            let minuteSamples = self.aggregate(samples: oldSeconds, level: .minute, calendar: calendar)
            repository.replace(level: .minute, samples: minuteSamples)
            let keys = oldSeconds.map {
                TrafficHistoryRepository.makeKey(
                    level: .second,
                    timestamp: $0.timestamp,
                    networkID: $0.network.id,
                    applicationID: $0.application.id
                )
            }
            repository.delete(keys: keys)
        }

        let oldMinutes = repository.fetch(
            TrafficHistoryQuery(
                level: .minute,
                start: Date(timeIntervalSince1970: 0),
                end: minuteCutoff
            )
        )
        if !oldMinutes.isEmpty {
            let hourSamples = self.aggregate(samples: oldMinutes, level: .hour, calendar: calendar)
            repository.replace(level: .hour, samples: hourSamples)
            let keys = oldMinutes.map {
                TrafficHistoryRepository.makeKey(
                    level: .minute,
                    timestamp: $0.timestamp,
                    networkID: $0.network.id,
                    applicationID: $0.application.id
                )
            }
            repository.delete(keys: keys)
        }

        let oldHours = repository.fetch(
            TrafficHistoryQuery(
                level: .hour,
                start: Date(timeIntervalSince1970: 0),
                end: hourCutoff
            )
        )
        if !oldHours.isEmpty {
            let monthSamples = self.aggregate(samples: oldHours, level: .month, calendar: calendar)
            repository.replace(level: .month, samples: monthSamples)
            // Permanent monthly summaries keep source hours only after the hour cutoff.
            let keys = oldHours.map {
                TrafficHistoryRepository.makeKey(
                    level: .hour,
                    timestamp: $0.timestamp,
                    networkID: $0.network.id,
                    applicationID: $0.application.id
                )
            }
            repository.delete(keys: keys)
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
                    delta: sample.delta,
                    peakBytesPerSecond: sample.peakBytesPerSecond
                )
            }
        }
        return grouped.values.sorted { $0.timestamp < $1.timestamp }
    }
}

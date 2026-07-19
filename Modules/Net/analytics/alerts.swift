//
//  alerts.swift
//  Net
//

import Foundation

public enum TrafficAlertKind: String, Codable, CaseIterable {
    case quota
    case sustainedUpload
    case baselineSpike
    case connectivity
}

public enum TrafficAlertSeverity: String, Codable, CaseIterable {
    case info
    case warning
    case critical
}

public struct TrafficAlertEvent: Codable, Equatable {
    public let id: String
    public let kind: TrafficAlertKind
    public let timestamp: Date
    public let message: String
    public let applicationID: String?
    public let networkID: String?
    public let severity: TrafficAlertSeverity
    public let measuredValue: UInt64?
    public let thresholdValue: UInt64?
    public let baselineValue: UInt64?
    public let duration: TimeInterval?
    public let deduplicationKey: String

    public init(
        id: String = UUID().uuidString,
        kind: TrafficAlertKind,
        timestamp: Date = Date(),
        message: String,
        applicationID: String? = nil,
        networkID: String? = nil,
        severity: TrafficAlertSeverity = .warning,
        measuredValue: UInt64? = nil,
        thresholdValue: UInt64? = nil,
        baselineValue: UInt64? = nil,
        duration: TimeInterval? = nil,
        deduplicationKey: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.message = message
        self.applicationID = applicationID
        self.networkID = networkID
        self.severity = severity
        self.measuredValue = measuredValue
        self.thresholdValue = thresholdValue
        self.baselineValue = baselineValue
        self.duration = duration
        self.deduplicationKey = deduplicationKey ?? "\(kind.rawValue)|\(message)|\(applicationID ?? "")|\(networkID ?? "")|\(thresholdValue.map(String.init) ?? "")"
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, timestamp, message, applicationID, networkID, severity, measuredValue, thresholdValue, baselineValue, duration, deduplicationKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.kind = try container.decode(TrafficAlertKind.self, forKey: .kind)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.message = try container.decode(String.self, forKey: .message)
        self.applicationID = try container.decodeIfPresent(String.self, forKey: .applicationID)
        self.networkID = try container.decodeIfPresent(String.self, forKey: .networkID)
        self.severity = try container.decodeIfPresent(TrafficAlertSeverity.self, forKey: .severity) ?? .warning
        self.measuredValue = try container.decodeIfPresent(UInt64.self, forKey: .measuredValue)
        self.thresholdValue = try container.decodeIfPresent(UInt64.self, forKey: .thresholdValue)
        self.baselineValue = try container.decodeIfPresent(UInt64.self, forKey: .baselineValue)
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.deduplicationKey = try container.decodeIfPresent(String.self, forKey: .deduplicationKey)
            ?? "\(self.kind.rawValue)|\(self.message)|\(self.applicationID ?? "")|\(self.networkID ?? "")|\(self.thresholdValue.map(String.init) ?? "")"
    }
}

public struct TrafficAnomalyDetector {
    public var sustainedUploadBytesPerSecond: UInt64
    public var sustainedDurationSeconds: TimeInterval
    public var spikeMultiplier: Double
    public var minimumBaselineBytes: UInt64

    public init(
        sustainedUploadBytesPerSecond: UInt64 = 1_000_000,
        sustainedDurationSeconds: TimeInterval = 60,
        spikeMultiplier: Double = 3,
        minimumBaselineBytes: UInt64 = 10_000_000
    ) {
        self.sustainedUploadBytesPerSecond = sustainedUploadBytesPerSecond
        self.sustainedDurationSeconds = sustainedDurationSeconds
        self.spikeMultiplier = spikeMultiplier
        self.minimumBaselineBytes = minimumBaselineBytes
    }

    public func evaluate(
        recentSamples: [TrafficSample],
        priorComparableBuckets: [TrafficBucket],
        connectivityOnline: Bool?,
        previousConnectivityOnline: Bool?,
        disconnectCountLastHour: Int
    ) -> [TrafficAlertEvent] {
        guard priorComparableBuckets.count >= 7 else {
            return self.evaluate(
                recentSamples: recentSamples,
                baselineAverageBytes: nil,
                connectivityOnline: connectivityOnline,
                previousConnectivityOnline: previousConnectivityOnline,
                disconnectCountLastHour: disconnectCountLastHour
            )
        }
        let baseline = priorComparableBuckets.reduce(UInt64(0)) { $0 + $1.download + $1.upload } / UInt64(priorComparableBuckets.count)
        return self.evaluate(
            recentSamples: recentSamples,
            baselineAverageBytes: baseline,
            connectivityOnline: connectivityOnline,
            previousConnectivityOnline: previousConnectivityOnline,
            disconnectCountLastHour: disconnectCountLastHour
        )
    }

    public func evaluate(
        recentSamples: [TrafficSample],
        baselineAverageBytes: UInt64?,
        connectivityOnline: Bool?,
        previousConnectivityOnline: Bool?,
        disconnectCountLastHour: Int
    ) -> [TrafficAlertEvent] {
        var events: [TrafficAlertEvent] = []

        if let last = recentSamples.last {
            let window = recentSamples.filter {
                last.timestamp.timeIntervalSince($0.timestamp) <= self.sustainedDurationSeconds
            }.sorted { $0.timestamp < $1.timestamp }
            if let first = window.first,
               last.timestamp.timeIntervalSince(first.timestamp) >= self.sustainedDurationSeconds {
                let totalUpload = window.reduce(UInt64(0)) { $0 + $1.delta.upload }
                let elapsed = max(last.timestamp.timeIntervalSince(first.timestamp), 1)
                let average = UInt64(Double(totalUpload) / elapsed)
                if average >= self.sustainedUploadBytesPerSecond {
                    events.append(
                        TrafficAlertEvent(
                            kind: .sustainedUpload,
                            timestamp: last.timestamp,
                            message: "Sustained upload from \(last.application.displayName)",
                            applicationID: last.application.id,
                            networkID: last.network.id,
                            severity: .warning,
                            measuredValue: average,
                            thresholdValue: self.sustainedUploadBytesPerSecond,
                            duration: elapsed
                        )
                    )
                }
            }

            if let baselineAverageBytes, baselineAverageBytes >= self.minimumBaselineBytes {
                let current = last.delta.total
                if Double(current) >= Double(baselineAverageBytes) * self.spikeMultiplier {
                    events.append(
                        TrafficAlertEvent(
                            kind: .baselineSpike,
                            timestamp: last.timestamp,
                            message: "Traffic spike for \(last.application.displayName)",
                            applicationID: last.application.id,
                            networkID: last.network.id,
                            severity: .warning,
                            measuredValue: current,
                            thresholdValue: UInt64(Double(baselineAverageBytes) * self.spikeMultiplier),
                            baselineValue: baselineAverageBytes
                        )
                    )
                }
            } else if baselineAverageBytes == nil {
                // insufficient data: no spike alert
            }
        }

        if let connectivityOnline, let previousConnectivityOnline {
            if connectivityOnline != previousConnectivityOnline {
                events.append(
                    TrafficAlertEvent(
                        kind: .connectivity,
                        message: connectivityOnline ? "Network recovered" : "Network disconnected"
                    )
                )
            }
        }
        if disconnectCountLastHour >= 3 {
            events.append(
                TrafficAlertEvent(
                    kind: .connectivity,
                    message: "Network is unstable"
                )
            )
        }

        return self.deduplicate(events)
    }

    public func deduplicate(_ events: [TrafficAlertEvent]) -> [TrafficAlertEvent] {
        var seen = Set<String>()
        var result: [TrafficAlertEvent] = []
        for event in events {
            let key = event.deduplicationKey
            if seen.insert(key).inserted {
                result.append(event)
            }
        }
        return result
    }

    public func timelineMarkers(from events: [TrafficAlertEvent]) -> [Date] {
        events.map(\.timestamp).sorted()
    }
}

public final class TrafficAlertStore {
    public static let storageKey = "net.analytics.alerts.v1"
    public static let eventPrefix = "net.analytics.v2|alert|event|"
    public static let cooldownPrefix = "net.analytics.v2|alert|cooldown|"

    private let defaults: UserDefaults?
    private let store: TrafficKeyValueStoring?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.store = nil
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public init(store: TrafficKeyValueStoring) {
        self.defaults = nil
        self.store = store
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func all() -> [TrafficAlertEvent] {
        let events: [TrafficAlertEvent]
        if let store {
            events = store.values(prefix: Self.eventPrefix).compactMap { self.decode($0) }
        } else if let defaults,
                  let data = defaults.data(forKey: Self.storageKey),
                  let decoded = try? JSONDecoder.iso8601.decode([TrafficAlertEvent].self, from: data) {
            events = decoded
        } else {
            events = []
        }
        return events.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp { return lhs.id > rhs.id }
            return lhs.timestamp > rhs.timestamp
        }
    }

    public func append(_ events: [TrafficAlertEvent]) {
        guard !events.isEmpty else { return }
        if let store {
            let puts = events.compactMap { event -> (String, String)? in
                guard let encoded = self.encode(event) else { return nil }
                return (Self.eventKey(event), encoded)
            }
            let current = self.all()
            let retained = Array((current + events).sorted { $0.timestamp > $1.timestamp }.prefix(2_000))
            let retainedKeys = Set(retained.map(Self.eventKey))
            let potentialKeys = Set(store.keys(prefix: Self.eventPrefix) + puts.map { $0.0 })
            let deletes = Array(potentialKeys.filter { !retainedKeys.contains($0) })
            try? store.writeAtomically(puts: puts, deletes: deletes)
        } else if let defaults {
            let retained = Array((self.all() + events).sorted { $0.timestamp > $1.timestamp }.prefix(2_000))
            if let data = try? JSONEncoder.iso8601.encode(retained) {
                defaults.set(data, forKey: Self.storageKey)
            }
        }
    }

    public func hasCooldown(for key: String, now: Date = Date()) -> Bool {
        guard let store, let raw = store.get(key: Self.cooldownKey(key)), let date = Self.date(from: raw) else { return false }
        return date > now
    }

    public func setCooldown(for key: String, until date: Date) {
        guard let store else { return }
        try? store.writeAtomically(puts: [(Self.cooldownKey(key), Self.isoDate(date))], deletes: [])
    }

    public func clear() {
        if let store {
            try? store.writeAtomically(
                puts: [],
                deletes: store.keys(prefix: Self.eventPrefix) + store.keys(prefix: Self.cooldownPrefix)
            )
        } else {
            self.defaults?.removeObject(forKey: Self.storageKey)
        }
    }

    private func encode(_ event: TrafficAlertEvent) -> String? {
        guard let data = try? self.encoder.encode(event) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decode(_ value: String) -> TrafficAlertEvent? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? self.decoder.decode(TrafficAlertEvent.self, from: data)
    }

    private static func eventKey(_ event: TrafficAlertEvent) -> String {
        let timestamp = String(format: "%020.6f", event.timestamp.timeIntervalSince1970)
        return "\(Self.eventPrefix)\(timestamp)|\(event.id)"
    }

    private static func cooldownKey(_ key: String) -> String {
        let encoded = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return "\(Self.cooldownPrefix)\(encoded)"
    }

    private static func isoDate(_ date: Date) -> String { String(date.timeIntervalSince1970) }
    private static func date(from string: String) -> Date? { TimeInterval(string).map(Date.init(timeIntervalSince1970:)) }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public protocol TrafficAlertNotifying: AnyObject {
    func deliver(_ events: [TrafficAlertEvent])
}

public final class NoopTrafficAlertNotifier: TrafficAlertNotifying {
    public init() {}
    public func deliver(_ events: [TrafficAlertEvent]) { _ = events }
}

/// Coordinates anomaly detection, persisted cooldowns, and delivery after a committed batch.
public final class TrafficRuntimeAlertService {
    private let repository: TrafficHistoryRepository
    private let alertStore: TrafficAlertStore
    private let preferencesStore: TrafficAnalyticsPreferencesStore
    private let detector: TrafficAnomalyDetector
    private let clock: TrafficClock
    private let notifier: TrafficAlertNotifying
    private var previousConnectivityOnline: Bool?
    private var disconnectTimes: [Date] = []

    public init(
        repository: TrafficHistoryRepository,
        alertStore: TrafficAlertStore? = nil,
        preferencesStore: TrafficAnalyticsPreferencesStore = TrafficAnalyticsPreferencesStore(),
        detector: TrafficAnomalyDetector = TrafficAnomalyDetector(),
        clock: TrafficClock = SystemTrafficClock(),
        notifier: TrafficAlertNotifying = NoopTrafficAlertNotifier()
    ) {
        self.repository = repository
        self.alertStore = alertStore ?? repository.runtimeAlertStore
        self.preferencesStore = preferencesStore
        self.detector = detector
        self.clock = clock
        self.notifier = notifier
    }

    public func evaluate(batch: CommittedTrafficBatch) -> [TrafficAlertEvent] {
        guard self.preferencesStore.preferences().anomalyDetectionEnabled,
              !batch.samples.isEmpty else { return [] }
        let now = self.clock.now()
        let groups = Dictionary(grouping: batch.samples) { "\($0.application.id)|\($0.network.id)" }
        var events: [TrafficAlertEvent] = []
        for group in groups.values {
            guard let last = group.map(\.timestamp).max() else { continue }
            let start = last.addingTimeInterval(-self.detector.sustainedDurationSeconds)
            let stored = self.repository.fetch(TrafficHistoryQuery(
                level: .second,
                start: start,
                end: last,
                endExclusive: true,
                networkID: group[0].network.id,
                applicationID: group[0].application.id
            ))
            let recent = stored.isEmpty ? group : stored
            events.append(contentsOf: self.detector.evaluate(
                recentSamples: recent,
                baselineAverageBytes: nil,
                connectivityOnline: nil,
                previousConnectivityOnline: nil,
                disconnectCountLastHour: 0
            ))
        }
        return self.persistAndDeliver(events, now: now)
    }

    public func recordConnectivity(isOnline: Bool, at date: Date? = nil) -> [TrafficAlertEvent] {
        guard self.preferencesStore.preferences().anomalyDetectionEnabled else { return [] }
        let timestamp = date ?? self.clock.now()
        if !isOnline { self.disconnectTimes.append(timestamp) }
        self.disconnectTimes = self.disconnectTimes.filter { timestamp.timeIntervalSince($0) <= 3_600 }
        let events = self.detector.evaluate(
            recentSamples: [],
            baselineAverageBytes: nil,
            connectivityOnline: isOnline,
            previousConnectivityOnline: self.previousConnectivityOnline,
            disconnectCountLastHour: self.disconnectTimes.count
        ).map { event in
            TrafficAlertEvent(
                id: event.id,
                kind: event.kind,
                timestamp: timestamp,
                message: event.message,
                applicationID: event.applicationID,
                networkID: event.networkID,
                severity: event.kind == .connectivity && event.message.contains("unstable") ? .critical : .warning,
                deduplicationKey: event.deduplicationKey
            )
        }
        self.previousConnectivityOnline = isOnline
        return self.persistAndDeliver(events, now: timestamp)
    }

    private func persistAndDeliver(_ events: [TrafficAlertEvent], now: Date) -> [TrafficAlertEvent] {
        let accepted = events.filter { event in
            let key = "\(event.deduplicationKey)|duration:\(event.duration ?? 0)|threshold:\(event.thresholdValue ?? 0)"
            return !self.alertStore.hasCooldown(for: key, now: now)
        }
        guard !accepted.isEmpty else { return [] }
        self.alertStore.append(accepted)
        for event in accepted {
            let key = "\(event.deduplicationKey)|duration:\(event.duration ?? 0)|threshold:\(event.thresholdValue ?? 0)"
            self.alertStore.setCooldown(for: key, until: now.addingTimeInterval(max(60, self.detector.sustainedDurationSeconds)))
        }
        self.notifier.deliver(accepted)
        return accepted
    }
}

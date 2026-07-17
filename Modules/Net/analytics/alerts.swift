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

public struct TrafficAlertEvent: Codable, Equatable {
    public let id: String
    public let kind: TrafficAlertKind
    public let timestamp: Date
    public let message: String
    public let applicationID: String?
    public let networkID: String?

    public init(
        id: String = UUID().uuidString,
        kind: TrafficAlertKind,
        timestamp: Date = Date(),
        message: String,
        applicationID: String? = nil,
        networkID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.message = message
        self.applicationID = applicationID
        self.networkID = networkID
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
        baselineAverageBytes: UInt64?,
        connectivityOnline: Bool?,
        previousConnectivityOnline: Bool?,
        disconnectCountLastHour: Int
    ) -> [TrafficAlertEvent] {
        var events: [TrafficAlertEvent] = []

        if let last = recentSamples.last {
            let window = recentSamples.filter {
                last.timestamp.timeIntervalSince($0.timestamp) <= self.sustainedDurationSeconds
            }
            if !window.isEmpty {
                let totalUpload = window.reduce(UInt64(0)) { $0 + $1.delta.upload }
                let average = totalUpload / UInt64(max(1, window.count))
                if average >= self.sustainedUploadBytesPerSecond {
                    events.append(
                        TrafficAlertEvent(
                            kind: .sustainedUpload,
                            timestamp: last.timestamp,
                            message: "Sustained upload from \(last.application.displayName)",
                            applicationID: last.application.id,
                            networkID: last.network.id
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
                            networkID: last.network.id
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
            let key = "\(event.kind.rawValue)|\(event.message)|\(event.applicationID ?? "")"
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

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func all() -> [TrafficAlertEvent] {
        guard let data = self.defaults.data(forKey: Self.storageKey),
              let events = try? JSONDecoder().decode([TrafficAlertEvent].self, from: data) else {
            return []
        }
        return events.sorted { $0.timestamp > $1.timestamp }
    }

    public func append(_ events: [TrafficAlertEvent]) {
        guard !events.isEmpty else { return }
        var current = self.all()
        current.insert(contentsOf: events, at: 0)
        if current.count > 200 {
            current = Array(current.prefix(200))
        }
        if let data = try? JSONEncoder().encode(current) {
            self.defaults.set(data, forKey: Self.storageKey)
        }
    }

    public func clear() {
        self.defaults.removeObject(forKey: Self.storageKey)
    }
}

//
//  coordinator.swift
//  Net
//

import Foundation

public struct TrafficCollectorSnapshot: Equatable {
    public let samplesWritten: Int
    public let lastError: String?
    public let isCollecting: Bool

    public init(samplesWritten: Int, lastError: String?, isCollecting: Bool) {
        self.samplesWritten = samplesWritten
        self.lastError = lastError
        self.isCollecting = isCollecting
    }
}

public protocol TrafficClock {
    func now() -> Date
}

public struct SystemTrafficClock: TrafficClock {
    public init() {}
    public func now() -> Date { Date() }
}

public final class TrafficAnalyticsCoordinator {
    private let repository: TrafficHistoryRepository
    private let resolver: ApplicationIdentityResolver
    private let clock: TrafficClock
    private let queue: DispatchQueue

    private var previousCounters: [String: ProcessTrafficCounter] = [:]
    private var currentNetwork = NetworkIdentity(
        id: "unknown",
        displayName: "Unknown",
        interfaceName: "unknown",
        kind: .other
    )
    private var samplesWritten = 0
    private var lastError: String?
    private var isCollecting = false
    private var consecutiveFailures = 0
    private var pendingSamples: [TrafficSample] = []

    public init(
        repository: TrafficHistoryRepository,
        resolver: ApplicationIdentityResolver = ApplicationIdentityResolver(provider: AppKitProcessMetadataProvider()),
        clock: TrafficClock = SystemTrafficClock(),
        queue: DispatchQueue = DispatchQueue(label: "eu.exelban.Stats.Net.analytics.coordinator")
    ) {
        self.repository = repository
        self.resolver = resolver
        self.clock = clock
        self.queue = queue
    }

    public func start() {
        self.queue.sync {
            self.isCollecting = true
            self.lastError = nil
        }
    }

    public func stop() {
        self.queue.sync {
            self.flushLocked()
            self.isCollecting = false
        }
    }

    public func updateNetwork(_ network: NetworkIdentity) {
        self.queue.sync {
            self.currentNetwork = network
        }
    }

    public func ingest(counters: [ProcessTrafficCounter]) {
        self.queue.sync {
            guard self.isCollecting else { return }

            var produced: [TrafficSample] = []
            let timestamp = self.clock.now()
            var next: [String: ProcessTrafficCounter] = [:]

            for counter in counters {
                let lifetime = "\(counter.processID):\(counter.processStartToken)"
                let identity = self.resolver.identity(
                    processID: counter.processID,
                    fallbackName: counter.identity.displayName
                )
                let normalized = ProcessTrafficCounter(
                    identity: identity,
                    processID: counter.processID,
                    processStartToken: counter.processStartToken,
                    download: counter.download,
                    upload: counter.upload
                )
                next[lifetime] = normalized

                let previous = self.previousCounters[lifetime]
                let delta = TrafficDeltaCalculator.delta(from: previous, to: normalized)
                guard previous != nil else { continue }
                guard delta.total > 0 else { continue }

                produced.append(
                    TrafficSample(
                        timestamp: timestamp,
                        application: identity,
                        network: self.currentNetwork,
                        processID: counter.processID,
                        delta: delta,
                        peakBytesPerSecond: delta.total
                    )
                )
            }

            self.previousCounters = next
            if !produced.isEmpty {
                self.repository.insert(samples: produced)
                self.samplesWritten += produced.count
                self.pendingSamples.removeAll()
            }
            self.consecutiveFailures = 0
            self.lastError = nil
        }
    }

    public func recordFailure(_ message: String) {
        self.queue.sync {
            self.consecutiveFailures += 1
            self.lastError = message
        }
    }

    public func shouldSkipRead(at date: Date = Date()) -> Bool {
        self.queue.sync {
            // Bounded exponential backoff after failures: 1s, 2s, 4s... capped at 30s.
            // Callers can use consecutiveFailures for sleep; coordinator itself is pull-based.
            return false
        }
    }

    public func backoffSeconds() -> TimeInterval {
        self.queue.sync {
            guard self.consecutiveFailures > 0 else { return 0 }
            let exp = min(self.consecutiveFailures - 1, 5)
            return min(30, pow(2.0, Double(exp)))
        }
    }

    public func flush() {
        self.queue.sync {
            self.flushLocked()
        }
    }

    public func snapshot() -> TrafficCollectorSnapshot {
        self.queue.sync {
            TrafficCollectorSnapshot(
                samplesWritten: self.samplesWritten,
                lastError: self.lastError,
                isCollecting: self.isCollecting
            )
        }
    }

    public static func networkIdentity(from usage: Network_Usage) -> NetworkIdentity {
        let interfaceName = usage.interface?.BSDName ?? "unknown"
        let displayName = usage.interface?.displayName ?? interfaceName
        let kind = self.networkKind(interfaceName: interfaceName, displayName: displayName, wifiSSID: usage.wifiDetails.ssid)
        let id: String
        if kind == .wifi, let ssid = usage.wifiDetails.ssid, !ssid.isEmpty {
            id = "wifi:\(ssid)"
        } else {
            id = "iface:\(interfaceName)"
        }
        return NetworkIdentity(
            id: id,
            displayName: displayName,
            interfaceName: interfaceName,
            kind: kind
        )
    }

    public static func networkKind(
        interfaceName: String,
        displayName: String,
        wifiSSID: String?
    ) -> NetworkKind {
        let name = interfaceName.lowercased()
        let display = displayName.lowercased()
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") || name.hasPrefix("tun") || name.hasPrefix("tap") || display.contains("vpn") {
            return .tunnel
        }
        if name.hasPrefix("awdl") || display.contains("personal hotspot") || display.contains("iphone") || display.contains("cellular") {
            return .hotspot
        }
        if name.hasPrefix("en"), wifiSSID != nil || display.contains("wi-fi") || display.contains("wifi") {
            return .wifi
        }
        if name.hasPrefix("en") || display.contains("ethernet") || display.contains("lan") {
            return .ethernet
        }
        if wifiSSID != nil {
            return .wifi
        }
        return .other
    }

    private func flushLocked() {
        guard !self.pendingSamples.isEmpty else { return }
        self.repository.insert(samples: self.pendingSamples)
        self.samplesWritten += self.pendingSamples.count
        self.pendingSamples.removeAll()
    }
}

//
//  coordinator.swift
//  Net
//

import Foundation

public struct TrafficCollectorSnapshot: Equatable {
    public let samplesWritten: Int
    public let pendingSamples: Int
    public let lastError: String?
    public let isCollecting: Bool
    public let isHistoryEnabled: Bool

    public init(
        samplesWritten: Int,
        pendingSamples: Int,
        lastError: String?,
        isCollecting: Bool,
        isHistoryEnabled: Bool
    ) {
        self.samplesWritten = samplesWritten
        self.pendingSamples = pendingSamples
        self.lastError = lastError
        self.isCollecting = isCollecting
        self.isHistoryEnabled = isHistoryEnabled
    }
}

public struct TrafficPersistencePolicy: Equatable {
    public let maxPendingSamples: Int
    public let maxConsecutiveFailures: Int

    public init(maxPendingSamples: Int = 256, maxConsecutiveFailures: Int = 3) {
        precondition(maxPendingSamples > 0)
        precondition(maxConsecutiveFailures > 0)
        self.maxPendingSamples = maxPendingSamples
        self.maxConsecutiveFailures = maxConsecutiveFailures
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
    private let persistencePolicy: TrafficPersistencePolicy

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
    private var isHistoryEnabled = true
    private var consecutivePersistenceFailures = 0
    private var pendingSamples: [TrafficSample] = []

    public init(
        repository: TrafficHistoryRepository,
        resolver: ApplicationIdentityResolver = ApplicationIdentityResolver(provider: AppKitProcessMetadataProvider()),
        clock: TrafficClock = SystemTrafficClock(),
        queue: DispatchQueue = DispatchQueue(label: "eu.exelban.Stats.Net.analytics.coordinator"),
        persistencePolicy: TrafficPersistencePolicy = TrafficPersistencePolicy()
    ) {
        self.repository = repository
        self.resolver = resolver
        self.clock = clock
        self.queue = queue
        self.persistencePolicy = persistencePolicy
    }

    public func start() {
        self.queue.sync {
            self.isCollecting = true
            if self.isHistoryEnabled {
                self.lastError = nil
            }
        }
    }

    @discardableResult
    public func stop() -> Bool {
        self.queue.sync {
            let persisted = self.flushLocked()
            self.isCollecting = false
            return persisted
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
                let interfaceName = counter.interfaceName
                let lifetime = "\(counter.processDiscriminator)|\(interfaceName ?? "")"
                let identity = self.resolver.identity(
                    processID: counter.processID,
                    fallbackName: counter.identity.displayName
                )
                let normalized = ProcessTrafficCounter(
                    identity: identity,
                    processID: counter.processID,
                    processStartToken: counter.processStartToken,
                    processDiscriminator: counter.processDiscriminator,
                    interfaceName: interfaceName,
                    isDelta: counter.isDelta,
                    download: counter.download,
                    upload: counter.upload
                )
                next[lifetime] = normalized

                let previous = self.previousCounters[lifetime]
                let delta: TrafficDelta
                if normalized.isDelta {
                    delta = TrafficDelta(download: normalized.download, upload: normalized.upload)
                } else {
                    delta = TrafficDeltaCalculator.delta(from: previous, to: normalized)
                    guard previous != nil else { continue }
                }
                guard delta.total > 0 else { continue }

                let network = interfaceName.map { self.networkIdentity(interfaceName: $0) } ?? self.currentNetwork
                produced.append(
                    TrafficSample(
                        timestamp: timestamp,
                        application: identity,
                        network: network,
                        processID: counter.processID,
                        processName: counter.identity.displayName,
                        processStartToken: counter.processStartToken,
                        processDiscriminator: counter.processDiscriminator,
                        delta: delta,
                        peakBytesPerSecond: delta.total
                    )
                )
            }

            self.previousCounters = next
            guard self.isHistoryEnabled else { return }

            let availableCapacity = max(0, self.persistencePolicy.maxPendingSamples - self.pendingSamples.count)
            let accepted = Array(produced.prefix(availableCapacity))
            let dropped = produced.count - accepted.count
            let samples = self.pendingSamples + accepted
            guard dropped == 0 else {
                self.disableHistoryLocked(
                    reason: "Traffic history disabled after pending buffer reached \(self.persistencePolicy.maxPendingSamples) samples",
                    droppedSamples: samples.count + dropped
                )
                return
            }
            guard !samples.isEmpty else {
                self.lastError = nil
                return
            }

            self.persistLocked(samples)
        }
    }

    public func recordFailure(_ message: String) {
        self.queue.sync {
            guard self.isHistoryEnabled else { return }
            self.lastError = message
        }
    }

    @discardableResult
    public func flush() -> Bool {
        self.queue.sync {
            self.flushLocked()
        }
    }

    public func clearAnalyticsData() throws {
        try self.queue.sync {
            try self.repository.clearAnalyticsData()
            self.previousCounters.removeAll()
            self.pendingSamples.removeAll()
            self.samplesWritten = 0
            self.consecutivePersistenceFailures = 0
            self.isHistoryEnabled = true
            self.lastError = nil
        }
    }

    public func snapshot() -> TrafficCollectorSnapshot {
        self.queue.sync {
            TrafficCollectorSnapshot(
                samplesWritten: self.samplesWritten,
                pendingSamples: self.pendingSamples.count,
                lastError: self.lastError,
                isCollecting: self.isCollecting,
                isHistoryEnabled: self.isHistoryEnabled
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

    private func networkIdentity(interfaceName: String) -> NetworkIdentity {
        if interfaceName == self.currentNetwork.interfaceName {
            return self.currentNetwork
        }
        let kind = Self.networkKind(interfaceName: interfaceName, displayName: interfaceName, wifiSSID: nil)
        return NetworkIdentity(
            id: "iface:\(interfaceName)",
            displayName: interfaceName,
            interfaceName: interfaceName,
            kind: kind
        )
    }

    @discardableResult
    private func flushLocked() -> Bool {
        guard self.isHistoryEnabled else { return false }
        guard !self.pendingSamples.isEmpty else { return true }
        return self.persistLocked(self.pendingSamples)
    }

    @discardableResult
    private func persistLocked(_ samples: [TrafficSample]) -> Bool {
        switch self.repository.ingest(samples) {
        case .success(let batch):
            self.samplesWritten += batch.samples.count
            self.pendingSamples.removeAll()
            self.consecutivePersistenceFailures = 0
            self.lastError = nil
            return true
        case .failure(let persistenceError):
            self.consecutivePersistenceFailures += 1
            self.pendingSamples = samples
            if self.consecutivePersistenceFailures >= self.persistencePolicy.maxConsecutiveFailures {
                self.disableHistoryLocked(
                    reason: "Traffic history disabled after \(self.consecutivePersistenceFailures) persistence failures: \(persistenceError.description)",
                    droppedSamples: self.pendingSamples.count
                )
            } else {
                self.lastError = "Traffic history persistence failed (attempt \(self.consecutivePersistenceFailures)/\(self.persistencePolicy.maxConsecutiveFailures)): \(persistenceError.description)"
            }
            return false
        }
    }

    private func disableHistoryLocked(reason: String, droppedSamples: Int) {
        self.pendingSamples.removeAll()
        self.isHistoryEnabled = false
        self.lastError = "\(reason); dropped \(droppedSamples) sample\(droppedSamples == 1 ? "" : "s")"
    }
}

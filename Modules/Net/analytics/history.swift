//
//  history.swift
//  Net
//

import Foundation
import Kit

public enum TrafficAggregationLevel: String, Codable, CaseIterable {
    case second
    case minute
    case hour
    case day
    case month
    case year
}

public enum TrafficHistorySchema: String, Codable {
    case v1
    case v2
}

public struct StoredProcessTrafficSummary: Codable, Equatable {
    public let processDiscriminator: String
    public let processID: Int32
    public let processName: String
    public let download: UInt64
    public let upload: UInt64
    public let peakBytesPerSecond: UInt64
    public let sampleCount: Int?
    public let identity: ApplicationIdentity?
    public let routeContexts: [TrafficRouteContext]

    public init(
        processDiscriminator: String,
        processID: Int32,
        processName: String,
        download: UInt64,
        upload: UInt64,
        peakBytesPerSecond: UInt64,
        sampleCount: Int?,
        identity: ApplicationIdentity? = nil,
        routeContexts: [TrafficRouteContext] = []
    ) {
        self.processDiscriminator = processDiscriminator
        self.processID = processID
        self.processName = processName
        self.download = download
        self.upload = upload
        self.peakBytesPerSecond = peakBytesPerSecond
        self.sampleCount = sampleCount
        self.identity = identity
        self.routeContexts = routeContexts
    }

    private enum CodingKeys: String, CodingKey {
        case processDiscriminator, processID, processName, download, upload, peakBytesPerSecond, sampleCount, identity, routeContexts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.processDiscriminator = try container.decode(String.self, forKey: .processDiscriminator)
        self.processID = try container.decode(Int32.self, forKey: .processID)
        self.processName = try container.decode(String.self, forKey: .processName)
        self.download = try container.decode(UInt64.self, forKey: .download)
        self.upload = try container.decode(UInt64.self, forKey: .upload)
        self.peakBytesPerSecond = try container.decode(UInt64.self, forKey: .peakBytesPerSecond)
        self.sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount)
        self.identity = try container.decodeIfPresent(ApplicationIdentity.self, forKey: .identity)
        self.routeContexts = try container.decodeIfPresent([TrafficRouteContext].self, forKey: .routeContexts) ?? []
    }
}

public struct StoredTrafficRecord: Codable, Equatable {
    public let schema: TrafficHistorySchema
    public let level: TrafficAggregationLevel
    public let sample: TrafficSample
    public let sampleCount: Int?
    public let processSummaries: [StoredProcessTrafficSummary]?

    public init(
        schema: TrafficHistorySchema,
        level: TrafficAggregationLevel,
        sample: TrafficSample,
        sampleCount: Int?,
        processSummaries: [StoredProcessTrafficSummary]? = nil
    ) {
        self.schema = schema
        self.level = level
        self.sample = sample
        self.sampleCount = sampleCount
        self.processSummaries = processSummaries
    }
}

public struct CommittedTrafficBatch: Equatable {
    public let samples: [TrafficSample]

    public init(samples: [TrafficSample]) {
        self.samples = samples
    }
}

public enum TrafficPersistenceError: Error, Equatable, CustomStringConvertible {
    case encodingFailed
    case storeFailed(String)

    public var description: String {
        switch self {
        case .encodingFailed: return "Unable to encode traffic history"
        case .storeFailed(let message): return message
        }
    }
}

public protocol TrafficKeyValueStoring: AnyObject {
    func writeAtomically(puts: [(key: String, value: String)], deletes: [String]) throws
    func get(key: String) -> String?
    func values(prefix: String) -> [String]
    func keys(prefix: String) -> [String]
}

public extension TrafficKeyValueStoring {
    func put(key: String, value: String) throws {
        try self.writeAtomically(puts: [(key, value)], deletes: [])
    }

    func delete(keys: [String]) throws {
        try self.writeAtomically(puts: [], deletes: keys)
    }
}

public final class InMemoryTrafficStore: TrafficKeyValueStoring {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func writeAtomically(puts: [(key: String, value: String)], deletes: [String]) throws {
        self.lock.lock()
        defer { self.lock.unlock() }
        var next = self.storage
        puts.forEach { next[$0.key] = $0.value }
        deletes.forEach { next.removeValue(forKey: $0) }
        self.storage = next
    }

    public func get(key: String) -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage[key]
    }

    public func values(prefix: String) -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
            .filter { $0.key.hasPrefix(prefix) }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    public func keys(prefix: String) -> [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage.keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
    }
}

public final class LevelDBTrafficStore: TrafficKeyValueStoring {
    private let db: DB

    public init(db: DB = .shared) {
        self.db = db
    }

    public func writeAtomically(puts: [(key: String, value: String)], deletes: [String]) throws {
        try self.db.writeRawAtomically(puts: puts, deletes: deletes)
    }

    public func get(key: String) -> String? {
        self.db.getRaw(key: key)
    }

    public func values(prefix: String) -> [String] {
        self.db.values(prefix: prefix)
    }

    public func keys(prefix: String) -> [String] {
        self.db.keys(prefix: prefix)
    }
}

public struct TrafficHistoryQuery: Equatable {
    public let level: TrafficAggregationLevel
    public let start: Date
    public let end: Date
    public let endExclusive: Bool
    public let networkID: String?
    public let applicationID: String?

    public init(
        level: TrafficAggregationLevel,
        start: Date,
        end: Date,
        endExclusive: Bool = false,
        networkID: String? = nil,
        applicationID: String? = nil
    ) {
        self.level = level
        self.start = start
        self.end = end
        self.endExclusive = endExclusive
        self.networkID = networkID
        self.applicationID = applicationID
    }
}

public final class TrafficHistoryRepository {
    public static let schemaVersion = "v2"
    public static let keyPrefix = "net.analytics.\(schemaVersion)"
    public static let legacyKeyPrefix = "net.analytics.v1"
    private static let trafficKeyPrefix = "\(keyPrefix)|"
    private static let legacyTrafficKeyPrefix = "\(legacyKeyPrefix)|"

    private let store: TrafficKeyValueStoring
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let alertStore: TrafficAlertStore
    private let ruleStore: TrafficRuleStore

    public init(
        store: TrafficKeyValueStoring,
        queue: DispatchQueue = DispatchQueue(label: "eu.exelban.Stats.Net.analytics.history"),
        alertStore: TrafficAlertStore? = nil,
        ruleStore: TrafficRuleStore = TrafficRuleStore()
    ) {
        self.store = store
        self.queue = queue
        self.alertStore = alertStore ?? TrafficAlertStore(store: store)
        self.ruleStore = ruleStore
        self.queue.setSpecific(key: self.queueKey, value: 1)
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    public func ingest(_ samples: [TrafficSample], level: TrafficAggregationLevel = .second) -> Result<CommittedTrafficBatch, TrafficPersistenceError> {
        self.queue.sync {
            do {
                var recordsByKey: [String: StoredTrafficRecord] = [:]
                for sample in samples {
                    let key = Self.makeKey(
                        level: level,
                        timestamp: sample.timestamp,
                        networkID: sample.network.id,
                        applicationID: sample.application.id,
                        processDiscriminator: level == .second ? sample.processDiscriminator : nil
                    )
                    let record = StoredTrafficRecord(
                        schema: .v2,
                        level: level,
                        sample: sample,
                        sampleCount: level == .second ? 1 : nil
                    )
                    recordsByKey[key] = recordsByKey[key].map {
                        TrafficAggregation.merge($0, record, level: level)
                    } ?? record
                }

                let puts = try recordsByKey.keys.sorted().map { key in
                    let contribution = recordsByKey[key]!
                    let record = self.decodeRecord(key: key, schema: .v2, level: level).map {
                        TrafficAggregation.merge($0, contribution, level: level)
                    } ?? contribution
                    return (key, try self.encode(record))
                }
                try self.writeAtomically(puts: puts, deletes: [])
                return .success(CommittedTrafficBatch(samples: samples))
            } catch let error as TrafficPersistenceError {
                return .failure(error)
            } catch {
                return .failure(.storeFailed(error.localizedDescription))
            }
        }
    }

    public func insert(_ sample: TrafficSample, level: TrafficAggregationLevel = .second) {
        _ = self.ingest([sample], level: level)
    }

    public func insert(samples: [TrafficSample], level: TrafficAggregationLevel = .second) {
        _ = self.ingest(samples, level: level)
    }

    public func fetch(_ query: TrafficHistoryQuery) -> [TrafficSample] {
        self.fetchRecords(query).map(\.sample)
    }

    public func fetchRecords(_ query: TrafficHistoryQuery) -> [StoredTrafficRecord] {
        self.queue.sync {
            self.fetchRecordsLocked(query).sorted { lhs, rhs in
                if lhs.sample.timestamp == rhs.sample.timestamp {
                    return lhs.sample.processDiscriminator < rhs.sample.processDiscriminator
                }
                return lhs.sample.timestamp < rhs.sample.timestamp
            }
        }
    }

    public func deleteTrafficHistory() throws {
        try self.queue.sync {
            try self.writeAtomically(puts: [], deletes: self.trafficKeysLocked())
        }
    }

    public func clearAnalyticsData() throws {
        try self.queue.sync {
            try self.writeAtomically(puts: [], deletes: self.trafficKeysLocked())
            self.alertStore.clear()
            self.ruleStore.clearRuntimeState()
        }
    }

    public func trafficAlerts() -> [TrafficAlertEvent] {
        self.queue.sync { self.alertStore.all() }
    }

    public var runtimeAlertStore: TrafficAlertStore { self.alertStore }

    private func trafficKeysLocked() -> [String] {
        let current = TrafficAggregationLevel.allCases.flatMap {
            self.store.keys(prefix: "\(Self.keyPrefix)|\($0.rawValue)|")
        }
        let legacy = TrafficAggregationLevel.allCases.flatMap {
            self.store.keys(prefix: "\(Self.legacyKeyPrefix)|\($0.rawValue)|")
        }
        return Array(Set(current + legacy))
    }

    public func deleteAll() {
        try? self.deleteTrafficHistory()
    }

    public func delete(keys: [String]) {
        self.queue.sync {
            var expanded: [String] = []
            for key in keys {
                if key.hasPrefix("\(Self.keyPrefix)|second|") && key.split(separator: "|", omittingEmptySubsequences: false).count == 5 {
                    expanded.append(contentsOf: self.store.keys(prefix: "\(key)|"))
                } else {
                    expanded.append(key)
                }
            }
            try? self.writeAtomically(puts: [], deletes: Array(Set(expanded)))
        }
    }

    public func replace(level: TrafficAggregationLevel, samples: [TrafficSample]) {
        _ = self.ingest(samples, level: level)
    }

    public func replaceAtomically(
        level: TrafficAggregationLevel,
        samples: [TrafficSample],
        deleting sourceKeys: [String]
    ) throws {
        try self.queue.sync {
            try self.replaceAtomicallyLocked(
                records: samples.map {
                    StoredTrafficRecord(schema: .v2, level: level, sample: $0, sampleCount: level == .second ? 1 : nil)
                },
                deleting: sourceKeys
            )
        }
    }

    public func replaceAtomically(
        level: TrafficAggregationLevel,
        samples: [TrafficSample],
        deleting sourceQuery: TrafficHistoryQuery
    ) throws {
        try self.queue.sync {
            let sourceKeys = self.keysLocked(for: sourceQuery)
            try self.replaceAtomicallyLocked(
                records: samples.map {
                    StoredTrafficRecord(schema: .v2, level: level, sample: $0, sampleCount: level == .second ? 1 : nil)
                },
                deleting: sourceKeys
            )
        }
    }

    public func replaceAtomically(
        records: [StoredTrafficRecord],
        deleting sourceQuery: TrafficHistoryQuery
    ) throws {
        try self.queue.sync {
            let sourceKeys = self.keysLocked(for: sourceQuery)
            try self.replaceAtomicallyLocked(records: records, deleting: sourceKeys)
        }
    }

    public func replaceAtomically(
        records: [StoredTrafficRecord],
        deleting sourceKeys: [String]
    ) throws {
        try self.queue.sync {
            try self.replaceAtomicallyLocked(records: records, deleting: sourceKeys)
        }
    }

    public func storeAtomically(records: [StoredTrafficRecord]) throws {
        try self.queue.sync {
            var recordsByKey: [String: StoredTrafficRecord] = [:]
            for record in records {
                let sample = record.sample
                let key = Self.makeKey(
                    level: record.level,
                    timestamp: sample.timestamp,
                    networkID: sample.network.id,
                    applicationID: sample.application.id,
                    processDiscriminator: record.level == .second ? sample.processDiscriminator : nil
                )
                recordsByKey[key] = recordsByKey[key].map {
                    TrafficAggregation.merge($0, record, level: record.level)
                } ?? record
            }
            let puts = try recordsByKey.keys.sorted().map { key in
                (key, try self.encode(recordsByKey[key]!))
            }
            try self.writeAtomically(puts: puts, deletes: [])
        }
    }

    public func recordsWithKeys(_ query: TrafficHistoryQuery) -> [(key: String, record: StoredTrafficRecord)] {
        self.queue.sync {
            [TrafficHistorySchema.v1, .v2].flatMap { schema in
                self.keysLocked(for: query, schema: schema).compactMap { key in
                    guard let record = self.decodeRecord(key: key, schema: schema, level: query.level) else { return nil }
                    let sample = record.sample
                    guard sample.timestamp >= query.start,
                          query.endExclusive ? sample.timestamp < query.end : sample.timestamp <= query.end else {
                        return nil
                    }
                    if let networkID = query.networkID, sample.network.id != networkID { return nil }
                    if let applicationID = query.applicationID, sample.application.id != applicationID { return nil }
                    return (key, record)
                }
            }.sorted { lhs, rhs in
                if lhs.record.sample.timestamp == rhs.record.sample.timestamp {
                    return lhs.key < rhs.key
                }
                return lhs.record.sample.timestamp < rhs.record.sample.timestamp
            }
        }
    }

    public static func makeKey(
        level: TrafficAggregationLevel,
        timestamp: Date,
        networkID: String,
        applicationID: String,
        processDiscriminator: String? = nil
    ) -> String {
        let seconds = Int64(timestamp.timeIntervalSince1970)
        let padded = String(format: "%020lld", seconds)
        var components = [
            keyPrefix,
            level.rawValue,
            padded,
            self.escape(networkID),
            self.escape(applicationID)
        ]
        if level == .second, let processDiscriminator {
            components.append(self.escape(processDiscriminator))
        }
        return components.joined(separator: "|")
    }

    public static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "|", with: "%7C")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private func fetchRecordsLocked(_ query: TrafficHistoryQuery) -> [StoredTrafficRecord] {
        dispatchPrecondition(condition: .onQueue(self.queue))
        return [TrafficHistorySchema.v1, .v2].flatMap { schema in
            self.keysLocked(for: query, schema: schema)
                .compactMap { key in self.decodeRecord(key: key, schema: schema, level: query.level) }
                .filter { record in
                    let sample = record.sample
                    if let networkID = query.networkID, sample.network.id != networkID { return false }
                    if let applicationID = query.applicationID, sample.application.id != applicationID { return false }
                    return sample.timestamp >= query.start
                        && (query.endExclusive ? sample.timestamp < query.end : sample.timestamp <= query.end)
                }
        }
    }

    private func keysLocked(for query: TrafficHistoryQuery) -> [String] {
        dispatchPrecondition(condition: .onQueue(self.queue))
        return [TrafficHistorySchema.v1, .v2].flatMap { self.keysLocked(for: query, schema: $0) }
    }

    private func keysLocked(for query: TrafficHistoryQuery, schema: TrafficHistorySchema) -> [String] {
        dispatchPrecondition(condition: .onQueue(self.queue))
        let prefix = "net.analytics.\(schema.rawValue)|\(query.level.rawValue)|"
        let startSeconds = Int64(query.start.timeIntervalSince1970)
        let endSeconds = Int64(query.end.timeIntervalSince1970)
        let startBound = "\(prefix)\(String(format: "%020lld", startSeconds))|"
        let endBoundSeconds = query.endExclusive ? endSeconds : endSeconds + 1
        let endBound = "\(prefix)\(String(format: "%020lld", endBoundSeconds))|"
        return self.store.keys(prefix: prefix).filter { $0 >= startBound && $0 < endBound }
    }

    private func replaceAtomicallyLocked(
        records: [StoredTrafficRecord],
        deleting sourceKeys: [String]
    ) throws {
        dispatchPrecondition(condition: .onQueue(self.queue))
        let sourceKeySet = Set(sourceKeys)
        var contributionsByKey: [String: StoredTrafficRecord] = [:]
        for record in records {
            let sample = record.sample
            let key = Self.makeKey(
                level: record.level,
                timestamp: sample.timestamp,
                networkID: sample.network.id,
                applicationID: sample.application.id,
                processDiscriminator: record.level == .second ? sample.processDiscriminator : nil
            )
            contributionsByKey[key] = contributionsByKey[key].map {
                TrafficAggregation.merge($0, record, level: record.level)
            } ?? record
        }
        let puts = try contributionsByKey.keys.sorted().map { key in
            let contribution = contributionsByKey[key]!
            let destinationRecord = sourceKeySet.contains(key)
                ? nil
                : self.decodeRecord(key: key, schema: .v2, level: contribution.level)
            let mergedRecord = destinationRecord.map {
                TrafficAggregation.merge($0, contribution, level: contribution.level)
            } ?? contribution
            return (key, try self.encode(mergedRecord))
        }
        try self.writeAtomically(puts: puts, deletes: sourceKeys)
    }

    private func decodeRecord(
        key: String,
        schema: TrafficHistorySchema,
        level: TrafficAggregationLevel
    ) -> StoredTrafficRecord? {
        dispatchPrecondition(condition: .onQueue(self.queue))
        guard let raw = self.store.get(key: key), let data = raw.data(using: .utf8) else { return nil }
        if schema == .v2, let record = try? self.decoder.decode(StoredTrafficRecord.self, from: data) {
            return record
        }
        guard let sample = try? self.decoder.decode(TrafficSample.self, from: data) else { return nil }
        return StoredTrafficRecord(
            schema: .v1,
            level: level,
            sample: sample,
            sampleCount: level == .second ? 1 : nil
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        dispatchPrecondition(condition: .onQueue(self.queue))
        guard let string = String(data: try self.encoder.encode(value), encoding: .utf8) else {
            throw TrafficPersistenceError.encodingFailed
        }
        return string
    }

    private func writeAtomically(puts: [(key: String, value: String)], deletes: [String]) throws {
        dispatchPrecondition(condition: .onQueue(self.queue))
        do {
            try self.store.writeAtomically(puts: puts, deletes: deletes)
        } catch {
            throw TrafficPersistenceError.storeFailed(error.localizedDescription)
        }
    }
}

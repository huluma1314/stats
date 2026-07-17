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
    case month
    case year
}

public protocol TrafficKeyValueStoring: AnyObject {
    func put(key: String, value: String)
    func get(key: String) -> String?
    func values(prefix: String) -> [String]
    func keys(prefix: String) -> [String]
    func delete(keys: [String])
}

public final class InMemoryTrafficStore: TrafficKeyValueStoring {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func put(key: String, value: String) {
        self.lock.lock()
        self.storage[key] = value
        self.lock.unlock()
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

    public func delete(keys: [String]) {
        self.lock.lock()
        keys.forEach { self.storage.removeValue(forKey: $0) }
        self.lock.unlock()
    }
}

public final class LevelDBTrafficStore: TrafficKeyValueStoring {
    private let db: DB

    public init(db: DB = .shared) {
        self.db = db
    }

    public func put(key: String, value: String) {
        self.db.putRaw(key: key, value: value)
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

    public func delete(keys: [String]) {
        self.db.delete(keys: keys)
    }
}

public struct TrafficHistoryQuery: Equatable {
    public let level: TrafficAggregationLevel
    public let start: Date
    public let end: Date
    public let networkID: String?
    public let applicationID: String?

    public init(
        level: TrafficAggregationLevel,
        start: Date,
        end: Date,
        networkID: String? = nil,
        applicationID: String? = nil
    ) {
        self.level = level
        self.start = start
        self.end = end
        self.networkID = networkID
        self.applicationID = applicationID
    }
}

public final class TrafficHistoryRepository {
    public static let schemaVersion = "v1"
    public static let keyPrefix = "net.analytics.\(schemaVersion)"

    private let store: TrafficKeyValueStoring
    private let queue: DispatchQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        store: TrafficKeyValueStoring,
        queue: DispatchQueue = DispatchQueue(label: "eu.exelban.Stats.Net.analytics.history")
    ) {
        self.store = store
        self.queue = queue
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func insert(_ sample: TrafficSample, level: TrafficAggregationLevel = .second) {
        self.queue.sync {
            let key = Self.makeKey(
                level: level,
                timestamp: sample.timestamp,
                networkID: sample.network.id,
                applicationID: sample.application.id
            )
            guard let data = try? self.encoder.encode(sample),
                  let value = String(data: data, encoding: .utf8) else {
                return
            }
            self.store.put(key: key, value: value)
        }
    }

    public func insert(samples: [TrafficSample], level: TrafficAggregationLevel = .second) {
        samples.forEach { self.insert($0, level: level) }
    }

    public func fetch(_ query: TrafficHistoryQuery) -> [TrafficSample] {
        self.queue.sync {
            let prefix = "\(Self.keyPrefix)|\(query.level.rawValue)|"
            let startSeconds = Int64(query.start.timeIntervalSince1970)
            let endSeconds = Int64(query.end.timeIntervalSince1970)
            let startBound = "\(prefix)\(String(format: "%020lld", startSeconds))|"
            let endBound = "\(prefix)\(String(format: "%020lld", endSeconds + 1))|"
            let keys = self.store.keys(prefix: prefix)
                .filter { $0 >= startBound && $0 < endBound }

            return keys.compactMap { key -> TrafficSample? in
                guard let raw = self.store.get(key: key),
                      let data = raw.data(using: .utf8),
                      let sample = try? self.decoder.decode(TrafficSample.self, from: data) else {
                    return nil
                }
                if let networkID = query.networkID, sample.network.id != networkID {
                    return nil
                }
                if let applicationID = query.applicationID, sample.application.id != applicationID {
                    return nil
                }
                if sample.timestamp < query.start || sample.timestamp > query.end {
                    return nil
                }
                return sample
            }.sorted { $0.timestamp < $1.timestamp }
        }
    }

    public func deleteAll() {
        self.queue.sync {
            let keys = self.store.keys(prefix: Self.keyPrefix)
            self.store.delete(keys: keys)
        }
    }

    public func delete(keys: [String]) {
        self.queue.sync {
            self.store.delete(keys: keys)
        }
    }

    public func replace(level: TrafficAggregationLevel, samples: [TrafficSample]) {
        self.queue.sync {
            for sample in samples {
                let key = Self.makeKey(
                    level: level,
                    timestamp: sample.timestamp,
                    networkID: sample.network.id,
                    applicationID: sample.application.id
                )
                guard let data = try? self.encoder.encode(sample),
                      let value = String(data: data, encoding: .utf8) else {
                    continue
                }
                self.store.put(key: key, value: value)
            }
        }
    }

    public static func makeKey(
        level: TrafficAggregationLevel,
        timestamp: Date,
        networkID: String,
        applicationID: String
    ) -> String {
        let seconds = Int64(timestamp.timeIntervalSince1970)
        let padded = String(format: "%020lld", seconds)
        return "\(keyPrefix)|\(level.rawValue)|\(padded)|\(networkID)|\(applicationID)"
    }
}

//
//  network_registry.swift
//  Net
//

import Foundation

public struct RegisteredNetwork: Codable, Equatable {
    public let identity: NetworkIdentity
    public var alias: String?
    public let firstSeen: Date
    public var lastSeen: Date
    public var observedBSSIDs: [String]
    public var observedInterfaceNames: [String]

    public init(
        identity: NetworkIdentity,
        alias: String? = nil,
        firstSeen: Date,
        lastSeen: Date,
        observedBSSIDs: [String] = [],
        observedInterfaceNames: [String] = []
    ) {
        self.identity = identity
        self.alias = alias
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.observedBSSIDs = observedBSSIDs
        self.observedInterfaceNames = observedInterfaceNames
    }

    private enum CodingKeys: String, CodingKey {
        case identity, alias, firstSeen, lastSeen, observedBSSIDs, observedInterfaceNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.identity = try container.decode(NetworkIdentity.self, forKey: .identity)
        self.alias = try container.decodeIfPresent(String.self, forKey: .alias)
        self.firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        self.lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        self.observedBSSIDs = try container.decodeIfPresent([String].self, forKey: .observedBSSIDs) ?? []
        self.observedInterfaceNames = try container.decodeIfPresent([String].self, forKey: .observedInterfaceNames) ?? []
    }
}

/// Persists the user-facing registry of observed networks without coupling it to history keys.
public final class NetworkRegistry {
    public static let storageKey = "net.analytics.networkRegistry.v1"

    private let defaults: UserDefaults
    private var entries: [String: RegisteredNetwork]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.load(defaults: defaults)
    }

    @discardableResult
    public func observe(_ identity: NetworkIdentity, at date: Date = Date()) -> RegisteredNetwork {
        let canonical = Self.canonicalIdentity(for: identity)
        let id = canonical.id
        if var existing = self.entries[id] {
            existing.lastSeen = max(existing.lastSeen, date)
            if let bssid = identity.bssid, !bssid.isEmpty, !existing.observedBSSIDs.contains(bssid) {
                existing.observedBSSIDs.append(bssid)
            }
            if !existing.observedInterfaceNames.contains(identity.interfaceName) {
                existing.observedInterfaceNames.append(identity.interfaceName)
            }
            self.entries[id] = existing
            self.persist()
            return existing
        }

        let entry = RegisteredNetwork(
            identity: canonical,
            firstSeen: date,
            lastSeen: date,
            observedBSSIDs: identity.bssid.map { [$0] } ?? [],
            observedInterfaceNames: [identity.interfaceName]
        )
        self.entries[id] = entry
        self.persist()
        return entry
    }

    public func all() -> [RegisteredNetwork] {
        self.entries.values.sorted {
            if $0.firstSeen == $1.firstSeen { return $0.identity.id < $1.identity.id }
            return $0.firstSeen < $1.firstSeen
        }
    }

    public func setAlias(_ alias: String?, for networkID: String) {
        guard var entry = self.entries[networkID] else { return }
        let normalized = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        entry.alias = normalized?.isEmpty == true ? nil : normalized
        self.entries[networkID] = entry
        self.persist()
    }

    public func displayName(for networkID: String) -> String {
        guard let entry = self.entries[networkID] else { return networkID }
        return entry.alias ?? entry.identity.displayName
    }

    public func identity(for networkID: String) -> NetworkIdentity? {
        self.entries[networkID]?.identity
    }

    public static func canonicalIdentity(for identity: NetworkIdentity) -> NetworkIdentity {
        let id: String
        switch identity.kind {
        case .wifi:
            let logicalName = identity.ssid ?? Self.stripPrefix(identity.id, prefix: "wifi:")
            id = "wifi:\(Self.normalizedComponent(logicalName.isEmpty ? identity.displayName : logicalName))"
        case .ethernet:
            let token = identity.hardwareAddress ?? identity.interfaceName
            id = "ethernet:\(Self.normalizedComponent(token))"
        case .hotspot:
            let token = identity.serviceIdentifier ?? identity.ssid ?? identity.displayName
            id = "hotspot:\(Self.normalizedComponent(token))|\(Self.normalizedComponent(identity.interfaceName))"
        case .tunnel:
            let token = identity.serviceIdentifier ?? Self.stripPrefix(identity.id, prefix: "tunnel:")
            id = "tunnel:\(Self.normalizedComponent(token.isEmpty ? identity.interfaceName : token))"
        case .other:
            id = "other:\(Self.normalizedComponent(identity.interfaceName))"
        }
        return NetworkIdentity(
            id: id,
            displayName: identity.displayName,
            interfaceName: identity.interfaceName,
            kind: identity.kind,
            ssid: identity.ssid,
            bssid: identity.bssid,
            hardwareAddress: identity.hardwareAddress,
            serviceIdentifier: identity.serviceIdentifier
        )
    }

    private static func load(defaults: UserDefaults) -> [String: RegisteredNetwork] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: RegisteredNetwork].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(self.entries) else { return }
        self.defaults.set(data, forKey: Self.storageKey)
    }

    private static func stripPrefix(_ value: String, prefix: String) -> String {
        value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    private static func normalizedComponent(_ value: String) -> String {
        let folded = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let pieces = folded.split { $0.isWhitespace || $0 == "_" }
        return pieces.joined(separator: "-")
    }
}

//
//  enforcement.swift
//  Net
//

import Foundation

public enum NetworkEnforcementCapability: Equatable {
    case available
    case unavailable(NetworkEnforcementUnavailableReason)
}

public enum NetworkEnforcementUnavailableReason: String, Codable, Equatable {
    case missingEntitlement
    case unsupportedSystem

    public var message: String {
        switch self {
        case .missingEntitlement:
            return "This build is not signed with a Network Extension entitlement."
        case .unsupportedSystem:
            return "This system version cannot host the required Network Extension."
        }
    }
}

public enum NetworkEnforcementDirection: String, Codable, CaseIterable {
    case upload
    case download
    case both
}

public struct NetworkEnforcementAction: Equatable {
    public enum Kind: Equatable {
        case block(NetworkEnforcementDirection)
        case rateLimit(downloadBytesPerSecond: UInt64?, uploadBytesPerSecond: UInt64?)
        case clear
        case pause
        case allow(duration: TimeInterval)
    }

    public let applicationID: String
    public let kind: Kind

    public init(applicationID: String, kind: Kind) {
        self.applicationID = applicationID
        self.kind = kind
    }
}

public enum NetworkEnforcementError: Error, Equatable {
    case unavailable(NetworkEnforcementUnavailableReason)
    case invalidRequest
}

public protocol NetworkRuleEnforcing {
    var capability: NetworkEnforcementCapability { get }
    func apply(_ action: NetworkEnforcementAction) throws
}

public final class UnavailableNetworkRuleEnforcer: NetworkRuleEnforcing {
    public let capability: NetworkEnforcementCapability

    public init(reason: NetworkEnforcementUnavailableReason = .missingEntitlement) {
        self.capability = .unavailable(reason)
    }

    public func apply(_ action: NetworkEnforcementAction) throws {
        if case .unavailable(let reason) = self.capability {
            throw NetworkEnforcementError.unavailable(reason)
        }
        throw NetworkEnforcementError.unavailable(.missingEntitlement)
    }
}

public final class FakeNetworkRuleEnforcer: NetworkRuleEnforcing {
    public private(set) var applied: [NetworkEnforcementAction] = []
    public let capability: NetworkEnforcementCapability = .available

    public init() {}

    public func apply(_ action: NetworkEnforcementAction) throws {
        self.applied.append(action)
    }
}

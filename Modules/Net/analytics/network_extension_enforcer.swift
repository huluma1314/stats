//
//  network_extension_enforcer.swift
//  Net
//

import Foundation

#if NETWORK_EXTENSION_ENFORCEMENT
import NetworkExtension

public final class NetworkExtensionRuleEnforcer: NetworkRuleEnforcing {
    public let capability: NetworkEnforcementCapability = .unavailable(.missingEntitlement)

    public init() {}

    public func apply(_ action: NetworkEnforcementAction) throws {
        _ = action
        throw NetworkEnforcementError.unavailable(.missingEntitlement)
    }
}
#else
public final class NetworkExtensionRuleEnforcer: NetworkRuleEnforcing {
    public let capability: NetworkEnforcementCapability = .unavailable(.missingEntitlement)

    public init() {}

    public func apply(_ action: NetworkEnforcementAction) throws {
        throw NetworkEnforcementError.unavailable(.missingEntitlement)
    }
}
#endif

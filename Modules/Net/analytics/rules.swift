//
//  rules.swift
//  Net
//

import Foundation

public enum QuotaPeriod: String, Codable, CaseIterable {
    case daily
    case weekly
    case monthly
    case custom
}

public enum QuotaAction: String, Codable, CaseIterable {
    case notify
    case rateLimit
    case block
}

public struct NetworkPlan: Codable, Equatable {
    public var billingCycleDay: Int
    public var byteLimit: UInt64?
    public var thresholds: [Int]

    public static let `default` = NetworkPlan(
        billingCycleDay: 1,
        byteLimit: nil,
        thresholds: [80, 90, 100]
    )

    public init(billingCycleDay: Int, byteLimit: UInt64?, thresholds: [Int]) {
        self.billingCycleDay = min(max(billingCycleDay, 1), 31)
        self.byteLimit = byteLimit
        self.thresholds = thresholds.sorted()
    }
}

public struct ApplicationTrafficRule: Codable, Equatable {
    public var id: String
    public var applicationID: String
    public var period: QuotaPeriod
    public var byteLimit: UInt64?
    public var downloadLimitBytesPerSecond: UInt64?
    public var uploadLimitBytesPerSecond: UInt64?
    public var action: QuotaAction
    public var isPaused: Bool
    public var allowUntil: Date?

    public init(
        id: String = UUID().uuidString,
        applicationID: String,
        period: QuotaPeriod = .monthly,
        byteLimit: UInt64? = nil,
        downloadLimitBytesPerSecond: UInt64? = nil,
        uploadLimitBytesPerSecond: UInt64? = nil,
        action: QuotaAction = .notify,
        isPaused: Bool = false,
        allowUntil: Date? = nil
    ) {
        self.id = id
        self.applicationID = applicationID
        self.period = period
        self.byteLimit = byteLimit
        self.downloadLimitBytesPerSecond = downloadLimitBytesPerSecond
        self.uploadLimitBytesPerSecond = uploadLimitBytesPerSecond
        self.action = action
        self.isPaused = isPaused
        self.allowUntil = allowUntil
    }

    private enum CodingKeys: String, CodingKey {
        case id, applicationID, period, byteLimit, downloadLimitBytesPerSecond, uploadLimitBytesPerSecond, action, isPaused, allowUntil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.applicationID = try container.decode(String.self, forKey: .applicationID)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? "legacy:\(self.applicationID)"
        self.period = try container.decodeIfPresent(QuotaPeriod.self, forKey: .period) ?? .monthly
        self.byteLimit = try container.decodeIfPresent(UInt64.self, forKey: .byteLimit)
        self.downloadLimitBytesPerSecond = try container.decodeIfPresent(UInt64.self, forKey: .downloadLimitBytesPerSecond)
        self.uploadLimitBytesPerSecond = try container.decodeIfPresent(UInt64.self, forKey: .uploadLimitBytesPerSecond)
        self.action = try container.decodeIfPresent(QuotaAction.self, forKey: .action) ?? .notify
        self.isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        self.allowUntil = try container.decodeIfPresent(Date.self, forKey: .allowUntil)
    }
}

public struct TrafficAnalyticsPreferences: Codable, Equatable {
    public var quotaAlertsEnabled: Bool
    public var anomalyDetectionEnabled: Bool
    public var overQuotaAction: QuotaAction
    public var minuteRetentionDays: Int
    public var hourRetentionDays: Int
    public var dayRetentionDays: Int
    public var sustainedUploadBytesPerSecond: UInt64
    public var anomalyMultiplier: Double

    public static let `default` = TrafficAnalyticsPreferences(
        quotaAlertsEnabled: true,
        anomalyDetectionEnabled: false,
        overQuotaAction: .notify,
        minuteRetentionDays: 7,
        hourRetentionDays: 60,
        dayRetentionDays: 730,
        sustainedUploadBytesPerSecond: 1_000_000,
        anomalyMultiplier: 3
    )

    public init(
        quotaAlertsEnabled: Bool,
        anomalyDetectionEnabled: Bool,
        overQuotaAction: QuotaAction,
        minuteRetentionDays: Int,
        hourRetentionDays: Int,
        dayRetentionDays: Int,
        sustainedUploadBytesPerSecond: UInt64,
        anomalyMultiplier: Double
    ) {
        self.quotaAlertsEnabled = quotaAlertsEnabled
        self.anomalyDetectionEnabled = anomalyDetectionEnabled
        self.overQuotaAction = overQuotaAction
        self.minuteRetentionDays = max(1, minuteRetentionDays)
        self.hourRetentionDays = max(1, hourRetentionDays)
        self.dayRetentionDays = max(1, dayRetentionDays)
        self.sustainedUploadBytesPerSecond = sustainedUploadBytesPerSecond
        self.anomalyMultiplier = max(1, anomalyMultiplier)
    }
}

public final class TrafficAnalyticsPreferencesStore {
    public static let storageKey = "net.analytics.preferences.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func preferences() -> TrafficAnalyticsPreferences {
        guard let data = self.defaults.data(forKey: Self.storageKey),
              let value = try? JSONDecoder().decode(TrafficAnalyticsPreferences.self, from: data) else {
            return .default
        }
        return value
    }

    public func save(_ preferences: TrafficAnalyticsPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        self.defaults.set(data, forKey: Self.storageKey)
    }
}

public struct RuleEvaluation: Equatable {
    public let triggeredThresholds: [Int]
    public let action: QuotaAction?
    public let usageBytes: UInt64
    public let limitBytes: UInt64?

    public init(triggeredThresholds: [Int], action: QuotaAction?, usageBytes: UInt64, limitBytes: UInt64?) {
        self.triggeredThresholds = triggeredThresholds
        self.action = action
        self.usageBytes = usageBytes
        self.limitBytes = limitBytes
    }
}

public enum TrafficRuleEngine {
    public static func evaluate(
        usageBytes: UInt64,
        limitBytes: UInt64?,
        thresholds: [Int],
        alreadyNotified: Set<Int>,
        action: QuotaAction,
        isPaused: Bool,
        allowUntil: Date?,
        now: Date
    ) -> RuleEvaluation {
        if isPaused || (allowUntil.map { $0 > now } ?? false) {
            return RuleEvaluation(triggeredThresholds: [], action: nil, usageBytes: usageBytes, limitBytes: limitBytes)
        }
        guard let limitBytes, limitBytes > 0 else {
            return RuleEvaluation(triggeredThresholds: [], action: nil, usageBytes: usageBytes, limitBytes: limitBytes)
        }
        let percent = Int((Double(usageBytes) / Double(limitBytes)) * 100)
        let triggered = thresholds.filter { percent >= $0 && !alreadyNotified.contains($0) }
        let shouldAct = percent >= 100
        return RuleEvaluation(
            triggeredThresholds: triggered,
            action: shouldAct ? action : (triggered.isEmpty ? nil : .notify),
            usageBytes: usageBytes,
            limitBytes: limitBytes
        )
    }

    public static func validate(
        billingCycleDay: Int,
        byteLimit: UInt64?,
        thresholds: [Int]
    ) -> Bool {
        (1...31).contains(billingCycleDay)
            && thresholds == thresholds.sorted()
            && thresholds.allSatisfy { (1...100).contains($0) }
            && (byteLimit == nil || byteLimit! > 0)
    }

    public static func validate(plan: NetworkPlan) -> Bool {
        self.validate(
            billingCycleDay: plan.billingCycleDay,
            byteLimit: plan.byteLimit,
            thresholds: plan.thresholds
        )
    }
}

public final class TrafficRuleStore {
    public static let networkPlanKey = "net.analytics.rules.v1.networkPlan"
    public static let networkPlansKey = "net.analytics.rules.v2.networkPlans"
    public static let allNetworksDefaultPlanID = "all-networks-default"
    public static let applicationRulesKey = "net.analytics.rules.v1.applicationRules"
    public static let includeLocalNetworkKey = "Network_analyticsIncludeLocal"
    public static let notifiedThresholdsKey = "net.analytics.rules.v1.notifiedThresholds"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Compatibility accessor for callers that have not selected a concrete network yet.
    public func networkPlan() -> NetworkPlan {
        let plans = self.allNetworkPlans()
        if let plan = plans[Self.allNetworksDefaultPlanID] {
            return plan
        }
        guard let data = self.defaults.data(forKey: Self.networkPlanKey),
              let plan = try? JSONDecoder().decode(NetworkPlan.self, from: data) else {
            return .default
        }
        return plan
    }

    /// Compatibility save used by the global/default settings surface.
    public func save(networkPlan: NetworkPlan) {
        guard TrafficRuleEngine.validate(plan: networkPlan) else { return }
        if let data = try? JSONEncoder().encode(networkPlan) {
            self.defaults.set(data, forKey: Self.networkPlanKey)
        }
        self.save(networkPlan: networkPlan, for: Self.allNetworksDefaultPlanID)
    }

    public func networkPlan(for networkID: String) -> NetworkPlan {
        var plans = self.allNetworkPlans()
        if let plan = plans[networkID] {
            return plan
        }
        if let fallback = plans[Self.allNetworksDefaultPlanID] {
            plans[networkID] = fallback
            self.persistNetworkPlans(plans)
            return fallback
        }
        if let data = self.defaults.data(forKey: Self.networkPlanKey),
           let legacy = try? JSONDecoder().decode(NetworkPlan.self, from: data) {
            plans[networkID] = legacy
            self.persistNetworkPlans(plans)
            return legacy
        }
        return .default
    }

    public func save(networkPlan: NetworkPlan, for networkID: String) {
        guard !networkID.isEmpty, TrafficRuleEngine.validate(plan: networkPlan) else { return }
        var plans = self.allNetworkPlans()
        plans[networkID] = networkPlan
        self.persistNetworkPlans(plans)
    }

    public func allNetworkPlans() -> [String: NetworkPlan] {
        guard let data = self.defaults.data(forKey: Self.networkPlansKey),
              let plans = try? JSONDecoder().decode([String: NetworkPlan].self, from: data) else {
            return [:]
        }
        return plans
    }

    private func persistNetworkPlans(_ plans: [String: NetworkPlan]) {
        guard let data = try? JSONEncoder().encode(plans) else { return }
        self.defaults.set(data, forKey: Self.networkPlansKey)
    }

    public func applicationRules() -> [ApplicationTrafficRule] {
        guard let data = self.defaults.data(forKey: Self.applicationRulesKey),
              let rules = try? JSONDecoder().decode([ApplicationTrafficRule].self, from: data) else {
            return []
        }
        return rules
    }

    public func save(applicationRules: [ApplicationTrafficRule]) {
        if let data = try? JSONEncoder().encode(applicationRules) {
            self.defaults.set(data, forKey: Self.applicationRulesKey)
        }
    }

    public var includeLocalNetwork: Bool {
        get {
            if self.defaults.object(forKey: Self.includeLocalNetworkKey) == nil {
                return true
            }
            return self.defaults.bool(forKey: Self.includeLocalNetworkKey)
        }
        set { self.defaults.set(newValue, forKey: Self.includeLocalNetworkKey) }
    }

    public func notifiedThresholds(for scope: String) -> Set<Int> {
        let map = self.defaults.dictionary(forKey: Self.notifiedThresholdsKey) as? [String: [Int]] ?? [:]
        return Set(map[scope] ?? [])
    }

    public func markNotified(thresholds: [Int], scope: String) {
        var map = self.defaults.dictionary(forKey: Self.notifiedThresholdsKey) as? [String: [Int]] ?? [:]
        var current = Set(map[scope] ?? [])
        thresholds.forEach { current.insert($0) }
        map[scope] = Array(current).sorted()
        self.defaults.set(map, forKey: Self.notifiedThresholdsKey)
    }

    public func resetNotified(scope: String) {
        var map = self.defaults.dictionary(forKey: Self.notifiedThresholdsKey) as? [String: [Int]] ?? [:]
        map[scope] = []
        self.defaults.set(map, forKey: Self.notifiedThresholdsKey)
    }

    public func clearRuntimeState() {
        self.defaults.removeObject(forKey: Self.notifiedThresholdsKey)
        self.defaults.removeObject(forKey: "net.analytics.runtime.cooldowns.v1")
        self.defaults.removeObject(forKey: "net.analytics.runtime.thresholds.v1")
    }
}

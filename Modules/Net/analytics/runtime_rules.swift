//
//  runtime_rules.swift
//  Net
//

import Foundation

public enum RuleActivationState: Equatable {
    case active
    case savedInactive(NetworkEnforcementUnavailableReason)
    case paused
    case temporarilyAllowed(until: Date)
    case failed(String)
}

public struct RuntimeRuleResult: Equatable {
    public let triggeredThresholds: [Int]
    public let requestedAction: QuotaAction?
    public let activationState: RuleActivationState

    public init(
        triggeredThresholds: [Int],
        requestedAction: QuotaAction?,
        activationState: RuleActivationState
    ) {
        self.triggeredThresholds = triggeredThresholds
        self.requestedAction = requestedAction
        self.activationState = activationState
    }
}

/// Evaluates only successfully committed samples and keeps notification state scoped to a rule cycle.
public final class TrafficRuntimeRuleService {
    private let repository: TrafficHistoryRepository
    private let ruleStore: TrafficRuleStore
    private let alertStore: TrafficAlertStore
    private let enforcer: NetworkRuleEnforcing
    private let preferencesStore: TrafficAnalyticsPreferencesStore
    private let clock: TrafficClock
    private let calendar: Calendar

    public init(
        repository: TrafficHistoryRepository,
        ruleStore: TrafficRuleStore = TrafficRuleStore(),
        alertStore: TrafficAlertStore = TrafficAlertStore(),
        enforcer: NetworkRuleEnforcing = NetworkExtensionRuleEnforcer(),
        preferencesStore: TrafficAnalyticsPreferencesStore = TrafficAnalyticsPreferencesStore(),
        clock: TrafficClock = SystemTrafficClock(),
        calendar: Calendar = .current
    ) {
        self.repository = repository
        self.ruleStore = ruleStore
        self.alertStore = alertStore
        self.enforcer = enforcer
        self.preferencesStore = preferencesStore
        self.clock = clock
        self.calendar = calendar
    }

    public func evaluate(batch: CommittedTrafficBatch) -> [RuntimeRuleResult] {
        guard !batch.samples.isEmpty else { return [] }
        return self.evaluate(samples: batch.samples)
    }

    public func evaluate(result: Result<CommittedTrafficBatch, TrafficPersistenceError>) -> [RuntimeRuleResult] {
        guard case .success(let batch) = result else { return [] }
        return self.evaluate(batch: batch)
    }

    public func evaluate(rule: ApplicationTrafficRule, usageBytes: UInt64) -> RuntimeRuleResult {
        let state = self.suppressionState(for: rule)
        if state != .active {
            return RuntimeRuleResult(triggeredThresholds: [], requestedAction: nil, activationState: state)
        }
        guard let limit = rule.byteLimit, limit > 0 else {
            return RuntimeRuleResult(triggeredThresholds: [], requestedAction: nil, activationState: .active)
        }
        let threshold = usageBytes >= limit ? 100 : 0
        return RuntimeRuleResult(
            triggeredThresholds: threshold == 100 ? [100] : [],
            requestedAction: threshold == 100 ? rule.action : nil,
            activationState: .active
        )
    }

    public func activationState(for rule: ApplicationTrafficRule) -> RuleActivationState {
        let suppression = self.suppressionState(for: rule)
        guard suppression == .active else { return suppression }
        if rule.action == .notify { return .active }
        guard case .available = self.enforcer.capability else {
            if case .unavailable(let reason) = self.enforcer.capability { return .savedInactive(reason) }
            return .savedInactive(.missingEntitlement)
        }
        return .active
    }

    @discardableResult
    public func activate(_ rule: ApplicationTrafficRule) -> RuleActivationState {
        let suppression = self.suppressionState(for: rule)
        guard suppression == .active else { return suppression }
        guard rule.action != .notify else { return .active }
        guard case .available = self.enforcer.capability else {
            if case .unavailable(let reason) = self.enforcer.capability { return .savedInactive(reason) }
            return .savedInactive(.missingEntitlement)
        }
        guard let action = self.enforcementAction(for: rule) else { return .failed("invalid request") }
        do {
            try self.enforcer.apply(action)
            return .active
        } catch let error as NetworkEnforcementError {
            switch error {
            case .invalidRequest: return .failed("failed")
            case .unavailable(let reason): return .savedInactive(reason)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func enforcementAction(for rule: ApplicationTrafficRule) -> NetworkEnforcementAction? {
        switch rule.action {
        case .notify: return nil
        case .rateLimit:
            return NetworkEnforcementAction(
                applicationID: rule.applicationID,
                kind: .rateLimit(
                    downloadBytesPerSecond: rule.downloadLimitBytesPerSecond,
                    uploadBytesPerSecond: rule.uploadLimitBytesPerSecond
                )
            )
        case .block:
            return NetworkEnforcementAction(applicationID: rule.applicationID, kind: .block(.both))
        }
    }

    private func evaluate(samples: [TrafficSample]) -> [RuntimeRuleResult] {
        let now = self.clock.now()
        var results: [RuntimeRuleResult] = []
        for rule in self.ruleStore.applicationRules() {
            let affected = samples.filter { $0.application.id == rule.applicationID }
            guard !affected.isEmpty else { continue }
            let referenceDate = affected.map(\.timestamp).max() ?? now
            let cycle = self.cycleInterval(containing: referenceDate, period: rule.period)
            let snapshot = TrafficAnalyticsEngine(repository: self.repository).snapshot(for: TrafficAnalyticsQuery(
                range: TrafficCustomRange.range(for: cycle.duration),
                selectedInterval: cycle,
                now: referenceDate
            ))
            let persistedUsage = snapshot.ranking.first { $0.identity.id == rule.applicationID }?.total
            let usage = persistedUsage ?? affected.reduce(UInt64(0)) { $0 + $1.delta.total }
            let scope = "rule:\(rule.id)|cycle:\(cycle.start.timeIntervalSince1970)"
            let prior = self.ruleStore.notifiedThresholds(for: scope)
            let raw = self.evaluate(rule: rule, usageBytes: usage)
            let triggered = raw.triggeredThresholds.filter { !prior.contains($0) }
            guard !triggered.isEmpty else {
                results.append(RuntimeRuleResult(
                    triggeredThresholds: [],
                    requestedAction: nil,
                    activationState: raw.activationState
                ))
                continue
            }
            self.ruleStore.markNotified(thresholds: triggered, scope: scope)
            let state: RuleActivationState
            if rule.action == .notify {
                state = .active
            } else {
                state = self.activate(rule)
            }
            let events = triggered.map { threshold in
                TrafficAlertEvent(
                    kind: .quota,
                    timestamp: referenceDate,
                    message: "\(rule.applicationID) reached \(threshold)% of its quota",
                    applicationID: rule.applicationID,
                    networkID: affected.first?.network.id
                )
            }
            self.alertStore.append(events)
            results.append(RuntimeRuleResult(
                triggeredThresholds: triggered,
                requestedAction: raw.requestedAction,
                activationState: state
            ))
        }
        results.append(contentsOf: self.evaluateNetworkPlans(samples: samples))
        return results
    }

    private func evaluateNetworkPlans(samples: [TrafficSample]) -> [RuntimeRuleResult] {
        var results: [RuntimeRuleResult] = []
        let preferences = self.preferencesStore.preferences()
        for networkID in Set(samples.map { $0.network.id }) {
            let plan = self.ruleStore.networkPlan(for: networkID)
            guard let limit = plan.byteLimit, limit > 0 else { continue }
            let referenceDate = samples.filter { $0.network.id == networkID }.map(\.timestamp).max() ?? self.clock.now()
            let cycle = self.billingCycle(containing: referenceDate, day: plan.billingCycleDay)
            let snapshot = TrafficAnalyticsEngine(repository: self.repository).snapshot(for: TrafficAnalyticsQuery(
                range: TrafficCustomRange.range(for: cycle.duration),
                networkID: networkID,
                selectedInterval: cycle,
                billingCycleDay: plan.billingCycleDay,
                now: referenceDate
            ))
            let fallback = samples.filter { $0.network.id == networkID }.reduce(UInt64(0)) { $0 + $1.delta.total }
            let usage = snapshot.total == 0 ? fallback : snapshot.total
            let scope = "network:\(networkID)|cycle:\(cycle.start.timeIntervalSince1970)"
            let prior = self.ruleStore.notifiedThresholds(for: scope)
            let evaluation = TrafficRuleEngine.evaluate(
                usageBytes: usage,
                limitBytes: limit,
                thresholds: plan.thresholds,
                alreadyNotified: prior,
                action: preferences.overQuotaAction,
                isPaused: false,
                allowUntil: nil,
                now: referenceDate
            )
            guard !evaluation.triggeredThresholds.isEmpty else { continue }
            self.ruleStore.markNotified(thresholds: evaluation.triggeredThresholds, scope: scope)
            self.alertStore.append(evaluation.triggeredThresholds.map { threshold in
                TrafficAlertEvent(
                    kind: .quota,
                    timestamp: referenceDate,
                    message: "\(networkID) reached \(threshold)% of its quota",
                    networkID: networkID
                )
            })
            let state: RuleActivationState
            if evaluation.action == nil || evaluation.action == .notify {
                state = .active
            } else if case .unavailable(let reason) = self.enforcer.capability {
                state = .savedInactive(reason)
            } else {
                // Network-wide packet control is not represented by an application enforcer action.
                state = .failed("Network-wide enforcement requires a functional Network Extension adapter")
            }
            results.append(RuntimeRuleResult(
                triggeredThresholds: evaluation.triggeredThresholds,
                requestedAction: evaluation.action,
                activationState: state
            ))
        }
        return results
    }

    private func billingCycle(containing date: Date, day: Int) -> DateInterval {
        let requested = min(max(day, 1), 31)
        let month = self.calendar.dateInterval(of: .month, for: date)?.start ?? self.calendar.startOfDay(for: date)
        let current = self.cycleDate(month: month, requestedDay: requested)
        if date >= current {
            let nextMonth = self.calendar.date(byAdding: .month, value: 1, to: month) ?? date
            return DateInterval(start: current, end: self.cycleDate(month: nextMonth, requestedDay: requested))
        }
        let previousMonth = self.calendar.date(byAdding: .month, value: -1, to: month) ?? date
        return DateInterval(start: self.cycleDate(month: previousMonth, requestedDay: requested), end: current)
    }

    private func cycleDate(month: Date, requestedDay: Int) -> Date {
        let maximum = self.calendar.range(of: .day, in: .month, for: month)?.count ?? 28
        var components = self.calendar.dateComponents([.year, .month], from: month)
        components.day = min(requestedDay, maximum)
        return self.calendar.date(from: components) ?? month
    }

    private func suppressionState(for rule: ApplicationTrafficRule) -> RuleActivationState {
        if rule.isPaused { return .paused }
        if let allowUntil = rule.allowUntil, allowUntil > self.clock.now() {
            return .temporarilyAllowed(until: allowUntil)
        }
        return .active
    }

    private func cycleInterval(containing date: Date, period: QuotaPeriod) -> DateInterval {
        switch period {
        case .daily:
            let start = self.calendar.startOfDay(for: date)
            return DateInterval(start: start, end: self.calendar.date(byAdding: .day, value: 1, to: start) ?? date)
        case .weekly:
            let start = self.calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? self.calendar.startOfDay(for: date)
            return DateInterval(start: start, end: self.calendar.date(byAdding: .weekOfYear, value: 1, to: start) ?? date)
        case .monthly, .custom:
            let start = self.calendar.dateInterval(of: .month, for: date)?.start ?? self.calendar.startOfDay(for: date)
            return DateInterval(start: start, end: self.calendar.date(byAdding: .month, value: 1, to: start) ?? date)
        }
    }
}

# Network Analytics Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add plans, quota and anomaly alerts, capability-gated enforcement controls, localization, and final visual verification.

**Architecture:** Codable rules are evaluated by a pure engine. Actions flow through `NetworkRuleEnforcing`; the standard build injects an unavailable enforcer, while Network Extension code remains behind a signing capability boundary. UI always renders the real capability state.

**Tech Stack:** Swift, AppKit, UserNotifications, compile-time NetworkExtension boundary, XCTest, Xcode screenshot verification.

---

### Task 1: Add Plans, Quotas, And Rule Persistence

**Files:**
- Create: `Modules/Net/analytics/rules.swift`
- Modify: `Modules/Net/analytics/history.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing rule tests**

Cover network billing days; daily, weekly, monthly, and custom application periods; 80/90/100 defaults; once-per-threshold notification; cycle reset; pause; and temporary allowance.

- [ ] **Step 2: Implement models and engine**

Add `NetworkPlan`, `ApplicationTrafficRule`, `QuotaPeriod`, `QuotaAction`, and `RuleEvaluation`. Persist versioned keys separate from samples. Inject calendar and current time.

- [ ] **Step 3: Verify and commit**

Run focused tests and commit as `feat(net): add traffic quota rules`.

### Task 2: Add Alerts And Anomaly Detection

**Files:**
- Create: `Modules/Net/analytics/alerts.swift`
- Modify: `Modules/Net/analytics/coordinator.swift`
- Modify: `Modules/Net/analytics/views.swift`
- Modify: `Modules/Net/analytics/charts.swift`
- Modify: `Modules/Net/notifications.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing alert tests**

Test sustained upload, baseline spikes with insufficient data, disconnect/recovery, repeated instability, event de-duplication, and timeline marker conversion.

- [ ] **Step 2: Implement alerts**

Persist events, publish through the existing Net notification wrapper, expose the bell-button event list, and render warning markers in the timeline. Default actions notify only.

- [ ] **Step 3: Verify and commit**

Run full tests and commit as `feat(net): detect and report traffic anomalies`.

### Task 3: Add Honest Enforcement Capability

**Files:**
- Create: `Modules/Net/analytics/enforcement.swift`
- Create: `Modules/Net/analytics/network_extension_enforcer.swift`
- Modify: `Modules/Net/analytics/application_detail.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing capability tests**

Verify the standard enforcer reports `.unavailable(.missingEntitlement)`, every apply fails without mutating state, and a fake capable enforcer receives independent upload, download, and block actions.

- [ ] **Step 2: Implement interface and disabled UI**

Define capability, action, and error types. Add independent upload/download limits, block directions, quota actions, pause, and temporary allowance controls. Wire them to capability state, show the signing explanation, and never display an active badge after a failed action. Keep the Network Extension adapter behind a build flag so the standard scheme requires no entitlement.

- [ ] **Step 3: Verify and commit**

Run full tests and commit as `feat(net): gate application network enforcement`.

### Task 4: Add Settings And Localization

**Files:**
- Modify: `Modules/Net/settings.swift`
- Modify: `Stats/Supporting Files/en.lproj/Localizable.strings`
- Modify: `Stats/Supporting Files/zh-Hans.lproj/Localizable.strings`
- Modify: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Write failing validation tests**

Test billing days 1 through 31, positive byte/rate limits, ordered thresholds, local-network inclusion, and confirmed history clear.

- [ ] **Step 2: Implement settings and strings**

Add plan editing, alert thresholds, local-network toggle, refresh default, database status, clear confirmation, and enforcement capability status. Add every visible string in English and Simplified Chinese.

- [ ] **Step 3: Verify and commit**

Run full tests and commit as `feat(net): add analytics settings and localization`.

### Task 5: Final Build, Visual Verification, And Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-17-network-analytics-design.md` only if verification requires a documented correction

- [ ] **Step 1: Run automated verification**

```bash
xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Stats.xcodeproj -scheme Stats -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: tests and build pass; diff check is empty.

- [ ] **Step 2: Verify persistence and exports**

Generate traffic, quit, relaunch, and verify totals and ranking persist. Compare visible totals with CSV and JSON for the same selection.

- [ ] **Step 3: Verify the interface visually**

Capture light and dark screenshots at 720x480 and 1440x900. Check overlap, truncation, blank charts, nested cards, and state-driven layout shifts. Exercise hover, drag, heatmap click, expansion, manual refresh, menus, and unavailable enforcement.

- [ ] **Step 4: Document, commit, and push**

Document local storage, reset, export, and the Apple entitlement boundary. Commit as `docs(net): document analytics and enforcement limits`, then push `codex/network-analytics` to origin.

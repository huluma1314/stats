# Network Analytics Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tested process-traffic model, history repository, retention aggregation, and analytics query engine to the Net module.

**Architecture:** `ProcessReader` produces normalized cumulative snapshots, a coordinator converts them to deltas, and a repository persists ordered records through a narrow key-value adapter over Stats' LevelDB wrapper. Pure analytics services query repository records and produce immutable view snapshots.

**Tech Stack:** Swift 5, Foundation, AppKit process metadata, existing Kit LevelDB wrapper, XCTest, Xcode 17.

---

### Task 1: Restore The Upstream Build Baseline

**Files:**
- Create: `Stats/UserContext.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Reproduce the baseline failure**

Run `xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`.

Expected: compilation fails in `Stats/helpers.swift` because upstream commit `d6d8cbc0` references `UserContext` without adding its implementation.

- [ ] **Step 2: Add the missing implementation**

Create the exact module API:

```swift
enum UserContext {
    static func isScreenLocked() -> Bool
    static func secondsSinceLastInput() -> TimeInterval
    static func busyReason() -> String?
}
```

Use `CGSessionCopyCurrentDictionary()` for lock state and `CGEventSource.secondsSinceLastEventType` for idle time. Only return a busy reason for an observable presentation condition; unknown conditions return nil. Add the file to the Stats Sources phase.

- [ ] **Step 3: Verify and commit the isolated repair**

Run the command from Step 1. Expected: the missing-symbol errors disappear and the existing suite runs. Then commit `Stats/UserContext.swift` and the project file as `fix(app): restore missing user context helper`.

### Task 2: Define Traffic Models And Delta Semantics

**Files:**
- Create: `Modules/Net/analytics/models.swift`
- Create: `Modules/Net/analytics/deltas.swift`
- Create: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing tests**

Add `@testable import Net` tests proving normal counter growth returns exact deltas, a counter reset returns zero, and process reuse with a changed start token does not inherit old counters:

```swift
func testDeltaIgnoresCounterReset() {
    let previous = ProcessTrafficCounter(identity: .fixture, processID: 42,
        processStartToken: 1, download: 900, upload: 500)
    let current = ProcessTrafficCounter(identity: .fixture, processID: 42,
        processStartToken: 1, download: 100, upload: 50)
    XCTAssertEqual(TrafficDeltaCalculator.delta(from: previous, to: current), .zero)
}
```

- [ ] **Step 2: Verify RED**

Run `xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:Tests/NetAnalytics`. Expected: missing model and calculator symbols.

- [ ] **Step 3: Implement minimal domain API**

Define Codable, Equatable `ApplicationIdentity`, `ProcessTrafficCounter`, `TrafficDelta`, `NetworkIdentity`, `TrafficSample`, `TrafficBucket`, and `ApplicationTrafficSummary`. Clamp negative deltas to zero and use `(processID, processStartToken)` as the lifetime key.

- [ ] **Step 4: Verify GREEN and commit**

Run focused and full tests. Commit the four files as `feat(net): add traffic analytics domain models`.

### Task 3: Extract And Test nettop Parsing

**Files:**
- Create: `Modules/Net/analytics/nettop.swift`
- Modify: `Modules/Net/readers.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write parser tests**

Cover valid rows, names containing dots, missing fields, invalid bytes, and header-only output with the API `NettopSnapshotParser.parse(csv:)`.

- [ ] **Step 2: Verify RED**

Run focused tests. Expected: missing parser symbols.

- [ ] **Step 3: Implement parser and preserve reader behavior**

Return `NettopParseResult` with rows and malformed-row count. Keep the existing `/usr/bin/nettop` command and locale, and make `ProcessReader` consume the parser without changing popup output.

- [ ] **Step 4: Verify and commit**

Run focused and full tests. Commit as `refactor(net): isolate nettop snapshot parsing`.

### Task 4: Resolve And Group Application Identity

**Files:**
- Create: `Modules/Net/analytics/identity.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing grouping tests**

Use a fake metadata provider to prove helpers with one owning bundle group together, command-line tools remain separate by executable path, and search matches app name, bundle ID, and process name.

- [ ] **Step 2: Implement identity resolution**

Add `ProcessMetadataProviding` and an AppKit provider using `NSRunningApplication`, bundle URL, parent metadata, and canonical executable path. Inject the provider so grouping remains deterministic.

- [ ] **Step 3: Verify and commit**

Run focused tests and commit as `feat(net): group traffic by application identity`.

### Task 5: Add Ordered History Storage

**Files:**
- Modify: `Kit/plugins/DB.swift`
- Create: `Modules/Net/analytics/history.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write repository contract tests**

Test ordered insertion, inclusive ranges, app/network filters, deletion, and persistence encoding through an in-memory `TrafficKeyValueStoring` fake. Keys sort as `net.analytics.v1|second|00000000001721234567|network-id|application-id`.

- [ ] **Step 2: Verify RED**

Run focused tests. Expected: missing repository symbols.

- [ ] **Step 3: Extend DB and implement repository**

Expose queue-protected raw put, prefix values, prefix keys, and batch delete methods from `DB`. Add `LevelDBTrafficStore` as the only adapter. Encode JSON and execute repository work on one serial queue.

- [ ] **Step 4: Verify and commit**

Run focused and full tests. Commit as `feat(net): persist ordered traffic history`.

### Task 6: Implement Retention And Analytics Queries

**Files:**
- Create: `Modules/Net/analytics/aggregation.swift`
- Create: `Modules/Net/analytics/queries.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing calendar and retention tests**

Cover every adaptive bucket, DST transitions, 24-hour seconds, 30-day minutes, two-year hours, permanent month summaries, network-interface filters, tunnel/physical de-duplication, local-network exclusion, ranking, peak rate, and billing forecast.

- [ ] **Step 2: Implement services**

Use injected `Calendar`, time, and repository interfaces. Replace aggregate keys idempotently before deleting expired sources. Return immutable `TrafficAnalyticsSnapshot` values containing totals, buckets, ranking, and forecast.

- [ ] **Step 3: Verify and commit**

Run focused tests, the full suite, and `xcodebuild build -project Stats.xcodeproj -target Net -configuration Debug CODE_SIGNING_ALLOWED=NO`. Commit as `feat(net): aggregate and query traffic history`.

### Task 7: Wire Continuous Collection

**Files:**
- Create: `Modules/Net/analytics/coordinator.swift`
- Modify: `Modules/Net/main.swift`
- Modify: `Modules/Net/readers.swift`
- Modify: `Tests/NetAnalytics.swift`
- Modify: `Stats.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write failing coordinator tests**

Prove one-second collection continues during manual UI refresh, first counters establish a baseline without writing bytes, later counters write deltas, failures back off, and termination flushes pending records.

- [ ] **Step 2: Implement and mount coordinator**

Create it in `Network`, feed usage and process snapshots, start with module mount, stop on termination, and publish lightweight snapshots without touching AppKit off the main thread.

- [ ] **Step 3: Verify and commit**

Run the full suite and commit as `feat(net): collect persistent application traffic`.

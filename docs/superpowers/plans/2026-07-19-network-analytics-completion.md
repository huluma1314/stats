# Network Analytics Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the existing Network analytics implementation to the agreed retention, network identity, runtime rule, alert, export, and Bytetally-parity acceptance contract without regressing Stats' existing real-time Network page.

**Architecture:** Keep `UsageReader` and `ProcessReader` as collection sources, but make one repository queue the sole owner of versioned analytics history and one runtime coordinator the owner of quota/anomaly evaluation. Build stable network identities, per-network plans, query-tier planning, capability-gated enforcement, and immutable presentation snapshots on those boundaries; AppKit views consume snapshots and never infer persistence or enforcement success.

**Tech Stack:** Swift 5/6, AppKit, Foundation, SystemConfiguration, existing Kit LevelDB wrapper, XCTest, Xcode 26.4.1 (build 17E202), macOS 12 deployment target.

---

## Current Baseline

- Branch: `codex/network-analytics`
- Reviewed starting docs commit: `f2c4fba9` (`docs(net): plan analytics completion work`). This documentation-only commit may have a different SHA after review amendments.
- Parent implementation baseline: `1dd31cb4b2a06324a4c9c94a29da80ec82f2b9f7`; all implementation and test expectations in this plan are measured from that parent.
- Focused parent baseline: `Tests/NetAnalyticsTests` executes 40 tests with 0 failures and reports `** TEST SUCCEEDED **`.
- Unsigned Debug baseline: the Stats scheme reports `** BUILD SUCCEEDED **`.
- Existing nonfatal warnings: SwiftLint is not installed, the test target emits a deployment/XCTest warning, and the SMC helper service is absent on the verification machine.
- Existing implementation already includes process deltas and identity grouping, version-1 ordered history, basic compaction and analytics, three Network preview pages, custom history ranges, live application traffic, quota/rule models, an unavailable enforcer, anomaly primitives, CSV/JSON export, and initial analytics settings.
- This plan closes the remaining correctness and parity gaps. It does not redesign unrelated Stats modules and does not add a subscription or Pro gate.

## Completion Criteria

The work is complete only when all of the following are true:

- Existing 40 focused tests remain green and new tests cover storage v2 raw/aggregate keys, multi-helper restart round trips, queue ownership, atomic failure gating, migration with unknown legacy aggregate counts, complete-bucket compaction and interruption recovery, both deletion scopes, tier boundaries, registry aliases, per-network plans, runtime quotas, unavailable enforcement, runtime anomalies, alert persistence, proxy labeling, icon fallback, and export parity.
- One-second records always expire after 24 hours. Minute, hour, and day records use persisted user-configurable defaults of 7, 60, and 730 days. Monthly and yearly summaries have no automatic expiry.
- Queries split requested intervals across the correct retention tiers without gaps or duplicate bytes, including custom ranges and calendar boundaries.
- Network identities survive interface changes where their underlying network identity is stable, aliases are editable, and plans are keyed independently per network.
- Notify rules run without an entitlement. Future rate-limit/block rules can be saved, but a missing entitlement leaves them explicitly saved and inactive; activation/apply controls are unavailable, no success state is shown, and no `pf` fallback exists.
- Runtime quota, sustained-upload, baseline-spike, disconnect/recovery, and instability events are evaluated, de-duplicated, persisted, surfaced in notifications, and represented on the timeline.
- CSV and JSON exports exactly match the active time range, concrete network filter, chart selection, grouping choice, proxy labels, and visible totals. Application icons resolve with deterministic fallbacks and never block query work.
- The real-time page remains functional, the analytics pages are usable at minimum and wide sizes in light and dark appearances, English and Simplified Chinese strings are complete, the macOS 12 target remains intact, focused/full tests pass, the unsigned Debug build passes, and `git diff --check` is clean.

### Task 1: Reconfirm Baseline And Lock The Documentation Contract

**Files:**
- Read: `docs/superpowers/specs/2026-07-17-network-analytics-design.md`
- Read: `docs/superpowers/plans/2026-07-19-network-analytics-completion.md`
- Read: `Modules/Net/analytics/*.swift`
- Read: `Modules/Net/settings.swift`
- Read: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Verify the branch and clean baseline**

Run:

```bash
git status --short --branch
git rev-parse HEAD
git branch --show-current
```

Expected: branch `codex/network-analytics`, the reviewed documentation commit descended directly from parent implementation baseline `1dd31cb4b2a06324a4c9c94a29da80ec82f2b9f7`, and no working-tree changes. The reviewed docs commit was originally `f2c4fba9` and may have a replacement SHA after amendment. Record the actual reviewed starting SHA before changing implementation files; if the parent is not `1dd31cb4` or the controller has not approved a later parent baseline, stop on the mismatch.

- [ ] **Step 2: Re-run the focused baseline**

Run:

```bash
xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:Tests/NetAnalyticsTests
```

Expected: 40 tests, 0 failures, and `** TEST SUCCEEDED **`. Treat the known SwiftLint, test deployment/XCTest, and missing SMC helper messages as nonfatal; stop for any new warning that indicates analytics code was skipped or any test failure.

- [ ] **Step 3: Re-run the unsigned Debug build**

Run:

```bash
xcodebuild build -project Stats.xcodeproj -scheme Stats -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **` with the macOS 12 deployment target unchanged.

- [ ] **Step 4: Map every completion criterion to a later task**

Confirm the implementation sequence before editing source:

1. Storage v2 and database ownership: Task 2.
2. Retention and query-tier correctness: Task 3.
3. Network registry, aliases, and per-network plans: Task 4.
4. Runtime quota and enforcement behavior: Task 5.
5. Runtime anomaly and alert delivery: Task 6.
6. Export, icons, proxy labeling, and UI completion: Task 7.
7. Bytetally parity and delivery verification: Task 8.

This milestone changes no files and has no commit. Do not start Task 2 if a completion criterion has no owning task.

### Task 2: Introduce History Storage V2 And Single-Queue Ownership

**Files:**
- Modify: `Kit/plugins/DB.swift`
- Modify: `Modules/Net/readers.swift`
- Modify: `Modules/Net/main.swift`
- Modify: `Modules/Net/analytics/coordinator.swift`
- Modify: `Modules/Net/analytics/history.swift`
- Modify: `Modules/Net/analytics/identity.swift` (process metadata provider)
- Modify: `Modules/Net/analytics/models.swift`
- Modify: `Modules/Net/analytics/nettop.swift`
- Modify: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Add failing storage-v2 contract tests**

Add tests named:

```swift
func testHistoryV2ReadsLegacyV1AndWritesOnlyV2()
func testHistoryV2RawKeysRoundTripMultipleHelpersAcrossRestart()
func testReaderToRepositoryPIDReuseUsesKernelProcessStartToken()
func testProductionNettopConnectionCommandAndParserCarryPhysicalAndTunnelInterfaces()
func testConnectionCountersAggregateOncePerProcessLifetimeAndInterface()
func testConnectionSnapshotDeduplicatesRepeatedRowsWithoutAddingProcessSummaryBytes()
func testNettopCollectionTimeoutAndRetryBackoffAreBounded()
func testLegacyAggregateWithoutSampleCountRemainsUnknown()
func testHistoryRepositorySerializesStoreAccessOnItsOwnerQueue()
func testHistoryReplacementCommitsDestinationsAndSourceDeletesAtomically()
func testAtomicIngestFailureProducesNoCommittedBatch()
func testDeleteTrafficHistoryPreservesAlertsRulesAndPreferences()
func testClearAnalyticsDataRemovesTrafficAlertsAndRuntimeStateButPreservesPreferences()
```

Use a recording `TrafficKeyValueStoring` fake that captures operation order, queue-specific ownership, atomic-batch results, and injected failures. Seed a v1 second key, read it through the repository, insert a new sample, and assert the new raw key starts with `net.analytics.v2|`; seed a legacy aggregate without a sample-count field and assert its decoded count remains `nil`/unknown rather than becoming `1`. Round-trip raw records for two helpers owned by the same application, including a simulated repository restart, and prove their keys remain distinct while their aggregates converge on the same network/application/bucket key. Drive two lifetimes that reuse one PID through the real reader-to-repository boundary with different kernel process-start tokens and assert distinct raw v2 keys.

Exercise the production `ProcessReader` command builder and `NettopSnapshotParser` together, not only a synthetic row parser. Assert the launched command uses connection-level CSV output without `-P` (for example `/usr/bin/nettop -L 1 -n -x` with an explicit supported column selection containing `interface`, `bytes_in`, and `bytes_out`), and parse representative output containing process summary rows plus multiple child connection rows. The fixture must include simultaneous physical and tunnel observations, repeated/duplicate connection rows, one connection without interface attribution, and cumulative counters. Assert the parser associates each child connection with the current process summary/lifetime, retains a stable connection identity when `nettop` supplies one (otherwise a normalized row fingerprint), keeps the observed interface on each connection, and uses the current primary network only for the genuinely unattributed connection. Across consecutive snapshots, compute non-negative deltas per `(process lifetime, connection identity, observed interface)` before summing once into `(process lifetime, interface)` counters; process summary rows are ownership/metadata boundaries and must not be added on top of their child rows. Assert repeated rows in one snapshot and the same connection exposed more than once do not duplicate bytes, while distinct connections on the same interface aggregate correctly. Add a runner test with an injected hung launch/empty output/repeated failure sequence and fake clock or scheduler; prove each invocation has a finite timeout, the child process and pipes are cleaned up, retry delay is capped, and collection returns control without an unbounded block or retry loop.

For replacement, assert destination puts and exact source deletes are submitted in one atomic transaction and are never partially visible. For atomic ingest, inject a partial/write failure and assert the repository returns failure and exposes no committed samples. For scoped deletion, seed traffic history, alert events, cooldown/threshold state, rules, and preferences: `deleteTrafficHistory()` removes only traffic prefixes, while `clearAnalyticsData()` additionally removes alert events and cooldown/threshold runtime state but preserves rules, retention/alert preferences, aliases, and network plans.

- [ ] **Step 2: Verify RED**

Run the focused test command from Task 1.

Expected: the new tests fail because the repository writes `v1`, the reader substitutes PID for a real process-start token, `TrafficSample`/raw v2 keys cannot preserve that token, the production command still uses `nettop -P` process summaries that cannot reliably attribute each row to an interface, the parser cannot associate connection rows with process lifetimes or prevent summary/connection duplicate counting, collection execution has no proven bounded timeout/backoff contract, legacy aggregates invent a count, and the repository exposes no migration-compatible v2 behavior or atomic result, conflates traffic-only deletion with a full analytics reset, and cannot prove owner-queue operation ordering.

- [ ] **Step 3: Define the v2 record and key contract**

In `history.swift`, make the repository write schema v2 while retaining a read-only v1 decoder:

```swift
public enum TrafficHistorySchema: String, Codable {
    case v1
    case v2
}

public struct StoredTrafficRecord: Codable, Equatable {
    public let schema: TrafficHistorySchema
    public let level: TrafficAggregationLevel
    public let sample: TrafficSample
    public let sampleCount: Int?
}
```

The v2 key order remains prefix-queryable, but raw records and aggregate records have different identity requirements:

```text
raw second:
net.analytics.v2|second|<20-digit unix second>|<escaped network id>|<escaped application id>|<escaped process discriminator>

aggregate minute/hour/day/month/year:
net.analytics.v2|<level>|<20-digit bucket start>|<escaped network id>|<escaped application id>
```

The raw process discriminator is stable for the lifetime of one OS process and is composed from canonical executable identity plus the process ID and a real kernel process-start token captured by `AppKitProcessMetadataProvider` (the `proc_bsdinfo` start seconds/microseconds, or an equivalent kernel-provided token). PID, reader observation time, or a synthetic value derived from PID is forbidden because PIDs are reused; helper name alone is insufficient because multiple helpers can run concurrently. Propagate the token through `ProcessMetadata`, `ProcessTrafficCounter`, and `TrafficSample`, and include it in the raw v2 discriminator. Aggregation deliberately drops the discriminator from its key so all helpers owned by the same application merge into one network/application/bucket destination key, while retaining mergeable per-process summaries in the aggregate payload for later process export.

Replace the production `nettop -P` process-summary invocation with connection-level CSV collection that does not pass `-P`, using only flags supported by the deployed macOS `nettop` (for example `-L 1 -n -x` plus an explicit `-J`/`-j` column set containing `interface`, `bytes_in`, and `bytes_out`). Keep command construction and execution injectable so tests execute the exact production arguments and parser path. The parser treats process summary rows as parent/lifetime metadata and their following socket/connection rows as the attributable counters. Each normalized connection observation carries its owning process metadata and kernel start token, a stable connection key from a supplied connection identifier when available or a deterministic normalized row fingerprint otherwise, its cumulative download/upload counters, and its observed interface when present.

Maintain prior cumulative counters keyed by `(process lifetime discriminator, connection key, observed interface)`. For each snapshot, canonicalize and de-duplicate repeated connection rows by that key, compute monotonic non-negative deltas once per connection, then aggregate those deltas by `(process lifetime, interface)` before emitting samples. Never add the process summary cumulative counters to the connection totals when child connection rows are available, and never count the same connection once as a summary and again as a child row. Distinct connections for the same process/interface do sum. Preserve `nil` interface attribution when a usable connection row or process-only fallback genuinely lacks interface information; resolve that unattributed total through the current primary network only after parsing cannot supply an interface, never merely because one duplicate row omitted it. Physical and tunnel observations remain separate process-lifetime/interface totals for later all-networks de-duplication.

Run each snapshot command with a finite timeout and guaranteed task/pipe cleanup. Launch failure, timeout, malformed/empty output, and parser failure publish diagnostics and schedule another collection using bounded/capped backoff; no failure path may block the reader indefinitely, spin in an immediate retry loop, or stop the independent real-time interface reader.

Escape `%`, `|`, and newline in every identifier component before composing keys. A raw v1 second sample is one observed sample and may decode with `sampleCount == 1`; a legacy aggregate that did not persist sample count must decode with `sampleCount == nil`/unknown and must never invent `1`. New writes use only v2; a successful read of v1 must not rewrite or delete data during a query.

- [ ] **Step 4: Make the repository the sole database owner**

Keep all repository public methods synchronous for current callers, but route every store call through the repository's dedicated serial queue. Define a throwing or explicit-result atomic persistence contract; callers must be able to distinguish a fully committed batch from failure, and a partial batch must never be reported as committed. One acceptable shape is:

```swift
func writeAtomically(
    puts: [(key: String, value: String)],
    deletes: [String]
) throws

@discardableResult
func ingest(_ samples: [TrafficSample]) -> Result<CommittedTrafficBatch, TrafficPersistenceError>
```

`CommittedTrafficBatch` contains only samples whose complete write transaction committed. The LevelDB implementation must use one database write batch (or an equivalent all-or-nothing primitive) for the requested puts/deletes; catching/logging an error and returning success is forbidden. `LevelDBTrafficStore` remains a narrow adapter and must not create another analytics queue. `DB` may protect LevelDB internally, but no analytics caller may access `DB.shared` directly after construction of `LevelDBTrafficStore`. Add `dispatchPrecondition(condition: .onQueue(ownerQueue))` to private repository helpers, not to public entry points.

- [ ] **Step 5: Implement atomic replacement and two scoped deletion APIs**

Encode all destination records first. On the owner queue, commit destination puts and exact source deletes with the atomic persistence API. A successful return means the whole replacement committed; an error means no destination or source mutation is visible. If the store cannot atomically combine puts and deletes, persist an explicit merge transaction/journal and recover it before queries, rather than claiming atomicity from write ordering alone.

Expose two distinct operations:

```swift
func deleteTrafficHistory() throws
func clearAnalyticsData() throws
```

`deleteTrafficHistory()` deletes only traffic record prefixes for v1 and v2. `clearAnalyticsData()` calls the traffic deletion path and also deletes persisted analytics alert-event records plus runtime cooldown and quota/anomaly threshold state. Both operations preserve retention and alert preferences, network aliases/plans, and saved application rules. The destructive Settings reset invokes `clearAnalyticsData()`; traffic-only maintenance/tests invoke `deleteTrafficHistory()`.

- [ ] **Step 6: Verify and commit**

Run:

```bash
xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:Tests/NetAnalyticsTests
git diff --check
git add Kit/plugins/DB.swift Modules/Net/readers.swift Modules/Net/main.swift Modules/Net/analytics/coordinator.swift Modules/Net/analytics/history.swift Modules/Net/analytics/identity.swift Modules/Net/analytics/models.swift Modules/Net/analytics/nettop.swift Tests/NetAnalytics.swift
git commit -m "feat(net): add versioned analytics history ownership"
```

Expected: focused tests pass, diff check is empty, and the commit contains only storage-v2 work.

### Task 3: Complete Tiered Retention And Query Planning

**Files:**
- Modify: `Modules/Net/analytics/history.swift`
- Modify: `Modules/Net/analytics/aggregation.swift`
- Modify: `Modules/Net/analytics/queries.swift`
- Modify: `Modules/Net/analytics/rules.swift`
- Modify: `Modules/Net/analytics/coordinator.swift`
- Modify: `Modules/Net/settings.swift`
- Modify: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Add failing retention and query-plan tests**

Add tests named:

```swift
func testRetentionDefaultsAreFixed24HoursAndConfigurable7_60_730Days()
func testSettingsResetInvokesClearAnalyticsDataNotTrafficOnlyDeletion()
func testCompactionPromotesSecondMinuteHourDayMonthAndYearWithoutLoss()
func testRetentionAtNonAlignedNowWaitsForWholeDestinationBucketBeforeCompacting()
func testMonthlyAndYearlySummariesNeverExpire()
func testQueryPlannerSplitsARequestAcrossAvailableTiersWithoutOverlap()
func testCustomRangeAcrossTierBoundariesHasNoMissingOrDuplicateBytes()
func testCompactionRespectsCalendarDayMonthYearAcrossDST()
func testCompactionBatchLimitInsideOneDestinationBucketFinishesTheWholeBucket()
func testInterruptedCompleteBucketCompactionRestartsWithoutLossOrDuplication()
func testRawToMinuteCompactionPreservesProcessSummariesForExportHelper()
```

Use a fixed Gregorian calendar and a time zone with a DST transition. Seed uniquely sized samples on both sides of every cutoff and assert exact byte totals and exact segment boundaries. Use non-aligned `now` values for second-to-minute and later promotions: if the cutoff falls inside a destination bucket, assert that entire bucket remains at the source tier until its end is older than the cutoff, allowing retention slack shorter than one destination bucket and never deleting early. Include a range older than 730 days so month summaries are selected, and a multi-year overview so year summaries are selected without also counting the same months. Place the configured `compactionBatchSize` boundary inside one destination minute bucket; assert the pass extends through the end of that bucket, writes one complete aggregate, and starts no later bucket. Inject interruption at the complete destination transaction boundary, restart the repository/coordinator, and assert recovery produces exactly one complete aggregate with every source byte and no duplicate. Compact raw helper records to a minute aggregate, pass it through the process-export row helper, and assert its mergeable per-process summaries remain exportable with exact totals.

- [ ] **Step 2: Verify RED**

Run the focused test command.

Expected: failures show the missing `.day` level, old 30-day/two-year hard-coded policy, missing year promotion, unbounded compaction, and single-tier query selection.

- [ ] **Step 3: Implement the agreed retention policy**

Add `.day` to `TrafficAggregationLevel`. Replace the old three-duration policy with:

```swift
public struct TrafficRetentionPolicy: Equatable {
    public static let secondRetention: TimeInterval = 24 * 60 * 60
    public let minuteRetentionDays: Int
    public let hourRetentionDays: Int
    public let dayRetentionDays: Int
    public let compactionBatchSize: Int

    public static let standard = TrafficRetentionPolicy(
        minuteRetentionDays: 7,
        hourRetentionDays: 60,
        dayRetentionDays: 730,
        compactionBatchSize: 2_000
    )
}
```

Load the configurable values from `TrafficAnalyticsPreferencesStore`; do not expose or persist a second-retention setting. Keep the existing settings menus for minute/hour/day and ensure their selected defaults are 7, 60, and 730 days. Wire the confirmed destructive Settings action to `clearAnalyticsData()`, not `deleteTrafficHistory()`, and verify it clears traffic, alert events, and cooldown/threshold runtime state while retaining all user preferences, aliases/plans, and saved rules.

- [ ] **Step 4: Implement bounded calendar-aware promotion**

Promote records in this order:

```text
second older than 24 hours -> minute
minute older than configured minute days -> hour
hour older than configured hour days -> day
day older than configured day days -> month
completed months -> year summary while retaining month summaries
month and year -> never automatically delete
```

Group destination boundaries with the injected `Calendar`, preserve download, upload, peak, optional sample count, application, network, route metadata, and mergeable per-process summaries, and compact only when the whole destination bucket is older than the source-tier cutoff. Eligibility is determined by `destinationBucket.end <= cutoff`, not by an individual source timestamp; a non-aligned cutoff may therefore retain data for less than one additional destination bucket, but compaction never deletes early. Treat `compactionBatchSize` as the target number of source records at which selection stops admitting new buckets, not as permission to split the current bucket: if the limit falls inside a bucket, include the remainder of that bucket and stop before the next bucket. A single oversized bucket is therefore processed atomically in one pass. Never write an aggregate from a prefix of a destination bucket.

For each admitted bucket, compute one deterministic aggregate and atomically commit its destination put with deletion of all exact source keys. An interruption before commit leaves all sources and no aggregate; an interruption after commit leaves the complete aggregate and no sources. On restart, scanning the same keys is therefore idempotent and preserves totals without a persisted partial merge. This plan intentionally chooses complete-bucket batching instead of partial aggregate state.

- [ ] **Step 5: Add an explicit query planner**

Define:

```swift
public struct TrafficQuerySegment: Equatable {
    public let level: TrafficAggregationLevel
    public let interval: DateInterval
}

public struct TrafficQueryPlan: Equatable {
    public let segments: [TrafficQuerySegment]
}
```

Plan disjoint half-open segments from oldest to newest using the coarsest tier required by retention availability and the finest tier available for recent data. Convert the UI's inclusive end to a half-open repository bound once, then concatenate segment results. Never append second records on top of a minute/hour result for the same timestamp.

Use yearly summaries only for complete calendar years requested as whole-year overview segments; use monthly summaries for partial old years. Use day records for recent ranges beyond hour retention. Preset and custom queries share this planner.

- [ ] **Step 6: Schedule maintenance outside UI reloads**

Have `TrafficAnalyticsCoordinator` request one bounded compaction pass after collection starts and then at a low-frequency maintenance interval. The coordinator passes current preferences into the policy. No AppKit view may invoke compaction, and manual display refresh must not alter collection or maintenance timers.

- [ ] **Step 7: Verify and commit**

Run:

```bash
xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:Tests/NetAnalyticsTests
xcodebuild build -project Stats.xcodeproj -target Net -configuration Debug CODE_SIGNING_ALLOWED=NO
git diff --check
git add Modules/Net/analytics/history.swift Modules/Net/analytics/aggregation.swift Modules/Net/analytics/queries.swift Modules/Net/analytics/rules.swift Modules/Net/analytics/coordinator.swift Modules/Net/settings.swift Tests/NetAnalytics.swift
git commit -m "feat(net): complete tiered traffic retention"
```

Expected: focused tests and the Net target build pass; exact totals remain stable before and after compaction.

### Task 4: Add A Network Registry, Aliases, And Per-Network Plans

**Files:**
- Create: `Modules/Net/analytics/network_registry.swift`
- Modify: `Modules/Net/analytics/models.swift`
- Modify: `Modules/Net/analytics/coordinator.swift`
- Modify: `Modules/Net/analytics/rules.swift`
- Modify: `Modules/Net/analytics/queries.swift`
- Modify: `Modules/Net/analytics/analysis_view.swift`
- Modify: `Modules/Net/analytics/overview_view.swift`
- Modify: `Modules/Net/settings.swift`
- Modify: `Stats/Supporting Files/en.lproj/Localizable.strings`
- Modify: `Stats/Supporting Files/zh-Hans.lproj/Localizable.strings`
- Modify: `Stats.xcodeproj/project.pbxproj`
- Modify: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Add failing registry and plan tests**

Add tests named:

```swift
func testNetworkRegistryUsesStableWiFiEthernetHotspotAndTunnelIDs()
func testWiFiRoamingAcrossBSSIDsKeepsOneCanonicalSSIDIdentity()
func testNetworkAliasSurvivesRediscoveryAndDoesNotChangeStoredSampleID()
func testNetworkPlansAreIndependentPerRegisteredNetwork()
func testConcreteNetworkFilterSelectsOnlyThatNetwork()
func testAllNetworksDeduplicatesTunnelAndPhysicalButConcreteFiltersDoNot()
func testOverviewUsesTheSelectedNetworksBillingPlan()
```

Use isolated `UserDefaults` suites. Rediscover the same normalized SSID on a new BSD interface and BSSID and assert the stable network ID and alias remain unchanged while both BSSIDs remain observed metadata. Save two different plans and verify editing one cannot overwrite the other.

- [ ] **Step 2: Verify RED**

Run the focused test command.

Expected: failures show there is only one global plan, no alias store, and queries filter only by `NetworkKind`.

- [ ] **Step 3: Implement stable network identity and registry persistence**

Create these public contracts in `network_registry.swift`:

```swift
public struct RegisteredNetwork: Codable, Equatable {
    public let identity: NetworkIdentity
    public var alias: String?
    public let firstSeen: Date
    public var lastSeen: Date
}

public final class NetworkRegistry {
    public func observe(_ identity: NetworkIdentity, at date: Date) -> RegisteredNetwork
    public func all() -> [RegisteredNetwork]
    public func setAlias(_ alias: String?, for networkID: String)
    public func displayName(for networkID: String) -> String
}
```

Generate IDs as follows:

- Wi-Fi: logical identity is the normalized SSID only; BSSIDs are observed metadata and never part of the canonical ID.
- Ethernet: stable hardware address when available; fall back to interface BSD name.
- Hotspot/cellular: normalized SSID/device label plus interface name.
- Tunnel/VPN: service identifier or scoped interface name.
- Other: interface BSD name.

Persist the first observed identity and user alias. Changing an alias changes presentation only; it never rewrites historical keys or sample IDs.

- [ ] **Step 4: Replace the global plan with a per-network plan map**

Persist `[String: NetworkPlan]` under `net.analytics.rules.v2.networkPlans`. On first load, migrate the old `net.analytics.rules.v1.networkPlan` into the currently observed network when one exists; otherwise retain it as an `all-networks-default` plan until a concrete network is selected. Expose:

```swift
func networkPlan(for networkID: String) -> NetworkPlan
func save(networkPlan: NetworkPlan, for networkID: String)
func allNetworkPlans() -> [String: NetworkPlan]
```

Keep billing day validation at 1 through 31 and calculate short-month cycle boundaries with `Calendar`, not by clamping all plans to day 28.

- [ ] **Step 5: Wire collection, queries, overview, and settings**

Observe each coordinator network update in `NetworkRegistry`. Change `TrafficAnalyticsQuery` to carry `networkID: String?` in addition to any kind-level grouping used by heatmap options. Populate the analysis network menu with `All networks`, then registered aliases/display names; select by ID. The overview displays the selected network's plan, usage, remainder, and forecast. Settings lists registered networks, supports alias editing, and edits billing day, byte limit, and thresholds for one selected network at a time.

- [ ] **Step 6: Localize and register the new source file**

Add exact English and Simplified Chinese strings for network aliases, observed networks, no observed networks, per-network plan, billing-cycle validation, and all-networks default. Add `network_registry.swift` to the Net target and test dependency through `Stats.xcodeproj/project.pbxproj`.

- [ ] **Step 7: Verify and commit**

Run focused tests, the full Stats test suite, and the unsigned Net target build. Then run:

```bash
git diff --check
git add Modules/Net/analytics/network_registry.swift Modules/Net/analytics/models.swift Modules/Net/analytics/coordinator.swift Modules/Net/analytics/rules.swift Modules/Net/analytics/queries.swift Modules/Net/analytics/analysis_view.swift Modules/Net/analytics/overview_view.swift Modules/Net/settings.swift 'Stats/Supporting Files/en.lproj/Localizable.strings' 'Stats/Supporting Files/zh-Hans.lproj/Localizable.strings' Stats.xcodeproj/project.pbxproj Tests/NetAnalytics.swift
git commit -m "feat(net): add per-network analytics plans"
```

Expected: registry, alias, plan migration, and concrete-filter tests pass without changing existing real-time interface selection.

### Task 5: Execute Quota Rules At Runtime With Honest Capability State

**Files:**
- Create: `Modules/Net/analytics/runtime_rules.swift`
- Modify: `Modules/Net/analytics/rules.swift`
- Modify: `Modules/Net/analytics/enforcement.swift`
- Modify: `Modules/Net/analytics/network_extension_enforcer.swift`
- Modify: `Modules/Net/analytics/coordinator.swift`
- Modify: `Modules/Net/analytics/application_detail.swift`
- Modify: `Modules/Net/settings.swift`
- Modify: `Stats/Supporting Files/en.lproj/Localizable.strings`
- Modify: `Stats/Supporting Files/zh-Hans.lproj/Localizable.strings`
- Modify: `Stats.xcodeproj/project.pbxproj`
- Modify: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Add failing runtime rule tests**

Add tests named:

```swift
func testRuntimeRulesEvaluateNetworkAndApplicationUsageAfterIngest()
func testRuntimeRulesResetThresholdsAtEachBillingBoundary()
func testNotifyRuleIsActiveWithoutNetworkExtensionEntitlement()
func testUnavailableRateLimitRuleSavesAsInactiveWithoutCallingEnforcer()
func testUnavailableBlockRuleHasNoActivationOrApplyControl()
func testShippingBuildCannotReportAvailableForPlaceholderNetworkExtensionEnforcer()
func testFailedCapableEnforcerNeverProducesAnAppliedState()
func testFailedOrPartialIngestTriggersNoQuotaEventAlertOrEnforcer()
func testPauseAndTemporaryAllowanceSuppressActionsUntilTheyExpire()
func testUploadAndDownloadRuntimeLimitsRemainIndependent()
```

Use a fake clock, repository, alert sink, and recording enforcer. Assert unavailable rate-limit/block rules remain persisted, report `.savedInactive(.missingEntitlement)`, make zero `apply` calls, and never report success. Instantiate the production `NetworkExtensionRuleEnforcer` under every shipping build configuration and assert it cannot report `.available` while its adapter is a placeholder/no-op. Assert notify-only rules still emit quota notifications after a committed ingest. Configure the repository fake to throw and to simulate a backend that attempted a partial write but returned failure; in both cases assert zero quota evaluations, zero alert/event persistence or delivery, and zero enforcer calls.

- [ ] **Step 2: Verify RED**

Run focused tests.

Expected: failures show rules are persisted but not evaluated by the coordinator, save currently attempts enforcement, and presentation has no explicit desired-versus-active state.

- [ ] **Step 3: Add runtime evaluation and activation state**

Create:

```swift
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
}
```

`TrafficRuntimeRuleService` queries usage for the affected application and network billing period after each committed ingest batch. Persist notification threshold state by rule ID plus cycle start so a new cycle resets naturally. Evaluate daily, weekly, monthly, and explicit custom date intervals with injected `Calendar` and clock.

- [ ] **Step 4: Separate saving from activation**

Saving always validates and persists the desired rule. Behavior then depends on action and capability:

- Notify: active immediately; no enforcer call.
- Rate limit or block with `.available`: an explicit enabled activation/apply control calls the enforcer and records active only after success.
- Rate limit or block with `.unavailable`: activation/apply controls are disabled or absent, saving makes no enforcer call, and the status reads `Rule saved but inactive: Network Extension entitlement is missing.`
- Enforcer failure: retain the saved desired rule, show failed/inactive status, and never show an active badge.

Do not add shell commands, privileged helpers, packet-filter rules, or any `pf` implementation. Modify `network_extension_enforcer.swift` to remove or disable the current compile-time branch whose no-op `apply` reports `.available`. No shipping build configuration may report `.available` until a functional entitlement-backed adapter exists and its apply result is verified; until then the production adapter is unavailable and throws without side effects. Keep the `NetworkRuleEnforcing` capability interface and unavailable behavior in the current target. A future entitlement-backed adapter may implement the interface, but creating an actual Network Extension target is out of scope until Apple grants the entitlement.

- [ ] **Step 5: Wire runtime rules into the coordinator**

Call the repository's throwing/result-returning `ingest` API first. Only the `.success(CommittedTrafficBatch)` branch may pass samples to `TrafficRuntimeRuleService` and the anomaly service; evaluate only scopes touched by that committed batch. Publish quota/anomaly events to their persistent alert sink and apply capable actions off the main thread only after that success gate. The `.failure` branch records diagnostics/status and returns without quota evaluation, threshold/cooldown mutation, alert-event creation or notification delivery, or enforcer calls. A store adapter that reports partial execution as failure is treated identically; no downstream side effect may infer success from attempted writes.

- [ ] **Step 6: Update application detail and settings controls**

Keep the save control enabled for valid future rules. Add a separate activation/apply control for rate-limit/block actions and make it unavailable when capability is missing. Show the saved desired values after reopening the detail page. The global over-quota action setting uses the same capability explanation and cannot imply that unavailable enforcement is active.

- [ ] **Step 7: Verify and commit**

Run focused and full tests, then the unsigned Debug build. Search the diff for prohibited fallback code:

```bash
rg -n "(/sbin/pfctl|pfctl|NetworkRuleEnforcing.*pf|PacketFilter)" Modules/Net Kit Tests || true
git diff --check
git add Modules/Net/analytics/runtime_rules.swift Modules/Net/analytics/rules.swift Modules/Net/analytics/enforcement.swift Modules/Net/analytics/network_extension_enforcer.swift Modules/Net/analytics/coordinator.swift Modules/Net/analytics/application_detail.swift Modules/Net/settings.swift 'Stats/Supporting Files/en.lproj/Localizable.strings' 'Stats/Supporting Files/zh-Hans.lproj/Localizable.strings' Stats.xcodeproj/project.pbxproj Tests/NetAnalytics.swift
git commit -m "feat(net): run quota rules with capability gating"
```

Expected: the search returns no fallback implementation, unavailable rules are saved but inactive, and no false success test can pass through an error path.

### Task 6: Run Anomaly Detection And Alert Delivery

**Files:**
- Modify: `Modules/Net/analytics/alerts.swift`
- Modify: `Modules/Net/analytics/coordinator.swift`
- Modify: `Modules/Net/analytics/history.swift`
- Modify: `Modules/Net/analytics/queries.swift`
- Modify: `Modules/Net/analytics/charts.swift`
- Modify: `Modules/Net/analytics/analysis_view.swift`
- Modify: `Modules/Net/notifications.swift`
- Modify: `Modules/Net/main.swift`
- Modify: `Stats/Supporting Files/en.lproj/Localizable.strings`
- Modify: `Stats/Supporting Files/zh-Hans.lproj/Localizable.strings`
- Modify: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Add failing runtime alert tests**

Add tests named:

```swift
func testSustainedUploadRequiresTheConfiguredWallClockDuration()
func testBaselineSpikeUsesPriorComparableBucketsAndRequiresEnoughHistory()
func testConnectivityRuntimeEmitsDisconnectRecoveryAndInstabilityEvents()
func testAlertCooldownDeduplicatesAcrossCoordinatorBatchesAndRestart()
func testAlertStorePersistsTimelineMetadataAndPrunesDeterministically()
func testTimelineSnapshotIncludesVisibleAlertMarkersOnly()
func testDisabledAlertPreferencesSkipEvaluationAndNotification()
```

Use fixed timestamps rather than sample counts. Seed prior comparable buckets excluding the current bucket. Restart the service against the same store and assert cooldown state prevents duplicate delivery.

- [ ] **Step 2: Verify RED**

Run focused tests.

Expected: failures show the detector is a standalone pure helper, uses average sample count instead of full wall-clock coverage, stores alerts only in a fixed UserDefaults list, and is not connected to collection, connectivity, notifications, or charts.

- [ ] **Step 3: Define persistent alert records and cooldowns**

Extend `TrafficAlertEvent` with severity, measured value, threshold/baseline, duration, and a stable de-duplication key. Persist events and cooldown state under repository-owned v2 alert prefixes so writes are ordered with analytics history access. Retain the newest 2,000 events and delete older events in bounded batches. `deleteTrafficHistory()` must leave alert events and cooldown/threshold state untouched; `clearAnalyticsData()` removes them together with traffic history while preserving preferences, aliases/plans, and saved rules.

- [ ] **Step 4: Correct anomaly evaluation**

For sustained upload, require samples spanning at least the configured duration and a time-weighted upload rate at or above the threshold. For baseline spikes, compare the current application/network bucket with prior same-hour-of-week buckets, require at least seven comparable buckets and `minimumBaselineBytes`, and exclude the current interval. For connectivity, emit one disconnect, one recovery, and one instability event after the configured repeated-disconnect threshold.

Apply a persisted cooldown per `(kind, applicationID, networkID, threshold configuration)` so repeated coordinator batches do not duplicate events. Changing threshold configuration creates a new cooldown key.

- [ ] **Step 5: Wire collection and connectivity runtime paths**

Run traffic anomaly evaluation only from the same successful `CommittedTrafficBatch` coordinator branch used by quota evaluation, and only when the preference is enabled. Failed or partial persistence must create no anomaly event, cooldown update, or notification. Feed connectivity transitions from `Network.connectivityCallback` to the same runtime alert service through their own explicit persistence result path. Deliver user notifications through the existing `Notifications` wrapper on the main thread only after event persistence succeeds; keep existing Network notifications intact.

- [ ] **Step 6: Surface alert history and timeline markers**

Add an alert-list button to Traffic Analysis with newest-first events, clear action, severity, application/network labels, and measured-versus-threshold detail. Add visible-range alert markers to `TrafficAnalyticsSnapshot` and render them in the line chart. Selecting a marker shows its details without changing the chart's selected interval.

- [ ] **Step 7: Verify and commit**

Run focused/full tests and the unsigned Debug build. Then run:

```bash
git diff --check
git add Modules/Net/analytics/alerts.swift Modules/Net/analytics/coordinator.swift Modules/Net/analytics/history.swift Modules/Net/analytics/queries.swift Modules/Net/analytics/charts.swift Modules/Net/analytics/analysis_view.swift Modules/Net/notifications.swift Modules/Net/main.swift 'Stats/Supporting Files/en.lproj/Localizable.strings' 'Stats/Supporting Files/zh-Hans.lproj/Localizable.strings' Tests/NetAnalytics.swift
git commit -m "feat(net): deliver runtime traffic alerts"
```

Expected: runtime events are persisted and visible exactly once per cooldown, while disabled alert preferences produce no event or notification.

### Task 7: Finish Export, Icons, Proxy Labels, And Analytics UI

**Files:**
- Create: `Modules/Net/analytics/icon_resolver.swift`
- Modify: `Modules/Net/analytics/models.swift`
- Modify: `Modules/Net/analytics/coordinator.swift`
- Modify: `Modules/Net/analytics/export.swift`
- Modify: `Modules/Net/analytics/application_table.swift`
- Modify: `Modules/Net/analytics/application_detail.swift`
- Modify: `Modules/Net/analytics/analysis_view.swift`
- Modify: `Modules/Net/analytics/overview_view.swift`
- Modify: `Modules/Net/analytics/charts.swift`
- Modify: `Modules/Net/settings.swift`
- Modify: `Stats/Supporting Files/en.lproj/Localizable.strings`
- Modify: `Stats/Supporting Files/zh-Hans.lproj/Localizable.strings`
- Modify: `Stats.xcodeproj/project.pbxproj`
- Modify: `Tests/NetAnalytics.swift`

- [ ] **Step 1: Add failing export, icon, proxy, and UI-state tests**

Add tests named:

```swift
func testExportV2IncludesSelectionNetworkAliasProcessesAlertsAndRouteContext()
func testExportTotalsMatchTheVisibleSnapshotForGroupedAndExpandedRows()
func testProxyRouteLabelDoesNotReassignBytesToAnotherApplication()
func testDirectTrafficWithSystemProxyConfiguredIsNotClaimedAsForwarded()
func testIconResolverUsesBundleExecutableAndDefaultFallbackOrder()
func testIconResolverCachesOffTheQueryPath()
func testChartOptionsAndGroupingPersistAcrossPreviewRecreation()
func testMinimumWidthKeepsRangeNetworkExportAndAlertControlsReachable()
```

Construct a snapshot with a concrete network alias, selected chart interval, direct traffic while system proxy settings are enabled, traffic observed on a known proxy/tunnel application or interface, child processes, and alert markers. Assert the direct row is labeled `System proxy configured` rather than claimed as forwarded, while only observed known proxy/tunnel context receives that label. Assert stable CSV columns and JSON schema version 2. Icon tests use a fake workspace provider and never depend on installed third-party apps.

- [ ] **Step 2: Verify RED**

Run focused tests.

Expected: failures show export schema v1 lacks process/selection/route/alert metadata, application rows have no icon resolver, route context is absent, and several UI choices are not persisted.

- [ ] **Step 3: Add route and proxy-forwarding metadata without false attribution**

Add:

```swift
public enum TrafficRouteKind: String, Codable {
    case direct
    case systemProxy
    case tunnel
}

public struct TrafficRouteContext: Codable, Equatable {
    public let kind: TrafficRouteKind
    public let proxyHost: String?
    public let proxyPort: Int?
}
```

Treat `CFNetworkCopySystemProxySettings` only as configuration metadata; it does not prove that a particular flow was forwarded and must not turn future samples into `.systemProxy`. Mark proxy/tunnel forwarding only when the collector observes a known proxy/tunnel application or interface for that sample. Otherwise keep the route direct and, when proxy settings are enabled, show the separate label `System proxy configured` with an explanation that per-flow proxy attribution is unavailable. A route label never moves bytes between application identities or claims to identify the originating client behind a local proxy. Existing v1 records decode as `.direct`.

- [ ] **Step 4: Implement deterministic icon lookup**

Add `ApplicationIconResolving` with an AppKit implementation that attempts bundle URL, executable path, running application, then `Constants.defaultProcessIcon`. Cache by application ID plus lookup metadata on a dedicated queue. Query and aggregation services transport icon metadata only; `NSImage` lookup happens in presentation controllers on the main thread after rows are built.

Render icons in application ranking, live active processes, overview top applications, and application detail. Child process rows use the owner icon unless they have their own resolved executable icon.

- [ ] **Step 5: Upgrade export to schema v2**

CSV and JSON include:

- export schema and timestamp;
- preset/custom range plus exact visible start/end and selected chart interval;
- concrete network ID, alias, kind, and interface metadata;
- route kind and proxy host/port when present;
- application name, bundle ID, executable path, process ID, and process name;
- download, upload, peak rate, total, and sample count;
- visible alert marker IDs/kinds/timestamps.

Generate export rows from the same immutable snapshot used by the table. Export application rows in grouped mode and process rows when process grouping/expansion export is selected. Sum exported traffic rows and assert they equal visible totals; metadata rows do not contribute bytes.

- [ ] **Step 6: Complete persisted UI options**

Add and persist chart options for download/upload series visibility, grouping by application versus process, local-network inclusion, proxy-label visibility, and alert-marker visibility. Keep range, custom selection, concrete network filter, refresh mode, chart mode, search, sort, and ranking synchronized through one `TrafficSelection` reload path.

At narrow width, wrap secondary controls into another row or place them in the existing More menu; range, network, export, alerts, and manual refresh remain reachable. Add empty/loading/error states with stable chart/card dimensions. Preserve the existing real-time page and live-traffic controls.

- [ ] **Step 7: Complete localization and accessibility**

Add every new visible string in English and Simplified Chinese. Give icon-only controls accessibility descriptions and tooltips. Verify table columns have localized headers and numeric values remain sortable independent of formatted text.

- [ ] **Step 8: Verify and commit**

Run focused/full tests and the unsigned Debug build. Then run:

```bash
git diff --check
git add Modules/Net/analytics/icon_resolver.swift Modules/Net/analytics/models.swift Modules/Net/analytics/coordinator.swift Modules/Net/analytics/export.swift Modules/Net/analytics/application_table.swift Modules/Net/analytics/application_detail.swift Modules/Net/analytics/analysis_view.swift Modules/Net/analytics/overview_view.swift Modules/Net/analytics/charts.swift Modules/Net/settings.swift 'Stats/Supporting Files/en.lproj/Localizable.strings' 'Stats/Supporting Files/zh-Hans.lproj/Localizable.strings' Stats.xcodeproj/project.pbxproj Tests/NetAnalytics.swift
git commit -m "feat(net): complete analytics export and presentation"
```

Expected: export totals match the visible snapshot, proxy labeling is descriptive rather than attributive, icon fallback is deterministic, and all essential controls remain reachable at minimum width.

### Task 8: Verify Bytetally Parity And Prepare Delivery

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-17-network-analytics-design.md` only to record a verified correction discovered during this task; do not broaden scope

- [ ] **Step 1: Run the complete automated verification**

Run:

```bash
xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:Tests/NetAnalyticsTests
xcodebuild test -project Stats.xcodeproj -scheme Stats -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Stats.xcodeproj -scheme Stats -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: focused and full tests pass, the unsigned Debug build reports `** BUILD SUCCEEDED **`, and diff check is empty. The three documented baseline warnings remain nonfatal; investigate any additional warning caused by the changed files.

- [ ] **Step 2: Verify retention and persistence with controlled time**

Using test fixtures or a Debug-only injected clock, write samples across all cutoffs, run bounded compaction until idle, quit, relaunch, and query the same intervals. Confirm second/minute/hour/day expiry at 24 hours and configured 7/60/730-day defaults, permanent month/year summaries, no byte loss, no duplicate bytes, and preserved network aliases/plans/alerts.

- [ ] **Step 3: Verify collection, quota, anomaly, and capability behavior manually**

Generate traffic on at least two applications and two observed networks. Confirm live rates update each second, manual display refresh does not pause collection, per-network quota forecasts differ, notify rules fire once per threshold, and sustained upload/connectivity events appear in notifications and the timeline.

On the unsigned build, save one rate-limit rule and one block rule. Confirm both reopen with their desired values, both read `saved but inactive`, activation/apply controls are unavailable, no active badge appears, and no system network configuration changes. Confirm notify-only rules remain operational.

- [ ] **Step 4: Verify Bytetally acceptance surfaces**

Check each acceptance-matrix item in the design spec:

- Monthly overview: anomaly status, current-period usage, quota remainder, forecast, seven-day average/total and trend, top applications, proxy-forwarded labels.
- History: presets/custom range, line/heatmap, concrete network filters, refresh modes, visible export, chart options, drag selection, alert markers, search, sorting, and interval-linked ranking.
- Live application traffic: all/single application, download/upload/total rate, 60-second/5-minute/15-minute windows, active-process ranking.
- Settings: application/process grouping, observed network aliases, global default and per-network plans, quota/anomaly alerts, application rules, capability status, 7/60/730 retention defaults, and CSV/JSON export.

Record a failure as an implementation defect and fix it in the owning task's files before continuing; do not waive a matrix row without an approved design change.

- [ ] **Step 5: Perform visual and accessibility verification**

Capture and inspect the Network preview at approximately 720x480 and 1440x900 in light and dark appearances, in English and Simplified Chinese. Check all three pages, empty/loading/error states, long aliases, long application names, large byte values, icon fallbacks, hover text, drag selection, heatmap selection, alert popover, application detail, settings, and unavailable enforcement.

Use Accessibility Inspector or VoiceOver to reach every segmented control, menu, icon button, table column, alert marker, rule status, and save/activation control. Confirm no essential control is clipped or reachable only by resizing wider.

- [ ] **Step 6: Verify export parity**

For one custom selected interval and concrete network, export CSV and JSON in application-grouped and process-grouped modes. Compare download/upload/total with the visible snapshot, confirm proxy and alert metadata, verify CSV quoting with commas/quotes/newlines, decode JSON schema v2, and confirm a failed write leaves selection and history unchanged.

- [ ] **Step 7: Update public documentation**

Update `README.md` with the completed local-first analytics surfaces, local history/reset behavior, configurable retention defaults, CSV/JSON export, network aliases/plans, and the Network Extension entitlement boundary. State plainly that unsigned builds can save future rate-limit/block rules but cannot activate them, and that Stats does not substitute `pf` rules.

Change the design spec in this milestone only if verification proved an existing statement inaccurate and the controller approves the correction. The retention and missing-entitlement contract is not optional.

- [ ] **Step 8: Inspect the final diff and commit delivery documentation**

Run:

```bash
git status --short
git diff --stat
git diff -- README.md docs/superpowers/specs/2026-07-17-network-analytics-design.md
git diff --check
git add README.md
git add docs/superpowers/specs/2026-07-17-network-analytics-design.md 2>/dev/null || true
git commit -m "docs(net): document completed analytics behavior"
```

Before committing, unstage the design spec if it has no approved verification correction. Expected: the documentation accurately describes implemented behavior and introduces no source changes.

- [ ] **Step 9: Final delivery review**

Run:

```bash
git status --short --branch
git log --oneline --decorate -10
```

Expected: a clean working tree on `codex/network-analytics`, with one focused commit per implementation milestone and the final documentation commit. Do not push; provide the controller the commit range, test/build results, visual verification notes, remaining baseline warnings, and any approved design deviations.

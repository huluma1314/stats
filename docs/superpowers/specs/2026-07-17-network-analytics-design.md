# Network Analytics Design

## Objective

Extend the existing Stats Network preview with persistent, per-application
traffic analytics while preserving the current real-time monitoring page. The
feature must remain local-first, work on Intel and Apple Silicon, and keep the
project's macOS 12 deployment target.

The reference screenshots define the information architecture and interactions,
but the implementation uses Stats' existing AppKit visual language and does not
copy third-party source code, branding, or assets.

## Bytetally Acceptance Matrix

The installed `/Applications/Bytetally.app` is the behavioral acceptance
reference. Verification on July 18, 2026 established these required surfaces:

- **Monthly overview:** anomaly status, current-month usage, quota remainder,
  month-end forecast, seven-day average/total, daily trend, highest-traffic apps,
  and proxy-forwarded traffic labeling.
- **History analysis:** preset and custom date ranges, line/heatmap modes,
  network filtering, refresh modes, visible-range export, chart options, drag
  zoom, alert markers, search, sorting, and ranking linked to the visible chart
  interval.
- **Live application traffic:** all-app or single-app focus, current download /
  upload / total rates, 60-second / 5-minute / 15-minute rolling windows, and a
  current-frame active-process ranking.
- **Settings:** appearance and menu-bar mode, application/process grouping,
  network identities and aliases, global and per-network quota plans, quota and
  anomaly alerts, application control rules, extension status, retention for
  minute/hour/day records, and CSV/JSON export.

Stats keeps its existing Network real-time diagnostics. The live application
traffic surface is added to that page so the original interface is preserved
while the Bytetally capability is available in the same Network preview.

## Product Structure

The existing Network item in the Stats settings window remains the only entry
point. Its preview becomes a three-page segmented interface:

1. **Real-time monitor** preserves the current `Modules/Net/preview.swift`
   content and behavior.
2. **Traffic analysis** contains range controls, line/heatmap modes, network
   filtering, refresh controls, download/upload/total summaries, an interactive
   timeline, and a searchable application ranking.
3. **Usage overview** contains current billing-period usage, quota status,
   projected usage, a seven-day trend, and the highest-traffic applications.

The pages remain inside the existing resizable settings window. They do not add
a menu-bar item or open another window. The layout supports light and dark mode,
English, and Simplified Chinese.

## Time And Refresh Controls

Traffic analysis supports these ranges: 10 minutes, 1 hour, today, 7 days,
30 days, and current month. Line and heatmap views use the same selected range
and network filter.

Heatmap buckets are adaptive:

- 10 minutes: 30 seconds per cell
- 1 hour: 5 minutes per cell
- Today: 1 hour per cell
- 7 days: weekday by hour
- 30 days and current month: 1 day per cell

Hovering a point or cell shows download, upload, and total bytes. Selecting a
chart interval filters the application ranking to the same interval. Selecting
a heatmap cell zooms the timeline and ranking to that cell.

The display refresh choices are manual, 5 seconds, 10 seconds, 30 seconds,
1 minute, and 5 minutes. They only control UI refresh. Background collection
continues at one-second resolution. In manual mode, the existing refresh button
reloads the visible data.

## Collection And Application Identity

The existing `UsageReader` remains the source of interface totals and current
bandwidth. The existing `ProcessReader` remains the basis for process totals,
but parsing, identity resolution, command execution, and sampling are separated
into testable components.

Production process collection runs `nettop` in connection-level CSV logging mode
without `-P`, because the per-process summary mode does not reliably expose an
interface for every process row. The command uses only supported flags (for
example `-L 1 -n -x` plus an explicit `-J`/`-j` selection containing
`interface`, `bytes_in`, and `bytes_out`), and the parser is header-driven rather
than depending on fixed column positions. Process summary rows establish the
owning PID/name and process-lifetime metadata; child socket/connection rows carry
the cumulative counters and observed interface used for attribution.

Each normalized connection observation retains the kernel process-start token,
a stable connection key composed from any supplied connection identifier plus
the normalized protocol/endpoints and interface (or a deterministic normalized
row fingerprint when no identifier is supplied), cumulative download/upload
counters, and the observed interface when available. Consecutive snapshots keep
prior counters by `(process lifetime, connection key, observed interface)`,
de-duplicate exact repeated observations in a snapshot, compute one non-negative
monotonic delta per connection, and then aggregate those deltas by
`(process lifetime, observed interface)`. Distinct connections on the same
interface are summed; a process summary is never added on top of its child
connection rows. A usable connection row whose interface is genuinely absent
retains `nil` attribution, as does a process-only fallback when no usable child
counters exist; neither receives a fabricated row interface.

Application identity follows these rules:

- Processes with a running macOS application are grouped by bundle identifier.
- Helper and child processes are grouped under their owning application when an
  owning bundle can be resolved.
- Processes without a bundle identifier are grouped by canonical executable
  path, with the process name as the fallback display name.
- Each raw record also carries a stable process discriminator composed from
  executable identity, process ID, and a real kernel process-start token from
  `proc_bsdinfo` start seconds/microseconds or an equivalent kernel source. The
  token propagates through reader metadata and `TrafficSample` into the raw v2
  key; PID, reader time, or a PID-derived synthetic token is insufficient. This
  prevents PID reuse after exit/relaunch from colliding with an earlier process;
  concurrent helpers remain distinct even when they share an owning app.
- Aggregate records intentionally discard that process discriminator and are
  keyed by network, owning application, and time bucket, so helpers merge into
  the correct application total.
- The stored identity includes display name, bundle identifier when available,
  executable path when available, icon lookup metadata, and child process data.
- Search matches display name, bundle identifier, and process name.

The default ranking shows one row per application. Expanding a row shows its
processes. Columns are download, upload, peak transfer rate, and total. Sorting
is available on every numeric column.

Collection starts when the enhanced build first runs with the Network module
enabled. Existing lifetime interface counters are displayed only in the
real-time page and are not backfilled into historical analytics.

## Network Scope And De-duplication

Filters include all networks, Wi-Fi, Ethernet, hotspot/cellular, and
VPN/tunnel. Local-network traffic is included by default and can be disabled in
settings.

Each sample records the interface observed on its connection-level `nettop` row.
The current primary network is used only for traffic that remains genuinely
unattributed after parsing and aggregation; it is not substituted for a missing
interface on one child row when another observation identifies that connection.
Physical and tunnel connection observations from the same snapshot remain
separate `(process lifetime, interface)` totals. Exact repeated connection rows
are canonicalized before delta calculation, and process summary counters are not
added to child connection counters, preventing duplicate counting within a
snapshot. The all-networks view then de-duplicates tunnel and physical-interface
accounting where the same transfer is visible at both layers. De-duplication uses
interface class and primary-route context; it never subtracts bytes from a single
application's monotonic process counters.

## Persistence And Retention

Historical data is stored locally through Stats' existing LevelDB wrapper. A
dedicated serial repository queue owns all database access. Version-2 raw keys
are ordered by schema version, aggregation level, timestamp, network identifier,
application identifier, and the stable process discriminator that includes the
process-start token. Aggregate keys end at network identifier plus application
identifier for a bucket, allowing every helper for that application to merge
without raw-key collisions while range queries remain prefix-based.

Retention is tiered:

- One-second samples for a fixed 24 hours
- One-minute aggregates for a configurable period, defaulting to 7 days
- One-hour aggregates for a configurable period, defaulting to 60 days
- One-day aggregates for a configurable period, defaulting to 730 days
- Monthly and yearly summaries without automatic expiry

The one-second period is not configurable. Settings expose the minute, hour, and
day periods and persist the selected values. Compaction is incremental and
bounded so it cannot block the UI or the network reader. A source record is
eligible only when its whole destination bucket ends at or before the cutoff;
non-aligned cutoffs may retain less than one destination bucket of slack, but
records are never deleted early. Each maintenance batch contains only complete
destination buckets. The batch size is a target: when the limit falls inside a
bucket, compaction finishes that bucket and admits no later bucket. Destination
replacement and deletion of all exact source keys commit atomically, so
interruption/restart cannot expose a partial aggregate or duplicate bytes.
Aggregation records preserve download, upload, peak rate, optional sample count,
application/network dimensions, and mergeable per-process summaries so process
export remains available after raw-to-minute and later compaction.
A legacy aggregate without a persisted sample count keeps that value unknown;
the decoder never invents a count of one.

The repository exposes separate destructive operations. `deleteTrafficHistory()`
removes traffic records only. `clearAnalyticsData()` removes traffic plus alert
events and cooldown/quota/anomaly threshold runtime state while preserving
retention and alert preferences, network aliases/plans, and saved rules. The
confirmed Settings reset invokes `clearAnalyticsData()`.

## Quotas, Forecasts, And Alerts

Users can define independent plans for network identities such as a Wi-Fi SSID
or hotspot. Wi-Fi canonical identity is the logical normalized SSID; BSSIDs are
observed roaming metadata only and do not split history, aliases, or plans. A plan
contains its billing-cycle day, byte limit, and notification thresholds. Defaults are the first day of the month and alerts at 80%, 90%, and
100%. Reaching a network quota never disconnects the network automatically.

Applications can have daily, weekly, monthly, or custom-period quotas. Their
over-limit action is notify, rate-limit, or block. Upload and download limits
are configured independently. Rules can be paused or temporarily allowed for
10 minutes or 1 hour.

The usage forecast extrapolates the current billing-period rate over the
remaining days and explicitly labels insufficient-data states. Alerts include:

- Network or application quota thresholds
- Sustained upload above a user-defined rate and duration
- A traffic spike relative to the application's historical baseline
- Network disconnect, recovery, or repeated instability

Alerts appear in the notification center view and as timeline markers. The
default action is notification only. Automatic enforcement occurs only for a
rule the user explicitly configures.

## Enforcement Capability Boundary

Per-application blocking and throttling are modeled behind a
`NetworkRuleEnforcing` interface. The standard build uses an unavailable
implementation that reports the missing Network Extension entitlement and
never claims a rule is active.

The current project defines only the capability interface and an unavailable
adapter that reports the missing entitlement. The compile-time placeholder branch
whose no-op apply path reports available is removed or disabled: no shipping build
may report enforcement available until a functional entitlement-backed adapter
exists and verifies apply success. A future entitlement-backed integration may
implement that interface after Apple grants the required Network Extension
entitlement, but adding an actual Network Extension target is out of scope until
the entitlement is available. When capability is missing,
users may still configure and save future rate-limit or block rules, but
activation and apply controls are unavailable. The UI clearly reports that the
rule is saved but inactive, never reports a successful apply, and never shows
the rule as active. Notify-only quota rules remain available because they do not
require enforcement capability. The project does not use `pf` address rules as
a substitute because those rules can affect unrelated applications sharing an
endpoint.

This boundary lets all analytics, quotas, forecasts, exports, notifications,
and alerts work without a paid Apple Developer account while keeping future
rate-limit and block enforcement ready for proper signing later.

## Proxy And Tunnel Semantics

System proxy configuration is configuration metadata, not evidence that a
particular flow was forwarded. Stats marks proxy/tunnel routing only when it
observes a known proxy/tunnel application or interface for that sample. Otherwise
the sample remains direct; when system proxy settings are enabled, presentation
uses the separate label `System proxy configured` and explains that per-flow
attribution is unavailable. Proxy labels never reassign bytes between
applications.

## Export

The export menu contains CSV and JSON. Export uses the active time range,
network filter, and chart selection. Both formats include interval metadata,
download/upload/total values, application name, bundle identifier, and process
identity where applicable. Export work runs off the main thread and reports
file-system errors without losing the current selection.

## Component Boundaries

The implementation is divided into these units:

- **Sampling:** execute bounded connection-level `nettop` snapshots without
  `-P`, parse process/connection hierarchy and interfaces, de-duplicate
  connection observations, resolve application identity, and emit normalized
  per-process-lifetime/interface deltas.
- **Repository:** atomically persist samples with a throwing/result-returning
  commit API, aggregate retention tiers, query ranges, and perform the two scoped
  deletion operations.
- **Analytics:** bucket time ranges, compute summaries, forecasts, rankings,
  heatmap intensity, and anomaly events.
- **Rules:** store quota and enforcement policies, evaluate thresholds, and
  call the capability-gated enforcer.
- **Presentation:** host the three AppKit pages, controls, charts, table, detail
  view, settings, alert list, and exports.

Readers never update AppKit views directly for the new analytics path. They
publish normalized samples to the repository. Only a fully successful atomic
commit returns a committed batch to the runtime coordinator; failed or partial
commits trigger no quota evaluation, threshold/cooldown update, alert-event
creation or notification, or enforcer call. The coordinator publishes
lightweight snapshots to the main-thread presentation layer. Existing real-time
callbacks remain unchanged to avoid regressions.

## Failure Handling

- Each connection-level `nettop` snapshot has a finite execution timeout and
  guaranteed child-process/pipe cleanup. Launch failure, timeout, empty output,
  or parse failure records diagnostics and retries with bounded, capped backoff;
  no failure path blocks indefinitely or spins, and the real-time interface
  reader continues independently.
- Malformed process or connection rows are skipped individually and counted for
  diagnostics; valid rows in the same snapshot still proceed.
- Database open or write failure disables history for the session, shows a
  non-blocking status, and retains real-time monitoring. Persistence reports
  success only for a fully committed atomic batch; failed or partial attempts
  have no quota, alert, cooldown/threshold, notification, or enforcement side
  effects.
- Interrupted aggregation is idempotent because compaction admits complete
  destination buckets only and atomically replaces each destination together
  with deletion of all exact source keys.
- Export failures leave the database and current UI state unchanged.
- Missing enforcement entitlement still permits saving future rate-limit and
  block rules, but activation and apply controls remain unavailable; the UI
  reports saved but inactive, with no false success state and no `pf` fallback.

## Testing And Acceptance

Unit tests cover process parsing, reader-to-repository PID reuse with distinct
kernel start tokens, connection-row de-duplication and monotonic deltas, per-row
physical/tunnel interface propagation, identity grouping, Wi-Fi roaming across
BSSIDs, multi-helper raw-key round trips across restart, monotonic counter resets,
legacy aggregates with unknown sample count, time bucketing across calendar
boundaries, non-aligned-now retention eligibility, complete-bucket batch limits
and interruption recovery, raw-to-minute process export, both scoped deletion
APIs, filtering, ranking, forecasts, quotas, anomalies, honest proxy labeling for
direct traffic with proxy configuration, and CSV/JSON encoding. Repository tests
use a temporary LevelDB directory and injected atomic write failures. Coordinator
tests prove failed or partial commits produce no quota/event/enforcer side
effects. Rule tests use a fake enforcer and verify that the unavailable production
enforcer and every shipping placeholder configuration cannot report success or
availability.

Integration verification covers:

- The production command builder invokes connection-level `nettop` without `-P`
  and its real parser consumes representative CSV containing process parents,
  repeated connection rows, unavailable interface attribution, and simultaneous
  physical/tunnel observations. The resulting deltas are counted once per
  connection and aggregated by process lifetime and interface; a timeout/failure
  fixture proves command cleanup and retry backoff stay bounded.
- Existing Stats tests remain green.
- Debug builds succeed with Xcode 26.4.1 (build 17E202) and the macOS 12 target intact.
- Network preview callbacks still update the existing real-time page.
- History survives application restart and totals match exported data.
- Manual display refresh does not pause collection.
- Range, network, chart selection, and application ranking stay synchronized.
- The UI remains usable at the minimum settings-window size and at a wide
  desktop size in light and dark appearances.
- Intel and Apple Silicon code paths compile without architecture-specific
  assumptions.

## Delivery Sequence

Work is delivered in independently testable milestones:

1. Sampling models, parser, repository, retention, analytics, and tests.
2. Three-page host with the existing real-time page preserved.
3. Traffic-analysis controls, charts, heatmap, ranking, and export.
4. Usage overview, plans, forecasts, alerts, and settings.
5. Application detail, rule storage, and entitlement-gated enforcement UI.
6. Localization, appearance verification, performance checks, and public fork
   documentation.

No milestone introduces a paid subscription or Pro feature gate.
